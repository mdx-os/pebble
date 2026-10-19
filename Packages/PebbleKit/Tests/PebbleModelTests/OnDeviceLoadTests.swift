import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import PebbleModel
import Testing

/// A tiny Qwen3 model with random weights, the pinned model's own kind,
/// written to a folder as a download leaves it.
private enum TinyQwen {
    static let config = #"""
    {"model_type": "qwen3", "hidden_size": 8, "num_hidden_layers": 1, "intermediate_size": 16,
     "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 4, "rms_norm_eps": 1e-6,
     "vocab_size": 8, "tie_word_embeddings": true, "eos_token_id": 3}
    """#

    static let generationConfig = #"{"eos_token_id": [3, 5], "stop_strings": ["gg"]}"#

    static let tokenizer = #"""
    {"model": {"type": "BPE", "vocab": {"a": 0, "b": 1, "c": 2, "<|im_end|>": 3, "d": 4, "e": 5, "f": 6, "g": 7},
               "merges": []},
     "added_tokens": [{"id": 3, "content": "<|im_end|>", "special": true}]}
    """#

    static let tokenizerConfig = #"""
    {"tokenizer_class": "Qwen2Tokenizer", "eos_token": "<|im_end|>",
     "chat_template": "{% for message in messages %}{{ message['content'] }}{% endfor %}"}
    """#

    static func folder() async throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-qwen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in ["config.json": config, "generation_config.json": generationConfig,
                             "tokenizer.json": tokenizer, "tokenizer_config.json": tokenizerConfig] {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        let model = try await LLMModelFactory.shared.typeRegistry.createModel(configuration: Data(config.utf8),
                                                                               modelType: "qwen3")
        let arrays = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
        eval(Array(arrays.values))
        try save(arrays: arrays, url: folder.appendingPathComponent("model.safetensors"))
        return folder
    }

    /// The prompt's tokens, the logits for it, and the configuration.
    static func run(_ container: ModelContainer) async throws -> ([Int32], [Float], ModelConfiguration) {
        try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(chat: [.user("abc")]))
            let logits = context.model(input.text.tokens[.newAxis], cache: nil)
            return (input.text.tokens.asArray(Int32.self), logits.asArray(Float.self), context.configuration)
        }
    }
}

/// A Qwen3 model that writes down MLX's default device as each step of a
/// load reaches it: making the model, sanitizing the weights read from the
/// safetensors, and preparing it before the last evaluation.
private final class DeviceProbe: Module, LLMModel, KVCacheDimensionProvider {
    static let type = "device_probe"
    nonisolated(unsafe) private static var seen: [String] = []
    private static let lock = NSLock()

    @ModuleInfo(key: "inner") var inner: Qwen3Model

    init(_ data: Data) throws {
        Self.note("make")
        _inner.wrappedValue = Qwen3Model(try JSONDecoder().decode(Qwen3Configuration.self, from: data))
    }

    static func note(_ step: String) {
        let device = Device.defaultDevice().deviceType == .cpu ? "processor" : "graphics chip"
        lock.withLock { seen.append("\(step) on the \(device)") }
    }

    static func take() -> [String] {
        lock.withLock {
            defer { seen = [] }
            return seen
        }
    }

    var loraLayers: [Module] { inner.loraLayers }
    var kvHeads: [Int] { inner.kvHeads }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        Self.note("sanitize")
        return Dictionary(uniqueKeysWithValues: inner.sanitize(weights: weights).map { ("inner." + $0, $1) })
    }

    func prepare() throws {
        Self.note("prepare")
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        inner(inputs, cache: cache)
    }
}

/// MLX can make arrays only where it was built with its programs for the
/// graphics chip, as `xcodebuild` builds it (`make model-test`). `swift
/// test` builds it without them, so these tests wait for that run, which
/// sets `MLX_MODEL_TEST` and fails if MLX can't run there.
private let mlxRuns = Bundle.allBundles.contains { bundle in
    let programs = bundle.bundleURL.deletingLastPathComponent()
        .appending(path: "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    return FileManager.default.fileExists(atPath: programs.path)
}
private let mlxRequired = ProcessInfo.processInfo.environment["MLX_MODEL_TEST"] == "1"

@Suite(.enabled(if: mlxRuns || mlxRequired, "MLX runs only in make model-test"))
struct OnDeviceLoadTests {
    init() throws {
        try #require(mlxRuns, "make model-test found no MLX programs for the graphics chip")
    }

    /// `OnDeviceLoad` takes `LLMModelFactory._load`'s steps with the
    /// processor as the device. The same folder loaded both ways gives the
    /// same configuration, the same tokens for a chat, and the same logits,
    /// so the model the chat gets is the one the library would have made.
    @Test func theLoadOnTheProcessorMakesTheLibrarysModel() async throws {
        let folder = try await TinyQwen.folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let ours = try await TinyQwen.run(
            OnDeviceLoad.container(from: folder, tokenizerLoader: LocalDirectoryTokenizerLoader()))
        let library = try await TinyQwen.run(
            LLMModelFactory.shared.loadContainer(from: folder, using: LocalDirectoryTokenizerLoader()))

        #expect(ours.0 == [0, 1, 2])
        #expect(ours.0 == library.0)
        #expect(ours.1.count == 3 * 8)
        #expect(zip(ours.1, library.1).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(ours.2 == library.2)
        #expect(ours.2.eosTokenIds == [3, 5])
        #expect(ours.2.stopStrings == ["gg"])
        #expect(ours.2.reasoningConfig != nil)
    }

    /// Every step of the load that makes MLX work runs with the processor
    /// as the default device, the weights' too on the loading thread, so a
    /// load sends the graphics chip nothing, however late the app leaves.
    /// The library's own load, for contrast, runs them on the graphics chip.
    @Test func everyStepOfTheLoadRunsOnTheProcessor() async throws {
        await LLMModelFactory.shared.typeRegistry.registerModelType(DeviceProbe.type) { try DeviceProbe($0) }
        let folder = try await TinyQwen.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = try String(contentsOf: folder.appendingPathComponent("config.json"), encoding: .utf8)
        try Data(config.replacingOccurrences(of: "\"qwen3\"", with: "\"\(DeviceProbe.type)\"").utf8)
            .write(to: folder.appendingPathComponent("config.json"))
        _ = DeviceProbe.take()

        _ = try await OnDeviceLoad.container(from: folder, tokenizerLoader: LocalDirectoryTokenizerLoader())
        #expect(DeviceProbe.take() == ["make on the processor", "sanitize on the processor",
                                       "prepare on the processor"])

        _ = try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalDirectoryTokenizerLoader())
        #expect(DeviceProbe.take() == ["make on the graphics chip", "sanitize on the graphics chip",
                                       "prepare on the graphics chip"])
    }
}
