// EntityStore.swift
// The coordination layer for structured memory. Wraps MessageDatabase's
// entity CRUD with:
//   - Ingestion: normalize extracted entities, dedupe via exact + alias
//     match, queue ambiguous-match candidates for disambiguation UX.
//   - Retrieval: hybrid keyword-first + vector-fallback to select the
//     entities relevant to the current user message.
//   - Disambiguation queue: @Published list of pending questions so
//     ChatView can surface an inline banner. Resolution applies to the
//     DB and pops the queue.
//   - Deletion: per-entity `delete(_:)` for the Memory screen. Also
//     drops any pending disambiguations that reference the deleted
//     entity so the user never sees a ghost prompt.
//
// Concurrency: @MainActor because of the @Published state. DB
// reads/writes are synchronous on GRDB's own queue — cheap enough to
// call directly from the main actor for our volume (tens of entities,
// not thousands).
//
// Why keep this separate from ConversationStore: ConversationStore is
// already doing a lot (messages, summary, compression, pending disk
// writes). Entity memory is a parallel concern with its own lifecycle
// triggers. Splitting files keeps each one under a couple hundred
// lines of real logic.

import Foundation
import SwiftUI

@MainActor
final class EntityStore: ObservableObject {

    // MARK: - Inputs

    private let database: MessageDatabase
    private let embedder: EntityEmbedder

    // MARK: - Published state

    /// The full list of entities Nod knows about. Kept in sync with the
    /// DB for fast retrieval on every inference call AND for the Memory
    /// screen's reactive rendering. `@Published` so SwiftUI
    /// (MemoryView, sidebar count badge) re-renders on changes.
    /// `private(set)` keeps the write API narrow — only EntityStore's
    /// own methods mutate this.
    @Published private(set) var entities: [Entity] = []

    /// Pending disambiguation prompts for the user. ChatView observes
    /// this and renders a banner per pending item between messages.
    /// Intentionally in-memory only — if the user closes the app with
    /// a pending prompt, it's dropped (see `PendingDisambiguation`
    /// rationale).
    @Published private(set) var pendingDisambiguations: [PendingDisambiguation] = []

    /// Flips to true after `hydrate()` completes. Parallels
    /// `ConversationStore.isHydrated`. Exposed for future callers that
    /// might need to gate on entity readiness; today ChatView only
    /// gates send on the conversation side, because entity retrieval
    /// gracefully returns an empty list pre-hydrate.
    @Published private(set) var isHydrated: Bool = false

    // MARK: - Decoded-embedding cache
    //
    // INVARIANT: for every entity currently in `entities` that has a
    // non-nil `.embedding` blob, `decodedEmbeddings[entity.id]` holds
    // the decoded `[Float]` form of that blob. For entities without an
    // embedding (embedder unavailable at ingest time), the map has no
    // entry — retrieval and fuzzy-match paths gracefully skip them.
    //
    // Why this exists: `retrieveRelevant` and `findFuzzyMatch` run on
    // every message send / ingest. Without the cache, both paths call
    // `embedder.decode(blob)` per stored entity on each invocation —
    // at 50 entities that's ~50 KB of `[Float]` allocation churn per
    // call, plus the per-byte copy out of `Data`. Caching the decoded
    // form once (at load time and on each mutation) makes the hot
    // paths pure O(N) cosine scans over pre-decoded vectors.
    //
    // MAINTENANCE CONTRACT: all writes to `entity.embedding` MUST go
    // through `applyEmbedding(_:to:)`. All deletions MUST remove the
    // entry. Direct assignment bypasses the cache and silently returns
    // stale retrieval results. The helpers below are the ONLY callers
    // of `decodedEmbeddings[...]`.
    private var decodedEmbeddings: [UUID: [Float]] = [:]

    // MARK: - Tuning

    /// Vector-similarity threshold for fuzzy entity matching during
    /// extraction. Above this, we treat the extracted name as an alias
    /// of an existing entity (and queue for user confirmation if the
    /// canonical names differ). Below, we treat it as brand new.
    ///
    /// 0.70 is conservative — names like "M" vs "Mark" score well
    /// above that when the roles match; unrelated entities score well
    /// below. Tunable after on-device usage.
    private let fuzzyMatchThreshold: Float = 0.70

    /// Minimum similarity for vector retrieval at inference time.
    /// Separate from the merge threshold because retrieval over a user
    /// message (natural language) has more noise than entity-vs-entity
    /// comparison. Lower means more recall, more false positives.
    private let retrievalMinSimilarity: Float = 0.55

    /// Max entities injected into the system block per turn. Token
    /// budget discipline — we want personalization + summary + entities
    /// + prompt to stay under ~1.2k tokens of context before history.
    private let retrievalTopK: Int = 5

    // MARK: - Init

    init(database: MessageDatabase) {
        self.database = database
        self.embedder = EntityEmbedder()
        // NOTE: No disk work here. Fetch + embedding-decode moved to
        // `hydrate()` so ChatView.init stays lightweight and the splash
        // animation isn't blocked during cold launch. Caller invokes
        // hydrate() post-mount.
    }

    /// Bring in-memory state into sync with disk. Called once from
    /// ChatView's `.task` on cold launch, in parallel with
    /// ConversationStore's hydrate.
    ///
    /// Fetch runs off-main via Task.detached; embedding decode (fast —
    /// microseconds per entity) stays on main actor because `embedder`
    /// isn't Sendable and the work is too small to bother offloading.
    ///
    /// Idempotent: calling twice is a no-op.
    func hydrate() async {
        guard !isHydrated else { return }

        let db = self.database
        let fetched: [Entity] = await Task.detached {
            (try? db.fetchAllEntities()) ?? []
        }.value

        self.entities = fetched
        // Populate decoded-embedding cache. See the invariant note above
        // `decodedEmbeddings`. This is the only place we pay the N-decode
        // cost; every subsequent retrieval reads the cached vectors.
        decodedEmbeddings.removeAll()
        for entity in entities {
            resyncEmbeddingCache(for: entity)
        }

        self.isHydrated = true
    }

    // MARK: - Read API (for ConversationStore.buildInferenceInputs)

    /// Return the entities most relevant to the user's current message.
    /// Hybrid: keyword + alias match first (word-level, case-insensitive);
    /// vector similarity as a fallback when keyword returns nothing.
    ///
    /// The hybrid shape — rather than always-vector — is deliberate.
    /// Keyword hits are high-precision, no false positives. Vector hits
    /// are higher-recall but can false-positive on unrelated messages
    /// ("I'm tired" finding some random entity by accident). By only
    /// running vector when keyword returned zero, we avoid polluting
    /// the system prompt with irrelevant entities on most turns.
    ///
    /// Empty result is common and correct — most messages don't
    /// reference stored entities, and we inject NOTHING in that case.
    /// That's how we keep Nod from volunteering pattern observations.
    func retrieveRelevant(for userMessage: String) -> [Entity] {
        guard !entities.isEmpty else { return [] }
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Layer 1: word-level match on canonical name or aliases. Must
        // be word-level, not substring: design-doc-canonical names like
        // "M" or "J" (single letters) would substring-match nearly
        // every English message if we used `contains`. `hasWordMatch`
        // tokenises on whitespace, strips punctuation and possessives,
        // and requires an exact token equality.
        let keywordMatches = entities.filter { entity in
            if Self.hasWordMatch(in: trimmed, name: entity.canonicalName) {
                return true
            }
            for alias in entity.aliases
            where Self.hasWordMatch(in: trimmed, name: alias) {
                return true
            }
            return false
        }
        if !keywordMatches.isEmpty {
            return Array(keywordMatches.prefix(retrievalTopK))
        }

        // Layer 2: vector similarity fallback. Skipped when embedder
        // isn't available for this locale. We still decode the USER's
        // message on-the-fly (one-shot query vec, not worth caching) —
        // the per-entity decode that used to happen here is the one
        // that now reads from the pre-populated `decodedEmbeddings`
        // map. See the invariant at the map's declaration.
        guard embedder.isAvailable,
              let queryVec = embedder.embed(trimmed).flatMap(embedder.decode) else {
            return []
        }
        let scored: [(Entity, Float)] = entities.compactMap { entity in
            guard let vec = decodedEmbeddings[entity.id] else { return nil }
            let score = embedder.cosine(queryVec, vec)
            return score >= retrievalMinSimilarity ? (entity, score) : nil
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(retrievalTopK)
            .map(\.0)
    }

    // MARK: - Write API (called by ConversationStore after extraction)

    /// Ingest a batch of extracted entities. For each:
    ///   - Exact canonical / alias match → update in place
    ///     (increment count, append any new detail).
    ///   - Fuzzy match (vector similarity ≥ threshold, different name)
    ///     → queue a PendingDisambiguation for the user.
    ///   - No match → insert a new entity.
    ///
    /// Safe to call repeatedly with overlapping batches; the strict-
    /// match path is idempotent.
    func ingest(_ extracted: ExtractedEntities) {
        for raw in extracted.items {
            guard let type = EntityType(rawValue: raw.type.lowercased()) else {
                continue  // LLM returned an unknown type; skip.
            }
            let trimmedName = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            let trimmedRole = raw.role.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNote = raw.note.trimmingCharacters(in: .whitespacesAndNewlines)

            // Exact or alias match → update in place.
            if let existingIdx = findExactMatch(name: trimmedName) {
                updateExisting(at: existingIdx, newRole: trimmedRole, newNote: trimmedNote)
                continue
            }

            // Build a candidate entity so we can either queue for
            // disambiguation or insert fresh.
            let candidate = Entity(
                type: type,
                canonicalName: trimmedName,
                role: trimmedRole.isEmpty ? nil : trimmedRole,
                notes: trimmedNote,
                aliases: [],
                firstMentionedAt: Date(),
                lastMentionedAt: Date(),
                mentionCount: 1,
                embedding: nil  // filled in below
            )

            // Compute the embedding once so fuzzy match and persistence
            // both see the same vector. `applyEmbedding` both sets the
            // blob on the candidate AND populates the decoded-vector
            // cache for its id, so findFuzzyMatch below and a later
            // retrieveRelevant both read the same cached decode.
            var candidateEmbed: [Float]? = nil
            var candidateWithEmbedding = candidate
            if embedder.isAvailable {
                candidateEmbed = applyEmbedding(
                    embedder.embed(candidate.embeddingSource),
                    to: &candidateWithEmbedding
                )
            }

            // Fuzzy match? Only if embedding worked for both candidate
            // and at least one existing entity. Different canonical_name
            // + high vector similarity + same type = same thing under a
            // different spelling; queue for user confirmation.
            if let queryVec = candidateEmbed,
               let fuzzy = findFuzzyMatch(vector: queryVec, type: type) {
                // Don't persist the candidate yet — it's pending the
                // user's [Same/New] answer. If they pick [Same] we add
                // the alias; [New] we insert fresh.
                let pending = PendingDisambiguation(
                    candidate: candidateWithEmbedding,
                    existing: fuzzy
                )
                pendingDisambiguations.append(pending)
                continue
            }

            // No match at all → insert fresh.
            insertFresh(candidateWithEmbedding)
        }
    }

    /// How the user answered a PendingDisambiguation.
    enum Resolution {
        /// The candidate and the existing are the same thing. Add the
        /// candidate's name as an alias on the existing entity; merge
        /// any new details.
        case same
        /// The candidate is genuinely a new entity. Insert it as a new
        /// row.
        case new
    }

    /// Apply the user's answer to a pending disambiguation prompt and
    /// pop it from the queue. No-op if the prompt has already been
    /// resolved (defensive against double-tap).
    ///
    /// Defensive path on `.same`: if the existing entity has been
    /// deleted (via the Memory screen) between when the prompt was
    /// queued and when the user answered, treat the resolution as if
    /// the user had picked `.new` — the candidate is a meaningful
    /// entity regardless, and silently dropping it would lose info.
    func resolve(_ pending: PendingDisambiguation, as resolution: Resolution) {
        guard pendingDisambiguations.contains(where: { $0.id == pending.id }) else {
            return
        }
        switch resolution {
        case .same:
            if let idx = entities.firstIndex(where: { $0.id == pending.existing.id }) {
                var merged = entities[idx]
                if !merged.aliases.contains(pending.candidate.canonicalName) {
                    merged.aliases.append(pending.candidate.canonicalName)
                }
                merged.lastMentionedAt = Date()
                merged.mentionCount += 1
                merged.notes = mergeNotes(existing: merged.notes, incoming: pending.candidate.notes)
                // Re-embed with the richer content. `applyEmbedding`
                // mutates `merged.embedding` AND refreshes the cache
                // entry so retrievals immediately see the new vector.
                if embedder.isAvailable {
                    applyEmbedding(
                        embedder.embed(merged.embeddingSource),
                        to: &merged
                    )
                }
                persistAndCache(merged, at: idx)
            } else {
                // Existing entity got deleted while this prompt was
                // queued. Rather than silently drop the candidate,
                // persist it as a new row — the user said the two were
                // the same thing, but that thing no longer lives in
                // the store, so the candidate is the only survivor.
                insertFresh(pending.candidate)
            }
        case .new:
            insertFresh(pending.candidate)
        }
        pendingDisambiguations.removeAll { $0.id == pending.id }
    }

    /// Delete one entity from the memory. Called by MemoryView's
    /// swipe-to-delete + confirmation alert. Also drops any pending
    /// disambiguation that references this entity as `existing` — a
    /// deleted entity can no longer be merged with, so the prompt is
    /// meaningless. Candidate-side references stay untouched (those
    /// haven't been written yet and still represent a real potential
    /// entity).
    ///
    /// Write order: DB first, then cache. On DB error, cache stays
    /// consistent with disk. Same failure-mode pattern as the rest of
    /// EntityStore's writes.
    func delete(_ entity: Entity) {
        do {
            try database.deleteEntity(id: entity.id)
        } catch {
            return
        }
        entities.removeAll { $0.id == entity.id }
        pendingDisambiguations.removeAll { $0.existing.id == entity.id }
        // Cache invariant: no entity → no cached vector. Without this
        // the decoded map would leak vectors for deleted ids.
        decodedEmbeddings.removeValue(forKey: entity.id)
    }

    /// Full wipe: DB rows + in-memory cache + pending queue. Used when
    /// the caller owns both sides of the teardown.
    func clear() {
        do {
            try database.deleteAllEntities()
        } catch {
            return
        }
        resetInMemory()
    }

    /// Reset only the in-memory cache + pending disambiguation queue.
    /// Used by ConversationStore.clear(), which wipes the entity tables
    /// as part of its own `database.clearAll()` transaction — calling
    /// this makes the intent (sync cache to already-wiped DB) explicit.
    func resetInMemory() {
        entities.removeAll()
        pendingDisambiguations.removeAll()
        decodedEmbeddings.removeAll()
    }

    // MARK: - Private helpers

    /// Write an embedding blob onto an entity AND keep the decoded-vector
    /// cache in sync. This is the ONLY legal way to mutate
    /// `entity.embedding` inside EntityStore — direct assignment
    /// bypasses the cache (see invariant at the `decodedEmbeddings`
    /// declaration).
    ///
    /// Returns the decoded vector on success, nil if blob is nil or
    /// failed to decode. The return value saves a cache lookup in
    /// callers that need the freshly-computed vector (e.g., ingest
    /// passing the vector into `findFuzzyMatch`).
    @discardableResult
    private func applyEmbedding(_ blob: Data?, to entity: inout Entity) -> [Float]? {
        entity.embedding = blob
        return resyncEmbeddingCache(for: entity)
    }

    /// Bring the cache entry for an entity in line with that entity's
    /// current `embedding` blob. Used by `applyEmbedding` and by the
    /// error-recovery path in `persistAndCache` (where we want to
    /// restore the cache to match `entities[index]` after a failed DB
    /// write left the cache holding a not-yet-persisted vector).
    @discardableResult
    private func resyncEmbeddingCache(for entity: Entity) -> [Float]? {
        if let blob = entity.embedding, let vec = embedder.decode(blob) {
            decodedEmbeddings[entity.id] = vec
            return vec
        }
        decodedEmbeddings.removeValue(forKey: entity.id)
        return nil
    }

    /// Does `haystack` contain `name` at a word boundary?
    ///
    /// Short canonical names like "M" or "J" (common per design doc —
    /// users use initials for recurring people) MUST NOT substring-
    /// match the "m" in "I'm" or the "j" in "enjoy." `localizedCase-
    /// InsensitiveContains` would do exactly that, and silently pollute
    /// every retrieval.
    ///
    /// Strategy: split on whitespace, strip surrounding punctuation
    /// AND any trailing possessive ("M's" → "M"), compare exact.
    /// Multi-word names ("the fintech interview") fall back to
    /// substring, which is reasonable because they're long enough to
    /// be specific.
    ///
    /// Cases this handles:
    ///   - "M sent"        ✓ matches "M"
    ///   - "M's reply"     ✓ matches "M" (possessive stripped)
    ///   - "I hate M."     ✓ matches "M" (period stripped)
    ///   - "I'm going"     ✗ does NOT match "M"
    ///   - "my coffee"     ✗ does NOT match "M"
    ///   - "MM is weird"   ✗ does NOT match "M"
    static func hasWordMatch(in haystack: String, name: String) -> Bool {
        let needle = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }

        // Multi-word phrases ("the fintech interview") are long enough
        // that substring match is safe and intuitive — "did the fintech
        // interview go well" should hit the stored phrase.
        if needle.contains(where: { $0.isWhitespace }) {
            return haystack.localizedCaseInsensitiveContains(needle)
        }

        // Single-token name: tokenise, strip, compare.
        let strip = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
        return haystack
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .contains { raw in
                var token = String(raw).trimmingCharacters(in: strip)
                // Strip possessive suffix: "m's" → "m" (ASCII + curly apostrophe).
                if token.hasSuffix("'s") || token.hasSuffix("\u{2019}s") {
                    token = String(token.dropLast(2))
                }
                return token == needle
            }
    }

    private func findExactMatch(name: String) -> Int? {
        for (i, entity) in entities.enumerated() {
            if entity.canonicalName.caseInsensitiveCompare(name) == .orderedSame {
                return i
            }
            if entity.aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return i
            }
        }
        return nil
    }

    private func findFuzzyMatch(vector: [Float], type: EntityType) -> Entity? {
        var bestScore: Float = 0
        var best: Entity?
        for entity in entities {
            // Type gate first (cheap), then cached-vector lookup.
            // Same-source decode used to happen inline per iteration —
            // ingest bursts (many extracted entities hitting this in a
            // row) are the other hot path this cache protects.
            guard entity.type == type,
                  let existingVec = decodedEmbeddings[entity.id] else { continue }
            let score = embedder.cosine(vector, existingVec)
            if score >= fuzzyMatchThreshold, score > bestScore {
                bestScore = score
                best = entity
            }
        }
        return best
    }

    private func updateExisting(at index: Int, newRole: String, newNote: String) {
        var entity = entities[index]
        entity.lastMentionedAt = Date()
        entity.mentionCount += 1
        if entity.role == nil, !newRole.isEmpty {
            entity.role = newRole
        }
        entity.notes = mergeNotes(existing: entity.notes, incoming: newNote)
        // Re-embed through the cache-aware helper so the next
        // retrieveRelevant sees the updated vector (otherwise the
        // decoded cache would hold the stale pre-update vector).
        if embedder.isAvailable {
            applyEmbedding(
                embedder.embed(entity.embeddingSource),
                to: &entity
            )
        }
        persistAndCache(entity, at: index)
    }

    private func insertFresh(_ entity: Entity) {
        do {
            try database.upsertEntity(entity)
            entities.append(entity)
        } catch {
            // DB write failed — keep the in-memory state consistent
            // with disk by NOT updating the cache, and silently drop
            // the entity. Next compression retries.
            //
            // The caller (ingest) has already populated
            // `decodedEmbeddings[entity.id]` via `applyEmbedding` on the
            // candidate, in anticipation of a successful insert. Since
            // the entity won't exist in `entities`, drop the orphaned
            // cache entry to preserve the invariant.
            decodedEmbeddings.removeValue(forKey: entity.id)
        }
    }

    private func persistAndCache(_ entity: Entity, at index: Int) {
        do {
            try database.upsertEntity(entity)
            entities[index] = entity
        } catch {
            // DB write failed. `entities[index]` still holds the old
            // version. The caller (updateExisting / resolve) has
            // already applied the new vector to the cache via
            // `applyEmbedding`, so the cache is ahead of `entities`.
            // Revert by re-syncing the cache to the unchanged entity's
            // blob — keeps the invariant and avoids silent-stale
            // retrievals.
            resyncEmbeddingCache(for: entities[index])
        }
    }

    /// Merge two notes strings. Simple policy: if the incoming text is
    /// genuinely new (not already a substring of existing), append with
    /// a separator. Keeps notes growing organically over time while
    /// avoiding the "repeated the same sentence three times" failure
    /// when the LLM keeps emitting the same note.
    private func mergeNotes(existing: String, incoming: String) -> String {
        guard !incoming.isEmpty else { return existing }
        if existing.isEmpty { return incoming }
        if existing.localizedCaseInsensitiveContains(incoming) { return existing }
        return "\(existing); \(incoming)"
    }
}
