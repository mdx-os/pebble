import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import PebbleCore
import Tokenizers

/// Why an on-device model folder could not be loaded.
///
/// A failure is remembered. The next reply throws the same error and does not
/// load the folder again.
public enum MLXChatModelError: Error, Equatable, Sendable {
    /// The folder is missing a file the loader needs, or the load itself failed.
    case unavailable
    /// `config.json` is present but is not usable model configuration.
    case invalidConfiguration
}

/// On-device MLX adapter for `ModelClient`.
///
/// Loads weights from a directory the person already has on this device.
/// `loadContainer(from:using:)` reads that directory and does not use a
/// downloader. Tokenizer files are read from the same directory. Replies are
/// generated on device. This type does not open a network connection.
public actor MLXChatModel: ModelClient {
    /// Caps the MLX allocator cache so a long reply does not keep every freed buffer.
    static let cacheLimitBytes = 64 * 1024 * 1024

    private let directory: URL
    private var loaded: ModelContainer?
    private var loadFailure: MLXChatModelError?
    private var loading: Task<ModelContainer, Error>?

    public init(directory: URL) {
        self.directory = directory
    }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        guard transcript.contains(where: { $0.speaker == .person }) else {
            throw ModelClientError.noPersonTurn
        }
        let container = try await container()
        let prepared = try await container.prepare(input: UserInput(chat: Self.messages(for: transcript)))
        let stream = try await container.generate(
            input: prepared,
            parameters: GenerateParameters(maxTokens: OnDeviceTranscript.maxReplyTokens)
        )
        return await Self.text(from: stream)
    }

    private func container() async throws -> ModelContainer {
        if let loaded {
            return loaded
        }
        if let loadFailure {
            throw loadFailure
        }
        let task: Task<ModelContainer, Error>
        if let loading {
            task = loading
        } else {
            task = Task { try await self.performLoad() }
            loading = task
        }
        do {
            let container = try await task.value
            loaded = container
            loading = nil
            return container
        } catch let error as MLXChatModelError {
            loadFailure = error
            loading = nil
            throw error
        } catch {
            loadFailure = .unavailable
            loading = nil
            throw MLXChatModelError.unavailable
        }
    }

    private func performLoad() async throws -> ModelContainer {
        try preflight()
        Memory.cacheLimit = Self.cacheLimitBytes
        return try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalDirectoryTokenizerLoader()
        )
    }

    /// Confirms the folder can be loaded before MLX reads the weights.
    private func preflight() throws {
        let configURL = directory.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw MLXChatModelError.unavailable
        }
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw MLXChatModelError.unavailable
        }
        do {
            _ = try JSONDecoder.json5().decode(ModelTypeProbe.self, from: data)
        } catch {
            throw MLXChatModelError.invalidConfiguration
        }
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            throw MLXChatModelError.unavailable
        }
        guard Self.containsWeights(in: directory) else {
            throw MLXChatModelError.unavailable
        }
    }

    private static func containsWeights(in directory: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return files.contains { file in
            guard file.pathExtension == "safetensors" else { return false }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
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

private struct ModelTypeProbe: Decodable {
    let modelType: String

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
    }
}

/// Reads tokenizer files from the model directory. Does not download them.
private struct LocalDirectoryTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizerData = try Self.readConfig(named: "tokenizer.json", in: directory)
        let tokenizerConfig = try Self.tokenizerConfig(in: directory)
        let upstream = try AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
        return LocalFileTokenizer(upstream: upstream)
    }

    /// The same chat-template merge the folder loader applied, without building a hub client.
    private static func tokenizerConfig(in directory: URL) throws -> Config {
        var config: Config?
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            config = try readConfig(at: configURL)
        }
        if let template = chatTemplate(in: directory) {
            if var dict = config?.dictionary() {
                dict["chat_template"] = Config(template)
                config = Config(dict)
            } else {
                config = Config(["chat_template": Config(template)])
            }
        }
        guard let config else {
            throw MLXChatModelError.unavailable
        }
        return config
    }

    /// Prefers `chat_template.jinja`. A failed read does not fall through to the JSON file.
    private static func chatTemplate(in directory: URL) -> String? {
        let jinjaURL = directory.appendingPathComponent("chat_template.jinja")
        let jsonURL = directory.appendingPathComponent("chat_template.json")
        if FileManager.default.fileExists(atPath: jinjaURL.path) {
            return try? String(contentsOf: jinjaURL, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: jsonURL.path),
                  let parsed = try? readConfig(at: jsonURL) {
            return parsed["chat_template"].string()
        }
        return nil
    }

    private static func readConfig(named name: String, in directory: URL) throws -> Config {
        try readConfig(at: directory.appendingPathComponent(name))
    }

    private static func readConfig(at url: URL) throws -> Config {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MLXChatModelError.unavailable
        }
        do {
            return try JSONDecoder.json5().decode(Config.self, from: data)
        } catch {
            throw MLXChatModelError.invalidConfiguration
        }
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
