// MLXEngineClient.swift
// One on-device MLX engine instance, parameterized by MLXModelSpec.
// Originally Qwen-only; generalized to back Qwen 3 Instruct 2507,
// Qwen 3.5 4B, and Gemma 4 E2B Text equally via the model spec.
//
// Why multiple on-device options:
//   1. AFM is Apple-Intelligence-gated. Many users won't have it enabled
//      or will have regional/device restrictions. MLX-based models run on
//      any device with enough RAM (roughly iPhone 15 Pro and up for 4B).
//   2. Open weights across vendors (Alibaba / Google) let users pick
//      based on voice, release recency, and training data mix.
//
// Each spec carries a stable identifier, display name, R2 base URL, and
// a file manifest with pinned SHA-256s. The client itself is identical
// regardless of which spec it's initialized with.
//
// Model weights (~2.3-3.0 GB) are downloaded on first use from our
// Cloudflare R2 bucket (not Hugging Face — HF's public endpoints
// throttle at any real install count). EngineHolder observes
// `makeStateStream()` to drive the download progress UI. See
// `MLXR2BackgroundSession` for the fetch + verify details.
//
// Concurrency shape: this is an actor. The heavy MLX objects
// (LanguageModel, Tokenizer, KV cache) aren't Sendable, so we keep them
// behind MLX's own `ModelContainer` actor and run all generation inside
// `container.perform { context in ... }`. Only Sendable values (String)
// cross the boundary back into our actor.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import os

// No `import Hub` — mlx-swift-lm 3.x decoupled from the Hugging Face Hub
// downloader package. By the time we reach loadModelContainer, the files
// are already sitting on disk in Application Support thanks to
// MLXR2BackgroundSession, so we just hand MLX the URL and let it read
// config.json, tokenizer.json, etc. directly.
//
// We intentionally avoid mlx-swift-lm's `MLXHuggingFace` macro wrapper
// here. The macro only expands to a small adapter that bridges MLX's
// `TokenizerLoader` / `Tokenizer` protocols to swift-transformers'
// `AutoTokenizer`. Inlining that adapter locally keeps the build graph
// free of external macro targets, which avoids Xcode's "trust and enable
// macro" gate for this app.

private struct TransformersTokenizerLoader: TokenizerLoader {
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

private let log = Logger(subsystem: "app.usenod.nod", category: "mlx.client")

actor MLXEngineClient: ListeningEngine {

    // MARK: - Spec
    //
    // Injected at init. Everything model-specific (name, R2 URL, file
    // manifest, disk directory) lives here.
    let spec: MLXModelSpec

    /// What the engine is doing right now, for the UI.
    ///
    /// The four "progress-ish" cases all carry `DownloadMetrics` so the UI
    /// can render the same card chrome with different headers and frozen
    /// state: .downloading animates, .waitingForNetwork / .waitingForWifi
    /// show the last known progress with the bar frozen and rate nulled,
    /// .paused waits for a Resume tap.
    enum State: Equatable, Sendable {
        case notLoaded
        case downloading(DownloadMetrics)
        /// No connectivity at all (airplane mode, no Wi-Fi, no cellular).
        /// URLSession's `waitsForConnectivity` puts the request into this
        /// state automatically.
        case waitingForNetwork(DownloadMetrics)
        /// Cellular download is disallowed by the user's preference, and
        /// the current path is cellular. Shows "Waiting for Wi-Fi…" with
        /// a "Use cellular this time" one-shot escape hatch.
        case waitingForWifi(DownloadMetrics)
        /// User tapped Cancel. Resume data persisted to disk; UI offers a
        /// Resume button. Distinct from .notLoaded because there's real
        /// partial progress to preserve in the UI.
        case paused(DownloadMetrics)
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: State = .notLoaded

    private let listeningPrompt: String
    private let summaryPrompt: String
    private let extractionPrompt: String

    /// Loaded once, reused across calls. Nil until `prepare()` succeeds.
    /// ModelContainer is an actor — safe to hold here.
    private var container: ModelContainer?

    /// An in-flight load. Subsequent `prepare()` callers await this same
    /// task so we never double-download the 2.3GB weights.
    private var loadingTask: Task<Void, Error>?

    /// State change observer. At most one — replaced on each call.
    /// EngineHolder attaches this to drive the download UI.
    private var stateContinuation: AsyncStream<State>.Continuation?

    /// Ceiling for the summary-compression path. summary.md targets ~300
    /// words ≈ 400 tokens; the previous 250-token cap was truncating
    /// summaries mid-sentence, which fed a fragmented briefing back into
    /// every subsequent inference.
    ///
    /// Listening replies no longer use a static cap — callers pass a
    /// per-style `GenerationOptions.maxTokens` (200/300/400 for brief/
    /// conversational/deeper). Every saved token is ~100 KB of KV on a
    /// 28-layer / 8-KV-head 4B model, which matters on a 3 GB-budget
    /// iPhone 15 Pro.
    private static let maxSummaryTokens = 400

    /// Ceiling for entity extraction. A realistic 8-message batch should
    /// produce at most ~10 entities, each taking ~25 tokens in our JSON
    /// wire format — so 300 tokens is ample with headroom to spare. This
    /// is only used on the MLX fallback path; AFM's @Generable path
    /// doesn't go through this ceiling.
    private static let maxExtractionTokens = 300

    // MARK: - KV cache quantization
    //
    // mlx-swift-lm 3.31.3 ships affine KV-cache quantization as a public
    // `GenerateParameters` knob (QuantizedKVCache + maybeQuantizeKVCache
    // in MLXLMCommon/KVCache.swift). 4-bit @ group-size 64 gives ~4x peak
    // KV reduction (~185 MB saved per generation on our typical
    // ~2,500-token inference of system + personalization + summary + 4
    // recent turns + reply) against the iOS jetsam line.
    //
    // Published benchmarks on Qwen3-4B (mlx-lm#1059) show 0.995 logit
    // cosine similarity to FP16 at 4-bit with perfect top-1 token
    // accuracy — near-lossless for our use case.
    //
    // `quantizedKVStart = 256` keeps the first 256 tokens full-precision.
    // That window covers the listening_mode.md system prompt and most
    // personalization blocks, so the instruction-following parts of the
    // cache never get quantized — only the conversational bulk beyond
    // them. A small insurance policy against any quality drift.
    //
    // Next tier: PolarQuant / TurboQuant (3-bit, 4.6x compression,
    // 0.957 cosine sim on Qwen3-4B). Swift PR open at
    // ml-explore/mlx-swift-lm#160 but currently CONFLICTING, ports an
    // early mlx-vlm snapshot missing later optimizations, and decode
    // throughput is ~0.5x FP16 without fused Metal kernels. Revisit
    // when the PR rebases and the Metal kernel follow-ups land.
    private static let kvBits: Int = 4
    private static let kvGroupSize: Int = 64
    private static let quantizedKVStart: Int = 256

    // MARK: - R2 download source
    //
    // Files are re-hosted at a versioned path on Cloudflare R2 so we can
    // ship future model updates without invalidating existing installs.
    // SHA-256 values are computed once at upload time and pinned in
    // `MLXModelSpec.files` to guarantee bit-identical weights even if the
    // CDN (or our bucket) is ever tampered with.
    //
    // All spec-specific values — URL, files, disk directory, resume data
    // path — come from `self.spec`. Adding a new model is a new
    // `MLXModelSpec` static constant plus an `EnginePreference` case.

    init(spec: MLXModelSpec) throws {
        self.spec = spec
        self.listeningPrompt  = try Self.loadPrompt(named: "listening_mode")
        self.summaryPrompt    = try Self.loadPrompt(named: "summary")
        self.extractionPrompt = try Self.loadPrompt(named: "entity_extraction")
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

    // MARK: - State observation

    /// Subscribe to state changes. Yields the current state immediately,
    /// then every subsequent change until the stream is cancelled. Only
    /// one observer at a time — calling this twice replaces the continuation.
    func makeStateStream() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        stateContinuation = continuation
        continuation.yield(state)
        return stream
    }

    /// Single point of state mutation. Keep all updates going through
    /// here so observers never miss a transition.
    private func setState(_ new: State) {
        state = new
        stateContinuation?.yield(new)
    }

    // MARK: - Load lifecycle

    /// Download (if needed) and load the model into memory. Safe to call
    /// repeatedly and from multiple callers — only does work the first time.
    func prepare() async throws {
        if container != nil {
            setState(.ready)
            return
        }
        if let existing = loadingTask {
            try await existing.value
            return
        }

        setState(.loading)
        let task = Task { try await self.performLoad() }
        loadingTask = task

        defer { loadingTask = nil }
        try await task.value
    }

    // Note: The earlier `cancelLoading()` method was removed as dead
    // code. Its only caller (EngineHolder's engine-switch path) now
    // uses `cancelDownload()` so that switching engines mid-download
    // persists resume data to the outgoing spec's per-engine file.
    // For "user hit Start fresh / wipe everything", call
    // `MLXModelSpec.deleteDownloadedFiles()` on the relevant spec
    // directly.

    // MARK: - User-facing controls

    /// Pause the active download. The background session persists resume
    /// data to disk and transitions to .paused. A later `prepare()` call
    /// resumes from the same spot. Safe to call if nothing is downloading.
    func cancelDownload() async {
        await MLXR2BackgroundSession.shared.cancelAndPersistResume()
        loadingTask?.cancel()
        loadingTask = nil
    }

    /// Resume a previously paused download. Equivalent to calling
    /// `prepare()` — the session reads persisted resume data on its own.
    func resumeDownload() async throws {
        try await prepare()
    }

    /// Drop the loaded ModelContainer to reclaim its weight memory
    /// (~2.3-3.0 GB depending on spec). Two callers today:
    ///   1. EngineHolder's idle timer — after N minutes of no inference.
    ///   2. LaunchCrashBreaker on the FIRST memory-warning strike — give
    ///      the user a chance to stay on their chosen MLX engine by
    ///      releasing weights instead of immediately falling back to AFM.
    /// The next `respond()` call transparently re-prepares from the
    /// already-downloaded files on disk (no re-download). State flips
    /// to .notLoaded so the UI can reflect the reload.
    ///
    /// Safe to call even if nothing is loaded yet; also cancels an
    /// in-flight load task so we don't race a pending prepare().
    func releaseContainer() {
        loadingTask?.cancel()
        loadingTask = nil
        guard container != nil else { return }
        container = nil
        setState(.notLoaded)
    }

    /// One-shot override: allow cellular for THIS run only. Doesn't touch
    /// the persistent preference. The UI exposes this via "Use cellular
    /// this time" on the .waitingForWifi card.
    func useCellularThisTime() async {
        MLXR2BackgroundSession.shared.useCellularThisTime()
    }

    private func performLoad() async throws {
        do {
            // Phase 1: fetch + verify the weight files from our R2 bucket.
            // `ensureLocalFiles` is a no-op for anything already present
            // and size-valid, so relaunches after a successful download
            // skip straight to phase 2.
            //
            // The background session observes the download events we
            // bridge into `applyDownloadEvent` so both the progress UI
            // and the four waiting/paused states surface through one path.
            let modelDir = spec.modelDirectoryURL

            try await MLXR2BackgroundSession.shared.ensureLocalFiles(
                baseURL: spec.r2BaseURL,
                files: spec.files,
                destinationDir: modelDir,
                resumeDataURL: spec.resumeDataURL,
                on: { [weak self] event in
                    guard let self else { return }
                    Task { await self.applyDownloadEvent(event) }
                }
            )
            try Task.checkCancellation()

            setState(.loading)

            // Phase 2: hand MLX a pre-populated directory. mlx-swift-lm
            // 3.x requires an explicit TokenizerLoader. We provide a
            // small local bridge to swift-transformers'
            // AutoTokenizer.from(modelFolder:) so we don't need the
            // package's macro-based convenience wrapper. MLX picks up
            // config.json and wires the right architecture via the
            // registered model types.
            let loaded = try await loadModelContainer(
                from: modelDir,
                using: TransformersTokenizerLoader()
            )
            try Task.checkCancellation()
            self.container = loaded
            setState(.ready)
        } catch is CancellationError {
            // Swift task-level cancellation (e.g. Task.cancel propagated
            // before URLSession started).
            setState(.notLoaded)
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            // URLSession-level cancellation — fires when our loadingTask
            // is cancelled mid-download. NOT a failure; treat as notLoaded.
            setState(.notLoaded)
            throw CancellationError()
        } catch DownloadError.canceledByUser {
            // User tapped Cancel. The session already emitted .paused via
            // the event stream, so state is already in .paused(...). Don't
            // overwrite with .failed — this isn't a failure.
            throw CancellationError()
        } catch {
            let mapped = Self.mapDownloadError(error)
            log.error("performLoad: failed \(String(describing: mapped), privacy: .public)")
            setState(.failed(String(describing: mapped)))
            throw mapped
        }
    }

    /// Translate URLError / HubApi errors into typed InferenceError cases
    /// so the UI can show user-friendly copy instead of dumping raw
    /// `NSURLErrorDomain` strings.
    private static func mapDownloadError(_ error: Error) -> Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .timedOut,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return InferenceError.downloadFailedNoNetwork
            case .cannotWriteToFile, .cannotCreateFile:
                return InferenceError.downloadFailedDiskFull
            default:
                return InferenceError.downloadFailedServer
            }
        }
        return error
    }

    /// Called by MLXR2BackgroundSession whenever progress or a
    /// connectivity-state change needs to surface. Metrics carry the full
    /// picture (fraction, bytes, speed, ETA). Transitions from a
    /// progress-ish state map cleanly into one of the four progress
    /// cases; .ready and .failed are terminal so background-task echoes
    /// that arrive after the fact are ignored.
    func applyDownloadEvent(_ event: DownloadEvent) {
        switch state {
        case .ready, .failed:
            return
        default:
            break
        }

        switch event {
        case .progress(let metrics):
            if metrics.fraction >= 1.0 {
                setState(.loading)
            } else {
                setState(.downloading(metrics))
            }
        case .waitingForNetwork(let metrics):
            setState(.waitingForNetwork(metrics.frozen()))
        case .waitingForWifi(let metrics):
            setState(.waitingForWifi(metrics.frozen()))
        case .paused(let metrics):
            setState(.paused(metrics.frozen()))
        }
    }

    // MARK: - InferenceEngine

    func respond(
        to userMessage: String,
        context userContext: String,
        history: [Message],
        options: GenerationOptions
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

        // Thinking mode handling, per-model:
        //   - Qwen 3 Instruct 2507: instruct-only build, no thinking branch
        //     in its chat template. Zero budget spent on reasoning.
        //   - Qwen 3.5 4B: template defaults enable_thinking=true. We flip
        //     it off inside `generate` via additionalContext so the model
        //     spends its full token budget on the user-visible reply.
        //   - Gemma 4 E2B: doesn't use the enable_thinking concept; its
        //     template ignores the flag.
        //
        // `stripThinkingBlock` below stays as belt-and-suspenders — with
        // enable_thinking=false Qwen 3.5 emits `<think>\n\n</think>\n\n`
        // as a pre-closed prefix, which the strip handles cleanly.
        let raw = try await Self.generate(
            container: container,
            instructions: instructions,
            history: history,
            userPrompt: userMessage,
            maxTokens: options.maxTokens
        )
        return stripThinkingBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Real per-token streaming for MLX. Each yielded element is the FULL
    /// accumulated reply so far — callers just assign the snapshot to the
    /// bubble, no delta math.
    ///
    /// CANCELLATION: when the consumer's `AsyncThrowingStream` is torn
    /// down (Task.cancel on the caller), `continuation.onTermination`
    /// fires and cancels the producer Task. The producer's inner
    /// `for try await generation in stream` loop already honors
    /// Task.cancellation at each suspension, so MLX generation exits
    /// within a token or two of cancellation. This is real stop: the GPU
    /// stops generating, not just the UI stops reading.
    nonisolated func streamResponse(
        to userMessage: String,
        context userContext: String,
        history: [Message],
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    if await self.container == nil {
                        try await self.prepare()
                    }
                    guard let container = await self.container else {
                        throw InferenceError.modelNotReady
                    }

                    let instructions: String
                    if userContext.isEmpty {
                        instructions = await self.listeningPrompt
                    } else {
                        instructions = await self.listeningPrompt + "\n\n---\n\n" + userContext
                    }

                    try await Self.generateStreaming(
                        container: container,
                        instructions: instructions,
                        history: history,
                        userPrompt: userMessage,
                        maxTokens: options.maxTokens
                    ) { snapshot in
                        // Guard against cancellation before each yield.
                        // Throwing CancellationError breaks the MLX loop
                        // cooperatively — the GPU stops generating.
                        try Task.checkCancellation()
                        // Strip `<think>...</think>` progressively. While
                        // the model is still inside a thinking block,
                        // cleaned is empty — typing-dots cover that
                        // window. Once the close tag lands we begin
                        // yielding snapshots of the user-visible reply.
                        let cleaned = await self.stripThinkingBlock(snapshot)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            continuation.yield(cleaned)
                        }
                    }

                    try Task.checkCancellation()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
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
            history: [],  // summary is self-contained; transcript is in instructions
            userPrompt: "Produce the updated summary now.",
            maxTokens: Self.maxSummaryTokens
        )
        return stripThinkingBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - EntityExtractor

    /// Extract entities from a batch of messages via MLX. This is the
    /// fallback path used when AFM is unavailable or refuses — AFM's
    /// `@Generable` gives us guaranteed-valid JSON; this path has to
    /// ask the model for JSON text and parse it defensively.
    ///
    /// On parse failure we return an empty list rather than throwing.
    /// The alternative — throwing and letting extraction fail loudly —
    /// would mean one bad generation wipes out memory for the whole
    /// compression batch. Returning empty means we just miss a batch
    /// of entities; the user can keep using the app, and the next
    /// compression pass has another shot.
    func extractEntities(from messages: [Message]) async throws -> ExtractedEntities {
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

        // Hard-coded JSON contract because the model can't be trusted to
        // follow `@Generable`-style shape hints alone. The "EXAMPLE" block
        // is the most reliable way to get small models to hit the format.
        let instructions = """
        \(extractionPrompt)

        ---

        Output format: ONE JSON object with a single key "items" containing
        a list of entity objects. Each entity has exactly these fields:
        "type" (string, one of "person"/"place"/"project"/"situation"),
        "name" (string), "role" (string, empty if unknown),
        "note" (string, empty if unknown).

        Output ONLY the JSON. No markdown fences, no prose, no commentary.
        If no entities are present, return {"items":[]}.

        EXAMPLE INPUT:
        User: M sent another passive-aggressive email today.

        EXAMPLE OUTPUT:
        {"items":[{"type":"person","name":"M","role":"","note":"sent a passive-aggressive email"}]}

        ---

        CONVERSATION CHUNK TO ANALYZE:
        \(transcript)
        """

        let raw = try await Self.generate(
            container: container,
            instructions: instructions,
            history: [],
            userPrompt: "Return the JSON now.",
            maxTokens: Self.maxExtractionTokens
        )
        let stripped = stripThinkingBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.parseExtractedJSON(stripped)
    }

    /// Defensive parser for the JSON the model is asked to produce.
    /// Strips any stray prose around the JSON, parses, and falls back
    /// to an empty list on any failure. Every failure mode here is
    /// "return empty" — we never throw — because partial extraction
    /// data silently corrupts the entity store, but zero extraction
    /// just means we retry on the next compression.
    private static func parseExtractedJSON(_ raw: String) -> ExtractedEntities {
        // Find the first { ... } span. Small models sometimes wrap JSON
        // in prose ("Here's the output:") or markdown fences (```json).
        guard let startIdx = raw.firstIndex(of: "{"),
              let endIdx = raw.lastIndex(of: "}") else {
            return ExtractedEntities(items: [])
        }
        let jsonString = String(raw[startIdx...endIdx])
        guard let data = jsonString.data(using: .utf8) else {
            return ExtractedEntities(items: [])
        }

        // The model's JSON output maps cleanly to ExtractedEntities only
        // if the fields align. We decode through Foundation's Codable
        // using a local mirror struct that's the same shape — this
        // avoids coupling the @Generable wire format to the JSON wire
        // format (they just happen to match today).
        struct WireEntity: Decodable {
            let type: String?
            let name: String?
            let role: String?
            let note: String?
        }
        struct WireEntities: Decodable {
            let items: [WireEntity]?
        }
        guard let wire = try? JSONDecoder().decode(WireEntities.self, from: data) else {
            return ExtractedEntities(items: [])
        }
        let items = (wire.items ?? []).compactMap { e -> ExtractedEntity? in
            guard let type = e.type, let name = e.name, !name.isEmpty else {
                return nil
            }
            return ExtractedEntity(
                type: type,
                name: name,
                role: e.role ?? "",
                note: e.note ?? ""
            )
        }
        return ExtractedEntities(items: items)
    }

    // MARK: - Generation

    /// Runs one generation pass inside the ModelContainer's isolation.
    /// Everything non-Sendable (ModelContext, KV cache, MLXArrays) stays
    /// on the container actor; only the resulting String crosses back.
    ///
    /// `history` is an ordered list of prior turns that get inserted
    /// between the system message and the final user turn as real
    /// `.user` / `.assistant` `Chat.Message` values. The chat template
    /// renders them with the model's native turn tokens — way better
    /// recall than embedding them as narration in the system message.
    /// `.nod` role maps to `.assistant("(I nodded.)")` so the silent
    /// acknowledgment stays in context.
    private static func generate(
        container: ModelContainer,
        instructions: String,
        history: [Message],
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        try await container.perform { context in
            var chat: [Chat.Message] = [.system(instructions)]
            for msg in history {
                switch msg.role {
                case .user:
                    chat.append(.user(msg.text))
                case .assistant:
                    // Defensive skip of any empty assistant turns that
                    // slipped past the ConversationStore filter.
                    if !msg.text.isEmpty {
                        chat.append(.assistant(msg.text))
                    }
                case .nod:
                    chat.append(.assistant("(I nodded.)"))
                }
            }
            chat.append(.user(userPrompt))
            // Qwen 3.5's chat_template.jinja defaults `enable_thinking` to
            // true and prepends `<think>\n` to every generation. For a
            // listening-mode chat app that's terrible: the model burns
            // tokens reasoning before producing any user-visible reply,
            // and on .brief (maxTokens=200) can hit the ceiling mid-think,
            // leaving us an orphan-<think> buffer that stripThinkingBlock
            // turns into an empty string ("Something went wrong").
            //
            // Passing enable_thinking=false flips to the template's else
            // branch — `<think>\n\n</think>\n\n` — so the model starts
            // already past the think window and spends its full budget on
            // the actual reply.
            //
            // Per-model behavior of the flag (verified against each
            // shipped chat_template.jinja):
            //   - Qwen 3 Instruct 2507: instruct-only build, template has
            //     no `enable_thinking` branch at all — key is ignored.
            //   - Qwen 3.5 4B: default ON, flag flips it OFF. ← the fix.
            //   - Gemma 4 E2B Text: template DOES reference
            //     `enable_thinking` (emits `<|think|>\n` when true), but
            //     default is already OFF. Our flag matches the default,
            //     so it's a no-op here.
            // Safe to pass unconditionally for all three.
            let userInput = UserInput(
                chat: chat,
                additionalContext: ["enable_thinking": false]
            )
            let input = try await context.processor.prepare(input: userInput)

            var parameters = GenerateParameters()
            parameters.maxTokens = maxTokens
            // KV cache quantization. The token generator (TokenIterator
            // in MLXLMCommon) calls maybeQuantizeKVCache on every step
            // once cache.offset > quantizedKVStart, switching the cache
            // over to a QuantizedKVCache with these parameters.
            parameters.kvBits = Self.kvBits
            parameters.kvGroupSize = Self.kvGroupSize
            parameters.quantizedKVStart = Self.quantizedKVStart
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            )

            var output = ""
            for try await generation in stream {
                switch generation {
                case .chunk(let chunk):
                    output += chunk
                case .info, .toolCall:
                    break
                }
            }

            Stream.gpu.synchronize()
            return output
        }
    }

    /// Streaming variant of `generate`: runs the same MLX token loop and
    /// calls `onSnapshot` with the FULL accumulated reply each time a
    /// chunk arrives. Accumulation happens here (inside the single
    /// `container.perform` closure) so the caller's Sendable callback
    /// doesn't need to juggle a captured mutable String across
    /// concurrency boundaries.
    ///
    /// The inner `for try await generation in stream` loop honors
    /// Task.cancellation at each suspension, so cancellation of the
    /// outer Task breaks the loop within a token or two.
    ///
    /// `onSnapshot` is async-throwing so callers can use it as a
    /// cancellation checkpoint.
    private static func generateStreaming(
        container: ModelContainer,
        instructions: String,
        history: [Message],
        userPrompt: String,
        maxTokens: Int,
        onSnapshot: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        try await container.perform { context in
            var chat: [Chat.Message] = [.system(instructions)]
            for msg in history {
                switch msg.role {
                case .user:
                    chat.append(.user(msg.text))
                case .assistant:
                    if !msg.text.isEmpty {
                        chat.append(.assistant(msg.text))
                    }
                case .nod:
                    chat.append(.assistant("(I nodded.)"))
                }
            }
            chat.append(.user(userPrompt))
            let userInput = UserInput(
                chat: chat,
                additionalContext: ["enable_thinking": false]
            )
            let input = try await context.processor.prepare(input: userInput)

            var parameters = GenerateParameters()
            parameters.maxTokens = maxTokens
            parameters.kvBits = Self.kvBits
            parameters.kvGroupSize = Self.kvGroupSize
            parameters.quantizedKVStart = Self.quantizedKVStart
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: parameters,
                context: context
            )

            var accumulator = ""
            for try await generation in stream {
                switch generation {
                case .chunk(let chunk):
                    accumulator += chunk
                    try await onSnapshot(accumulator)
                case .info, .toolCall:
                    break
                }
            }

            Stream.gpu.synchronize()
        }
    }

    // MARK: - Helpers

    /// Belt-and-suspenders strip of Qwen's `<think>…</think>` block, even
    /// if `/no_think` wasn't honored and we end up with one anyway.
    ///
    /// Three cases handled:
    ///   • matched `<think>…</think>` → keep what's after the close
    ///   • orphan `<think>` with no close (budget ran out mid-think, the
    ///     exact failure mode we observed) → drop the whole buffer rather
    ///     than leak raw reasoning to the user
    ///   • no `<think>` at all → pass through untouched
    private func stripThinkingBlock(_ text: String) -> String {
        if let end = text.range(of: "</think>") {
            return String(text[end.upperBound...])
        }
        if text.contains("<think>") {
            // Everything after an unclosed `<think>` is internal reasoning
            // we don't want to show. Show only what came before it (usually
            // nothing, since thinking starts the buffer).
            if let start = text.range(of: "<think>") {
                return String(text[..<start.lowerBound])
            }
            return ""
        }
        return text
    }
}
