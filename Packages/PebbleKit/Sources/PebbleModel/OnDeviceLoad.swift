import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Loads a model folder on the processor, never on the graphics chip.
///
/// iOS ends an app that sends work to the graphics chip from the
/// background, and a person can leave the app during the first load.
/// `LLMModelFactory.loadContainer` evaluates the weights on the default
/// device, the graphics chip, on a queue of its own that nothing can steer
/// or stop. So this takes the same steps as its `_load` in the copy of
/// mlx-swift-lm 3.32.3 in `Packages/MLXLM`, with the processor as MLX's
/// default device: building the model, reading the safetensors (MLX reads
/// them on the processor anyway), and the evaluation that makes the
/// weights real.
/// Nothing in a load reaches the graphics chip, so a load the app leaves
/// part way can finish in the background without harm. The weights are in
/// memory both chips share, and replies use them on the graphics chip as
/// they are.
///
/// Left out of `_load`: reading a tool call format from the tokenizer's
/// settings, since the chat never offers tools.
enum OnDeviceLoad {
    /// The folder's model, ready for replies. `MLXGenerator` runs it apart
    /// from any reply and never stops it, so a load the app leaves still
    /// ends and is kept.
    static func container(from directory: URL, tokenizerLoader: any TokenizerLoader) async throws -> ModelContainer {
        let tokenizer = try await tokenizerLoader.load(from: directory)
        let configData = try Data(contentsOf: directory.appending(component: "config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        // The device choice follows the task into the registry's actor.
        let model = try await Device.withDefaultDevice(.cpu) {
            try await LLMModelFactory.shared.typeRegistry.createModel(configuration: configData,
                                                                       modelType: base.modelType)
        }
        let box = ModelBox(model)
        try await onProcessor {
            // The synchronous loader, so its evaluation runs on this thread,
            // where the processor is the default device.
            try loadWeights(modelDirectory: directory, model: box.model,
                            perLayerQuantization: base.perLayerQuantization)
        }
        return ModelContainer(context: context(directory, base: base, model: model, tokenizer: tokenizer))
    }

    /// Runs `work` on a thread of its own, off Swift's shared threads, with
    /// the processor as MLX's default device there.
    static func onProcessor(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Device.withDefaultDevice(.cpu, work) })
            }
        }
    }

    private static func context(_ directory: URL, base: BaseConfiguration, model: any LanguageModel,
                                tokenizer: any Tokenizer) -> ModelContext {
        var eosTokenIds = base.effectiveEOSTokenIds
        let generation = (try? Data(contentsOf: directory.appending(component: "generation_config.json")))
            .flatMap { try? JSONDecoder.json5().decode(GenerationConfigFile.self, from: $0) }
        if let ids = generation?.eosTokenIds?.values {
            eosTokenIds = Set(ids)
        }
        // The name `_load` gives a local folder: its parent and its own.
        let name = directory.deletingLastPathComponent().lastPathComponent + "/" + directory.lastPathComponent
        let conventions = ChatConventionsRegistry.shared
        let toolCallFormat = conventions.toolCallFormat(modelId: name, modelType: base.modelType) ?? model.toolCallFormat
        let reasoningConfig = conventions.reasoningConfig(modelId: name, modelType: base.modelType)
            ?? model.reasoningConfig
        let messageGenerator = (model as? LLMModel)?.messageGenerator(tokenizer: tokenizer) ?? DefaultMessageGenerator()
        let configuration = ModelConfiguration(directory: directory, stopStrings: generation?.stopStrings ?? [],
                                               eosTokenIds: eosTokenIds, toolCallFormat: toolCallFormat,
                                               reasoningConfig: reasoningConfig)
        return ModelContext(configuration: configuration, model: model,
                            processor: ChatInputProcessor(tokenizer: tokenizer, messageGenerator: messageGenerator),
                            tokenizer: tokenizer)
    }
}

/// Hands the model to the loading thread. Only that thread uses it until
/// the load returns.
private final class ModelBox: @unchecked Sendable {
    let model: any LanguageModel

    init(_ model: any LanguageModel) {
        self.model = model
    }
}

/// Turns chat messages into the model's tokens, as `_load`'s own processor
/// for language models does.
private struct ChatInputProcessor: UserInputProcessor {
    let tokenizer: any Tokenizer
    let messageGenerator: any MessageGenerator

    func prepare(input: UserInput) throws -> LMInput {
        let messages = messageGenerator.generate(from: input)
        do {
            let tokens = try tokenizer.applyChatTemplate(messages: messages, tools: input.tools,
                                                         additionalContext: input.additionalContext)
            return LMInput(tokens: MLXArray(tokens))
        } catch TokenizerError.missingChatTemplate {
            let prompt = messages.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
            return LMInput(tokens: MLXArray(tokenizer.encode(text: prompt)))
        }
    }
}
