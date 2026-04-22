// ConversationStore.swift
// The one continuous conversation with Nod. Backed by SQLite via
// MessageDatabase so it survives app close, restart, and reboot.
//
// Per the product thesis: no sessions, no "new chat." One user, one ongoing
// relationship with Nod. This object is the in-memory view of that
// relationship plus the compression machinery that lets it run forever.
//
// Compression ("the magic in the backend"): once the un-summarized message
// count crosses HIGH_WATER_MARK, the oldest BATCH_SIZE messages get rolled
// into the running summary. Everything between that summary and the latest
// message is sent to the LLM as full-fidelity context.

import Foundation
import SwiftUI

@MainActor
final class ConversationStore: ObservableObject {

    private enum PendingDiskWrite: Codable, Sendable {
        case insert(Message)
        case updateText(id: UUID, text: String)
        case delete(id: UUID)
        case setCancelled(id: UUID, cancelled: Bool)

        func apply(to database: MessageDatabase) throws {
            switch self {
            case .insert(let message):
                try database.insert(message)
            case .updateText(let id, let text):
                try database.updateText(id: id, text: text)
            case .delete(let id):
                try database.deleteMessage(id: id)
            case .setCancelled(let id, let cancelled):
                try database.setCancelled(id: id, cancelled: cancelled)
            }
        }
    }

    @Published private(set) var messages: [Message] = []

    /// Flips to true after `hydrate()` completes. Drives the send-button
    /// gate in ChatView: sending before hydrate would build inference
    /// inputs from the still-empty `messages` array, seeding an AFM
    /// session with wrong context. In practice hydrate finishes during
    /// the splash, so users never see a disabled send.
    @Published private(set) var isHydrated: Bool = false

    // Compression tuning. High-water kicks compression; batch-size is how
    // many we eat on each compression pass. The gap between them is how
    // many full-fidelity recent turns are always available to the LLM
    // after compression settles.
    //
    // Why these specific numbers: on iPhone 15 Pro, passing 20 full-fidelity
    // recent turns plus the summary plus the system prompt to Qwen 3 4B
    // blows the KV cache past the jetsam line — we saw this empirically as
    // a second-message crash. Dropping to 4 recent turns after compression
    // keeps effective context under ~1.5 k tokens, which gives MLX Swift
    // meaningful headroom alongside a 2.3-3.0 GB model on a 3-6 GB memory
    // budget (increased-memory-limit entitlement in play).
    //
    // Tightened from 16/10 (6 recent) to 12/8 (4 recent) during the
    // memory-optimization pass — each dropped full-fidelity turn saves
    // roughly 100-150 tokens of prompt, which is ~10-15 MB of peak KV
    // per generation.
    private let HIGH_WATER_MARK = 12
    private let BATCH_SIZE = 8

    private let database: MessageDatabase
    private let summarizer: () -> ConversationSummarizer?

    /// The running compressed summary. Mirrors what's in the summary table;
    /// kept in memory so context-building for LLM calls is synchronous.
    private(set) var summary: String = ""

    /// Compression runs on a background task. We hold the handle so we don't
    /// fire a second one while the first is still running.
    private var compressionTask: Task<Void, Never>?
    private var pendingDiskWrites: [PendingDiskWrite] = []

    /// Structured memory (people, places, projects, situations). Writes
    /// run alongside compression (same batch, same task); reads run
    /// per-turn inside `buildInferenceInputs` to inject entity context
    /// when the user's current message references a known entity.
    ///
    /// Owned by the view layer (ChatView) so SwiftUI observes changes to
    /// its published disambiguation queue without going through this
    /// store. We keep the reference here so compression can ingest.
    let entityStore: EntityStore

    /// AFM-primary extraction orchestrator. Lazy-constructed with a
    /// closure that reaches back for the CURRENT listening engine as
    /// fallback — so switching engines doesn't strand extraction.
    private let entityExtractor: EntityExtractorService

    init(
        database: MessageDatabase,
        entityStore: EntityStore,
        summarizer: @escaping () -> ConversationSummarizer?,
        entityFallbackProvider: @escaping () -> (any ListeningEngine)?
    ) {
        self.database = database
        self.entityStore = entityStore
        self.summarizer = summarizer
        self.entityExtractor = EntityExtractorService(fallbackProvider: entityFallbackProvider)
        // NOTE: No disk work here. All fetches + WAL replay moved to
        // `hydrate()` so ChatView.init can stay lightweight and the
        // splash animation isn't blocked by main-thread SQLite work
        // during cold launch. Caller (ChatView `.task`) invokes
        // hydrate() post-mount.
    }

    /// Bring in-memory state into sync with disk. Called once from
    /// ChatView's `.task` on cold launch (post-mount, so it runs
    /// concurrently with the splash animation without blocking it).
    ///
    /// Runs the SQLite fetches on a detached task so the main actor
    /// isn't blocked. Main-actor work (assigning `@Published` state,
    /// WAL replay which mutates `messages`) happens after the fetches
    /// return.
    ///
    /// Idempotent: calling twice is a no-op. The guard matches the
    /// self-guarding pattern in `EngineHolder.startEagerPrepareIfNeeded`.
    func hydrate() async {
        guard !isHydrated else { return }

        // Off-main fetches. `database` is Sendable (MessageDatabase is
        // `@unchecked Sendable`; its internals — a GRDB DatabaseQueue
        // and an immutable URL — are thread-safe). `walURL` is a value
        // type, trivially Sendable.
        let db = self.database
        let walURL = database.pendingWritesURL
        async let fetchedMessages: [Message] = Task.detached {
            (try? db.fetchAllMessages()) ?? []
        }.value
        async let fetchedSummary: String = Task.detached {
            (try? db.fetchSummary()) ?? ""
        }.value
        async let fetchedWAL: [PendingDiskWrite] = Task.detached {
            Self.loadPendingDiskWritesFromURL(walURL)
        }.value

        let loadedMessages = await fetchedMessages
        let loadedSummary = await fetchedSummary
        let loadedWAL = await fetchedWAL

        // Back on MainActor — apply to published state.
        self.messages = loadedMessages
        self.summary = loadedSummary
        self.pendingDiskWrites = loadedWAL
        applyPendingWritesToMemory()
        flushPendingDiskWrites()

        self.isHydrated = true
    }

    // MARK: - Appending messages

    func append(_ message: Message) {
        messages.append(message)
        enqueueDiskWrite(.insert(message))
        // Only trigger compression on messages with actual text — skip the
        // empty assistant placeholder that ChatView inserts before streaming
        // tokens in, and skip nod (silent acknowledgment) messages.
        if !message.text.isEmpty {
            maybeTriggerCompression()
        }
    }

    /// Commit-path for streaming replies: updates the last assistant message
    /// AND enqueues a disk write. Call this ONCE per reply, at stream
    /// completion — not per chunk. For per-chunk in-flight updates during
    /// streaming, use `updateLastAssistantMessageInMemory(with:)` which
    /// skips the WAL enqueue to avoid disk churn at 30 Hz.
    func replaceLastAssistantMessage(with text: String) {
        guard let lastIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let current = messages[lastIndex]
        let updated = Message(
            id: current.id,
            role: .assistant,
            text: text,
            wasCancelled: current.wasCancelled,
            createdAt: current.createdAt
        )
        messages[lastIndex] = updated
        enqueueDiskWrite(.updateText(id: updated.id, text: text))
    }

    /// In-flight streaming update: mutates the last assistant message
    /// text in memory WITHOUT enqueueing a disk write. The caller is
    /// responsible for calling `replaceLastAssistantMessage(with:)` once
    /// at stream completion to persist the final text.
    ///
    /// Why split: streaming at 30 Hz with `enqueueDiskWrite` per call
    /// triggers 30 JSON-WAL rewrites per second per reply, which hammers
    /// disk for no benefit (the final text is what matters). One write
    /// at the end matches the pre-streaming cost exactly.
    func updateLastAssistantMessageInMemory(with text: String) {
        guard let lastIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let current = messages[lastIndex]
        messages[lastIndex] = Message(
            id: current.id,
            role: .assistant,
            text: text,
            wasCancelled: current.wasCancelled,
            createdAt: current.createdAt
        )
    }

    /// Remove the LAST assistant message (by position). Used when the
    /// user cancels before any token streams in — we tear down the empty
    /// placeholder rather than leave an orphan empty bubble. No-op if
    /// the last message isn't an assistant.
    func removeLastAssistantMessage() {
        guard let lastIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let id = messages[lastIndex].id
        messages.remove(at: lastIndex)
        enqueueDiskWrite(.delete(id: id))
    }

    /// Remove a specific assistant message by ID. Used during regenerate:
    /// we keep the old reply visible until the new reply's first token
    /// arrives, then remove the old one. Keying by ID (not position)
    /// avoids fragility if other turns land in between.
    func removeAssistantMessage(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        guard messages[index].role == .assistant else { return }
        messages.remove(at: index)
        enqueueDiskWrite(.delete(id: id))
    }

    /// Flip the `wasCancelled` flag on a message (and persist it). Used
    /// when the user taps stop mid-stream to mark the partial reply as
    /// "stopped" so the tag shows on reload.
    func markAssistantCancelled(id: UUID, cancelled: Bool = true) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let current = messages[index]
        guard current.role == .assistant else { return }
        messages[index] = Message(
            id: current.id,
            role: current.role,
            text: current.text,
            wasCancelled: cancelled,
            createdAt: current.createdAt
        )
        enqueueDiskWrite(.setCancelled(id: id, cancelled: cancelled))
    }

    // MARK: - Context for the LLM

    /// Bundle of inputs for an inference call.
    ///
    /// Split in two on purpose: `systemBlock` is what frames who Nod is and
    /// what it knows (personalization + running summary). `history` is the
    /// recent un-summarized conversation as actual `Message` values so
    /// engines can pass them to the LLM as real chat turns — NOT narrated
    /// into a system-message paragraph. Chat-tuned models attend to turn
    /// structure; flat-text history is why 4B models lose recall.
    ///
    /// `history` excludes:
    ///   - the in-flight empty assistant placeholder (not real history)
    ///   - the most recent user message (it's the current query, passed
    ///     separately to `respond(to:)`; embedding it twice confuses the
    ///     model)
    struct InferenceInputs {
        var systemBlock: String
        var history: [Message]
    }

    /// Primary input-builder for inference. Returns a structured
    /// `InferenceInputs` so engines can consume `systemBlock` as a
    /// system-message string and `history` as real chat turns.
    ///
    /// When `currentUserMessage` is non-nil, the system block will also
    /// include a "PEOPLE AND SITUATIONS YOU KNOW ABOUT" section with the
    /// entities this message references — by name, alias, or semantic
    /// paraphrase. This is the memory-injection path: the model sees
    /// context about "M" only when the user is actually talking about M.
    /// Without that filter we'd risk Nod lapsing into pattern-surfacing
    /// ("you've mentioned M a lot recently"), which the design explicitly
    /// forbids.
    func buildInferenceInputs(currentUserMessage: String? = nil) -> InferenceInputs {
        var parts: [String] = []

        // Personalisation first so it frames how the rest of the context
        // should be interpreted. Empty when the user has kept all defaults.
        let personalization = PersonalizationStore.shared.current.promptBlock
        if !personalization.isEmpty {
            parts.append(personalization)
        }

        if !summary.isEmpty {
            parts.append("WHAT YOU KNOW FROM EARLIER IN THIS ONGOING CONVERSATION:\n\(summary)")
        }

        // Entity injection — only when the current user message is
        // provided AND we find entities it references. Empty set is the
        // common case (user didn't mention any known entity), and the
        // block is simply omitted in that case.
        if let msg = currentUserMessage {
            let relevant = entityStore.retrieveRelevant(for: msg)
            if !relevant.isEmpty {
                let lines = relevant.map { "- \($0.contextLine)" }.joined(separator: "\n")
                parts.append("PEOPLE AND SITUATIONS YOU KNOW ABOUT (reference naturally if the user brings them up; never volunteer):\n\(lines)")
            }
        }

        var history: [Message] = []
        do {
            var recent = try database.fetchUnsummarizedMessages()
            // Drop the empty assistant placeholder that ChatView inserts
            // before streaming tokens back in.
            recent = recent.filter { !($0.role == .assistant && $0.text.isEmpty) }
            // Drop the most recent user message — it's the current query.
            if let lastIndex = recent.lastIndex(where: { $0.role == .user }) {
                recent.remove(at: lastIndex)
            }
            history = recent
        } catch {
            // DB read failure: engines still see personalization + summary.
            // Worse answer this turn, but not a crash.
        }

        return InferenceInputs(
            systemBlock: parts.joined(separator: "\n\n"),
            history: history
        )
    }

    // Note: an older `contextForInference()` method narrated history as
    // flat text into a RECENT EXCHANGES section. That single-string shape
    // is no longer used — both engines consume `buildInferenceInputs()`
    // above and handle history their own way (MLX as real chat turns,
    // AFM as a seed for `LanguageModelSession`). Deleted to avoid dead
    // code drift.

    // MARK: - Compression

    private func maybeTriggerCompression() {
        guard compressionTask == nil else { return }
        do {
            let count = try database.unsummarizedCount()
            guard count >= HIGH_WATER_MARK else { return }
        } catch {
            return
        }
        guard let summarizer = summarizer() else { return }

        compressionTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runCompression(summarizer: summarizer)
        }
    }

    private func runCompression(summarizer: ConversationSummarizer) async {
        defer {
            Task { @MainActor in self.compressionTask = nil }
        }
        do {
            let oldest = try database.fetchOldestUnsummarized(limit: BATCH_SIZE)
            guard !oldest.isEmpty else { return }

            let existingSummary = try database.fetchSummary()

            // Run summary + entity extraction in parallel over the SAME
            // batch of messages. Both read-only against `oldest`, so no
            // contention. Extraction is best-effort and never throws
            // (EntityExtractorService swallows errors), so it won't take
            // down summarization.
            async let newSummary = summarizer.summarize(
                messages: oldest,
                existingSummary: existingSummary
            )
            async let extracted = entityExtractor.extract(from: oldest)

            let resolvedSummary = try await newSummary
            let resolvedExtracted = await extracted

            try database.setSummary(resolvedSummary)
            try database.markSummarized(ids: oldest.map(\.id))

            self.summary = resolvedSummary
            self.entityStore.ingest(resolvedExtracted)
        } catch {
            // Compression is best-effort — if it fails this pass, the
            // un-summarized backlog grows by one batch and we retry on
            // the next high-water trip. The conversation keeps working.
        }
    }

    // MARK: - Start fresh

    /// Clears the entire conversation (messages and running summary) from
    /// both memory and disk. The user opts into this explicitly via the
    /// sidebar's "Start fresh" action.
    ///
    /// Waits for any in-flight compression to fully cancel before wiping
    /// the database — otherwise a late-finishing compression task could
    /// write a new summary into the just-cleared table.
    func clear() async {
        // Stop any pending compression and wait for it to actually exit.
        compressionTask?.cancel()
        if let task = compressionTask {
            _ = await task.value
        }
        compressionTask = nil

        // Wipe disk in one transaction. If the write fails (e.g. disk full
        // at the exact moment the user hit "Start fresh"), bail without
        // clearing the in-memory state so the UI stays consistent with disk.
        do {
            try database.clearAll()
        } catch {
            return
        }

        pendingDiskWrites.removeAll()
        // Reset in-memory state so the UI flips to the empty state.
        messages.removeAll()
        summary = ""
        // `database.clearAll()` already wiped the entity rows; this
        // resets the EntityStore's in-memory cache and published
        // disambiguation queue to match, keeping UI consistent.
        entityStore.resetInMemory()
    }

    var isConversationBackupEnabled: Bool {
        database.isICloudBackupEnabled
    }

    func setConversationBackupEnabled(_ enabled: Bool) {
        do {
            try database.setICloudBackupEnabled(enabled)
            objectWillChange.send()
        } catch {
            return
        }
    }

    private func enqueueDiskWrite(_ write: PendingDiskWrite) {
        pendingDiskWrites.append(write)
        persistPendingDiskWrites()
        flushPendingDiskWrites()
    }

    private func flushPendingDiskWrites() {
        var didChange = false
        while let write = pendingDiskWrites.first {
            do {
                try write.apply(to: database)
                pendingDiskWrites.removeFirst()
                didChange = true
            } catch {
                if didChange {
                    persistPendingDiskWrites()
                }
                return
            }
        }
        if didChange || pendingDiskWrites.isEmpty {
            persistPendingDiskWrites()
        }
    }

    private func applyPendingWritesToMemory() {
        for write in pendingDiskWrites {
            switch write {
            case .insert(let message):
                if let existingIndex = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[existingIndex] = message
                } else {
                    messages.append(message)
                }
            case .updateText(let id, let text):
                guard let index = messages.firstIndex(where: { $0.id == id }) else { continue }
                let current = messages[index]
                messages[index] = Message(
                    id: current.id,
                    role: current.role,
                    text: text,
                    wasCancelled: current.wasCancelled,
                    createdAt: current.createdAt
                )
            case .delete(let id):
                messages.removeAll { $0.id == id }
            case .setCancelled(let id, let cancelled):
                guard let index = messages.firstIndex(where: { $0.id == id }) else { continue }
                let current = messages[index]
                messages[index] = Message(
                    id: current.id,
                    role: current.role,
                    text: current.text,
                    wasCancelled: cancelled,
                    createdAt: current.createdAt
                )
            }
        }
        messages.sort { $0.createdAt < $1.createdAt }
    }

    /// Static variant used by `hydrate()` from a detached Task. Captures
    /// only a URL (value type, trivially Sendable) — no `self` capture,
    /// so it's safe to call from outside the main actor.
    ///
    /// Marked `nonisolated` so it doesn't inherit ConversationStore's
    /// `@MainActor` isolation. Without this, Swift 6 strict concurrency
    /// correctly complains: "main actor-isolated static method cannot
    /// be called from outside of the actor." The function's body only
    /// touches value types (URL, Data, JSONDecoder result), so running
    /// off-actor is safe.
    private nonisolated static func loadPendingDiskWritesFromURL(_ url: URL) -> [PendingDiskWrite] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingDiskWrite].self, from: data)) ?? []
    }

    private func persistPendingDiskWrites() {
        let url = database.pendingWritesURL
        if pendingDiskWrites.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(pendingDiskWrites) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

/// What a summarizer has to be able to do. FoundationModelsClient (and later
/// QwenClient) will conform to this.
protocol ConversationSummarizer: Sendable {
    func summarize(messages: [Message], existingSummary: String) async throws -> String
}
