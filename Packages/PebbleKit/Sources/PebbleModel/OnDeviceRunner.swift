import Foundation

/// Lets one on-device reply run at a time, from loading and reading the
/// prompt to the last word or a stop, and none while the app is away.
///
/// Each reply holds its own cache, about 450 MB at the full context, so two
/// at once, as from two windows, would pass the memory the model was let in
/// with. A reply that comes while another runs waits its turn. However a
/// reply ends, its work on the graphics chip is drained before the turn
/// passes, so a stopped reply has finished all its work before the next one
/// starts.
///
/// On iPhone and iPad the system refuses work on the graphics chip once the
/// app is in the background. `closeGate` shuts the way in at once and stops
/// the reply under way, `drained` waits for it to drain, and no new one
/// starts until `returnToForeground`.
public actor OnDeviceRunner {
    /// The app's one runner, shared by every on-device model it makes.
    public static let shared = OnDeviceRunner()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let gate = Gate()

    public init() {}

    /// Runs `work` once no other reply is running, then `drain`, whether
    /// `work` returned, threw or was stopped, before the next one starts.
    /// Throws `MLXChatModelError.interrupted` when the app is away, or goes
    /// away before `work` ends.
    func run(_ work: @escaping @Sendable () async throws -> String,
             drain: @escaping @Sendable () async -> Void) async throws -> String {
        guard !gate.isClosed else { throw MLXChatModelError.interrupted }
        await takeTurn()
        defer { passTurn() }
        try Task.checkCancellation()
        guard let task = gate.admit(work) else { throw MLXChatModelError.interrupted }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        await drain()
        gate.finished(task)
        if case .failure = result, gate.isClosed { throw MLXChatModelError.interrupted }
        return try result.get()
    }

    /// The app is leaving the screen. From this call on no reply starts,
    /// and the one under way is stopped. Returns at once; `leaveForeground`
    /// waits for the stopped reply to drain.
    public nonisolated func closeGate() {
        gate.close()
    }

    /// The app left the foreground. Closes the gate, then returns once the
    /// reply under way has stopped and drained.
    public func leaveForeground() async {
        gate.close()
        await drained()
    }

    /// Returns once the reply under way, if any, has ended and drained.
    /// Leaves the gate as it is.
    public func drained() async {
        await takeTurn()
        passTurn()
    }

    /// The app is in front again, so replies can start.
    public nonisolated func returnToForeground() {
        gate.open()
    }

    /// True while the app is away and nothing new starts.
    public nonisolated var isAway: Bool { gate.isClosed }

    private func takeTurn() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the turn straight to the next in line, or frees it.
    private func passTurn() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// The way in to the model, closed and checked under one lock, so a reply
/// either starts before the gate closes, and is stopped by it, or never starts.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var current: Task<String, Error>?

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func close() {
        lock.withLock {
            closed = true
            current?.cancel()
        }
    }

    func open() {
        lock.withLock { closed = false }
    }

    /// Starts `work` unless the gate is closed.
    func admit(_ work: @escaping @Sendable () async throws -> String) -> Task<String, Error>? {
        lock.withLock {
            guard !closed else { return nil }
            let task = Task { try await work() }
            current = task
            return task
        }
    }

    func finished(_ task: Task<String, Error>) {
        lock.withLock {
            if current == task { current = nil }
        }
    }
}
