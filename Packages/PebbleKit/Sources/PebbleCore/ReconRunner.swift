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
/// redaction and preview. The card stays live until the summary is in hand,
/// so a card never says it is done before it is.
public final class ReconRunner: TaskEngine, @unchecked Sendable {
    public let engine: any TaskEngine
    public let provider: any SourceProvider
    private let lock = NSLock()
    private var runs: [String: Run] = [:]
    private var observers: [UUID: @Sendable ([AgentTask]) -> Void] = [:]
    private var watching: TaskObservation?
    private let now: @Sendable () -> Date

    private struct Run {
        let task: ReconTask
        var summary: ReconSummary?
        var work: Task<Void, Never>?
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
        let sources = (try? provider.sources(for: task)) ?? []
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
        runs[id] = Run(task: task)
        lock.unlock()
        if let local = summarizer as? LocalReconSummarizer {
            // On this device, so it's ready at once.
            finish(id, with: local.summary(task, id: id, sources: sources, gatheredAt: gatheredAt))
        } else {
            let work = Task { [weak self] in
                let summary = await summarizer.summarize(task, id: id, sources: sources, gatheredAt: gatheredAt)
                guard !Task.isCancelled else { return }
                self?.finish(id, with: summary)
            }
            lock.lock()
            runs[id]?.work = work
            lock.unlock()
        }
        changed()
        return id
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

    private func finish(_ id: String, with summary: ReconSummary) {
        lock.lock()
        guard runs[id] != nil else { lock.unlock(); return }
        // A recon that was stopped keeps no summary.
        if let task = engine.tasks.first(where: { $0.id == id }), task.state == .stopped || task.state == .failed {
            lock.unlock()
            return
        }
        runs[id]?.summary = summary
        runs[id]?.work = nil
        lock.unlock()
        changed()
    }

    // MARK: TaskEngine

    public var rule: AskFirst { engine.rule }

    /// Examples when the engine's tasks are, or when a recon read sample sources.
    public var isSample: Bool {
        let list = engine.tasks
        guard !list.isEmpty else { return false }
        return engine.isSample || (provider.isSample && list.contains { isRecon($0.id) })
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
            var shown = task
            if task.state == .done {
                if let summary = run.summary {
                    shown.result = summary.plainText
                    if summary.points.isEmpty { shown.step = ReconWords.nothingFoundLine }
                } else {
                    shown.state = .running
                    shown.step = ReconWords.puttingTogether
                    shown.progress = .indeterminate
                    shown.wrapUp = nil
                }
            }
            return shown
        }
    }

    @discardableResult
    public func start(_ request: TaskRequest) -> String { engine.start(request) }

    public func observe(_ onChange: @escaping @Sendable ([AgentTask]) -> Void) -> TaskObservation {
        let key = UUID()
        lock.lock()
        observers[key] = onChange
        lock.unlock()
        onChange(tasks)
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

    @discardableResult
    public func stop(_ id: String) -> Bool {
        lock.lock()
        let work = runs[id]?.work
        runs[id]?.work = nil
        lock.unlock()
        // Stopping also stops a cloud preview still waiting for an answer.
        work?.cancel()
        let stopped = engine.stop(id)
        if !stopped, work != nil {
            // The engine had finished; the card was only waiting on the summary.
            lock.lock()
            runs[id] = nil
            lock.unlock()
            changed()
        }
        return stopped || work != nil
    }

    @discardableResult
    public func retry(_ id: String) -> Bool { engine.retry(id) }

    public func resume(_ id: String, with approval: Approval) -> TaskApproval { engine.resume(id, with: approval) }

    public func questionClosed(_ request: ConfirmationRequest) { engine.questionClosed(request) }

    public func refresh() { engine.refresh() }

    /// Moves a scripted engine's clock, for the showcase and tests.
    public func advance(by seconds: TimeInterval) {
        (engine as? LocalFakeEngine)?.advance(by: seconds)
    }

    private func changed() {
        lock.lock()
        let listeners = Array(observers.values)
        lock.unlock()
        guard !listeners.isEmpty else { return }
        let snapshot = tasks
        for listener in listeners { listener(snapshot) }
    }
}
