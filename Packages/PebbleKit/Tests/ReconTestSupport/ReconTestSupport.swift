import Foundation
import PebbleCore

// One copy of the engines, gates and waits the recon tests share, so the
// core tests and the UI tests never drift apart on what they stand for.

/// A scripted engine that shows none of a script's steps, with a test
/// moving each task on by hand. Unlike `LocalFakeEngine`, it plays a task
/// again from any end on retry, as a looser engine might.
public final class ReplayEngine: ScriptedTaskEngine, @unchecked Sendable {
    public let rule = AskFirst.isolated()
    private let lock = NSLock()
    private var list: [AgentTask] = []
    private var observers: [UUID: @Sendable (TaskSnapshot) -> Void] = [:]
    private var sequence = 0
    private var made = 0
    private var stopHook: (@Sendable (String) -> Void)?

    public init() {}

    /// Called inside `stop`, after the engine has given its answer and
    /// before `stop` returns, so a test can land something in the middle.
    public var duringStop: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stopHook }
        set { lock.lock(); stopHook = newValue; lock.unlock() }
    }

    public var tasks: [AgentTask] { lock.lock(); defer { lock.unlock() }; return list }

    public func start(_ script: TaskScript) -> String {
        start(TaskRequest(title: script.title))
    }

    /// Shows `step` on the card, and `kept` in its wrap-up when given, as
    /// an engine playing its script would.
    public func show(_ id: String, step: String, kept: [String]? = nil) {
        change {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].step = step
            if let kept { list[index].wrapUp = TaskWrapUp(kept: kept, notDone: []) }
        }
    }

    public func start(_ request: TaskRequest) -> String {
        change { () -> String in
            made += 1
            let id = "replay:\(made)"
            list.insert(AgentTask(id: id, title: request.title, step: "Working", startedAt: Date(timeIntervalSince1970: 0)), at: 0)
            return id
        }
    }

    public func finish(_ id: String) { set(id, .done) }

    public func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        let key = UUID()
        lock.lock()
        observers[key] = onChange
        let snapshot = TaskSnapshot(sequence: sequence, tasks: list)
        lock.unlock()
        onChange(snapshot)
        return TaskObservation { [weak self] in
            self?.lock.lock()
            self?.observers[key] = nil
            self?.lock.unlock()
        }
    }

    public func redirect(_ id: String, with instructions: String) -> Bool { false }

    public func stop(_ id: String) -> Bool {
        let active = tasks.first(where: { $0.id == id })?.isActive == true
        if active { set(id, .stopped) }
        duringStop?(id)
        return active
    }

    public func dismiss(_ id: String) -> Bool {
        change {
            guard let index = list.firstIndex(where: { $0.id == id }), !list[index].isActive else { return false }
            list.remove(at: index)
            return true
        }
    }

    public func clear() -> ClearedTasks {
        change {
            let count = list.count
            list.removeAll()
            return ClearedTasks(forgotten: count)
        }
    }

    public func retry(_ id: String) -> Bool {
        guard tasks.contains(where: { $0.id == id }) else { return false }
        set(id, .running)
        return true
    }

    public func resume(_ id: String, with approval: Approval) -> TaskApproval { .refused }
    public func questionClosed(_ request: ConfirmationRequest) {}
    public func refresh() {}

    private func set(_ id: String, _ state: TaskState) {
        change {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].state = state
            list[index].step = state == .done ? "Done" : "Working"
        }
    }

    private func change<T>(_ body: () -> T) -> T {
        lock.lock()
        let value = body()
        sequence += 1
        let snapshot = TaskSnapshot(sequence: sequence, tasks: list)
        let listeners = Array(observers.values)
        lock.unlock()
        for listener in listeners { listener(snapshot) }
        return value
    }
}

/// An engine that picks its own steps for whatever it is asked, and
/// plays no given script. It only notes what it was asked to start.
public final class OwnStepsEngine: TaskEngine, @unchecked Sendable {
    public let rule = AskFirst.isolated()
    private let lock = NSLock()
    private var titles: [String] = []
    public init() {}
    public var started: [String] { lock.lock(); defer { lock.unlock() }; return titles }
    public var tasks: [AgentTask] { [] }
    public func start(_ request: TaskRequest) -> String {
        lock.lock(); titles.append(request.title); lock.unlock()
        return "own:\(request.title)"
    }
    public func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation {
        onChange(TaskSnapshot(sequence: 0, tasks: []))
        return TaskObservation {}
    }
    public func redirect(_ id: String, with instructions: String) -> Bool { false }
    public func stop(_ id: String) -> Bool { false }
    public func dismiss(_ id: String) -> Bool { false }
    public func clear() -> ClearedTasks { ClearedTasks(forgotten: 0) }
    public func retry(_ id: String) -> Bool { false }
    public func resume(_ id: String, with approval: Approval) -> TaskApproval { .refused }
    public func questionClosed(_ request: ConfirmationRequest) {}
    public func refresh() {}
}

/// Holds something back until the test lets it go.
public actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    public func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Raised once; anyone waiting goes on.
public actor Flag {
    private var raised = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func raise() {
        raised = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    public func wait() async {
        if raised { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// A clock a test moves by hand.
public final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    public init(_ date: Date) { self.date = date }
    public var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return date }
        set { lock.lock(); date = newValue; lock.unlock() }
    }
}

/// How long `eventually` waits before it gives up. One number for every
/// recon test, set wide so a slow CI machine never fails on time alone.
public let eventuallyLimit: Duration = .seconds(30)

/// Waits, a short sleep at a time, until `condition` holds or
/// `eventuallyLimit` passes. The caller then checks the condition itself,
/// so a wait that ran out fails on what was expected, not here.
@MainActor
public func eventually(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + eventuallyLimit
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
