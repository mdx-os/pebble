import Foundation

/// An engine that picks its own steps and keeps its own file of tasks, as
/// the device's own engine does. Today runs recons beside it, on a scripted
/// engine of their own, through `JoinedTasks`, so it is never given one.
public protocol RunsReconsBeside: TaskEngine {}

/// Two engines as one, for Today: `main`, which picks its own steps and
/// keeps its own file, and a scripted one beside it that plays what
/// `ReconRunner` gives it.
///
/// So "look into something" runs next to the device's tasks without ever
/// reaching them. A request goes to `main`; a script goes to `scripted`.
/// Nothing here is kept while the app is closed: `main` keeps its own
/// tasks, and a recon's topic never reaches `main`, so it is never written
/// to `main`'s file. Forget everything clears both.
///
/// `main`'s ids pass through as they are, so what it kept under them is
/// found again. Each of `scripted`'s is shown with `idPrefix` in front, and
/// every call is sent by its id to the one engine that gave it. An id from
/// one engine never stops, dismisses or answers a task of the other, even
/// when both engines count their ids the same way.
public final class JoinedTasks: ScriptedTaskEngine, @unchecked Sendable {
    public let main: any TaskEngine
    public let scripted: LocalFakeEngine
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (TaskSnapshot) -> Void] = [:]
    private var watching: [TaskObservation] = []
    /// Held while a snapshot is taken and numbered, so a later number always
    /// means a later look. Never held while observers are told.
    private let snapshotLock = NSLock()
    private var sequence = 0

    /// Put before each of `scripted`'s ids.
    public static let idPrefix = "beside:"

    public init(main: any TaskEngine, scripted: LocalFakeEngine) {
        self.main = main
        self.scripted = scripted
        watching = [main.observe { [weak self] _ in self?.changed() },
                    scripted.observe { [weak self] _ in self?.changed() }]
    }

    /// Which engine gave `id`, and its id there.
    private enum Owner {
        case main(String)
        case scripted(String)
    }

    private func owner(of id: String) -> Owner {
        guard id.hasPrefix(Self.idPrefix) else { return .main(id) }
        let inner = String(id.dropFirst(Self.idPrefix.count))
        return scripted.task(inner) != nil ? .scripted(inner) : .main(id)
    }

    // MARK: TaskEngine

    public var rule: AskFirst { main.rule }

    /// Whether `main`'s tasks are examples. A scripted task is asked of
    /// `scripted` one by one.
    public var isSample: Bool { main.isSample }

    public func isSample(_ id: String) -> Bool {
        switch owner(of: id) {
        case .main(let id): return main.isSample(id)
        case .scripted(let id): return scripted.isSample(id)
        }
    }

    /// Both engines' tasks, newest first.
    public var tasks: [AgentTask] {
        let own = main.tasks
        let beside = scripted.tasks.map { $0.with(id: Self.idPrefix + $0.id) }
        return (own + beside).enumerated()
            .sorted { $0.element.startedAt != $1.element.startedAt
                ? $0.element.startedAt > $1.element.startedAt : $0.offset < $1.offset }
            .map(\.element)
    }

    @discardableResult
    public func start(_ request: TaskRequest) -> String { main.start(request) }

    @discardableResult
    public func start(_ script: TaskScript) -> String { Self.idPrefix + scripted.start(script) }

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

    @discardableResult
    public func redirect(_ id: String, with instructions: String) -> Bool {
        switch owner(of: id) {
        case .main(let id): return main.redirect(id, with: instructions)
        case .scripted(let id): return scripted.redirect(id, with: instructions)
        }
    }

    @discardableResult
    public func stop(_ id: String) -> Bool {
        switch owner(of: id) {
        case .main(let id): return main.stop(id)
        case .scripted(let id): return scripted.stop(id)
        }
    }

    @discardableResult
    public func dismiss(_ id: String) -> Bool {
        switch owner(of: id) {
        case .main(let id): return main.dismiss(id)
        case .scripted(let id): return scripted.dismiss(id)
        }
    }

    /// Forgets both engines' tasks. Erased only when both are.
    @discardableResult
    public func clear() -> ClearedTasks {
        let own = main.clear()
        let beside = scripted.clear()
        return ClearedTasks(forgotten: own.forgotten + beside.forgotten, underway: own.underway + beside.underway,
                            erased: own.erased && beside.erased)
    }

    @discardableResult
    public func retry(_ id: String) -> Bool {
        switch owner(of: id) {
        case .main(let id): return main.retry(id)
        case .scripted(let id): return scripted.retry(id)
        }
    }

    public func resume(_ id: String, with approval: Approval) -> TaskApproval {
        switch owner(of: id) {
        case .main(let id): return main.resume(id, with: approval)
        case .scripted(let id): return scripted.resume(id, with: approval)
        }
    }

    /// Each engine closes only a question of its own.
    public func questionClosed(_ request: ConfirmationRequest) {
        main.questionClosed(request)
        scripted.questionClosed(request)
    }

    public func refresh() {
        main.refresh()
        scripted.refresh()
    }

    public var builtIns: [TaskRequest] { main.builtIns }

    public var hasStoredFile: Bool { main.hasStoredFile }

    public func forgetQuotes(of note: MemoryNote) -> QuotesForgotten { main.forgetQuotes(of: note) }

    /// Counted from `main`, whose tasks are kept. A scripted task is never.
    public var endings: TaskEndings { main.endings }

    /// Moves the scripted engine's clock. `main` keeps its own.
    public func advance(by seconds: TimeInterval) {
        scripted.advance(by: seconds)
    }

    // MARK: Telling observers

    private func snapshot(advancing: Bool) -> TaskSnapshot {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        let list = tasks
        if advancing { sequence += 1 }
        return TaskSnapshot(sequence: sequence, tasks: list)
    }

    private func changed() {
        lock.lock()
        let listeners = Array(observers.values)
        lock.unlock()
        guard !listeners.isEmpty else { return }
        let snapshot = snapshot(advancing: true)
        for listener in listeners { listener(snapshot) }
    }
}
