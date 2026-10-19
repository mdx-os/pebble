import Foundation

/// Lets one on-device reply run at a time, from reading the prompt to the
/// last word or a stop, and none while the app is away.
///
/// The weight load is not a turn. It runs on the processor before `run`,
/// so leaving during that first load finds the turn free and returns
/// without waiting, and nothing is sent to the graphics chip. A reply
/// waiting on that load is registered here. Closing the gate cancels the
/// wait, not the load, and opening the gate does not take the cancel back.
/// The reply is refused when it asks to run.
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
/// the reply under way, and any reply still waiting on the load.
/// `drained` waits for the reply under way to drain, not for the load, and
/// no new one starts until `returnToForeground`.
public actor OnDeviceRunner {
    /// A reply that has not taken a turn yet, for example while the first
    /// load is still running. Closing the gate cancels it. Opening the gate
    /// leaves that cancel in place.
    struct WaitingReply: Sendable {
        fileprivate let id: UUID
    }

    /// The app's one runner, shared by every on-device model it makes.
    public static let shared = OnDeviceRunner()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let gate = Gate()

    public init() {}

    /// Registers a reply that is waiting before its turn, so leaving cancels
    /// `cancel`. That does not take a turn, and `cancel` must not stop the
    /// shared load. A reply registered while the gate is already closed is
    /// cancelled at once.
    nonisolated func registerWaiting(_ cancel: @escaping @Sendable () -> Void) -> WaitingReply {
        gate.register(cancel)
    }

    /// Drops a registration. A reply already refused stays refused.
    nonisolated func unregisterWaiting(_ reply: WaitingReply) {
        gate.unregister(reply)
    }

    /// Runs `work` once no other reply is running, then `drain`, whether
    /// `work` returned, threw or was stopped, before the next one starts.
    /// Throws `MLXChatModelError.interrupted` when the app is away, or goes
    /// away before `work` ends. A `waiting` reply that leaving already
    /// cancelled is refused here, including after the gate has opened again.
    func run(_ work: @escaping @Sendable () async throws -> String,
             drain: @escaping @Sendable () async -> Void,
             waiting: WaitingReply? = nil) async throws -> String {
        if let waiting { gate.silence(waiting) }
        guard gate.accepts(waiting) else { throw MLXChatModelError.interrupted }
        await takeTurn()
        defer { passTurn() }
        try Task.checkCancellation()
        guard let task = gate.admit(waiting, work) else { throw MLXChatModelError.interrupted }
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
    /// the one under way is stopped, and any reply still waiting on the
    /// load is cancelled. Returns at once, and leaves that load running.
    /// `leaveForeground` waits for the stopped reply to drain.
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
///
/// `generation` advances on each close and stays there when the gate opens.
/// A reply registered before that close is from an earlier generation, so
/// it is still refused after the app comes back.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var generation: UInt64 = 0
    private var born: [UUID: UInt64] = [:]
    private var cancels: [UUID: @Sendable () -> Void] = [:]
    private var current: Task<String, Error>?

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func register(_ cancel: @escaping @Sendable () -> Void) -> OnDeviceRunner.WaitingReply {
        let id = UUID()
        let cancelNow = lock.withLock { () -> Bool in
            if closed { return true }
            born[id] = generation
            cancels[id] = cancel
            return false
        }
        if cancelNow { cancel() }
        return OnDeviceRunner.WaitingReply(id: id)
    }

    func unregister(_ reply: OnDeviceRunner.WaitingReply) {
        lock.withLock {
            born[reply.id] = nil
            cancels[reply.id] = nil
        }
    }

    /// The wait is over, so a later close must not run its cancel. The
    /// reply can still be refused, if leaving already happened.
    func silence(_ reply: OnDeviceRunner.WaitingReply) {
        lock.withLock { cancels[reply.id] = nil }
    }

    func accepts(_ reply: OnDeviceRunner.WaitingReply?) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            guard let reply else { return true }
            return born[reply.id] == generation
        }
    }

    func close() {
        let stop: [@Sendable () -> Void] = lock.withLock {
            closed = true
            generation &+= 1
            let stop = Array(cancels.values)
            cancels.removeAll()
            let task = current
            return stop + [{ task?.cancel() }]
        }
        for cancel in stop { cancel() }
    }

    func open() {
        lock.withLock { closed = false }
    }

    /// Starts `work` unless the gate is closed, or `reply` was registered
    /// before a close. Opening again does not make such a reply acceptable.
    func admit(_ reply: OnDeviceRunner.WaitingReply?,
               _ work: @escaping @Sendable () async throws -> String) -> Task<String, Error>? {
        lock.withLock {
            guard !closed else { return nil }
            if let reply {
                guard born.removeValue(forKey: reply.id) == generation else { return nil }
            }
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
