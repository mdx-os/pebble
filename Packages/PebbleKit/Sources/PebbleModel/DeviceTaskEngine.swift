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
/// change. Forgetting the digest note takes the words off the card.
///
/// The engine looks at the notes after every change, whoever made it,
/// and at launch. When a note a kept digest quoted is gone or changed, it
/// takes that note's line out of the digest note itself, unless the person
/// changed the digest by hand, which leaves it theirs. So a note forgotten
/// anywhere, or one forgotten just before the app closed, leaves no words
/// behind. A digest not yet kept whose notes change is stopped, and its
/// question withdrawn, since a yes would be for other words.
/// `forgetQuotes(of:)` says whether any of a note's words stayed.
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
        /// True once the person changed the kept digest by hand. It is
        /// theirs then: nothing is taken out of it here again.
        var byHand = false

        /// Which notes it points at, so the file is written when only
        /// these change.
        var links: Links { Links(kept: kept, drewFrom: drewFrom, quoted: quoted, more: more, byHand: byHand) }
    }

    private struct Links: Equatable {
        let kept: UUID?
        let drewFrom: [UUID]
        let quoted: [UUID]?
        let more: [UUID]?
        let byHand: Bool
    }

    /// A kept digest with notes to take out of it.
    private struct Plan {
        let kept: UUID
        let written: DigestTask.Written
        let gone: Set<UUID>
        let lines: [UUID: String]
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
    /// True when the file was there but couldn't be decoded, so the tasks
    /// it held, and which digests they kept, are not known. Until Forget
    /// everything, a forgotten note may still be quoted somewhere.
    private var tasksLost = false
    /// In memory only: the line each quoted note had when the notes were
    /// last looked at, so a line is known to be its note's once the note
    /// is gone or changed. Only words still in the notes at that look, and
    /// replaced at each one.
    private var lastLines: [UUID: String] = [:]
    /// Notes forgotten or changed while the notes couldn't be read, looked
    /// for again at the next look. Ids only.
    private var pendingForgotten: Set<UUID> = []
    /// Notes whose lines were taken out since `forgetQuotes(of:)` last
    /// asked about them. Ids only.
    private var cleanedOf: Set<UUID> = []
    /// Questions asked by an engine before this one that its file's tasks
    /// still had open, to withdraw.
    private var orphans: [(AskFirst, ConfirmationRequest)] = []
    /// One look at the notes at a time. A look's own writes tell it the
    /// notes changed, on the same thread, so `sweeping` and `sweepAgain`
    /// make that a second look rather than one inside the first.
    private let sweepLock = NSRecursiveLock()
    private var sweeping = false
    private var sweepAgain = false

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
        // `published` is set by the first look below, which reads the
        // notes once for the cards too.
        let orphaned = orphans
        orphans = []
        lock.unlock()
        for (rule, request) in orphaned { rule.withdraw(request) }
        // Any writer's change to the notes, not only the memory screen's,
        // so a card never shows words that have changed or gone, and a
        // digest never keeps them.
        watchingNotes = notes.observeChanges { [weak self] in self?.notesChanged() }
        // Words forgotten just before the app last closed go now.
        sweep()
    }

    /// A question this engine leaves open can't be said yes to once it is
    /// gone, so it is withdrawn.
    deinit {
        for (rule, request) in Self.open.takeAll(of: ObjectIdentifier(self)) { rule.withdraw(request) }
    }

    private func notesChanged() {
        sweep()
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
            lastLines = [:]
            pendingForgotten = []
            cleanedOf = []
            // A file left unread, as on a locked device, or one that
            // couldn't be decoded, goes too.
            loaded = true
            tasksLost = false
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
        let saved: (kept: MemoryNote?, line: String)
        switch try? notes.rememberOnce(digest, at: clock(), source: .inferred) {
        case (.saved(let note), let isNew)?: saved = (note, isNew ? DigestWords.done : DigestWords.alreadyKept)
        case (.tooLong, _)?: saved = (nil, DigestWords.tooLongToKeep)
        case (.needsWords, _)?: saved = (nil, DigestWords.emptyDigest)
        case (.notFound, _)?, nil: saved = (nil, DigestWords.couldNotSave)
        }
        let lookAgain = mutate { () -> Bool in
            guard let index = runs.firstIndex(where: { $0.task.id == id }), runs[index].stage == .saving else { return false }
            guard let kept = saved.kept else {
                end(&runs[index], as: .failed, line: saved.line,
                    wrapUp: TaskWrapUp(kept: [], notDone: [DigestTask.saveTodo]))
                return false
            }
            end(&runs[index], as: .done, line: saved.line, wrapUp: nil)
            // Only which note, never its words: the card reads them from
            // the notes, so forgetting the note takes them away.
            runs[index].kept = kept.id
            runs[index].task.progress = .fraction(1)
            // The save's own change was just looked at, so the card takes
            // the words just kept rather than read them again.
            guard case .read(var ids, var digests) = seen else {
                seen = .unread
                return true
            }
            ids.insert(kept.id)
            digests[kept.id] = kept.text
            seen = .read(ids: ids, digests: digests)
            return !runs[index].drewFrom.allSatisfy(ids.contains)
        }
        // A note forgotten while the digest was being saved goes from it now.
        if lookAgain { sweep() }
        return .proceeding
    }

    /// Says whether a forgotten note's words, or a changed note's earlier
    /// words in `note`, are gone from everything a task kept. The line is
    /// taken out by the look at the notes that every change brings; this
    /// looks once more, with `note`'s words to check the line by, and then
    /// at what no task here points to any longer: a digest whose card was
    /// put away or let go, and one from a task file that couldn't be read.
    /// It never calls words gone that may still be there.
    public func forgetQuotes(of note: MemoryNote) -> QuotesForgotten {
        guard let all = sweep([note.id: DigestTask.line(for: note)]) else { return .stayed }
        let current = all.first { $0.id == note.id }
        lock.lock()
        let kept = Set(runs.compactMap(\.kept))
        var stayed = false
        // Older digests, kept before which line is whose was written down,
        // and found not to hold the words.
        var notThere: Set<UUID> = []
        for run in runs where run.drewFrom.contains(note.id) {
            guard let digest = run.kept.flatMap({ id in all.first { $0.id == id } }) else { continue }
            if run.byHand {
                // The person changed it: said plainly, never guessed.
                stayed = true
            } else if let quoted = run.quoted {
                // Still quoted after the look, as when the digest couldn't
                // be written just now, unless its line is the note's own
                // words as they are now.
                if quoted.contains(note.id), current.map({ DigestTask.line(for: $0) }) != DigestTask.line(for: note) {
                    stayed = true
                }
            } else if DigestTask.mayQuote(note, in: digest.text) {
                stayed = true
            } else {
                notThere.insert(digest.id)
            }
        }
        // Digests no task points to: looked for, leaning to say they stay.
        let others = all.filter { $0.id != note.id && !kept.contains($0.id) }
        if others.contains(where: { DigestTask.isDigest($0) && DigestTask.mayQuote(note, in: $0.text) }) {
            stayed = true
        }
        // With the task file unread or unreadable, a digest it knew of may
        // have been changed past finding. Only the agent keeps a note as
        // its own guess, so with none of those there is nothing to fear.
        if !loaded || tasksLost, others.contains(where: { $0.source == .inferred }) {
            stayed = true
        }
        let cleaned = cleanedOf.remove(note.id) != nil
        lock.unlock()
        if !notThere.isEmpty {
            mutate {
                for index in runs.indices where runs[index].kept.map(notThere.contains) == true {
                    runs[index].drewFrom.removeAll { $0 == note.id }
                }
            }
        }
        if stayed { return .stayed }
        return cleaned || !notThere.isEmpty ? .forgotten : .notQuoted
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
    /// and looks at the notes again: a kept digest's words that changed
    /// reach the cards, and lines left from before, as while the notes
    /// were locked, go.
    public func refresh() {
        lock.lock()
        let open = runs.compactMap { $0.stage == .waiting ? $0.question : nil }
        lock.unlock()
        let closed = open.filter { rule.isClosed($0) }.map { ($0, rule.wasWithdrawn($0)) }
        mutate {
            if !loaded { loadFile() }
            for (request, withdrawn) in closed {
                guard let index = runs.firstIndex(where: { $0.stage == .waiting && $0.question == request }) else { continue }
                runs[index].question = nil
                endWithoutSaving(&runs[index], line: withdrawn ? TaskWords.declined(DigestTask.saveTodo)
                                                               : TaskWords.timedOut(DigestTask.saveTodo))
            }
        }
        sweep()
    }

    // MARK: Looking at the notes

    /// Looks at the notes, then again for as long as a look's own writes,
    /// or another writer's, changed them meanwhile. `asked` holds a note
    /// the caller names with the line its words had, as when it was just
    /// changed. Returns the notes as the last look read them, or nil when
    /// they couldn't be read.
    @discardableResult
    private func sweep(_ asked: [UUID: String] = [:]) -> [MemoryNote]? {
        sweepLock.lock()
        defer { sweepLock.unlock() }
        guard !sweeping else {
            sweepAgain = true
            return nil
        }
        sweeping = true
        defer { sweeping = false }
        var all = sweepOnce(asked, read: !asked.isEmpty)
        while sweepAgain {
            sweepAgain = false
            all = sweepOnce([:], read: all != nil)
        }
        return all
    }

    /// One look. Takes each gone or changed note's line out of the kept
    /// digest that quoted it, stops a digest not yet kept whose notes
    /// changed, and keeps what the cards show. With `read` false, the
    /// notes are read only when some task points at them.
    private func sweepOnce(_ asked: [UUID: String], read: Bool) -> [MemoryNote]? {
        lock.lock()
        let anything = read || !pendingForgotten.isEmpty
            || runs.contains { $0.kept != nil || $0.task.isActive }
        lock.unlock()
        // Nothing to look for: no read, and the cards as they are.
        guard anything else {
            mutate {}
            return nil
        }
        guard case .notes(let all) = notes.contents() else {
            mutate {
                seen = .unavailable
                pendingForgotten.formUnion(asked.keys)
            }
            return nil
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        lock.lock()
        let before = lastLines
        lastLines = Self.lines(of: runs, in: byID)
        let pending = pendingForgotten
        var plans: [UUID: Plan] = [:]
        // Each digest note once, though two tasks may point at it.
        for run in runs {
            guard let kept = run.kept, byID[kept] != nil, let quoted = run.quoted, !run.byHand,
                  plans[kept] == nil else { continue }
            var gone = Set<UUID>(), lines: [UUID: String] = [:]
            for id in quoted {
                guard let note = byID[id] else {
                    gone.insert(id)
                    lines[id] = asked[id] ?? before[id]
                    continue
                }
                let now = DigestTask.line(for: note)
                if let said = asked[id], said != now {
                    // Changed, with its earlier words named: they go.
                    gone.insert(id)
                    lines[id] = said
                } else if let was = before[id], was != now {
                    // Changed since its line was last read: the same.
                    gone.insert(id)
                    lines[id] = was
                } else if pending.contains(id) {
                    // Changed while the notes were locked: its earlier
                    // words aren't known, so only where its line sits is.
                    gone.insert(id)
                } else {
                    lines[id] = now
                }
            }
            let more = run.more ?? []
            for id in more where byID[id] == nil { gone.insert(id) }
            if !gone.isEmpty {
                plans[kept] = Plan(kept: kept, written: DigestTask.Written(text: "", quoted: quoted, more: more),
                                   gone: gone, lines: lines)
            }
        }
        lock.unlock()

        // Written outside this engine's lock, since each write tells it the
        // notes changed. What each cleaned digest's lines are now; nil
        // inside when the digest went.
        var cleaned: [UUID: DigestTask.Written?] = [:]
        var theirs: Set<UUID> = [], failed: Set<UUID> = []
        for plan in plans.values {
            guard let digest = byID[plan.kept] else { continue }
            switch DigestTask.dropping(plan.gone, from: digest.text, as: plan.written, lines: plan.lines) {
            case .edited(let next):
                if case .saved? = try? notes.edit(plan.kept, to: next.text) { cleaned[plan.kept] = next } else {
                    failed.formUnion(plan.gone)
                }
            case .emptied:
                if (try? notes.forget(plan.kept)) == true { cleaned[plan.kept] = .some(nil) } else {
                    failed.formUnion(plan.gone)
                }
            case .notThere:
                break
            case .cantTell:
                theirs.insert(plan.kept)
            }
        }

        mutate {
            for index in runs.indices {
                guard let kept = runs[index].kept else { continue }
                if theirs.contains(kept) { runs[index].byHand = true }
                guard let next = cleaned[kept], let plan = plans[kept] else { continue }
                runs[index].drewFrom.removeAll(where: plan.gone.contains)
                if let next {
                    runs[index].quoted = next.quoted
                    runs[index].more = next.more
                }
            }
            for (kept, _) in cleaned { cleanedOf.formUnion(plans[kept]?.gone ?? []) }
            // Kept only while a digest here still quotes them unchecked.
            pendingForgotten.formUnion(failed)
            pendingForgotten = pendingForgotten.filter { id in
                runs.contains { !$0.byHand && $0.kept != nil && (($0.quoted ?? []) + ($0.more ?? [])).contains(id) }
            }
            // A digest not yet kept whose notes changed: the yes would be
            // for other words, so it stops and nothing is kept.
            for index in runs.indices where Self.drewOnChanged(runs[index], in: byID) {
                withdrawQuestion(&runs[index])
                runs[index].task.record(TaskStep(DigestWords.noteChanged, mark: .skipped, at: clock()))
                end(&runs[index], as: .stopped, line: DigestWords.noteChanged,
                    wrapUp: TaskWrapUp(kept: [], notDone: [DigestTask.saveTodo]))
            }
            // What the cards show, from this read and this look's writes.
            var ids = Set(byID.keys)
            var digests: [UUID: String] = [:]
            for kept in Set(runs.compactMap(\.kept)) {
                switch cleaned[kept] {
                case .some(.some(let next)): digests[kept] = next.text
                case .some(.none): ids.remove(kept)
                case .none: if let note = byID[kept] { digests[kept] = note.text }
                }
            }
            seen = .read(ids: ids, digests: digests)
        }
        return all
    }

    /// The line each quoted note has now, for every digest still kept or
    /// still being written. None for a digest the person removed.
    private static func lines(of runs: [Run], in byID: [UUID: MemoryNote]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for run in runs where run.kept.map({ byID[$0] != nil }) ?? run.task.isActive {
            for id in run.quoted ?? [] {
                if let note = byID[id] { out[id] = DigestTask.line(for: note) }
            }
        }
        return out
    }

    /// True for a digest not yet kept, read or written from notes that
    /// have since gone or changed.
    private static func drewOnChanged(_ run: Run, in byID: [UUID: MemoryNote]) -> Bool {
        switch run.stage {
        case .picking:
            // Every note was read; only this week's go in.
            return DigestTask.thisWeek(run.notes, now: run.task.updatedAt).contains { byID[$0.id] != $0 }
        case .writing:
            return run.notes.contains { byID[$0.id] != $0 }
        case .toAsk, .asking, .waiting:
            guard let digest = run.digest else { return false }
            if run.drewFrom.contains(where: { byID[$0] == nil }) { return true }
            let lines = digest.components(separatedBy: "\n")
            return (run.quoted ?? []).enumerated().contains { index, id in
                let line = index + 1 < lines.count ? lines[index + 1] : nil
                return byID[id].map { DigestTask.line(for: $0) } != line
            }
        case .reading, .saving, .ended:
            return false
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
            // Each line's words as written, so a change to its note is
            // seen even before the next look.
            for note in run.notes where written.quoted.contains(note.id) { lastLines[note.id] = DigestTask.line(for: note) }
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
        let orphaned = orphans
        orphans = []
        lock.unlock()
        for (rule, request) in orphaned { rule.withdraw(request) }
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
        Self.open.update(ObjectIdentifier(self), rule: rule, open: Dictionary(
            runs.compactMap { run in run.question.map { (run.task.id, $0) } }, uniquingKeysWith: { first, _ in first }))
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
        guard let stored = try? Self.decoder.decode([StoredTask].self, from: data) else {
            tasksLost = true
            return
        }
        let going = Set(runs.map(\.task.id))
        let back = stored.filter { !going.contains($0.id) }.map { stored in
            Run(task: stored.restored(at: clock()), stage: .ended, kept: stored.kept, drewFrom: stored.drewFrom ?? [],
                quoted: stored.quoted, more: stored.more, byHand: stored.byHand == true)
        }
        runs = back + runs
        // A question an engine before this one asked for these tasks, in
        // this app, can't be answered here: they came back stopped.
        orphans += Self.open.take(Set(back.map(\.task.id)), notOwnedBy: ObjectIdentifier(self))
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
                       quoted: $0.quoted, more: $0.more, byHand: $0.byHand)
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

    /// Every engine's open questions in this app.
    private static let open = OpenQuestions()
}

/// The questions each engine in this app has open, by task. A question
/// lives only in memory, so this is all of them: an engine made again over
/// the same file, as when the model is switched and back, withdraws those
/// its file's tasks still had open, and one that goes withdraws its own.
private final class OpenQuestions: @unchecked Sendable {
    private struct Entry {
        let owner: ObjectIdentifier
        let rule: AskFirst
        let request: ConfirmationRequest
    }

    private let lock = NSLock()
    private var byTask: [String: Entry] = [:]

    /// The questions `owner` has open now, replacing those it had.
    func update(_ owner: ObjectIdentifier, rule: AskFirst, open: [String: ConfirmationRequest]) {
        lock.lock()
        defer { lock.unlock() }
        byTask = byTask.filter { $0.value.owner != owner || open[$0.key] != nil }
        for (task, request) in open { byTask[task] = Entry(owner: owner, rule: rule, request: request) }
    }

    /// Takes the questions for these tasks that another engine asked.
    func take(_ tasks: Set<String>, notOwnedBy owner: ObjectIdentifier) -> [(AskFirst, ConfirmationRequest)] {
        lock.lock()
        defer { lock.unlock() }
        let taken = byTask.filter { tasks.contains($0.key) && $0.value.owner != owner }
        for task in taken.keys { byTask[task] = nil }
        return taken.values.map { ($0.rule, $0.request) }
    }

    func takeAll(of owner: ObjectIdentifier) -> [(AskFirst, ConfirmationRequest)] {
        lock.lock()
        defer { lock.unlock() }
        let taken = byTask.filter { $0.value.owner == owner }
        for task in taken.keys { byTask[task] = nil }
        return taken.values.map { ($0.rule, $0.request) }
    }
}

/// A task as the file keeps it: what its card shows, whether a save the
/// person said yes to was under way, and for a kept digest, which notes
/// to read its words from. Never a note's words. Its history does keep
/// the person's own instructions, as they typed them to change course,
/// until the card is put away or Forget everything erases the file.
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
    /// True once the person changed the kept digest, so it is left as
    /// theirs. Absent otherwise.
    let byHand: Bool?

    init(_ task: AgentTask, saving: Bool, kept: UUID? = nil, drewFrom: [UUID] = [], quoted: [UUID]? = nil,
         more: [UUID]? = nil, byHand: Bool = false) {
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
        self.byHand = kept != nil && byHand ? true : nil
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
