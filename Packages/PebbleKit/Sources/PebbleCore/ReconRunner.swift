import Foundation

/// An engine that can play a given script, as `LocalFakeEngine` does. A
/// recon runs only on such an engine, which plays the recon's own steps
/// and does nothing else with its topic. An engine that picks its own steps
/// would take "look into" a topic as work of its own, and there is no
/// contract yet for what that work may do, so a recon is never started there.
public protocol ScriptedTaskEngine: TaskEngine {
    @discardableResult
    func start(_ script: TaskScript) -> String
}

extension LocalFakeEngine: ScriptedTaskEngine {}

/// What came of asking the runner to look into a topic.
public enum ReconStart: Equatable, Sendable {
    /// A new recon, with its task's id.
    case started(String)
    /// One on the same topic is already going or ready, so nothing more
    /// was started. Its id, or nil while it is still being started, and
    /// whether its summary may be put into words off this device.
    case already(id: String?, mayUseCloud: Bool)
    /// Nothing could start: see `ReconRunner.start(lookingInto:with:)`.
    case notStarted

    /// The new recon's id, only when one was started.
    public var startedID: String? {
        if case .started(let id) = self { return id }
        return nil
    }
}

/// Runs "look into this" requests as tasks on an engine, and keeps the
/// summary each one comes back with.
///
/// It is the feed's task engine: every task of the engine underneath passes
/// through, and a recon's card is one more task. A recon reads only from a
/// provider on this device. Its summary comes from the summarizer it was
/// started with: `LocalReconSummarizer` on this device, or, only when the
/// person turned the cloud on, one that goes through the cloud model's
/// redaction and preview.
///
/// The summary is begun only once the card says "Putting it together" (or,
/// on a scripted engine that doesn't show that step, once the engine is
/// done), so a cloud preview never shows while the card still says it is
/// planning. The
/// card stays live until the summary is in hand, so it never says it is
/// done before it is.
///
/// It keeps the engine contract for every task, a recon's included: it never
/// calls the engine or `AskFirst` while holding its own lock, its snapshots
/// are numbered in order, and `clear` forgets every summary and source a
/// recon read along with the engine's tasks.
public final class ReconRunner: TaskEngine, @unchecked Sendable {
    public let engine: any TaskEngine
    public let provider: any SourceProvider
    private let lock = NSLock()
    private var runs: [String: Run] = [:]
    private var observers: [UUID: @Sendable (TaskSnapshot) -> Void] = [:]
    private var watching: TaskObservation?
    private let now: @Sendable () -> Date
    /// Held while a snapshot is taken and numbered, so a later number always
    /// means a later look. Never held while observers are told.
    private let snapshotLock = NSLock()
    private var sequence = 0
    /// Every summary's work until it returns, cancelled or not. Only for
    /// `settleEverything`. Each work holds the sources it was given until it
    /// returns, so what a recon read lives here no longer than its work does.
    private var underway: [UUID: Task<Void, Never>] = [:]
    /// Work that returned before `summarize` could note it.
    private var endedEarly: Set<UUID> = []
    /// Goes up with each `clear`, so a recon whose `lookInto` was under way
    /// when everything was forgotten is never kept after it, and a summary
    /// begun before it never lands on a card made after it.
    private var generation = 0
    /// Topics being started right now, as `topicKey` gives them, with
    /// whether each may leave the device. Held from the moment a start is
    /// let through until its run is noted, so two asks at once start one.
    private var starting: [String: Bool] = [:]
    /// Held from just before the engine is given a recon's task until its
    /// run is noted or let go, and by `clear` and `saved`. So a start knows
    /// whether the engine forgot everything before it had the task or after,
    /// and nothing is saved while the engine holds a recon not yet noted.
    /// Recursive, since the engine tells its observers inside `start`, and
    /// one may forget everything or save right there.
    private let startLock = NSRecursiveLock()
    /// The titles of recons the engine has been given and the runner hasn't
    /// noted yet, with how many of each. Their tasks are never saved.
    private var titlesStarting: [String: Int] = [:]

    private struct Run {
        let task: ReconTask
        let summarizer: any ReconSummarizer
        /// The provider said its pages are examples, or the engine said its
        /// task is one, when this was started. The summary is stamped as
        /// one whoever puts it together.
        let isSample: Bool
        /// What was read. Let go once the summary holds it, or the card stops.
        var sources: [ReconSource]
        /// How many sources this round read, and how many the engine's
        /// script was made for. A retry may read a different number than
        /// the script it plays again says.
        var read: Int
        let scripted: Int
        var gatheredAt: Date
        /// The provider couldn't be read at all: a failure, not an empty result.
        var readFailed: Bool
        var summary: ReconSummary?
        var work: Task<Void, Never>?
        /// The summary has been begun this round, so it is never begun twice.
        var begun = false
        /// A summary of this recon got past the person's yes to send what
        /// was read, as `CloudYes` says, so it may have left the device.
        /// Never set back: not by a stop, a retry or the summary landing.
        var sentToCloud = false
        /// Stopped by the person. The card says stopped, never done, and
        /// nothing it read is kept.
        var stopped = false
        /// Stop was tapped and is under way. A summary that lands before
        /// it is done is dropped, so Stop always wins.
        var stopping = false
        /// Seen in the engine's list. Leaving it after that means the engine
        /// let it go, so the run goes too.
        var seen = false
        /// Goes up with each retry, so a summary from an earlier try is dropped.
        var round = 0
    }

    /// `now` is when sources count as read. By default it is the wall
    /// clock, `Date()`, for every engine but a `LocalFakeEngine`, whose
    /// scripted clock is read instead, since that engine stands in for a
    /// set moment, as the showcase's does. A `LocalFakeEngine` moved only
    /// while a card is live falls behind the wall clock, so one that plays
    /// in real time is given the wall clock, as `HomeView.reconFeedModel` does.
    public init(engine: any TaskEngine, provider: any SourceProvider, now: (@Sendable () -> Date)? = nil) {
        self.engine = engine
        self.provider = provider
        // The engine is held as the runner holds it, so a scripted engine's
        // clock is never swapped for the wall clock behind the runner's back.
        let fake = engine as? LocalFakeEngine
        self.now = now ?? { fake?.currentDate ?? Date() }
        watching = engine.observe { [weak self] _ in self?.changed() }
    }

    // MARK: Looking into something

    /// True when `lookInto` can start anything at all: the engine plays a
    /// given script and the provider reads on this device. When false, a
    /// chat never offers, since every tap would end in "couldn't start".
    public var canLookInto: Bool {
        provider.runsOnDevice && engine is ScriptedTaskEngine
    }

    /// Starts looking into `topic`. Returns the task's id, or nil when
    /// nothing new was started: see `start(lookingInto:with:)`.
    @discardableResult
    public func lookInto(_ topic: String, with summarizer: any ReconSummarizer = LocalReconSummarizer()) -> String? {
        start(lookingInto: topic, with: summarizer).startedID
    }

    /// Starts looking into `topic`, unless one on the same topic is already
    /// going or ready: then nothing more starts, and the answer says which
    /// one it is, so every caller, the feed and each chat, is told the same.
    /// The topic is compared as `ReconTask` tidies it, whatever its case.
    /// One that stopped or failed doesn't count, so it can be asked again.
    ///
    /// The look and the claim on the topic are one step under the lock, so
    /// two asks at once, as a double tap or the feed and a chat together,
    /// start one recon between them.
    ///
    /// Nothing starts for an empty topic, words of crisis, a provider that
    /// doesn't run on this device, or an engine that doesn't play a given
    /// script (see `ScriptedTaskEngine`).
    @discardableResult
    public func start(lookingInto topic: String,
                      with summarizer: any ReconSummarizer = LocalReconSummarizer()) -> ReconStart {
        guard let task = ReconTask(topic: topic), provider.runsOnDevice,
              let scripted = engine as? ScriptedTaskEngine else { return .notStarted }
        let key = Self.topicKey(task.topic)
        lock.lock()
        if let mayUseCloud = starting[key] {
            lock.unlock()
            return .already(id: nil, mayUseCloud: mayUseCloud)
        }
        // Claimed before the engine is asked, so no other ask for this
        // topic gets past here until this one is noted or let go.
        starting[key] = summarizer.mayUseCloud
        let begun = generation
        let candidates = runs.filter { Self.topicKey($0.value.task.topic) == key }
            .mapValues(\.summarizer.mayUseCloud)
        lock.unlock()
        // Asked with the lock let go: the list comes from the engine.
        if let found = tasks.first(where: { candidates[$0.id] != nil && ($0.isActive || $0.state == .done) }) {
            letGo(key, begun)
            return .already(id: found.id, mayUseCloud: candidates[found.id] ?? false)
        }
        let (sources, failed) = read(task, isSample: provider.isSample)
        let gatheredAt = now()
        startLock.lock()
        lock.lock()
        let given = generation
        titlesStarting[task.title, default: 0] += 1
        lock.unlock()
        // Not under the lock: the engine tells its observers, this one
        // included, before `start` returns.
        let id = scripted.start(task.script(sources: sources.count))
        // An example engine's task is an example whatever it read, so its
        // summary is stamped as one, and no point of it is ever kept.
        let isSample = provider.isSample || scripted.isSample(id)
        lock.lock()
        // Forget everything came while this was being started. Nothing it
        // read is kept, and no card is left that no one asked for.
        let forgotten = generation != begun
        // Forgotten before the engine had the task, so the task is still
        // there and goes now. Forgotten after, the engine's forget took it,
        // and the id may be a newer task's by now, so it is left alone.
        let left = forgotten && generation == given
        if !forgotten {
            starting[key] = nil
            runs[id] = Run(task: task, summarizer: summarizer, isSample: isSample,
                           sources: isSample ? sources.map { $0.asSample() } : sources,
                           read: sources.count, scripted: sources.count, gatheredAt: gatheredAt, readFailed: failed)
        }
        lock.unlock()
        if left {
            _ = engine.stop(id)
            _ = engine.dismiss(id)
        }
        lock.lock()
        titlesStarting[task.title, default: 1] -= 1
        if titlesStarting[task.title] == 0 { titlesStarting[task.title] = nil }
        lock.unlock()
        startLock.unlock()
        if forgotten { return .notStarted }
        changed()
        return .started(id)
    }

    /// Lets go of the claim on `key`, unless everything was forgotten
    /// since it was made: `clear` let go of it then, and a newer claim may
    /// hold it now.
    private func letGo(_ key: String, _ begun: Int) {
        lock.lock(); defer { lock.unlock() }
        if generation == begun { starting[key] = nil }
    }

    /// The topic as two asks are compared: tidied by `ReconTask`, any case.
    private static func topicKey(_ topic: String) -> String {
        topic.folding(options: [.caseInsensitive], locale: nil)
    }

    /// Never under the lock: a provider is someone else's code. Pages from
    /// a provider of examples are marked as examples, so a summary made
    /// from them is one too.
    private func read(_ task: ReconTask, isSample: Bool) -> ([ReconSource], failed: Bool) {
        do {
            let pages = try provider.sources(for: task)
            return (isSample ? pages.map { $0.asSample() } : pages, false)
        } catch {
            return ([], true)
        }
    }

    /// Waits until the summary for `id` is in, or its work was stopped.
    public func settle(_ id: String) async {
        await work(id)?.value
    }

    /// Waits until every summary begun so far has returned, even one whose
    /// card was stopped, let go or forgotten, so a test can be sure a late
    /// one had its chance to land and didn't.
    package func settleEverything() async {
        while let next = nextUnderway() { await next.value }
    }

    private func nextUnderway() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return underway.values.first
    }

    /// The work has returned, kept or not.
    private func ended(_ key: UUID) {
        lock.lock(); defer { lock.unlock() }
        if underway.removeValue(forKey: key) == nil { endedEarly.insert(key) }
    }

    private func work(_ id: String) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return runs[id]?.work
    }

    /// True for a task started by `lookInto`.
    public func isRecon(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runs[id] != nil
    }

    /// The summary, once the card is done.
    public func summary(for id: String) -> ReconSummary? {
        guard let task = tasks.first(where: { $0.id == id }), task.state == .done else { return nil }
        lock.lock(); defer { lock.unlock() }
        return runs[id]?.summary
    }

    /// For tests: what the runner still holds for a recon.
    struct Held: Equatable {
        let begun: Bool
        let working: Bool
        let hasSummary: Bool
        let sources: Int
        /// The live round, so a test lands a summary for this try, not a guess.
        var round = 0
        /// How many times everything has been forgotten so far.
        var generation = 0
    }

    /// For tests: how many recons the runner holds anything for, and how
    /// many topics it is still starting, seen or not.
    var heldCount: (runs: Int, starting: Int) {
        lock.lock(); defer { lock.unlock() }
        return (runs.count, starting.count)
    }

    func held(_ id: String) -> Held? {
        lock.lock(); defer { lock.unlock() }
        return runs[id].map { Held(begun: $0.begun, working: $0.work != nil, hasSummary: $0.summary != nil,
                                   sources: $0.sources.count, round: $0.round, generation: generation) }
    }

    /// Summaries being put together by a summarizer that may send what was
    /// read off this device, as when the cloud is on.
    public var summariesMayLeaveDevice: Int {
        lock.lock(); defer { lock.unlock() }
        return runs.values.filter { $0.work != nil && $0.summarizer.mayUseCloud }.count
    }

    /// Recons whose sources may already have left the device: the person
    /// said yes to sending them and the request went on. Once marked, one
    /// stays counted, still going, stopped or done. One still reading,
    /// taking details out or waiting on its preview counts as none.
    public var summariesPastAYes: Int {
        lock.lock(); defer { lock.unlock() }
        return runs.values.filter(\.sentToCloud).count
    }

    /// True when a summary of this recon got past a yes, so what it read
    /// may have left the device.
    public func sentToCloud(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runs[id]?.sentToCloud == true
    }

    /// The yes for this round's summary is in, and the request is about to
    /// go. Refused, so nothing goes, for one begun before a retry or Forget
    /// everything, or one stopped or being stopped since its preview showed.
    private func heardYes(_ id: String, round: Int, generation begun: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == begun, let run = runs[id], run.round == round, !run.stopped, !run.stopping
        else { return false }
        runs[id]?.sentToCloud = true
        return true
    }

    /// The card has reached the step where the summary is put together.
    private static func isSummarizing(_ task: AgentTask) -> Bool {
        task.state == .done || (task.state == .running && task.step == ReconWords.puttingTogether)
    }

    /// Begins the summary, outside the lock. On this device it is ready at
    /// once; otherwise its work is kept so stop, clear and the cap can cancel it.
    private func summarize(_ id: String, round: Int, generation begun: Int, _ run: Run) {
        if let local = run.summarizer as? LocalReconSummarizer {
            finish(id, round: round, generation: begun,
                   with: local.summary(run.task, id: id, sources: run.sources, gatheredAt: run.gatheredAt))
            return
        }
        let (summarizer, task, sources, gatheredAt) = (run.summarizer, run.task, run.sources, run.gatheredAt)
        let key = UUID()
        let yes: @Sendable () -> Bool = { [weak self] in self?.heardYes(id, round: round, generation: begun) ?? false }
        let work = Task { [weak self] in
            defer { self?.ended(key) }
            let summary = await CloudYes.$run.withValue(id) {
                await CloudYes.$heard.withValue(yes) {
                    await summarizer.summarize(task, id: id, sources: sources, gatheredAt: gatheredAt)
                }
            }
            guard !Task.isCancelled else { return }
            self?.finish(id, round: round, generation: begun, with: summary)
        }
        lock.lock()
        // Work that already ended before it could be noted needs no wait.
        if endedEarly.remove(key) == nil { underway[key] = work }
        let current = runs[id]
        // Not while a stop is under way either: it has already taken the
        // work it found, so work noted now would never be cancelled.
        let keep = generation == begun && current?.round == round && current?.stopped == false
            && current?.stopping == false && current?.summary == nil
        if keep { runs[id]?.work = work }
        lock.unlock()
        // Stopped, retried, let go or forgotten while it was being begun.
        if !keep { work.cancel() }
    }

    /// Keeps a summary that came in. Not private, so a test can land one in
    /// the middle of a stop. `generation` is the one the summary was begun
    /// in, so one begun before Forget everything never lands, even on a
    /// newer card an engine gave the same id; nil for the live one.
    func finish(_ id: String, round: Int, generation begun: Int? = nil, with summary: ReconSummary) {
        // Asked before the lock is taken, so the engine is never called under it.
        let task = engine.tasks.first { $0.id == id }
        // A recon that was stopped, dismissed or forgotten keeps no summary.
        guard let task, task.state != .stopped, task.state != .failed else { return }
        lock.lock()
        guard generation == (begun ?? generation), let run = runs[id], run.round == round, !run.stopped,
              !run.stopping else { lock.unlock(); return }
        // Whoever put it together, a summary read from examples is one.
        runs[id]?.summary = summary.stamped(sample: run.isSample)
        runs[id]?.work = nil
        // The summary holds what was read now.
        runs[id]?.sources = []
        lock.unlock()
        changed()
    }

    // MARK: TaskEngine

    public var rule: AskFirst { engine.rule }

    /// Whether the engine's own tasks are examples. Ask `isSample(_:)` for
    /// one card: a recon is an example only when it read sample sources.
    public var isSample: Bool { engine.isSample }

    /// A recon is an example exactly when its summary is stamped as one:
    /// it read example pages, or ran on an example engine (see `start`).
    /// Decided from that stamp alone, so the card, `keepsPoints` and the
    /// summary's own `note(for:)` always agree. Any other task is asked of
    /// the engine.
    public func isSample(_ id: String) -> Bool {
        lock.lock()
        let run = runs[id]
        lock.unlock()
        guard let run else { return engine.isSample(id) }
        return run.isSample || run.summary?.isSample == true
    }

    /// The recon already going or ready for `topic`, if there is one. The
    /// topic is compared as `ReconTask` tidies it, whatever its case. One
    /// that stopped or failed doesn't count, so it can be asked again. Only
    /// a look: a tap starts through `start(lookingInto:with:)`, which looks
    /// and claims the topic in one step.
    public func activeRecon(for topic: String) -> String? {
        guard let wanted = ReconTask(topic: topic)?.topic else { return nil }
        let key = Self.topicKey(wanted)
        lock.lock()
        let topics = runs.mapValues { Self.topicKey($0.task.topic) }
        lock.unlock()
        return tasks.first { task in
            topics[task.id] == key && (task.isActive || task.state == .done)
        }?.id
    }

    /// True when the recon's summary is put together by a summarizer that
    /// may send what was read off this device, after a yes.
    public func mayUseCloud(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runs[id]?.summarizer.mayUseCloud == true
    }

    /// True when a point from this recon may be kept in the person's notes.
    /// Never for an example: its points are made up, and a note outlives the
    /// card that says it was one.
    public func keepsPoints(_ id: String) -> Bool {
        isRecon(id) && !isSample(id)
    }

    /// The engine's tasks. A recon the engine has finished while its summary
    /// is still coming shows as still working, on its last step.
    public var tasks: [AgentTask] {
        let list = engine.tasks
        lock.lock()
        let known = runs
        lock.unlock()
        return list.map { task in
            guard let run = known[task.id] else { return task }
            let shown = Self.shown(task, run)
            // Stopped after a Send: what was read may already have gone, and
            // the card says so plainly rather than only that it stopped.
            guard shown.state == .stopped, run.sentToCloud else { return shown }
            var told = shown
            told.step = ReconWords.stoppedAfterSend
            return told
        }
    }

    /// The card for one recon, before what a Send may have let go is added.
    private static func shown(_ task: AgentTask, _ run: Run) -> AgentTask {
        guard task.state == .done else { return Self.counted(task, run) }
        var shown = Self.counted(task, run)
        if run.stopped {
            // Nothing was summed up, so nothing was kept.
            shown.state = .stopped
            shown.step = TaskWords.stopped
            shown.result = nil
            shown.wrapUp = TaskWrapUp(kept: [], notDone: [])
        } else if run.readFailed {
            // The sources couldn't be read: that is a failure, not "nothing found".
            shown.state = .failed
            shown.step = ReconWords.couldNotRead
            shown.result = nil
            shown.wrapUp = TaskWrapUp(kept: [], notDone: [ReconWords.readTodo])
        } else if let summary = run.summary {
            shown.result = summary.plainText
            // From the summary, not the script: a retry may find what
            // the script it plays again had nothing of, or the other way.
            shown.step = summary.points.isEmpty ? ReconWords.nothingFoundLine : ReconWords.doneLine
        } else {
            shown.state = .running
            shown.step = ReconWords.puttingTogether
            shown.progress = .indeterminate
            shown.wrapUp = nil
        }
        return shown
    }

    /// The card's step and what it kept, with the number of sources this
    /// round read rather than the number its script was made for. A round
    /// that found none says it is looking, and keeps no "0 sources".
    private static func counted(_ task: AgentTask, _ run: Run) -> AgentTask {
        guard run.read != run.scripted else { return task }
        var shown = task
        if shown.step == ReconWords.reading(run.scripted) {
            shown.step = run.read == 0 ? ReconWords.looking : ReconWords.reading(run.read)
        }
        if let wrapUp = shown.wrapUp {
            let scripted = ReconWords.keptSources(run.scripted)
            let kept = run.read == 0 ? wrapUp.kept.filter { $0 != scripted }
                : wrapUp.kept.map { $0 == scripted ? ReconWords.keptSources(run.read) : $0 }
            shown.wrapUp = TaskWrapUp(kept: kept, notDone: wrapUp.notDone, underway: wrapUp.underway)
        }
        return shown
    }

    @discardableResult
    public func start(_ request: TaskRequest) -> String { engine.start(request) }

    public func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        let key = UUID()
        lock.lock()
        observers[key] = onChange
        lock.unlock()
        onChange(snapshot(advancing: false))
        return TaskObservation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[key] = nil
            self.lock.unlock()
        }
    }

    /// A recon can't change course: its topic is what it reads for. Stop it
    /// and ask again instead.
    @discardableResult
    public func redirect(_ id: String, with instructions: String) -> Bool {
        isRecon(id) ? false : engine.redirect(id, with: instructions)
    }

    /// Stops at once. A recon keeps nothing it read: its summary and its
    /// sources go, and a cloud preview still waiting is withdrawn.
    @discardableResult
    public func stop(_ id: String) -> Bool {
        lock.lock()
        let recon = runs[id] != nil
        let work = runs[id]?.work
        runs[id]?.work = nil
        // From here a summary that lands is dropped, even one that beats
        // the engine's answer below.
        runs[id]?.stopping = true
        lock.unlock()
        // Stopping also stops a cloud preview still waiting for an answer.
        work?.cancel()
        let stopped = engine.stop(id)
        guard recon else { return stopped }
        // The engine may have finished, with the card only waiting on the
        // summary. Then it is this runner that stops it.
        let engineDone = !stopped && engine.tasks.first { $0.id == id }?.state == .done
        lock.lock()
        var halted = stopped
        // Work noted after the first look, so it is cancelled too, never left
        // running with a preview Send could still answer.
        var late: Task<Void, Never>?
        if var run = runs[id] {
            let waiting = engineDone && run.summary == nil && !run.stopped && !run.readFailed
            if stopped || waiting {
                late = run.work
                run.stopped = true
                run.summary = nil
                run.sources = []
                run.work = nil
                halted = true
            }
            run.stopping = false
            runs[id] = run
        }
        lock.unlock()
        late?.cancel()
        if halted { changed() }
        return halted
    }

    /// Takes an ended card away, with its summary and the sources it read.
    /// False while it is still going, a recon whose summary is still coming
    /// included, so it is stopped first.
    @discardableResult
    public func dismiss(_ id: String) -> Bool {
        guard let shown = tasks.first(where: { $0.id == id }), !shown.isActive, engine.dismiss(id) else { return false }
        lock.lock()
        let had = runs.removeValue(forKey: id) != nil
        lock.unlock()
        // The engine has told observers already; tell them the summary went too.
        if had { changed() }
        return true
    }

    /// Forgets every task, and every summary and source a recon held, at
    /// once. Work still putting a summary together is cancelled, so nothing
    /// comes back later. A recon has no step to say yes to, so the count of
    /// steps under way is the engine's.
    @discardableResult
    public func clear() -> ClearedTasks {
        // So a recon being given to the engine is given wholly before this
        // forget or wholly after it.
        startLock.lock()
        lock.lock()
        let works = runs.values.compactMap(\.work)
        runs.removeAll()
        // A `lookInto` still on its way keeps nothing it read, and lets go
        // of its topic, so it can be asked for again.
        starting.removeAll()
        generation += 1
        lock.unlock()
        // Cancelling also withdraws a cloud preview still waiting for an answer.
        for work in works { work.cancel() }
        let cleared = engine.clear()
        startLock.unlock()
        changed()
        return cleared
    }

    /// Tries a stuck task again. A recon reads its sources again and puts a
    /// new summary together when it gets there, so a retried card always
    /// ends, and never shows a summary from before.
    ///
    /// One the engine finished but this runner ended, as when its sources
    /// couldn't be read or it was stopped while its summary was coming, may
    /// have nothing left for the engine to play. Then its card goes and the
    /// same topic is looked into again, with the same summarizer, under a
    /// new id.
    @discardableResult
    public func retry(_ id: String) -> Bool {
        lock.lock()
        let run = runs[id]
        let task = run?.task
        let isSample = run?.isSample ?? false
        lock.unlock()
        guard engine.retry(id) else {
            guard let run, run.readFailed || run.stopped,
                  engine.tasks.first(where: { $0.id == id })?.state == .done, dismiss(id) else { return false }
            return start(lookingInto: run.task.topic, with: run.summarizer).startedID != nil
        }
        guard let task else { return true }
        let (sources, failed) = read(task, isSample: isSample)
        let gatheredAt = now()
        lock.lock()
        let old = runs[id]?.work
        if var run = runs[id] {
            run.round += 1
            run.summary = nil
            run.work = nil
            run.begun = false
            run.stopped = false
            run.stopping = false
            run.sources = sources
            run.read = sources.count
            run.readFailed = failed
            run.gatheredAt = gatheredAt
            runs[id] = run
        }
        lock.unlock()
        old?.cancel()
        changed()
        return true
    }

    public func resume(_ id: String, with approval: Approval) -> TaskApproval { engine.resume(id, with: approval) }

    public func questionClosed(_ request: ConfirmationRequest) { engine.questionClosed(request) }

    public func refresh() { engine.refresh() }

    /// What the engine can start. A recon is never one: it starts only
    /// from a tap on Look into it.
    public var builtIns: [TaskRequest] { engine.builtIns }

    public var hasStoredFile: Bool { engine.hasStoredFile }

    /// A recon quotes no note, so only the engine's tasks are asked.
    public func forgetQuotes(of note: MemoryNote) -> QuotesForgotten { engine.forgetQuotes(of: note) }

    public var endings: TaskEndings { engine.endings }

    /// Moves a scripted engine's clock, for the showcase and tests, and
    /// the scripted one beside the device's own engine.
    public func advance(by seconds: TimeInterval) {
        if let joined = engine as? JoinedTasks {
            joined.advance(by: seconds)
        } else {
            (engine as? LocalFakeEngine)?.advance(by: seconds)
        }
    }

    /// Every task now, numbered. A change takes the next number; a first
    /// look for a new observer keeps the current one.
    private func snapshot(advancing: Bool) -> TaskSnapshot {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        let list = tasks
        if advancing { sequence += 1 }
        return TaskSnapshot(sequence: sequence, tasks: list)
    }

    private func changed() {
        let list = engine.tasks
        var begin: [(id: String, round: Int, run: Run)] = []
        var letGo: [Task<Void, Never>] = []
        lock.lock()
        for (id, run) in runs {
            if let task = list.first(where: { $0.id == id }) {
                runs[id]?.seen = true
                if !run.begun, !run.stopped, !run.readFailed, run.summary == nil, Self.isSummarizing(task) {
                    runs[id]?.begun = true
                    begin.append((id, run.round, run))
                }
            } else if run.seen {
                // The engine let its task go, as its cap on ended tasks does.
                // What the recon read goes with it, and work still putting a
                // summary together is cancelled, so no preview outlives its card.
                if let work = run.work { letGo.append(work) }
                runs[id] = nil
            }
        }
        let listeners = Array(observers.values)
        let current = generation
        lock.unlock()
        for work in letGo { work.cancel() }
        for item in begin { summarize(item.id, round: item.round, generation: current, item.run) }
        guard !listeners.isEmpty else { return }
        let snapshot = snapshot(advancing: true)
        for listener in listeners { listener(snapshot) }
    }
}

/// Tasks kept while the app is closed pass through to the engine, when it
/// keeps them. A recon is never kept: what it read and its summary live
/// only in memory, so a card picked up again would have nothing behind it,
/// and its topic is never written down. That holds while one is being
/// started too: the engine has its task before the runner has noted it.
extension ReconRunner: KeepsTasks {
    public func saved() -> [SavedTask] {
        guard let keeper = engine as? any KeepsTasks else { return [] }
        startLock.lock(); defer { startLock.unlock() }
        let kept = keeper.saved()
        lock.lock()
        let starting = titlesStarting
        lock.unlock()
        return kept.filter { !isRecon($0.id) && starting[$0.title] == nil }
    }

    public func restore(_ saved: [SavedTask], now: Date) {
        (engine as? any KeepsTasks)?.restore(saved, now: now)
    }

    public func takeReceipts() -> [Receipt] {
        (engine as? any KeepsTasks)?.takeReceipts() ?? []
    }
}
