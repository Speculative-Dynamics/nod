// QwenClient.swift
// Qwen 3 4B (4-bit) via MLX Swift — the alternate listening-loop engine.
//
// Why Qwen? Two reasons:
//   1. AFM is Apple-Intelligence-gated. Many users won't have it enabled or
//      will have regional/device restrictions. Qwen runs on any device with
//      enough RAM (roughly iPhone 15 Pro and up for the 4B).
//   2. Open weights mean we can fine-tune for the listening voice later.
//
// Note: the MLX registry ships Qwen 3 4B (not Qwen 3.5 — that family hasn't
// been converted to an `mlx-community/*` 4-bit build yet). Qwen 3 4B is the
// right starting point; swapping the ModelConfiguration when 3.5 lands is
// a one-line change.
//
// Model weights (~2.3GB) are downloaded on first use via HubApi. The
// download UX lives in later commits — this actor exposes `prepare()` and
// a load-state so the UI can present a progress screen.
//
// Concurrency shape: QwenClient is an actor. The heavy MLX objects
// (LanguageModel, Tokenizer, KV cache) aren't Sendable, so we keep them
// behind MLX's own `ModelContainer` actor and run all generation inside
// `container.perform { context in ... }`. Only Sendable values (String)
// cross the boundary back into our actor.

import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

actor QwenClient: ListeningEngine {

    /// What the engine is doing right now, for the UI.
    enum State: Equatable {
        case notLoaded
        case downloading(fractionCompleted: Double)
        case loading
        case ready
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.notLoaded, .notLoaded), (.loading, .loading), (.ready, .ready):
                return true
            case (.downloading(let a), .downloading(let b)):
                return a == b
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private(set) var state: State = .notLoaded

    private let listeningPrompt: String
    private let summaryPrompt: String

    /// Loaded once, reused across calls. Nil until `prepare()` succeeds.
    /// ModelContainer is an actor — safe to hold here.
    private var container: ModelContainer?

    /// An in-flight load. Subsequent `prepare()` callers await this same
    /// task so we never double-download the 2.3GB weights.
    private var loadingTask: Task<Void, Error>?

    /// Model config pinned at type-level. Swap for qwen3.5 family when
    /// mlx-community publishes a 4-bit build.
    private static let modelConfig = LLMRegistry.qwen3_4b_4bit

    init() throws {
        self.listeningPrompt = try Self.loadPrompt(named: "listening_mode")
        self.summaryPrompt   = try Self.loadPrompt(named: "summary")
    }

    private static func loadPrompt(named name: String) throws -> String {
        guard let url = Bundle.main.url(
                forResource: name,
                withExtension: "md",
                subdirectory: "prompts"
              ),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            throw InferenceError.promptNotFound
        }
        return text
    }

    // MARK: - Load lifecycle

    /// Download (if needed) and load the model into memory. Safe to call
    /// repeatedly and from multiple callers — only does work the first time.
    /// UI can observe `state` across calls for progress.
    func prepare() async throws {
        if container != nil {
            state = .ready
            return
        }
        if let existing = loadingTask {
            try await existing.value
            return
        }

        state = .loading
        let task = Task { try await self.performLoad() }
        loadingTask = task

        defer { loadingTask = nil }
        try await task.value
    }

    private func performLoad() async throws {
        do {
            let loaded = try await loadModelContainer(
                hub: HubApi(),
                configuration: Self.modelConfig,
                progressHandler: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.updateDownloadProgress(progress.fractionCompleted) }
                }
            )
            self.container = loaded
            self.state = .ready
        } catch {
            self.state = .failed(String(describing: error))
            throw error
        }
    }

    private func updateDownloadProgress(_ fraction: Double) {
        switch state {
        case .loading, .downloading, .notLoaded:
            state = fraction < 1.0 ? .downloading(fractionCompleted: fraction) : .loading
        case .ready, .failed:
            break
        }
    }

    // MARK: - InferenceEngine

    func respond(
        to userMessage: String,
        context userContext: String
    ) async throws -> String {
        if container == nil {
            try await prepare()
        }
        guard let container else {
            throw InferenceError.modelNotReady
        }

        let instructions: String
        if userContext.isEmpty {
            instructions = listeningPrompt
        } else {
            instructions = listeningPrompt + "\n\n---\n\n" + userContext
        }

        let raw = try await Self.generate(
            container: container,
            instructions: instructions,
            userPrompt: userMessage
        )
        return stripThinkingBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ConversationSummarizer

    func summarize(messages: [Message], existingSummary: String) async throws -> String {
        if container == nil {
            try await prepare()
        }
        guard let container else {
            throw InferenceError.modelNotReady
        }

        let transcript = messages.map { m -> String in
            switch m.role {
            case .user:      return "User: \(m.text)"
            case .assistant: return "Nod: \(m.text)"
            case .nod:       return "(Nod nodded silently.)"
            }
        }.joined(separator: "\n")

        let instructionInput: String
        if existingSummary.isEmpty {
            instructionInput = """
            \(summaryPrompt)

            ---

            EXISTING SUMMARY: (none yet — this is the first compression pass)

            NEW EXCHANGES TO INCORPORATE:
            \(transcript)
            """
        } else {
            instructionInput = """
            \(summaryPrompt)

            ---

            EXISTING SUMMARY:
            \(existingSummary)

            NEW EXCHANGES TO INCORPORATE:
            \(transcript)
            """
        }

        let raw = try await Self.generate(
            container: container,
            instructions: instructionInput,
            userPrompt: "Produce the updated summary now."
        )
        return stripThinkingBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Generation

    /// Runs one generation pass inside the ModelContainer's isolation.
    /// Everything non-Sendable (ModelContext, KV cache, MLXArrays) stays
    /// on the container actor; only the resulting String crosses back.
    private static func generate(
        container: ModelContainer,
        instructions: String,
        userPrompt: String
    ) async throws -> String {
        try await container.perform { context in
            let chat: [Chat.Message] = [
                .system(instructions),
                .user(userPrompt),
            ]
            let userInput = UserInput(chat: chat)
            let input = try await context.processor.prepare(input: userInput)

            let parameters = GenerateParameters()
            // Annotate the closure param so Swift picks the overload that
            // returns GenerateResult (not GenerateCompletionInfo).
            let result: GenerateResult = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            ) { (_: [Int]) -> GenerateDisposition in .more }

            return result.output
        }
    }

    // MARK: - Helpers

    /// Qwen 3 emits a `<think>…</think>` block before its user-facing reply
    /// when thinking mode is on. We want the reply only. Drop anything up
    /// to and including the closing tag; if there's no tag, return as-is.
    private func stripThinkingBlock(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...])
    }
}
