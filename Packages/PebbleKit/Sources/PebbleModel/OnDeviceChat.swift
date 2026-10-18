import Foundation
import PebbleCore

/// The app's one model client: the on-device model once it is ready, and
/// until then the placeholder that says why it isn't. A finished download
/// moves it over at once, without a new screen or a relaunch, and the chat
/// already open answers with the model from its next reply.
///
/// It only ever holds a model whose `runsOnDevice` is true, so it says true
/// too, and every line that reads its place stays honest.
///
/// When the model's folder can't be loaded, it moves back to the
/// placeholder, which says the model isn't ready, and tells whoever
/// listens through `onLoadFailure` which folder failed.
public final class OnDeviceChat: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any ModelClient
    private var loadFailureListener: (@Sendable (URL) -> Void)?

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

    /// Called with the folder each time a model's folder fails to load.
    public func onLoadFailure(_ listener: @escaping @Sendable (URL) -> Void) {
        lock.lock()
        loadFailureListener = listener
        lock.unlock()
    }

    public func stopForBackground() async {
        let model = active
        await model.stopForBackground()
        // A reply started on the previous model is still on the shared gate.
        if !(model is MLXChatModel) {
            await MLXChatModel.drainShared()
        }
    }

    public func resumeAfterBackground() async {
        await active.resumeAfterBackground()
    }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        let model = active
        do {
            return try await model.reply(to: transcript)
        } catch let error as MLXChatModelError where error.isLoadFailure {
            guard let failed = model as? MLXChatModel else { throw error }
            let placeholder = OnDeviceModel.model(for: .stub(.couldNotLoad))
            let (replaced, listener) = replace(failed, with: placeholder)
            // Another model put in place since this reply began stays, and answers.
            guard replaced else { return try await reply(to: transcript) }
            listener?(failed.folder)
            return try await placeholder.reply(to: transcript)
        }
    }

    /// Puts `placeholder` in for `failed`, unless another model is in place now.
    private func replace(_ failed: MLXChatModel, with placeholder: any ModelClient)
        -> (replaced: Bool, listener: (@Sendable (URL) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        guard (current as? MLXChatModel) === failed else { return (false, nil) }
        current = placeholder
        return (true, loadFailureListener)
    }
}
