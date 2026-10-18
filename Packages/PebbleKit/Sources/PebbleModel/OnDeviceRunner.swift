import Foundation
import MLX

/// Lets one on-device reply run at a time, from loading and reading the
/// prompt to the last word or a stop, and none while the app is away.
///
/// Each reply holds its own cache, about 450 MB at the full context, so two
/// at once, as from two windows, would pass the memory the model was let in
/// with. A reply that comes while another runs waits its turn. A stopped
/// reply has finished all its work on the model, including a graphics-chip
/// sync, before the next one starts. That sync covers a cancel while the
/// prompt is still being read: the iterator can throw before its last
/// `eval`, and before a generation task exists to wait on.
///
/// On iPhone and iPad the system refuses work on the graphics chip once the
/// app is no longer active, so leaving the foreground stops the reply under
/// way and waits until that sync has finished. No new one starts until the
/// app is active again.
public actor OnDeviceRunner {
    /// The app's one runner, shared by every on-device model it makes.
    public static let shared = OnDeviceRunner()

    /// Shared with the foreground watcher so a scene callback can wait
    /// without hopping onto this actor.
    nonisolated private let state: RunnerState
    private let synchronize: @Sendable () -> Void

    public init(synchronize: @escaping @Sendable () -> Void = OnDeviceGPU.finish) {
        self.synchronize = synchronize
        self.state = RunnerState()
    }

    /// Runs `work` once no other reply is running. Throws
    /// `MLXChatModelError.interrupted` when the app is away, or goes away
    /// before `work` ends. Synchronizes the graphics chip before returning
    /// the turn, whether `work` finished, threw, or was cancelled.
    func run(_ work: @escaping @Sendable () async throws -> String) async throws -> String {
        try await state.acquire()
        defer {
            synchronize()
            state.release()
        }
        guard !state.isAway else { throw MLXChatModelError.interrupted }
        try Task.checkCancellation()
        let task = Task { try await work() }
        state.setCurrent(task)
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        if case .failure = result, state.isAway { throw MLXChatModelError.interrupted }
        return try result.get()
    }

    /// The app left the active state. No reply starts from here, the one
    /// under way is stopped, and this returns once its graphics-chip work
    /// has been synchronized.
    public func leaveForeground() async {
        state.markAwayAndCancel()
        await state.waitUntilIdle()
    }

    /// Same stop as `leaveForeground`, but blocks the caller until the
    /// graphics chip is idle. The scene callback that is about to enter the
    /// background calls this and does not return first.
    public nonisolated func leaveForegroundAndWait() {
        state.markAwayAndCancel()
        state.waitUntilIdleBlocking()
    }

    /// The app is active again, so replies can start.
    public func returnToForeground() {
        state.markBack()
    }

    /// Same as `returnToForeground`, for the scene callback.
    public nonisolated func returnToForegroundNow() {
        state.markBack()
    }

    /// True while the app is away and nothing new starts.
    public var isAway: Bool { state.isAway }
}

/// Finishes graphics-chip work the model already submitted.
enum OnDeviceGPU {
    static func finish() {
        Stream.defaultStream.synchronize()
    }
}

/// The turn and the away flag, so a scene callback can close the gate and
/// wait without the actor.
private final class RunnerState: @unchecked Sendable {
    private let condition = NSCondition()
    private var away = false
    private var busy = false
    private var current: Task<String, Error>?
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var isAway: Bool {
        condition.lock()
        defer { condition.unlock() }
        return away
    }

    /// Takes the turn. Throws `MLXChatModelError.interrupted` when the app
    /// is already away. After this returns, the caller holds the turn until
    /// `release`.
    func acquire() async throws {
        condition.lock()
        if away {
            condition.unlock()
            throw MLXChatModelError.interrupted
        }
        if !busy {
            busy = true
            condition.unlock()
            return
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            turnWaiters.append(waiter)
            condition.unlock()
        }
    }

    /// Ends the turn. The next reply waiting in line takes it, or it is free
    /// and anyone waiting for the chip to go idle is told.
    func release() {
        condition.lock()
        current = nil
        if turnWaiters.isEmpty {
            busy = false
            let idle = idleWaiters
            idleWaiters.removeAll()
            condition.broadcast()
            condition.unlock()
            for waiter in idle { waiter.resume() }
        } else {
            let next = turnWaiters.removeFirst()
            condition.unlock()
            next.resume()
        }
    }

    func setCurrent(_ task: Task<String, Error>) {
        condition.lock()
        current = task
        let shouldCancel = away
        condition.unlock()
        if shouldCancel { task.cancel() }
    }

    func markAwayAndCancel() {
        condition.lock()
        away = true
        let task = current
        condition.unlock()
        task?.cancel()
    }

    func markBack() {
        condition.lock()
        away = false
        condition.unlock()
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            condition.lock()
            if !busy {
                condition.unlock()
                waiter.resume()
                return
            }
            idleWaiters.append(waiter)
            condition.unlock()
        }
    }

    /// Blocks until the turn is free. Called on the main thread from the
    /// background callback, which is not a Swift concurrency thread.
    func waitUntilIdleBlocking() {
        condition.lock()
        while busy {
            condition.wait()
        }
        condition.unlock()
    }
}
