import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import PebbleCore
import Tokenizers

/// One line the on-device model sees, in chat order.
public struct OnDeviceTranscriptLine: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case system
        case agent
        case person
    }

    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// The words sent to the on-device model with a transcript. Only
/// `MLXChatModel` sends them, and it runs here, so the system line is true.
public enum OnDeviceTranscript {
    /// Plain words in front of the transcript. The product name is not included.
    public static let instructions = "You are the person's agent on this device. Reply in plain words. Stay with what they asked. Nothing from this conversation leaves the device."

    /// Stop a reply after this many tokens so generation finishes.
    public static let maxReplyTokens = 512

    /// How many recent turns go with the system line. Older turns are left out.
    public static let maxHistoryTurns = 24

    /// The system line, then the most recent turns in order.
    public static func lines(for transcript: [ChatTurn]) -> [OnDeviceTranscriptLine] {
        var lines = [OnDeviceTranscriptLine(role: .system, text: instructions)]
        let recent = transcript.suffix(maxHistoryTurns)
        for turn in recent {
            switch turn.speaker {
            case .agent:
                lines.append(OnDeviceTranscriptLine(role: .agent, text: turn.text))
            case .person:
                lines.append(OnDeviceTranscriptLine(role: .person, text: turn.text))
            }
        }
        return lines
    }

    /// The lines whose prompt fits in `budget` tokens, as `count` measures
    /// them. The oldest turns go first; the system line and the latest
    /// message always stay. Throws `MLXChatModelError.tooLong` when those
    /// two alone don't fit.
    public static func fitting(
        _ lines: [OnDeviceTranscriptLine],
        budget: Int,
        count: ([OnDeviceTranscriptLine]) async throws -> Int
    ) async throws -> [OnDeviceTranscriptLine] {
        guard lines.count > 2 else {
            guard try await count(lines) <= budget else { throw MLXChatModelError.tooLong }
            return lines
        }
        let system = lines[0]
        let turns = Array(lines.dropFirst())
        func keeping(_ dropped: Int) -> [OnDeviceTranscriptLine] {
            [system] + turns.dropFirst(dropped)
        }
        if try await count(keeping(0)) <= budget { return keeping(0) }
        // Fewer turns never take more tokens, so search for the fewest to drop.
        var tooFew = 0
        var enough = turns.count - 1
        guard try await count(keeping(enough)) <= budget else { throw MLXChatModelError.tooLong }
        while enough - tooFew > 1 {
            let middle = (tooFew + enough) / 2
            if try await count(keeping(middle)) <= budget {
                enough = middle
            } else {
                tooFew = middle
            }
        }
        return keeping(enough)
    }
}

/// Why an on-device model folder could not be loaded.
///
/// A failure is remembered. The next reply throws the same error and does not
/// load the folder again.
public enum MLXChatModelError: Error, Equatable, Sendable {
    /// The folder is missing a file the loader needs, or the load itself failed.
    case unavailable
    /// `config.json` is present but is not usable model configuration.
    case invalidConfiguration
    /// The latest message alone is more than the model can read at once.
    /// Nothing was generated, and a shorter message can still be answered.
    case tooLong
    /// The app went to the background before the reply was done, so it was
    /// stopped. The same message can be sent again once the app is back.
    case interrupted

    /// True when the folder itself could not be loaded, so no reply from it
    /// will work until it is replaced.
    public var isLoadFailure: Bool {
        switch self {
        case .unavailable, .invalidConfiguration: true
        case .tooLong, .interrupted: false
        }
    }
}

/// One whole reply from the on-device model: loading if needed, reading
/// the prompt, and generating to the end. Stops soon after its task is
/// cancelled.
protocol OnDeviceGenerating: Sendable {
    func reply(to transcript: [ChatTurn]) async throws -> String
    /// Waits for every piece of work already sent to the graphics chip.
    /// Runs after each reply, however it ended, before the next one starts.
    func drain() async
}

/// On-device MLX adapter for `ModelClient`.
///
/// Loads weights from a directory the person already has on this device.
/// `loadContainer(from:using:)` reads that directory and does not use a
/// downloader. Tokenizer files are read from the same directory. Replies are
/// generated on device, one at a time through `OnDeviceRunner`. This type
/// does not open a network connection.
public final class MLXChatModel: ModelClient, Sendable {
    /// Caps the MLX allocator cache so a long reply does not keep every freed buffer.
    static let cacheLimitBytes = 64 * 1024 * 1024

    private let directory: URL
    private let runner: OnDeviceRunner
    private let generator: any OnDeviceGenerating

    public convenience init(directory: URL, runner: OnDeviceRunner = .shared) {
        self.init(directory: directory, runner: runner, generator: MLXGenerator(directory: directory))
    }

    init(directory: URL, runner: OnDeviceRunner, generator: any OnDeviceGenerating) {
        self.directory = directory
        self.runner = runner
        self.generator = generator
    }

    /// The weights and every word stay on this device.
    public var runsOnDevice: Bool { true }

    /// The folder this model loads.
    public var folder: URL { directory }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        guard transcript.contains(where: { $0.speaker == .person }) else {
            throw ModelClientError.noPersonTurn
        }
        let generator = generator
        return try await runner.run({ try await generator.reply(to: transcript) },
                                    drain: { await generator.drain() })
    }

    /// The reply's length and the cache's size, both inside `OnDeviceModel.contextTokens`.
    static var parameters: GenerateParameters {
        GenerateParameters(maxTokens: OnDeviceTranscript.maxReplyTokens, maxKVSize: OnDeviceModel.contextTokens)
    }
}

/// Loads the folder once, on the first reply, and answers with MLX.
///
/// A failed load is remembered. The next reply throws the same error and
/// does not load the folder again. A load stopped part way is not a
/// failure, and the next reply loads again.
actor MLXGenerator: OnDeviceGenerating {
    private let directory: URL
    private var loaded: ModelContainer?
    private var loadFailure: MLXChatModelError?
    /// True once MLX was asked to load, so there may be work to wait for.
    private var touchedModel = false

    init(directory: URL) {
        self.directory = directory
    }

    /// A stop while the prompt is read throws before its last evaluation,
    /// and the weights' evaluation runs on through a stopped load, so work
    /// can still be on the graphics chip when `reply` ends. Waits for it.
    func drain() {
        guard touchedModel else { return }
        MLX.Stream.gpu.synchronize()
        MLX.Stream.cpu.synchronize()
    }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        let container = try await container()
        try Task.checkCancellation()
        let lines = try await Self.fitted(OnDeviceTranscript.lines(for: transcript), in: container)
        try Task.checkCancellation()
        return try await container.perform { context in
            try await Self.generate(lines, context: context)
        }
    }

    /// Reads the prompt and generates the reply. When cancelled, stops
    /// taking new tokens and waits for the model's last work to end.
    private static func generate(_ lines: [OnDeviceTranscriptLine], context: ModelContext) async throws -> String {
        let input = try await context.processor.prepare(input: UserInput(chat: messages(for: lines)))
        try Task.checkCancellation()
        let iterator = try TokenIterator(input: input, model: context.model, parameters: MLXChatModel.parameters)
        let (stream, task) = generateTask(promptTokenCount: input.text.tokens.size,
                                          modelConfiguration: context.configuration,
                                          tokenizer: context.tokenizer, iterator: iterator)
        let reply = await withTaskCancellationHandler {
            await text(from: stream)
        } onCancel: {
            task.cancel()
        }
        await task.value
        try Task.checkCancellation()
        return reply
    }

    /// The lines that fit `OnDeviceModel.promptTokens`, counted with the model's own tokenizer and chat template.
    private static func fitted(_ lines: [OnDeviceTranscriptLine],
                               in container: ModelContainer) async throws -> [OnDeviceTranscriptLine] {
        try await container.perform { context in
            try await OnDeviceTranscript.fitting(lines, budget: OnDeviceModel.promptTokens) { candidate in
                try await context.processor.prepare(input: UserInput(chat: messages(for: candidate))).text.tokens.size
            }
        }
    }

    private func container() async throws -> ModelContainer {
        if let loaded {
            return loaded
        }
        if let loadFailure {
            throw loadFailure
        }
        do {
            let container = try await performLoad()
            loaded = container
            return container
        } catch let error as MLXChatModelError {
            loadFailure = error
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            loadFailure = .unavailable
            throw MLXChatModelError.unavailable
        }
    }

    private func performLoad() async throws -> ModelContainer {
        try preflight()
        touchedModel = true
        Memory.cacheLimit = MLXChatModel.cacheLimitBytes
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

    private static func messages(for lines: [OnDeviceTranscriptLine]) -> [Chat.Message] {
        lines.map { line in
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
