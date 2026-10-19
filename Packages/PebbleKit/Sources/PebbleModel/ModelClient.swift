import Foundation
import PebbleCore

/// The boundary between the chat and a model.
///
/// `ChatView` asks a `ModelClient` for each reply. The app passes
/// `LocalStubModel`, so Mac, iPhone, iPad, tests, and screenshots run
/// without downloading weights.
///
/// A real adapter is a `Sendable` type in this layer that implements
/// `reply(to:)`. Pass it into `ChatView` the same way the app passes
/// `LocalStubModel`.
///
/// MLX plugs in on device: load an open-weight model, generate from the
/// transcript, and keep the weights on the device. That path does not use
/// the network.
///
/// Ollama plugs in locally: send the transcript to an Ollama server the
/// person is already running on this machine, at its loopback address on
/// port 11434.
/// That request stays in this layer.
///
/// PebbleCore does not do networking. A cloud model stays off until the
/// person chooses one: `CloudModel` is that adapter, `ModelChoice` only
/// hands it out with the setting on, and it shows the person every request
/// before it is sent.
public protocol ModelClient: Sendable {
    /// Answers the transcript. The newest person turn is the message to answer.
    /// Call this only through `Conversation.appendingReply`. It answers words
    /// of crisis (and the message right after) without a model, and takes
    /// those exchanges out of every transcript a model sees.
    func reply(to transcript: [ChatTurn]) async throws -> String

    /// True only when every word stays on this device. Every promise about
    /// the device, in the chat and in memory, follows this through
    /// `privacyPlace`. A cloud model must say false.
    var runsOnDevice: Bool { get }
}

extension ModelClient {
    /// Off by default, so a new adapter never makes a promise it can't keep.
    public var runsOnDevice: Bool { false }

    /// The one source for every "on this device" line. The app passes this
    /// down from the active model; nothing keeps a second copy.
    public var privacyPlace: PrivacyPlace { PrivacyPlace(staysOnDevice: runsOnDevice) }
}

public enum ModelClientError: Error, Equatable, Sendable {
    /// The transcript has no person turn to answer.
    case noPersonTurn
}
