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
    /// The app left the foreground, or a reply was refused because it had.
    /// Nothing was kept as an answer, and the same message can be asked again.
    case stopped

    /// True when the folder itself could not be loaded, so no reply from it
    /// will work until it is replaced.
    public var isLoadFailure: Bool {
        switch self {
        case .unavailable, .invalidConfiguration: true
        case .tooLong, .stopped: false
        }
    }
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
    private let generation: OnDeviceGeneration
    private var loaded: ModelContainer?
    private var loadFailure: MLXChatModelError?
    private var loading: Task<ModelContainer, Error>?
    /// False from the moment the app leaves the foreground until it is back.
    private var loadsAllowed = true

    public init(directory: URL) {
        self.directory = directory
        self.generation = .shared
    }

    init(directory: URL, generation: OnDeviceGeneration) {
        self.directory = directory
        self.generation = generation
    }

    /// The weights and every word stay on this device.
    public nonisolated var runsOnDevice: Bool { true }

    /// The folder this model loads.
    public nonisolated var folder: URL { directory }

    public func stopForBackground() async {
        loadsAllowed = false
        loading?.cancel()
        await generation.stop()
        await Self.drainGPU()
    }

    public func resumeAfterBackground() async {
        loadsAllowed = true
        await generation.resume()
    }

    /// Stops every model that shares the process-wide generation, then drains.
    /// Used when the chat is no longer holding the model that was generating.
    static func drainShared() async {
        await OnDeviceGeneration.shared.stop()
        await drainGPU()
    }

    public func reply(to transcript: [ChatTurn]) async throws -> String {
        guard transcript.contains(where: { $0.speaker == .person }) else {
            throw ModelClientError.noPersonTurn
        }
        // One generation in the whole process. The next waits until this one
        // has left, including the drain after a cancel.
        return try await generation.run { slot in
            try await self.answer(transcript, slot: slot)
        }
    }

    private func answer(_ transcript: [ChatTurn], slot: GenerationSlot) async throws -> String {
        do {
            return try await generate(transcript, slot: slot)
        } catch {
            let backgrounded = !loadsAllowed || await generation.isClosed
            if backgrounded || Task.isCancelled {
                await Self.drainGPU()
            }
            if backgrounded && error is CancellationError {
                throw MLXChatModelError.stopped
            }
            throw error
        }
    }

    private func generate(_ transcript: [ChatTurn], slot: GenerationSlot) async throws -> String {
        if !loadsAllowed { throw MLXChatModelError.stopped }
        let container = try await container()
        let lines = try await Self.fitted(OnDeviceTranscript.lines(for: transcript), in: container)
        if !loadsAllowed || await generation.isClosed { throw MLXChatModelError.stopped }
        let (stream, task) = try await Self.stream(for: lines, in: container)
        slot.track(task)
        let text = await withTaskCancellationHandler {
            await Self.text(from: stream)
        } onCancel: {
            task.cancel()
        }
        // `task` synchronizes the GPU stream before it returns, so a cancel
        // does not leave an evaluation running into the next generation.
        await task.value
        if !loadsAllowed || await generation.isClosed { throw MLXChatModelError.stopped }
        try Task.checkCancellation()
        return text
    }

    /// The reply's length and the cache's size, both inside `OnDeviceModel.contextTokens`.
    static var parameters: GenerateParameters {
        GenerateParameters(maxTokens: OnDeviceTranscript.maxReplyTokens, maxKVSize: OnDeviceModel.contextTokens)
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
        } catch is CancellationError {
            // A stop while loading is not a broken folder. The next reply,
            // once the app is in front, loads again.
            loading = nil
            if !loadsAllowed { throw MLXChatModelError.stopped }
            throw CancellationError()
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

    /// The generation and the task that runs it. The task is what a cancel
    /// stops, and awaiting it waits until that generation's GPU work is done.
    private static func stream(for lines: [OnDeviceTranscriptLine],
                               in container: ModelContainer) async throws -> (AsyncStream<Generation>, Task<Void, Never>) {
        let generationParameters = Self.parameters
        return try await container.perform { context in
            let prepared = try await context.processor.prepare(
                input: UserInput(chat: messages(for: lines)))
            let iterator = try TokenIterator(
                input: prepared, model: context.model, parameters: generationParameters)
            return generateTask(
                promptTokenCount: prepared.text.tokens.size,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer,
                iterator: iterator)
        }
    }

    /// Waits until GPU work already submitted has finished, then frees cached buffers.
    private static func drainGPU() async {
        Stream.defaultStream.synchronize()
        Memory.clearCache()
    }

    private static func text(from stream: AsyncStream<Generation>) async -> String {
        var reply = ""
        for await event in stream {
            if Task.isCancelled { break }
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
