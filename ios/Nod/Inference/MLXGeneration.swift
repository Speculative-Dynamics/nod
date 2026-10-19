// MLXGeneration.swift
// Everything that turns a loaded MLX model into a reply or a chapter
// note: tokenizer bridge, chat assembly, sampling, KV-cache settings,
// and the token loop. Shared by MLXEngineClient (which adds download and
// lifecycle) and the eval runner (ios/evals/runner), so benchmarks run
// exactly the generation code the app ships.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Sampling

/// Sampling settings for one generation. Chat replies use each model
/// family's published recommendation; chapter notes use `.precise`
/// because they need faithful output.
struct MLXSampling: Sendable, Hashable {
    var temperature: Float
    var topP: Float
    var topK: Int
    var minP: Float = 0
    var presencePenalty: Float? = nil
    var repetitionPenalty: Float? = nil

    static let precise = MLXSampling(temperature: 0.3, topP: 0.9, topK: 0)

    /// Qwen 3 / 3.5 non-thinking: temperature 0.7, top-p 0.8, top-k 20.
    static let qwen3 = MLXSampling(temperature: 0.7, topP: 0.8, topK: 20)
    /// Qwen 3.5 additionally recommends presence penalty 1.5.
    static let qwen35 = MLXSampling(temperature: 0.7, topP: 0.8, topK: 20, presencePenalty: 1.5)
    /// Gemma 4: temperature 1.0, top-p 0.95, top-k 64.
    static let gemma4 = MLXSampling(temperature: 1.0, topP: 0.95, topK: 64)
    /// LFM2.5 model card: temperature 0.1, repetition penalty 1.1.
    static let lfm25 = MLXSampling(temperature: 0.1, topP: 1.0, topK: 0, repetitionPenalty: 1.1)

    /// Recommended chat sampling for a model's `config.json` model_type.
    static func recommended(forModelType type: String) -> MLXSampling {
        switch type {
        case "qwen3_5", "qwen3_5_text": return .qwen35
        case "gemma4", "gemma4_text": return .gemma4
        case "lfm2": return .lfm25
        default: return .qwen3
        }
    }
}

// MARK: - Generation

enum MLXGeneration {

    // KV cache quantization: 4-bit, group size 64, after the first 256
    // tokens (which keeps the system prompt full precision). ~4x smaller
    // KV cache against the iOS jetsam line; near-lossless on Qwen3-4B
    // (0.995 logit cosine similarity to FP16, mlx-lm#1059).
    static let kvBits = 4
    static let kvGroupSize = 64
    static let quantizedKVStart = 256

    /// Prompt tokens processed per step while prefilling. Smaller steps
    /// lower peak memory at a small speed cost. nil = library default.
    nonisolated(unsafe) static var prefillStepSize: Int? = nil

    /// Load a model from a local directory of MLX files.
    static func load(from directory: URL) async throws -> ModelContainer {
        try await loadModelContainer(from: directory, using: TransformersTokenizerLoader())
    }

    /// The model's `config.json` model_type (e.g. "qwen3", "lfm2").
    static func modelType(in directory: URL) -> String {
        guard let data = try? Data(contentsOf: directory.appending(path: "config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["model_type"] as? String else { return "" }
        return type
    }

    /// System message, prior turns, then the user prompt, assembled by
    /// the engine-neutral ListeningTurns so MLX and AFM see the same
    /// conversation (errors dropped, turns merged and alternating).
    static func chatMessages(instructions: String, history: [Message], userPrompt: String) -> [Chat.Message] {
        let assembled = ListeningTurns.assemble(history: history, userMessage: userPrompt)
        var chat: [Chat.Message] = [.system(instructions)]
        for turn in assembled.turns {
            switch turn.speaker {
            case .user: chat.append(.user(turn.text))
            case .nod: chat.append(.assistant(turn.text))
            }
        }
        chat.append(.user(assembled.prompt))
        return chat
    }

    static func parameters(maxTokens: Int, sampling: MLXSampling) -> GenerateParameters {
        var parameters = GenerateParameters()
        parameters.maxTokens = maxTokens
        parameters.temperature = sampling.temperature
        parameters.topP = sampling.topP
        parameters.topK = sampling.topK
        parameters.minP = sampling.minP
        parameters.presencePenalty = sampling.presencePenalty
        parameters.repetitionPenalty = sampling.repetitionPenalty
        parameters.kvBits = kvBits
        parameters.kvGroupSize = kvGroupSize
        parameters.quantizedKVStart = quantizedKVStart
        if let prefillStepSize { parameters.prefill.stepSize = prefillStepSize }
        return parameters
    }

    /// Run the token loop, calling `onSnapshot` with the full accumulated
    /// text after each chunk. Cancellation of the calling task stops
    /// generation within a token or two.
    ///
    /// `enable_thinking: false` keeps Qwen 3.5 (thinking on by default)
    /// from spending its budget on hidden reasoning; other templates
    /// ignore the flag or already default to off.
    static func stream(
        container: ModelContainer,
        instructions: String,
        history: [Message],
        userPrompt: String,
        maxTokens: Int,
        sampling: MLXSampling,
        onSnapshot: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        try await container.perform { context in
            let chat = chatMessages(instructions: instructions, history: history, userPrompt: userPrompt)
            let input = try await context.processor.prepare(
                input: UserInput(chat: chat, additionalContext: ["enable_thinking": false])
            )
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: parameters(maxTokens: maxTokens, sampling: sampling),
                context: context
            )
            var accumulator = ""
            for try await generation in stream {
                switch generation {
                case .chunk(let chunk):
                    accumulator += chunk
                    try await onSnapshot(accumulator)
                case .info, .toolCall, .rejectedToolCall:
                    break
                }
            }
            Stream.gpu.synchronize()
        }
    }

    /// Run to completion and return the text, thinking block removed.
    static func generate(
        container: ModelContainer,
        instructions: String,
        history: [Message],
        userPrompt: String,
        maxTokens: Int,
        sampling: MLXSampling
    ) async throws -> String {
        let box = TextBox()
        try await stream(
            container: container, instructions: instructions, history: history,
            userPrompt: userPrompt, maxTokens: maxTokens, sampling: sampling
        ) { snapshot in box.set(snapshot) }
        return stripThinkingBlock(box.value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A chapter note (see prompts/chapter_note.md).
    static func chapterNote(container: ModelContainer, prompt: String, messages: [Message], maxTokens: Int = 200) async throws -> String {
        let instructions = """
        \(prompt)

        ---

        EXCHANGES:
        \(AFMMemory.transcript(messages))
        """
        return try await generate(
            container: container, instructions: instructions, history: [],
            userPrompt: "Write the note now.", maxTokens: maxTokens, sampling: .precise
        )
    }

    /// Removes a `<think>…</think>` block if a model emits one anyway.
    /// An unclosed `<think>` (budget ran out mid-think) drops everything
    /// after it rather than leak raw reasoning.
    static func stripThinkingBlock(_ text: String) -> String {
        if let end = text.range(of: "</think>") {
            return String(text[end.upperBound...])
        }
        if let start = text.range(of: "<think>") {
            return String(text[..<start.lowerBound])
        }
        return text
    }

    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.withLock { text = value } }
        var value: String { lock.withLock { text } }
    }
}

// MARK: - Tokenizer bridge
//
// mlx-swift-lm 3.x needs an explicit TokenizerLoader. This small bridge to
// swift-transformers' AutoTokenizer avoids the package's macro wrapper
// (and Xcode's "trust and enable macro" gate).

struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizerBridge(upstream)
    }
}

private struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
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
