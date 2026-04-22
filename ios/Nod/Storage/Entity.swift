// Entity.swift
// Domain types for structured memory: the people, places, projects, and
// ongoing situations the user has mentioned across their conversation
// with Nod.
//
// These are the persistent, cross-session side of memory. The rolling
// summary (in ConversationStore) remembers the NARRATIVE; entities
// remember the NOUNS. Together they let Nod respond to "did M ever
// reply?" five sessions later without the user having to re-explain
// who M is.
//
// Design constraint (locked via outside-voice review, see TODOS.md):
// these records exist for CONTEXT INJECTION only. Nod NEVER volunteers
// pattern observations about them ("you've mentioned M a lot lately").
// The retrieval layer in EntityStore enforces this by only surfacing
// entities that the current user message already references (directly
// or via semantic match).
//
// Storage: SQLite via GRDB, tables `entities` + `entity_aliases`, see
// MessageDatabase.runMigrations v2_entities.

import Foundation

/// What kind of thing this entity is. Drives how Nod refers to it
/// in context ("M (manager)" vs "the fintech interview (situation)").
enum EntityType: String, Codable, Sendable, CaseIterable {
    case person
    case place
    case project
    case situation

    /// Human-readable label used in the context block we inject at
    /// inference time. Short so token count stays tight.
    var shortLabel: String {
        switch self {
        case .person:    return "person"
        case .place:     return "place"
        case .project:   return "project"
        case .situation: return "situation"
        }
    }
}

/// One persisted fact the user has mentioned. Canonical name is what
/// Nod uses to refer to it back ("M"); aliases are all the other
/// spellings we've seen for the same thing ("M.", "Mark"). Role gives
/// Nod the relationship context ("manager", "partner"). Notes are a
/// short factual tail ("laid off user in Q3, still unresolved") kept
/// deliberately brief so the injected context stays compact.
struct Entity: Identifiable, Equatable, Sendable {
    let id: UUID
    var type: EntityType
    var canonicalName: String
    var role: String?
    var notes: String
    var aliases: [String]
    var firstMentionedAt: Date
    var lastMentionedAt: Date
    var mentionCount: Int

    /// NLEmbedding-derived sentence vector of `canonical_name + role + notes`.
    /// Encoded as a BLOB of Float32 values (little-endian). Nullable
    /// because NLEmbedding can fail on some locales — keyword/alias
    /// match still works when this is nil.
    var embedding: Data?

    init(
        id: UUID = UUID(),
        type: EntityType,
        canonicalName: String,
        role: String? = nil,
        notes: String = "",
        aliases: [String] = [],
        firstMentionedAt: Date = Date(),
        lastMentionedAt: Date = Date(),
        mentionCount: Int = 1,
        embedding: Data? = nil
    ) {
        self.id = id
        self.type = type
        self.canonicalName = canonicalName
        self.role = role
        self.notes = notes
        self.aliases = aliases
        self.firstMentionedAt = firstMentionedAt
        self.lastMentionedAt = lastMentionedAt
        self.mentionCount = mentionCount
        self.embedding = embedding
    }

    /// The text we embed for vector retrieval. Combining name + role +
    /// notes gives the embedding enough signal that a user message like
    /// "my manager just apologized" semantically matches an entity
    /// stored as `canonical_name="M", role="manager"` even though the
    /// literal string "M" isn't in the user message.
    var embeddingSource: String {
        var parts: [String] = [canonicalName]
        if let role, !role.isEmpty {
            parts.append(role)
        }
        if !notes.isEmpty {
            parts.append(notes)
        }
        return parts.joined(separator: ". ")
    }

    /// One-line representation used inside the "PEOPLE AND SITUATIONS
    /// YOU KNOW ABOUT" block of the system prompt. Kept compact — we're
    /// spending tokens to bring this context in, so waste nothing.
    var contextLine: String {
        var line = "\(canonicalName)"
        if let role, !role.isEmpty {
            line += " (\(role))"
        }
        if !notes.isEmpty {
            line += ": \(notes)"
        }
        return line
    }
}

/// A pending question for the user when extraction produced a new
/// entity name that fuzzy-matches an existing one. Surface as an
/// inline banner in ChatView; user taps [Same] or [New] and we commit
/// the resolution.
///
/// These live in memory (never persisted) — if the user ignores a
/// prompt and closes the app, the prompt is dropped. The extracted
/// entity is NOT saved until resolved, so closing without answering
/// = discard. That's a deliberate UX choice: forcing the user to
/// answer every prompt would be worse than occasionally losing a
/// new alias.
struct PendingDisambiguation: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The brand-new entity we'd insert if the user taps [New].
    let candidate: Entity
    /// The existing entity that fuzzy-matched.
    let existing: Entity

    init(id: UUID = UUID(), candidate: Entity, existing: Entity) {
        self.id = id
        self.candidate = candidate
        self.existing = existing
    }
}
