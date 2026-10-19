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
    /// Counts ids from the start again after `clear`, as an engine may, so
    /// a newer task can have the id an older one had.
    private let reusesIDs: Bool

    public init(reusesIDs: Bool = false) { self.reusesIDs = reusesIDs }

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
        // Two takes of the lock, so another thread could change the task
        // between them. Fine for a test driving one thread; a real engine
        // checks and sets under one lock, as `LocalFakeEngine.stop` does.
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
            if reusesIDs { made = 0 }
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

/// A real engine's stand-in: the scripted engine underneath, but not an
/// example. Move it on through `inner`.
public final class PlainEngine: ScriptedTaskEngine, @unchecked Sendable {
    public let inner: LocalFakeEngine
    private let lock = NSLock()
    private var count = 0
    public init(_ inner: LocalFakeEngine) { self.inner = inner }
    /// Said outright, so a change to the protocol's default can't make it one.
    public var isSample: Bool { false }
    public func isSample(_ id: String) -> Bool { false }
    /// How many times its tasks were asked for.
    public var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    public var rule: AskFirst { inner.rule }
    public var tasks: [AgentTask] {
        lock.lock(); count += 1; lock.unlock()
        return inner.tasks
    }
    public func start(_ request: TaskRequest) -> String { inner.start(request) }
    public func start(_ script: TaskScript) -> String { inner.start(script) }
    public func observe(_ onChange: @escaping @Sendable (TaskSnapshot) -> Void) -> TaskObservation { inner.observe(onChange) }
    public func redirect(_ id: String, with instructions: String) -> Bool { inner.redirect(id, with: instructions) }
    public func stop(_ id: String) -> Bool { inner.stop(id) }
    public func dismiss(_ id: String) -> Bool { inner.dismiss(id) }
    public func clear() -> ClearedTasks { inner.clear() }
    public func retry(_ id: String) -> Bool { inner.retry(id) }
    public func resume(_ id: String, with approval: Approval) -> TaskApproval { inner.resume(id, with: approval) }
    public func questionClosed(_ request: ConfirmationRequest) { inner.questionClosed(request) }
    public func refresh() { inner.refresh() }
}

/// The sample pages' words, on this device, standing in for a real
/// provider, so a test can keep a point from them. Not an example, and
/// neither are its pages.
public struct PagesNotExamples: SourceProvider {
    public let pages: SampleSources
    public init(now: @escaping @Sendable () -> Date) { pages = SampleSources(now: now) }
    public var runsOnDevice: Bool { true }
    public var isSample: Bool { false }
    public func sources(for task: ReconTask) throws -> [ReconSource] { try pages.sources(for: task).map(notExample) }
}

/// The same page, not marked as an example, standing in for a real one.
public func notExample(_ page: ReconSource) -> ReconSource {
    ReconSource(id: page.id, title: page.title, publisher: page.publisher, url: page.url,
                published: page.published, text: page.text)
}

/// Counts every time it is asked, and reads the sample pages' words as if
/// they were real. Not an example.
public final class CountingProvider: SourceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let pages: PagesNotExamples
    /// Pages to give from the next ask on, instead of the sample ones.
    private var given: [ReconSource]?
    public init(now: @escaping @Sendable () -> Date) { pages = PagesNotExamples(now: now) }
    public var asked: Int { lock.lock(); defer { lock.unlock() }; return count }
    public var runsOnDevice: Bool { true }
    public var isSample: Bool { false }
    /// Runs inside `sources(for:)`, after the count, so a test can land
    /// something while a recon is being started.
    public var whileReading: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return hook }
        set { lock.lock(); hook = newValue; lock.unlock() }
    }
    private var hook: (@Sendable () -> Void)?
    public func give(_ pages: [ReconSource]?) { lock.lock(); given = pages; lock.unlock() }
    public func sources(for task: ReconTask) throws -> [ReconSource] {
        lock.lock()
        count += 1
        let pages = given
        let hook = self.hook
        lock.unlock()
        hook?()
        return try pages ?? self.pages.sources(for: task)
    }
}

/// A recon a test can play to its end.
public struct PlayedRecon: Sendable {
    public let name: String
    public let runner: ReconRunner
    /// Moves the scripted engine underneath on.
    public let advance: @Sendable (TimeInterval) -> Void
}

/// Every way a recon is an example: example pages, the scripted engine,
/// or both. No point from any of them may ever reach the notes, so the
/// core and the UI tests both check each one, and a new kind of example
/// goes here.
public func exampleRecons(at origin: Date) -> [PlayedRecon] {
    let both = LocalFakeEngine(rule: .isolated(), origin: origin)
    let scripted = LocalFakeEngine(rule: .isolated(), origin: origin)
    let pages = LocalFakeEngine(rule: .isolated(), origin: origin)
    return [
        PlayedRecon(name: "example pages on the scripted engine",
                    runner: ReconRunner(engine: both, provider: SampleSources(now: { origin })),
                    advance: { both.advance(by: $0) }),
        PlayedRecon(name: "the scripted engine",
                    runner: ReconRunner(engine: scripted, provider: PagesNotExamples(now: { origin })),
                    advance: { scripted.advance(by: $0) }),
        PlayedRecon(name: "example pages",
                    runner: ReconRunner(engine: PlainEngine(pages), provider: SampleSources(now: { origin }),
                                        now: { origin }),
                    advance: { pages.advance(by: $0) }),
    ]
}

/// The control for `exampleRecons`: neither the engine nor the pages are
/// examples, so its points may be kept.
public func realRecon(at origin: Date) -> PlayedRecon {
    let inner = LocalFakeEngine(rule: .isolated(), origin: origin)
    return PlayedRecon(name: "real", runner: ReconRunner(engine: PlainEngine(inner), provider: PagesNotExamples(now: { origin }),
                                                         now: { [inner] in inner.currentDate }),
                       advance: { inner.advance(by: $0) })
}

/// Lets go of a scratch notes store: its notes, and its file and any staged
/// copy, so no test leaves one behind in the temporary folder.
public func discard(_ store: MemoryStore) {
    try? store.forgetEverything()
    try? FileManager.default.removeItem(at: store.fileURL)
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
/// The main actor work these tests wait on queues behind every other
/// main-actor test in the run, about 16 s on a fast Mac and past 30 s on
/// CI, so this is the repo's limit for main-actor waits, about 60 s. A
/// passing test never waits on it.
public let eventuallyLimit: Duration = .seconds(60)

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
