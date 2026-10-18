import Foundation

/// One on-device generation at a time, for every window.
///
/// Each generation keeps its own cache, about 450 MB at the limit. Two at
/// once, plus the memory measured around a short chat, pass the 1 GB left
/// free and the system can end the app, conversation and all. The next
/// generation starts only after the previous one has returned, which is
/// after a cancellation has finished its cleanup.
actor OnDeviceGeneration {
    static let shared = OnDeviceGeneration()

    private var closed = false
    private var tail: Task<Void, Never>?
    private let slot = GenerationSlot()
    private var current = 0
    private var peak = 0

    /// Runs `body` only while no other generation is inside its own body.
    /// Throws `MLXChatModelError.stopped` once `stop` has closed admission.
    func run<T: Sendable>(_ body: @Sendable (GenerationSlot) async throws -> T) async throws -> T {
        if closed { throw MLXChatModelError.stopped }
        let previous = tail
        let ticket = GenerationTicket()
        tail = Task {
            await previous?.value
            await ticket.wait()
        }
        await previous?.value
        defer { ticket.finish() }
        if closed { throw MLXChatModelError.stopped }
        try Task.checkCancellation()
        current += 1
        peak = max(peak, current)
        defer { current -= 1 }
        return try await body(slot)
    }

    /// Refuses new generations, cancels the one running, and returns only
    /// after that one has left `run`, cleanup included.
    func stop() async {
        closed = true
        slot.cancel()
        await tail?.value
    }

    /// Allows generations again. Call after `stop` has returned.
    func resume() {
        closed = false
        slot.reset()
    }

    var isClosed: Bool { closed }

    /// The most generations that were inside `run` at once, since the last reset.
    func overlapPeak() -> Int { peak }

    func resetOverlap() {
        peak = 0
        current = 0
    }
}

/// The in-flight generation task. `cancel` sticks, so a task registered
/// after the cancel still stops.
final class GenerationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func reset() {
        lock.lock()
        cancelled = false
        task = nil
        lock.unlock()
    }
}

/// Wakes the next generation when this one has fully returned.
private final class GenerationTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish() {
        lock.lock()
        done = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
