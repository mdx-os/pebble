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

/// Weights that open on the processor, before a reply takes its turn on
/// the graphics chip. Leaving the app during this must return at once:
/// the load sends the chip nothing, so the background callback must not
/// wait for it.
protocol ProcessorLoading: Sendable {
    func loadOffTheChip() async throws
}

/// Remembers that the weights opened, and tells one listener, including a
/// listener set after the fact.
final class LoadSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: (@Sendable (URL) -> Void)?
    private var folder: URL?

    var hasLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return folder != nil
    }

    func whenLoaded(_ listener: @escaping @Sendable (URL) -> Void) {
        let existing: URL? = lock.withLock {
            self.listener = listener
            return folder
        }
        if let existing { listener(existing) }
    }

    func didLoad(_ folder: URL) {
        let listener: (@Sendable (URL) -> Void)? = lock.withLock {
            self.folder = folder
            return self.listener
        }
        listener?(folder)
    }
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
    private let loads: LoadSignal

    public convenience init(directory: URL, runner: OnDeviceRunner = .shared) {
        let loads = LoadSignal()
        self.init(directory: directory, runner: runner,
                  generator: MLXGenerator(directory: directory, engine: MLXEngine(),
                                          onLoaded: { loads.didLoad($0) }),
                  loads: loads)
    }

    init(directory: URL, runner: OnDeviceRunner, generator: any OnDeviceGenerating, loads: LoadSignal = LoadSignal()) {
        self.directory = directory
        self.runner = runner
        self.generator = generator
        self.loads = loads
    }

    /// True after the weights have opened. A new model is not ready before this.
    public var hasLoaded: Bool { loads.hasLoaded }

    /// Called with the folder once the weights have opened, including when
    /// they opened before the listener was set.
    func whenLoaded(_ listener: @escaping @Sendable (URL) -> Void) {
        loads.whenLoaded(listener)
    }

    /// Records a successful load. The real load calls this; tests do too,
    /// because `swift test` builds MLX without the programs a load needs.
    func noteLoaded() {
        loads.didLoad(directory)
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
        // The load is not a turn. Holding the turn for it would make
        // leaving wait until the weights opened, which is too late: the
        // callback has to return while a first load can still be running,
        // and nothing from that load may reach the graphics chip.
        // The reply still has to be cancellable while it waits. The
        // registration cancels that wait only. The shared load keeps going
        // and is reused, and coming back does not let this reply generate.
        if let loader = generator as? any ProcessorLoading {
            if runner.isAway { throw MLXChatModelError.interrupted }
            // Register before the load starts. The load can reach its first
            // step on another thread, and leaving has to find this reply
            // already registered. The slot takes a cancel that arrives
            // before the task exists.
            let slot = CancelSlot()
            let waiting = runner.registerWaiting { slot.fire() }
            defer { runner.unregisterWaiting(waiting) }
            if runner.isAway { throw MLXChatModelError.interrupted }
            let load = Task { try await loader.loadOffTheChip() }
            slot.arm { load.cancel() }
            do {
                try await withTaskCancellationHandler {
                    try await load.value
                } onCancel: {
                    load.cancel()
                }
            } catch is CancellationError {
                throw MLXChatModelError.interrupted
            }
            return try await runner.run({ try await generator.reply(to: transcript) },
                                        drain: { await generator.drain() },
                                        waiting: waiting)
        }
        return try await runner.run({ try await generator.reply(to: transcript) },
                                    drain: { await generator.drain() })
    }

    /// The reply's length and the cache's size, both inside `OnDeviceModel.contextTokens`.
    static var parameters: GenerateParameters {
        GenerateParameters(maxTokens: OnDeviceTranscript.maxReplyTokens, maxKVSize: OnDeviceModel.contextTokens)
    }
}

/// What `MLXGenerator` runs: a load that never uses the graphics chip, and
/// a reply that does. Tests stand in for it.
protocol OnDeviceEngine: Sendable {
    associatedtype Loaded: Sendable
    /// Confirms the folder can be loaded, before anything touches MLX.
    func preflight(_ directory: URL) throws
    /// Loads the folder, on the processor only.
    func load(_ directory: URL) async throws -> Loaded
    /// Reads the prompt and writes the reply, on the graphics chip.
    func reply(to lines: [OnDeviceTranscriptLine], with loaded: Loaded) async throws -> String
    /// Waits for every piece of work already sent to the graphics chip.
    func drain()
}

/// Loads the folder once, on the first reply, and answers with its engine.
///
/// The load runs on its own, on the processor, and is never stopped. It
/// is not a reply's turn, so leaving the app while it runs returns without
/// waiting and sends the graphics chip nothing. The load goes on and is
/// kept for the next reply. A failed load is remembered. The next reply
/// throws the same error and does not load the folder again.
actor MLXGenerator<Engine: OnDeviceEngine>: OnDeviceGenerating, ProcessorLoading {
    private let directory: URL
    private let engine: Engine
    private let onLoaded: @Sendable (URL) -> Void
    private var loaded: Engine.Loaded?
    private var loading: Task<Engine.Loaded, Error>?
    private var loadFailure: MLXChatModelError?
    /// True once a reply has sent work to the graphics chip, so there may be work to wait for.
    private var usedChip = false

    init(directory: URL, engine: Engine, onLoaded: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.directory = directory
        self.engine = engine
        self.onLoaded = onLoaded
    }

    func drain() {
        guard usedChip else { return }
        engine.drain()
    }

    /// Opens the weights on the processor, if they are not open yet.
    /// A stop ends the wait, not the load. Nothing here uses the graphics chip.
    func loadOffTheChip() async throws {
        _ = try await container()
    }

    func reply(to transcript: [ChatTurn]) async throws -> String {
        let loaded = try await container()
        // The gate closing as the app leaves stops the reply here, before
        // anything is sent to the graphics chip.
        try Task.checkCancellation()
        usedChip = true
        return try await engine.reply(to: OnDeviceTranscript.lines(for: transcript), with: loaded)
    }

    /// The loaded folder, waiting for a load under way, or starting one.
    /// A stop ends the wait, not the load.
    private func container() async throws -> Engine.Loaded {
        if let loaded {
            return loaded
        }
        if let loadFailure {
            throw loadFailure
        }
        if let loading {
            return try await StopWaiting.value(of: loading)
        }
        do {
            try engine.preflight(directory)
        } catch {
            let failure = error as? MLXChatModelError ?? .unavailable
            loadFailure = failure
            throw failure
        }
        let engine = engine
        let directory = directory
        let load = Task.detached {
            let result: Result<Engine.Loaded, Error>
            do {
                result = .success(try await engine.load(directory))
            } catch {
                result = .failure(error)
            }
            return try await self.finished(result)
        }
        loading = load
        return try await StopWaiting.value(of: load)
    }

    /// Keeps a finished load, or remembers why it failed.
    private func finished(_ result: Result<Engine.Loaded, Error>) throws -> Engine.Loaded {
        loading = nil
        switch result {
        case .success(let container):
            loaded = container
            onLoaded(directory)
            return container
        case .failure(let error):
            let failure = error as? MLXChatModelError ?? .unavailable
            loadFailure = failure
            throw failure
        }
    }
}

/// A cancel that may fire before its action is armed. Firing first still
/// runs the action once it is set, so a leave during that gap is not lost.
private final class CancelSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var fired = false

    func fire() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            fired = true
            let action = self.action
            self.action = nil
            return action
        }
        action?()
    }

    func arm(_ action: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if fired { return true }
            self.action = action
            return false
        }
        if runNow { action() }
    }
}

/// Waits for a task unless the waiting task is stopped first. The task
/// itself goes on either way.
enum StopWaiting {
    static func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                Task.detached { once.resume(with: await task.result) }
            }
        } onCancel: {
            once.resume(with: .failure(CancellationError()))
        }
    }

    /// Resumes one continuation once, with whichever result comes first,
    /// even one that comes before the continuation does.
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var done = false

        func set(_ continuation: CheckedContinuation<T, Error>) {
            let early: Result<T, Error>? = lock.withLock {
                guard let early = self.early else {
                    self.continuation = continuation
                    return nil
                }
                done = true
                return early
            }
            if let early { continuation.resume(with: early) }
        }

        func resume(with result: Result<T, Error>) {
            let waiting: CheckedContinuation<T, Error>? = lock.withLock {
                guard !done else { return nil }
                guard let continuation else {
                    if early == nil { early = result }
                    return nil
                }
                done = true
                self.continuation = nil
                return continuation
            }
            waiting?.resume(with: result)
        }
    }
}

/// The real engine: MLX, with the folder loaded on the processor by
/// `OnDeviceLoad`.
struct MLXEngine: OnDeviceEngine {
    func preflight(_ directory: URL) throws {
        try Self.check(directory)
    }

    func load(_ directory: URL) async throws -> ModelContainer {
        Memory.cacheLimit = MLXChatModel.cacheLimitBytes
        return try await OnDeviceLoad.container(from: directory, tokenizerLoader: LocalDirectoryTokenizerLoader())
    }

    func reply(to lines: [OnDeviceTranscriptLine], with container: ModelContainer) async throws -> String {
        let lines = try await Self.fitted(lines, in: container)
        try Task.checkCancellation()
        return try await container.perform { context in
            try await Self.generate(lines, context: context)
        }
    }

    /// A stop while the prompt is read throws before its last evaluation,
    /// so work can still be on the graphics chip when a reply ends. Waits
    /// for it. Only the global streams are synchronized: the copy of
    /// mlx-swift-lm in `Packages/MLXLM` generates on them. Generation run
    /// under `Stream.withNewDefaultStream` would need its own stream
    /// synchronized here.
    func drain() {
        MLX.Stream.gpu.synchronize()
        MLX.Stream.cpu.synchronize()
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

    /// Confirms the folder can be loaded before MLX reads the weights.
    private static func check(_ directory: URL) throws {
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
struct LocalDirectoryTokenizerLoader: TokenizerLoader {
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
