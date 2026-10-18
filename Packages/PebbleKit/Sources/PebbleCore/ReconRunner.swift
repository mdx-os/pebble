import Foundation

/// An engine that can play a given script, as `LocalFakeEngine` does. A
/// recon shows its own steps on such an engine; on any other it is started
/// by its title and the engine picks the steps.
public protocol ScriptedTaskEngine: TaskEngine {
    @discardableResult
    func start(_ script: TaskScript) -> String
}

extension LocalFakeEngine: ScriptedTaskEngine {}

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
/// on an engine that picks its own steps, once the engine is done), so a
/// cloud preview never shows while the card still says it is planning. The
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

    private struct Run {
        let task: ReconTask
        let summarizer: any ReconSummarizer
        /// What was read. Let go once the summary holds it, or the card stops.
        var sources: [ReconSource]
        var gatheredAt: Date
        /// The provider couldn't be read at all: a failure, not an empty result.
        var readFailed: Bool
        var summary: ReconSummary?
        var work: Task<Void, Never>?
        /// The summary has been begun this round, so it is never begun twice.
        var begun = false
        /// Stopped by the person. The card says stopped, never done, and
        /// nothing it read is kept.
        var stopped = false
        /// Seen in the engine's list. Leaving it after that means the engine
        /// let it go, so the run goes too.
        var seen = false
        /// Goes up with each retry, so a summary from an earlier try is dropped.
        var round = 0
    }

    /// `now` is when sources count as read. By default, the engine's own
    /// clock for a `LocalFakeEngine`, and the wall clock otherwise.
    public init(engine: any TaskEngine, provider: any SourceProvider, now: (@Sendable () -> Date)? = nil) {
        self.engine = engine
        self.provider = provider
        self.now = now ?? { [weak engine] in
            if let fake = engine as? LocalFakeEngine { return fake.currentDate }
            return Date()
        }
        watching = engine.observe { [weak self] _ in self?.changed() }
    }

    // MARK: Looking into something

    /// Starts looking into `topic`. Returns the task's id, or nil when
    /// nothing was started: an empty topic, words of crisis, or a provider
    /// that doesn't run on this device.
    @discardableResult
    public func lookInto(_ topic: String, with summarizer: any ReconSummarizer = LocalReconSummarizer()) -> String? {
        guard let task = ReconTask(topic: topic), provider.runsOnDevice else { return nil }
        let (sources, failed) = read(task)
        let gatheredAt = now()
        // Not under the lock: the engine tells its observers, this one
        // included, before `start` returns.
        let id: String
        if let scripted = engine as? ScriptedTaskEngine {
            id = scripted.start(task.script(sources: sources.count))
        } else {
            id = engine.start(TaskRequest(title: task.title, instructions: task.topic))
        }
        lock.lock()
        runs[id] = Run(task: task, summarizer: summarizer, sources: sources, gatheredAt: gatheredAt, readFailed: failed)
        lock.unlock()
        changed()
        return id
    }

    /// Never under the lock: a provider is someone else's code.
    private func read(_ task: ReconTask) -> ([ReconSource], failed: Bool) {
        do {
            return (try provider.sources(for: task), false)
        } catch {
            return ([], true)
        }
    }

    /// Waits until the summary for `id` is in, or its work was stopped.
    public func settle(_ id: String) async {
        await work(id)?.value
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
    }

    func held(_ id: String) -> Held? {
        lock.lock(); defer { lock.unlock() }
        return runs[id].map { Held(begun: $0.begun, working: $0.work != nil, hasSummary: $0.summary != nil, sources: $0.sources.count) }
    }

    /// Summaries being put together by a summarizer that may send what was
    /// read off this device, as when the cloud is on.
    public var summariesMayLeaveDevice: Int {
        lock.lock(); defer { lock.unlock() }
        return runs.values.filter { $0.work != nil && $0.summarizer.mayLeaveDevice }.count
    }

    /// The card has reached the step where the summary is put together.
    private static func isSummarizing(_ task: AgentTask) -> Bool {
        task.state == .done || (task.state == .running && task.step == ReconWords.puttingTogether)
    }

    /// Begins the summary, outside the lock. On this device it is ready at
    /// once; otherwise its work is kept so stop, clear and the cap can cancel it.
    private func summarize(_ id: String, round: Int, _ run: Run) {
        if let local = run.summarizer as? LocalReconSummarizer {
            finish(id, round: round, with: local.summary(run.task, id: id, sources: run.sources, gatheredAt: run.gatheredAt))
            return
        }
        let (summarizer, task, sources, gatheredAt) = (run.summarizer, run.task, run.sources, run.gatheredAt)
        let work = Task { [weak self] in
            let summary = await summarizer.summarize(task, id: id, sources: sources, gatheredAt: gatheredAt)
            guard !Task.isCancelled else { return }
            self?.finish(id, round: round, with: summary)
        }
        lock.lock()
        let current = runs[id]
        let keep = current?.round == round && current?.stopped == false && current?.summary == nil
        if keep { runs[id]?.work = work }
        lock.unlock()
        // Stopped, retried or let go while it was being begun.
        if !keep { work.cancel() }
    }

    private func finish(_ id: String, round: Int, with summary: ReconSummary) {
        // Asked before the lock is taken, so the engine is never called under it.
        let task = engine.tasks.first { $0.id == id }
        // A recon that was stopped, dismissed or forgotten keeps no summary.
        guard let task, task.state != .stopped, task.state != .failed else { return }
        lock.lock()
        guard let run = runs[id], run.round == round, !run.stopped else { lock.unlock(); return }
        runs[id]?.summary = summary
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

    public func isSample(_ id: String) -> Bool {
        engine.isSample(id) || (provider.isSample && isRecon(id))
    }

    /// The engine's tasks. A recon the engine has finished while its summary
    /// is still coming shows as still working, on its last step.
    public var tasks: [AgentTask] {
        let list = engine.tasks
        lock.lock()
        let known = runs
        lock.unlock()
        return list.map { task in
            guard let run = known[task.id], task.state == .done else { return task }
            var shown = task
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
                if summary.points.isEmpty { shown.step = ReconWords.nothingFoundLine }
            } else {
                shown.state = .running
                shown.step = ReconWords.puttingTogether
                shown.progress = .indeterminate
                shown.wrapUp = nil
            }
            return shown
        }
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
        if var run = runs[id] {
            let waiting = engineDone && run.summary == nil && !run.stopped && !run.readFailed
            if stopped || waiting {
                run.stopped = true
                run.summary = nil
                run.sources = []
                run.work = nil
                runs[id] = run
                halted = true
            }
        }
        lock.unlock()
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
        lock.lock()
        let works = runs.values.compactMap(\.work)
        runs.removeAll()
        lock.unlock()
        // Cancelling also withdraws a cloud preview still waiting for an answer.
        for work in works { work.cancel() }
        let cleared = engine.clear()
        changed()
        return cleared
    }

    /// Tries a stuck task again. A recon reads its sources again and puts a
    /// new summary together when it gets there, so a retried card always
    /// ends, and never shows a summary from before.
    @discardableResult
    public func retry(_ id: String) -> Bool {
        lock.lock()
        let task = runs[id]?.task
        lock.unlock()
        guard engine.retry(id) else { return false }
        guard let task else { return true }
        let (sources, failed) = read(task)
        let gatheredAt = now()
        lock.lock()
        let old = runs[id]?.work
        if var run = runs[id] {
            run.round += 1
            run.summary = nil
            run.work = nil
            run.begun = false
            run.stopped = false
            run.sources = sources
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

    /// Moves a scripted engine's clock, for the showcase and tests.
    public func advance(by seconds: TimeInterval) {
        (engine as? LocalFakeEngine)?.advance(by: seconds)
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
        lock.unlock()
        for work in letGo { work.cancel() }
        for item in begin { summarize(item.id, round: item.round, item.run) }
        guard !listeners.isEmpty else { return }
        let snapshot = snapshot(advancing: true)
        for listener in listeners { listener(snapshot) }
    }
}
