import Foundation
import MLXLLM
import MLXLMCommon
import PebbleCore
import Tokenizers

/// On-device MLX adapter for `ModelClient`.
///
/// Loads weights from a directory the person already has on this device.
/// `loadContainer(from:using:)` reads that directory and does not use a
/// downloader. The tokenizer is read from the same directory. Replies are
/// generated on device. This type does not open a network connection.
public actor MLXChatModel: ModelClient {
    private let directory: URL
    private var loaded: ModelContainer?

    public init(directory: URL) {
        self.directory = directory
    }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        guard transcript.contains(where: { $0.speaker == .person }) else {
            throw ModelClientError.noPersonTurn
        }
        let container = try await loadContainer()
        let prepared = try await container.prepare(input: UserInput(chat: Self.messages(for: transcript)))
        let stream = try await container.generate(
            input: prepared,
            parameters: GenerateParameters(maxTokens: OnDeviceTranscript.maxReplyTokens)
        )
        return await Self.text(from: stream)
    }

    private func loadContainer() async throws -> ModelContainer {
        if let loaded {
            return loaded
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalDirectoryTokenizerLoader()
        )
        loaded = container
        return container
    }

    private static func messages(for transcript: [ChatTurn]) -> [Chat.Message] {
        OnDeviceTranscript.lines(for: transcript).map { line in
            switch line.role {
            case .system:
                Chat.Message.system(line.text)
            case .agent:
                Chat.Message.assistant(line.text)
            case .person:
                Chat.Message.user(line.text)
            }
        }
    }

    private static func text(from stream: AsyncStream<Generation>) async -> String {
        var reply = ""
        for await event in stream {
            switch event {
            case .chunk(let text):
                reply += text
            case .info, .toolCall, .rejectedToolCall:
                break
            }
        }
        return reply
    }
}

/// Reads tokenizer files from the model directory. Does not download them.
private struct LocalDirectoryTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return LocalFileTokenizer(upstream: upstream)
    }
}

/// Adapts a local tokenizer to the MLX tokenizer interface.
private struct LocalFileTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
