import Foundation

/// Lets one on-device reply run at a time, from loading and reading the
/// prompt to the last word or a stop, and none while the app is away.
///
/// Each reply holds its own cache, about 450 MB at the full context, so two
/// at once, as from two windows, would pass the memory the model was let in
/// with. A reply that comes while another runs waits its turn. A stopped
/// reply has finished all its work on the model before the next one starts.
///
/// On iPhone and iPad the system refuses work on the graphics chip once the
/// app is in the background, so `leaveForeground` stops the reply under way
/// and waits for it, and no new one starts until `returnToForeground`.
public actor OnDeviceRunner {
    /// The app's one runner, shared by every on-device model it makes.
    public static let shared = OnDeviceRunner()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var current: Task<String, Error>?
    private var away = false

    public init() {}

    /// Runs `work` once no other reply is running. Throws
    /// `MLXChatModelError.interrupted` when the app is away, or goes away
    /// before `work` ends.
    func run(_ work: @escaping @Sendable () async throws -> String) async throws -> String {
        guard !away else { throw MLXChatModelError.interrupted }
        await takeTurn()
        defer { passTurn() }
        guard !away else { throw MLXChatModelError.interrupted }
        try Task.checkCancellation()
        let task = Task { try await work() }
        current = task
        defer { current = nil }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        if case .failure = result, away { throw MLXChatModelError.interrupted }
        return try result.get()
    }

    /// The app left the foreground. No reply starts from here, the one
    /// under way is stopped, and this returns once it has ended.
    public func leaveForeground() async {
        away = true
        current?.cancel()
        await takeTurn()
        passTurn()
    }

    /// The app is in front again, so replies can start.
    public func returnToForeground() {
        away = false
    }

    /// True while the app is away and nothing new starts.
    public var isAway: Bool { away }

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
