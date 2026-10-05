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
/// person is already running on this machine, at 127.0.0.1 port 11434.
/// That request stays in this layer.
///
/// PebbleCore does not do networking. A cloud model stays off until the
/// person chooses one.
public protocol ModelClient: Sendable {
    /// Answers the transcript. The newest person turn is the message to answer.
    func reply(to transcript: [ChatTurn]) async throws -> String
}

public enum ModelClientError: Error, Equatable, Sendable {
    /// The transcript has no person turn to answer.
    case noPersonTurn
}
