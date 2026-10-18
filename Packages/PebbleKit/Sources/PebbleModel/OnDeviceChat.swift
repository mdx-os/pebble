import Foundation
import PebbleCore

/// The app's one model client: the on-device model once it is ready, and
/// until then the placeholder that says why it isn't. A finished download
/// moves it over at once, without a new screen or a relaunch, and the chat
/// already open answers with the model from its next reply.
///
/// It only ever holds a model whose `runsOnDevice` is true, so it says true
/// too, and every line that reads its place stays honest.
public final class OnDeviceChat: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any ModelClient

    public init(_ initial: any ModelClient) {
        precondition(initial.runsOnDevice, "OnDeviceChat takes only a model whose runsOnDevice is true")
        current = initial
    }

    public var runsOnDevice: Bool { true }

    /// The model answering now.
    public var active: any ModelClient {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Answers with `model` from the next reply on. A model whose words may
    /// leave is refused, and the current one stays.
    @discardableResult
    public func use(_ model: any ModelClient) -> Bool {
        guard model.runsOnDevice else { return false }
        lock.lock()
        current = model
        lock.unlock()
        return true
    }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        try await active.reply(to: transcript)
    }
}
