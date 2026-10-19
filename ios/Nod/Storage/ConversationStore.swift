// ConversationStore.swift
// The one continuous conversation with Nod. Backed by SQLite via
// MessageDatabase so it survives app close, restart, and reboot.
//
// Per the product thesis: no sessions, no "new chat." One user, one ongoing
// relationship with Nod. This object is the in-memory view of that
// relationship plus the compression machinery that lets it run forever.
//
// What the model sees each turn:
//   - the recent, not-yet-compressed messages, verbatim, as real turns
//   - memory (ConversationMemory): the latest chapter note, older notes
//     and past user messages relevant to what was just said
// Once the verbatim backlog crosses the high-water mark, its oldest batch
// gets a write-once chapter note and ages out of the verbatim window.

import Foundation
import OSLog
import SwiftUI

/// Diagnostic logger for compression and memory events.
private let memoryLog = Logger(subsystem: "app.usenod.nod", category: "memory")

@MainActor
final class ConversationStore: ObservableObject {

    private enum PendingDiskWrite: Codable, Sendable {
        case insert(Message)
        case updateText(id: UUID, text: String)
        case delete(id: UUID)
        case setCancelled(id: UUID, cancelled: Bool)
        case setError(id: UUID, isError: Bool)

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
            case .setError(let id, let isError):
                try database.setError(id: id, isError: isError)
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
    ///
    /// These numbers are MLX's. Apple's model runs outside our memory
    /// budget and its turn assembly trims to the context window, so it
    /// keeps more recent turns verbatim (see `CompressionPolicy.roomy`).
    struct CompressionPolicy: Sendable {
        let highWaterMark: Int
        let batchSize: Int

        static let compact = CompressionPolicy(highWaterMark: 12, batchSize: 8)
        static let roomy = CompressionPolicy(highWaterMark: 20, batchSize: 12)
    }

    private let compressionPolicy: () -> CompressionPolicy

    private let database: MessageDatabase
    private let chapterWriter: () -> ChapterWriter?

    /// Chapters and recall index. Published so the Memory screen updates
    /// as chapters are written or forgotten.
    @Published private(set) var memory = ConversationMemory()

    /// Compression runs on a background task. We hold the handle so we don't
    /// fire a second one while the first is still running.
    private var compressionTask: Task<Void, Never>?

    private var pendingDiskWrites: [PendingDiskWrite] = []

    init(
        database: MessageDatabase,
        chapterWriter: @escaping () -> ChapterWriter?,
        compressionPolicy: @escaping () -> CompressionPolicy = { .compact }
    ) {
        self.database = database
        self.compressionPolicy = compressionPolicy
        self.chapterWriter = chapterWriter
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
        // Building the recall index tags every past message (NLTagger),
        // so it happens off the main actor too.
        async let fetchedMemory: ConversationMemory = Task.detached {
            var memory = ConversationMemory()
            for chapter in (try? db.fetchChapters()) ?? [] {
                memory.addChapter(chapter)
            }
            for message in (try? db.fetchRecallableUserMessages()) ?? [] where !message.isError {
                memory.addUserMessage(id: message.id, text: message.text, date: message.createdAt)
            }
            return memory
        }.value
        async let fetchedWAL: [PendingDiskWrite] = Task.detached {
            Self.loadPendingDiskWritesFromURL(walURL)
        }.value

        let loadedMessages = await fetchedMessages
        let loadedMemory = await fetchedMemory
        let loadedWAL = await fetchedWAL

        // Back on MainActor — apply to published state.
        self.messages = loadedMessages
        self.memory = loadedMemory
        self.pendingDiskWrites = loadedWAL
        applyPendingWritesToMemory()
        flushPendingDiskWrites()

        self.isHydrated = true
    }

    // MARK: - Appending messages

    func append(_ message: Message) {
        messages.append(message)
        enqueueDiskWrite(.insert(message))
        if message.role == .user, !message.text.isEmpty {
            memory.addUserMessage(id: message.id, text: message.text, date: message.createdAt)
        }
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
    ///
    /// `isError` marks the row as an app-written error notice, which keeps
    /// it out of the model's history, summaries, and memory.
    func replaceLastAssistantMessage(with text: String, isError: Bool = false) {
        guard let lastIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        let updated = messages[lastIndex].with(text: text, isError: isError)
        messages[lastIndex] = updated
        enqueueDiskWrite(.updateText(id: updated.id, text: text))
        if isError {
            enqueueDiskWrite(.setError(id: updated.id, isError: true))
        }
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
        messages[lastIndex] = messages[lastIndex].with(text: text)
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
        guard messages[index].role == .assistant else { return }
        messages[index] = messages[index].with(wasCancelled: cancelled)
        enqueueDiskWrite(.setCancelled(id: id, cancelled: cancelled))
    }

    // MARK: - Context for the LLM

    /// Bundle of inputs for an inference call.
    ///
    /// Split in two on purpose: `systemBlock` is what frames who Nod is and
    /// what it knows (personalization + memory). `history` is the
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
    /// The memory part of the system block (see ConversationMemory) holds
    /// the latest chapter note plus older notes and past messages that
    /// relate to `currentUserMessage`. Unrelated memory is never
    /// included, so Nod has nothing to volunteer.
    ///
    /// `excludingFromHistory` drops specific rows from `history` — used
    /// by regenerate so the reply being replaced isn't shown to the
    /// model as if it had already answered.
    func buildInferenceInputs(
        currentUserMessage: String? = nil,
        excludingFromHistory excluded: Set<UUID> = []
    ) -> InferenceInputs {
        var history: [Message] = []
        var verbatimSince: Date?
        do {
            var recent = try database.fetchUnsummarizedMessages()
            verbatimSince = recent.first?.createdAt
            // Drop the empty assistant placeholder that ChatView inserts
            // before streaming tokens back in.
            recent = recent.filter { !($0.role == .assistant && $0.text.isEmpty) }
            recent = recent.filter { !excluded.contains($0.id) && !$0.isError }
            // Drop the most recent user message — it's the current query.
            if let lastIndex = recent.lastIndex(where: { $0.role == .user }) {
                recent.remove(at: lastIndex)
            }
            history = recent
        } catch {
            // DB read failure: engines still see personalization + memory.
            // Worse answer this turn, but not a crash.
        }

        let systemBlock = memory.context(
            for: currentUserMessage ?? "",
            personalization: PersonalizationStore.shared.current.promptBlock,
            verbatimSince: verbatimSince
        )

        return InferenceInputs(
            systemBlock: systemBlock,
            history: history
        )
    }

    // MARK: - Compression

    private func maybeTriggerCompression() {
        guard compressionTask == nil else { return }
        let policy = compressionPolicy()
        do {
            let count = try database.unsummarizedCount()
            guard count >= policy.highWaterMark else { return }
        } catch {
            return
        }
        guard let writer = chapterWriter() else { return }

        compressionTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runCompression(writer: writer, batchSize: policy.batchSize)
        }
    }

    /// Age the oldest batch out of the verbatim window: write a chapter
    /// note about it (grounded against what the user said), then mark the
    /// batch compressed and store the chapter in one transaction.
    private func runCompression(writer: ChapterWriter, batchSize: Int) async {
        defer {
            Task { @MainActor in self.compressionTask = nil }
        }
        do {
            let oldest = try database.fetchOldestUnsummarized(limit: batchSize)
            guard !oldest.isEmpty else { return }
            // Error notices are app chrome, not conversation.
            let conversational = oldest.filter { !$0.isError && !$0.text.isEmpty }

            var chapter: ConversationMemory.Chapter?
            if !conversational.isEmpty {
                do {
                    let note = try await writer.chapterNote(messages: conversational)
                    chapter = ConversationMemory.makeChapter(note: note, covering: conversational)
                    if chapter == nil {
                        memoryLog.info("compression: note had nothing grounded; batch ages out without a chapter")
                    }
                } catch where AFMListening.classify(error) == .refusal {
                    // Retrying would refuse again forever and the backlog
                    // would never shrink. Age the batch out without a note;
                    // its messages are still recallable.
                    memoryLog.error("compression: chapter note refused — batch ages out without a chapter")
                }
            }

            try database.compress(ids: oldest.map(\.id), into: chapter)
            if let chapter {
                memory.addChapter(chapter)
            }
        } catch {
            // Best-effort: the backlog grows by one batch and we retry on
            // the next high-water trip. The conversation keeps working.
            memoryLog.error("compression: pass failed — \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Memory screen

    /// Forget a chapter: its note goes, and Nod stops recalling the
    /// user's messages from that stretch. The messages stay in the chat.
    func forgetChapter(_ chapter: ConversationMemory.Chapter) {
        do {
            try database.forgetChapter(chapter)
            memory.forgetChapter(id: chapter.id)
        } catch {
            memoryLog.error("forgetChapter failed — \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Start fresh

    /// Clears the entire conversation (messages and memory) from both
    /// memory and disk. The user opts into this explicitly via the
    /// sidebar's "Start fresh" action.
    ///
    /// Waits for any in-flight compression to fully cancel before wiping
    /// the database — otherwise a late-finishing compression task could
    /// write a new chapter into the just-cleared table.
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
        memory = ConversationMemory()
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
                messages[index] = messages[index].with(text: text)
            case .delete(let id):
                messages.removeAll { $0.id == id }
            case .setCancelled(let id, let cancelled):
                guard let index = messages.firstIndex(where: { $0.id == id }) else { continue }
                messages[index] = messages[index].with(wasCancelled: cancelled)
            case .setError(let id, let isError):
                guard let index = messages.firstIndex(where: { $0.id == id }) else { continue }
                messages[index] = messages[index].with(isError: isError)
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
        MessageDatabase.applyBackupPreference(to: url)
    }
}

/// Writes the note for a chapter (see prompts/chapter_note.md). Every
/// listening engine can do it.
protocol ChapterWriter: Sendable {
    func chapterNote(messages: [Message]) async throws -> String
}
