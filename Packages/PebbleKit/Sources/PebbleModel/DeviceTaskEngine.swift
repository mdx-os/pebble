import Foundation
import PebbleCore

/// The app's real task engine. It runs only with a model on this device,
/// reads and writes nothing but the person's notes and its own file, and
/// never reaches the network.
///
/// It does one built-in task, `DigestTask`: it reads the notes from the
/// past week, writes a short digest, and asks through `AskFirst` before it
/// keeps the digest as a new note. Nothing is saved without that yes.
///
/// Its tasks are kept in a file next to the notes, so they come back after
/// the app closes. A task that was still going comes back stopped, with a
/// line that says so, never as finished. One that had a yes and was saving
/// when the app closed comes back saying the save may be done.
///
/// No note's words are ever in this engine's file. The file keeps only
/// which note the digest became and which notes it drew from, and a card
/// reads the words from the notes, held in memory only until the notes
/// change. Forgetting the digest note takes the words off the card, and
/// `forgetQuotes(of:)` takes a forgotten note's line out of the digest
/// note itself.
///
/// Made only by `OnDeviceTasks.engine(model:notes:)`, from an
/// `OnDeviceTasks.Key` that only it can make, so the place is read from the
/// model and the compiler, not a test, keeps it from being written by hand.
///
/// Steps move on with `runPending()`. With a `pace`, the engine calls it
/// itself while work is waiting; without one, the caller does, so tests
/// never sleep.
public final class DeviceTaskEngine: TaskEngine, @unchecked Sendable {
    /// Where a task is in its work.
    enum Stage: String, Codable, Equatable {
        case reading, picking, writing
        /// At the question, before `AskFirst` has been asked.
        case toAsk
        /// `AskFirst` is being asked, outside the lock.
        case asking
        /// Waiting for the person's yes.
        case waiting
        /// The person said yes and the note is being written.
        case saving
        case ended
    }

    private struct Run {
        var task: AgentTask
        var stage: Stage
        /// This week's notes, once read. Never written to the task file.
        var notes: [MemoryNote] = []
        /// The digest, once written, until it is kept or let go. Never
        /// written to the task file.
        var digest: String?
        var question: ConfirmationRequest?
        /// The note the digest was kept as.
        var kept: UUID?
        /// The notes the digest was written from.
        var drewFrom: [UUID] = []
        /// The notes with a line in the digest, in the order of their
        /// lines, and the notes its last line counts. Nil for a digest kept
        /// before these were written down.
        var quoted: [UUID]?
        var more: [UUID]?

        /// Which notes it points at, so the file is written when only
        /// these change.
        var links: [[UUID]?] { [kept.map { [$0] }, drewFrom, quoted, more] }
    }

    /// The notes as cards last read them: every note's id, and the words
    /// of each kept digest. Read again after `refresh()` or any change to
    /// the notes, and let go by `clear()`.
    private enum Seen {
        case unread
        case unavailable
        case read(ids: Set<UUID>, digests: [UUID: String])
    }

    private struct PendingAsk {
        let id: String
        let action: ProposedAction
    }

    public let rule: AskFirst
    /// From the model, through `OnDeviceTasks.Key`. The engine does nothing
    /// unless it says every word stays here.
    public let place: PrivacyPlace
    /// The notes it reads, and the only place it ever writes a note.
    public let notes: MemoryStore
    /// Its own file, next to the notes.
    public let fileURL: URL
    private let pace: Duration?
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var runs: [Run] = []
    private var observers: [UUID: @Sendable (TaskSnapshot) -> Void] = [:]
    private var sequence = 0
    /// The tasks as observers last heard them.
    private var published: [AgentTask] = []
    private var withdrawals: [ConfirmationRequest] = []
    private var driving = false
    /// False while the file was there but couldn't be opened, as when the
    /// device is locked at launch. Nothing is written over it until it has
    /// been read.
    private var loaded = false
    /// True when a change came while the file was unread, so it is written
    /// once it has been.
    private var unsaved = false
    private var seen = Seen.unread
    private var watchingNotes: TaskObservation?

    /// Ended tasks kept at most, like `LocalFakeEngine.endedLimit`.
    public static let endedLimit = 12

    init(key: OnDeviceTasks.Key, notes: MemoryStore, fileURL: URL, rule: AskFirst,
         pace: Duration?, clock: @escaping @Sendable () -> Date) {
        self.place = key.place
        self.notes = notes
        self.fileURL = fileURL
        self.rule = rule
        self.pace = pace
        self.clock = clock
        lock.lock()
        loadFile()
        published = shown()
        lock.unlock()
        // Any writer's change to the notes, not only the memory screen's,
        // so a card never shows words that have changed or gone.
        watchingNotes = notes.observeChanges { [weak self] in self?.notesChanged() }
    }

    private func notesChanged() {
        mutate { seen = .unread }
    }

    /// The task file sits next to the notes file, so it is in the same
    /// folder, left out of backups, and erased the same way.
    public static func fileURL(besides notes: MemoryStore) -> URL {
        notes.fileURL.deletingLastPathComponent().appendingPathComponent("tasks.json")
    }

    /// What this engine can do, for Today to offer.
    public var builtIns: [TaskRequest] { [DigestTask.request] }

    public var tasks: [AgentTask] {
        lock.lock(); defer { lock.unlock() }
        return shown()
    }

    /// True while the task file is on disk, readable or not, so Forget
    /// everything is offered while there is anything to erase.
    public var hasStoredFile: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
            || FileManager.default.fileExists(atPath: stagingURL.path)
    }

    @discardableResult
    public func start(_ request: TaskRequest) -> String {
        let id = mutate { () -> String in
            // One digest at a time: asking again shows the one going.
            if let going = runs.first(where: { $0.task.title == request.title && $0.task.isActive }) {
                return going.task.id
            }
            let id = "device-task:\(UUID().uuidString)"
            let now = clock()
            var task = AgentTask(id: id, title: request.title, step: DigestWords.reading,
                                 progress: .fraction(0), startedAt: now)
            var stage = Stage.reading
            if request.title != DigestTask.title {
                task.state = .failed
                task.step = DigestWords.cantDoThatYet
                stage = .ended
            } else if !place.staysOnDevice {
                // Never with a model that may send words away.
                task.state = .failed
                task.step = TaskWords.failed
                task.wrapUp = TaskWrapUp(kept: [], notDone: DigestTask.todos)
                stage = .ended
            }
            runs.append(Run(task: task, stage: stage))
            return id
        }
        drive()
        return id
    }

    public func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        let key = UUID()
        lock.lock()
        observers[key] = onChange
        let snapshot = TaskSnapshot(sequence: sequence, tasks: shown())
        lock.unlock()
        onChange(snapshot)
        return TaskObservation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[key] = nil
            self.lock.unlock()
        }
    }

    /// Does the next step of every task that has one waiting. True while
    /// any task still has a step to do on its own.
    @discardableResult
    public func runPending() -> Bool {
        mutate {
            for index in runs.indices { step(&runs[index]) }
            return runs.contains { [.reading, .picking, .writing].contains($0.stage) }
        }
    }

    /// The person can't steer a digest yet, so the words are kept in its
    /// history and it says so plainly. A question waiting for a yes is
    /// withdrawn and the digest is not kept, since it was asked before the
    /// person changed course.
    @discardableResult
    public func redirect(_ id: String, with instructions: String) -> Bool {
        let words = instructions.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !words.isEmpty else { return false }
        let said = words.count > LocalFakeEngine.maxInstructionLength
            ? String(words.prefix(LocalFakeEngine.maxInstructionLength)) + "..." : words
        return mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), runs[index].task.isActive else { return false }
            let now = clock()
            runs[index].task.record(TaskStep(TaskWords.youSaid(said), mark: .redirected, at: now))
            switch runs[index].stage {
            case .saving:
                runs[index].task.step = TaskWords.finishingApproved
                runs[index].task.updatedAt = now
            case .toAsk, .asking, .waiting:
                withdrawQuestion(&runs[index])
                endWithoutSaving(&runs[index], line: TaskWords.changedCourse(DigestTask.saveTodo))
            default:
                runs[index].task.step = DigestWords.cantSteer
                runs[index].task.updatedAt = now
            }
            return true
        }
    }

    @discardableResult
    public func stop(_ id: String) -> Bool {
        mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), runs[index].task.isActive else { return false }
            withdrawQuestion(&runs[index])
            let saving = runs[index].stage == .saving
            end(&runs[index], as: .stopped, line: TaskWords.stopped,
                wrapUp: TaskWrapUp(kept: [], notDone: saving ? [] : [DigestTask.saveTodo],
                                   underway: saving ? DigestTask.saveTodo : nil))
            return true
        }
    }

    @discardableResult
    public func dismiss(_ id: String) -> Bool {
        mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), !runs[index].task.isActive else { return false }
            runs.remove(at: index)
            return true
        }
    }

    /// Stops and forgets every task, and erases the task file. If the file
    /// can't be erased, `ClearedTasks.erased` says so, and the tasks are
    /// still gone from the screen.
    @discardableResult
    public func clear() -> ClearedTasks {
        mutate {
            for index in runs.indices { withdrawQuestion(&runs[index]) }
            let underway = runs.filter { $0.stage == .saving }.count
            let forgotten = runs.count
            runs.removeAll()
            seen = .unread
            // A file left unread, as on a locked device, goes too.
            loaded = true
            unsaved = false
            let erased = (try? removeFile()) != nil
            return ClearedTasks(forgotten: forgotten, underway: underway, erased: erased)
        }
    }

    /// A digest never gets stuck, so there is nothing to try again.
    @discardableResult
    public func retry(_ id: String) -> Bool { false }

    public func resume(_ id: String, with approval: Approval) -> TaskApproval {
        lock.lock()
        let asked = runs.first { $0.task.id == id && $0.stage == .waiting }?.question
        lock.unlock()
        guard let asked, asked.id == approval.id else { return .refused }
        let verdict = rule.verdict(asked.action, approval: approval)
        let digest: String? = mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }),
                  runs[index].stage == .waiting, runs[index].question == asked else { return nil }
            switch verdict {
            case .proceed:
                let now = clock()
                runs[index].task.record(TaskStep(TaskWords.youSaidYes, mark: .approved, at: now))
                runs[index].question = nil
                runs[index].task.question = nil
                runs[index].task.state = .running
                runs[index].task.step = DigestWords.saving
                runs[index].task.updatedAt = now
                // Written to the file before the note is, so if the app
                // closes now the task comes back saying it may be done.
                runs[index].stage = .saving
                return runs[index].digest
            case .timedOut:
                runs[index].question = nil
                endWithoutSaving(&runs[index], line: TaskWords.timedOut(DigestTask.saveTodo))
                return nil
            case .stop:
                return nil
            }
        }
        guard verdict == .proceed else { return verdict == .timedOut ? .timedOut : .refused }
        guard let digest else { return .refused }
        // The only write to the notes, after a yes `AskFirst` honored, and
        // outside this engine's lock. Each line already names where its
        // note came from, and the digest itself is the agent's own work.
        // The same digest kept before, as when it runs twice in a week
        // with no new notes, is not kept twice: the card points at it.
        let saved: (kept: UUID?, line: String)
        switch try? notes.rememberOnce(digest, at: clock(), source: .inferred) {
        case (.saved(let note), let isNew)?: saved = (note.id, isNew ? DigestWords.done : DigestWords.alreadyKept)
        case (.tooLong, _)?: saved = (nil, DigestWords.tooLongToKeep)
        case (.needsWords, _)?: saved = (nil, DigestWords.emptyDigest)
        case (.notFound, _)?, nil: saved = (nil, DigestWords.couldNotSave)
        }
        mutate {
            guard let index = runs.firstIndex(where: { $0.task.id == id }), runs[index].stage == .saving else { return }
            if let kept = saved.kept {
                end(&runs[index], as: .done, line: saved.line, wrapUp: nil)
                // Only which note, never its words: the card reads them
                // from the notes, so forgetting the note takes them away.
                runs[index].kept = kept
                runs[index].task.progress = .fraction(1)
            } else {
                end(&runs[index], as: .failed, line: saved.line,
                    wrapUp: TaskWrapUp(kept: [], notDone: [DigestTask.saveTodo]))
            }
            seen = .unread
        }
        return .proceeding
    }

    /// Takes a forgotten note's words out of every kept digest that quoted
    /// it: its line goes and the count of the rest stays right, and a
    /// digest left with no line is removed. A digest the person changed is
    /// left as they made it, and if it still seems to hold the words, this
    /// says so rather than call them gone. Only ever takes words away.
    public func forgetQuotes(of note: MemoryNote) -> QuotesForgotten {
        lock.lock()
        // Each digest note once, though two tasks may point at it.
        var quoting: [UUID: DigestTask.Written?] = [:]
        for run in runs where run.drewFrom.contains(note.id) {
            guard let kept = run.kept, quoting[kept] == nil else { continue }
            quoting[kept] = run.quoted.map { DigestTask.Written(text: "", quoted: $0, more: run.more ?? []) }
        }
        lock.unlock()
        guard !quoting.isEmpty else { return .notQuoted }
        guard case .notes(let all) = notes.contents() else { return .stayed }
        // Written outside this engine's lock, since each write tells it the
        // notes changed. What each cleared digest's lines are now; nil
        // inside when the digest note is gone.
        var cleared: [UUID: DigestTask.Written?] = [:]
        var stayed = false
        for (kept, written) in quoting {
            guard let digest = all.first(where: { $0.id == kept }) else {
                cleared[kept] = .some(nil)
                continue
            }
            switch DigestTask.dropping(note, from: digest.text, as: written) {
            case .edited(let next):
                if case .saved? = try? notes.edit(kept, to: next.text) { cleared[kept] = next } else { stayed = true }
            case .emptied:
                if (try? notes.forget(kept)) != nil { cleared[kept] = .some(nil) } else { stayed = true }
            case .notThere:
                cleared[kept] = written
            case .cantTell:
                stayed = true
            }
        }
        mutate {
            for index in runs.indices {
                guard let kept = runs[index].kept, let next = cleared[kept] else { continue }
                runs[index].drewFrom.removeAll { $0 == note.id }
                if let next {
                    runs[index].quoted = next.quoted
                    runs[index].more = next.more
                }
            }
            seen = .unread
        }
        return stayed ? .stayed : .forgotten
    }

    public func questionClosed(_ request: ConfirmationRequest) {
        let ranOut = rule.isClosed(request) && !rule.wasWithdrawn(request)
        mutate {
            guard let index = runs.firstIndex(where: { $0.stage == .waiting && $0.question == request }) else { return }
            withdrawals.append(request)
            runs[index].question = nil
            endWithoutSaving(&runs[index], line: ranOut ? TaskWords.timedOut(DigestTask.saveTodo)
                                                         : TaskWords.declined(DigestTask.saveTodo))
        }
    }

    /// Settles questions that closed, reads a file left unread at launch,
    /// and tells observers if a kept digest's words changed in the notes.
    public func refresh() {
        lock.lock()
        let open = runs.compactMap { $0.stage == .waiting ? $0.question : nil }
        lock.unlock()
        let closed = open.filter { rule.isClosed($0) }.map { ($0, rule.wasWithdrawn($0)) }
        mutate {
            if !loaded { loadFile() }
            seen = .unread
            for (request, withdrawn) in closed {
                guard let index = runs.firstIndex(where: { $0.stage == .waiting && $0.question == request }) else { continue }
                runs[index].question = nil
                endWithoutSaving(&runs[index], line: withdrawn ? TaskWords.declined(DigestTask.saveTodo)
                                                               : TaskWords.timedOut(DigestTask.saveTodo))
            }
        }
    }

    // MARK: Steps. Everything below runs inside the lock.

    /// The tasks as their cards show them, newest first. A kept digest's
    /// words are read from the notes once until they change, and shown
    /// only while the digest note and every note it drew from are still
    /// there. When they aren't shown, the card's line says why.
    private func shown() -> [AgentTask] {
        if case .unread = seen, runs.contains(where: { $0.kept != nil }) { seen = readNotes() }
        return runs.reversed().map { run in
            var task = run.task
            guard let kept = run.kept else { return task }
            switch seen {
            case .unread, .unavailable:
                task.step = DigestWords.notesLocked
            case .read(let ids, let digests):
                if let text = digests[kept] {
                    if run.drewFrom.allSatisfy(ids.contains) { task.result = text } else { task.step = DigestWords.hiddenQuote }
                } else {
                    task.step = DigestWords.removed
                }
            }
            return task
        }
    }

    /// Every note's id, and the words of the digests kept.
    private func readNotes() -> Seen {
        guard case .notes(let all) = notes.contents() else { return .unavailable }
        let kept = Set(runs.compactMap(\.kept))
        let digests = Dictionary(all.filter { kept.contains($0.id) }.map { ($0.id, $0.text) },
                                 uniquingKeysWith: { first, _ in first })
        return .read(ids: Set(all.map(\.id)), digests: digests)
    }

    private func step(_ run: inout Run) {
        let now = clock()
        switch run.stage {
        case .reading:
            switch notes.contents() {
            case .notes(let all):
                run.notes = all
                run.task.record(TaskStep(DigestWords.reading, mark: .done, at: now))
                run.stage = .picking
                run.task.step = DigestWords.picking
                run.task.progress = .fraction(0.25)
                run.task.updatedAt = now
            case .unavailable, .unreadable:
                end(&run, as: .failed, line: DigestWords.couldNotRead,
                    wrapUp: TaskWrapUp(kept: [], notDone: DigestTask.todos))
            }
        case .picking:
            run.notes = DigestTask.thisWeek(run.notes, now: now)
            run.task.record(TaskStep(DigestWords.picking, mark: .done, at: now))
            if run.notes.isEmpty {
                end(&run, as: .done, line: DigestWords.nothingThisWeek, wrapUp: nil)
                run.task.progress = .fraction(1)
                return
            }
            run.stage = .writing
            run.task.step = DigestWords.writing
            run.task.progress = .fraction(0.5)
            run.task.updatedAt = now
        case .writing:
            let written = DigestTask.write(run.notes, now: now)
            run.digest = written.text
            run.drewFrom = run.notes.map(\.id)
            run.quoted = written.quoted
            run.more = written.more
            run.notes = []
            run.task.record(TaskStep(DigestWords.writing, mark: .done, at: now))
            run.task.progress = .fraction(0.75)
            run.stage = .toAsk
        case .toAsk, .asking, .waiting, .saving, .ended:
            break
        }
    }

    /// Ends a task whose digest was not kept. The draft goes with it.
    private func endWithoutSaving(_ run: inout Run, line: String) {
        run.task.record(TaskStep(line, mark: .skipped, at: clock()))
        end(&run, as: .done, line: line, wrapUp: TaskWrapUp(kept: [], notDone: [DigestTask.saveTodo]))
    }

    private func end(_ run: inout Run, as state: TaskState, line: String, wrapUp: TaskWrapUp?) {
        run.stage = .ended
        run.notes = []
        run.digest = nil
        run.question = nil
        run.task.state = state
        run.task.step = line
        run.task.question = nil
        run.task.wrapUp = wrapUp
        run.task.updatedAt = clock()
    }

    private func withdrawQuestion(_ run: inout Run) {
        if let question = run.question { withdrawals.append(question) }
        run.question = nil
        run.task.question = nil
    }

    private func takeRuleWork() -> (withdrawals: [ConfirmationRequest], asks: [PendingAsk]) {
        let out = withdrawals
        withdrawals = []
        var asks: [PendingAsk] = []
        for index in runs.indices where runs[index].stage == .toAsk {
            guard let digest = runs[index].digest else { continue }
            runs[index].stage = .asking
            asks.append(PendingAsk(id: runs[index].task.id, action: DigestTask.keep(digest)))
        }
        return (out, asks)
    }

    private func asked(_ ask: PendingAsk, _ request: ConfirmationRequest?) {
        guard let index = runs.firstIndex(where: { $0.task.id == ask.id }), runs[index].stage == .asking else {
            if let request { withdrawals.append(request) }
            return
        }
        guard let request else {
            endWithoutSaving(&runs[index], line: TaskWords.couldNotAsk(DigestTask.saveTodo))
            return
        }
        runs[index].stage = .waiting
        runs[index].question = request
        runs[index].task.question = request
        runs[index].task.state = .waitingOnYou
        runs[index].task.step = DigestWords.askLine
        runs[index].task.updatedAt = clock()
    }

    /// Runs a change inside the lock, asks and withdraws outside it, keeps
    /// the file in step, then tells observers once. A question whose task
    /// went in the change is withdrawn, so no sheet is left open with
    /// nothing behind it.
    private func mutate<T>(_ change: () -> T) -> T {
        lock.lock()
        let before = runs.map(\.task)
        let stagesBefore = runs.map(\.stage)
        let linksBefore = runs.map(\.links)
        let questionsBefore = runs.compactMap { run in run.question.map { (run.task.id, $0) } }
        let value = change()
        let ids = Set(runs.map(\.task.id))
        for (id, question) in questionsBefore where !ids.contains(id) && !withdrawals.contains(question) {
            withdrawals.append(question)
        }
        var work = takeRuleWork()
        lock.unlock()
        while !work.withdrawals.isEmpty || !work.asks.isEmpty {
            for request in work.withdrawals { rule.withdraw(request) }
            let answers = work.asks.map { ask in (ask, rule.ask(ask.action)) }
            lock.lock()
            for (ask, request) in answers { asked(ask, request) }
            work = takeRuleWork()
            lock.unlock()
        }
        lock.lock()
        dropOldEnded()
        if unsaved || before != runs.map(\.task) || stagesBefore != runs.map(\.stage) || linksBefore != runs.map(\.links) {
            saveFile()
        }
        let after = shown()
        let changed = after != published
        if changed {
            sequence += 1
            published = after
        }
        let snapshot = TaskSnapshot(sequence: sequence, tasks: after)
        let listeners = changed ? Array(observers.values) : []
        lock.unlock()
        for listener in listeners { listener(snapshot) }
        return value
    }

    private func dropOldEnded() {
        let ended = runs.indices.filter { !runs[$0].task.isActive }
        guard ended.count > Self.endedLimit else { return }
        for index in ended.prefix(ended.count - Self.endedLimit).reversed() { runs.remove(at: index) }
    }

    /// Moves steps along on its own while any are waiting, one at a time
    /// at `pace`, so a card can be read as it goes. Stops once none are.
    private func drive() {
        guard let pace else { return }
        lock.lock()
        let already = driving
        driving = true
        lock.unlock()
        guard !already else { return }
        Task.detached { [weak self] in
            while true {
                try? await Task.sleep(for: pace)
                guard let self, self.keepsDriving() else { return }
            }
        }
    }

    /// One step for every task, then whether to go on. Stops only when no
    /// step waits, checked under the lock, so a task started meanwhile is
    /// never left without a driver.
    private func keepsDriving() -> Bool {
        runPending()
        lock.lock()
        defer { lock.unlock() }
        let more = runs.contains { [.reading, .picking, .writing].contains($0.stage) }
        if !more { driving = false }
        return more
    }

    // MARK: The task file

    var stagingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".next")
    }

    /// Reads the file. A task that was still going when the app closed
    /// comes back stopped, and says so. Read late, as once a locked device
    /// opens, the tasks it holds join any started since, which stay as
    /// they are.
    private func loadFile() {
        let manager = FileManager.default
        try? manager.removeItem(at: stagingURL)
        guard manager.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }
        // Can't be opened right now: leave it, and look again on refresh.
        guard let data = try? Data(contentsOf: fileURL) else { return }
        loaded = true
        // Unreadable: start with none. The file is replaced on the next
        // change, or erased by Forget everything.
        guard let stored = try? Self.decoder.decode([StoredTask].self, from: data) else { return }
        let going = Set(runs.map(\.task.id))
        let back = stored.filter { !going.contains($0.id) }.map { stored in
            Run(task: stored.restored(at: clock()), stage: .ended, kept: stored.kept, drewFrom: stored.drewFrom ?? [],
                quoted: stored.quoted, more: stored.more)
        }
        runs = back + runs
    }

    /// Writes every task, or removes the file once there are none. Only
    /// what the card shows is kept, and never a note's words: not the
    /// notes read, not a draft, and not a digest once kept.
    private func saveFile() {
        guard loaded else {
            unsaved = true
            return
        }
        unsaved = false
        if runs.isEmpty {
            try? removeFile()
            return
        }
        let stored = runs.map {
            StoredTask($0.task, saving: $0.stage == .saving, kept: $0.kept, drewFrom: $0.drewFrom,
                       quoted: $0.quoted, more: $0.more)
        }
        guard let data = try? Self.encoder.encode(stored) else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: stagingURL)
        #if os(macOS)
        let options: Data.WritingOptions = [.withoutOverwriting]
        #else
        let options: Data.WritingOptions = [.withoutOverwriting, .completeFileProtection]
        #endif
        guard (try? data.write(to: stagingURL, options: options)) != nil else { return }
        if rename(stagingURL.path, fileURL.path) != 0 { try? manager.removeItem(at: stagingURL) }
    }

    private func removeFile() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: stagingURL.path) { try manager.removeItem(at: stagingURL) }
        if manager.fileExists(atPath: fileURL.path) { try manager.removeItem(at: fileURL) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// A task as the file keeps it: what its card shows, whether a save the
/// person said yes to was under way, and for a kept digest, which notes
/// to read its words from. Never a note's words.
struct StoredTask: Codable, Equatable {
    struct Step: Codable, Equatable {
        let text: String
        let mark: String
        let at: Date
    }

    struct WrapUp: Codable, Equatable {
        let kept: [String]
        let notDone: [String]
        let underway: String?
    }

    let id: String
    let title: String
    let step: String
    let state: String
    let history: [Step]
    let wrapUp: WrapUp?
    let startedAt: Date
    let updatedAt: Date
    /// The person said yes and the note was being written.
    let saving: Bool
    /// The note the digest was kept as.
    let kept: UUID?
    /// The notes a kept digest drew from.
    let drewFrom: [UUID]?
    /// The notes with a line in a kept digest, in order, and those its
    /// last line counts, so a forgotten note's line can be taken out.
    let quoted: [UUID]?
    let more: [UUID]?

    init(_ task: AgentTask, saving: Bool, kept: UUID? = nil, drewFrom: [UUID] = [], quoted: [UUID]? = nil,
         more: [UUID]? = nil) {
        id = task.id
        title = task.title
        step = task.step
        state = task.state.rawValue
        history = task.history.map { Step(text: $0.text, mark: $0.mark.rawValue, at: $0.at) }
        wrapUp = task.wrapUp.map { WrapUp(kept: $0.kept, notDone: $0.notDone, underway: $0.underway) }
        startedAt = task.startedAt
        updatedAt = task.updatedAt
        self.saving = saving
        self.kept = kept
        self.drewFrom = kept == nil ? nil : drewFrom
        self.quoted = kept == nil ? nil : quoted
        self.more = kept == nil ? nil : more
    }

    /// The task as it comes back after the app closed. One that ended
    /// comes back as it was, full only if it was done. One that was still
    /// going comes back stopped, never done, and a save said yes to may be
    /// done.
    func restored(at now: Date) -> AgentTask {
        let steps = history.map { TaskStep($0.text, mark: TaskStep.Mark(rawValue: $0.mark) ?? .done, at: $0.at) }
        let state = TaskState(rawValue: self.state) ?? .stopped
        guard !state.isFinished else {
            return AgentTask(id: id, title: title, step: step, progress: state == .done ? .fraction(1) : .indeterminate,
                             state: state, history: steps,
                             wrapUp: wrapUp.map { TaskWrapUp(kept: $0.kept, notDone: $0.notDone, underway: $0.underway) },
                             startedAt: startedAt, updatedAt: updatedAt)
        }
        return AgentTask(id: id, title: title, step: DigestWords.stoppedWhenClosed, progress: .indeterminate,
                         state: .stopped, history: steps,
                         wrapUp: TaskWrapUp(kept: [], notDone: saving ? [] : [DigestTask.saveTodo],
                                            underway: saving ? DigestTask.saveTodo : nil),
                         startedAt: startedAt, updatedAt: now)
    }
}
