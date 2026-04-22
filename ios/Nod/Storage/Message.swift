// Message.swift
// The data model for a single turn in a conversation.
//
// A "message" is one side of a back-and-forth: either the user typed/dictated
// something, or Nod responded. Plus a special "nod" kind for the "just nod"
// button, where the AI acknowledges without writing back.

import Foundation

struct Message: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
        case nod    // "just nod" response — no text, just a blink animation
    }

    let id: UUID
    let role: Role
    let text: String      // empty for .nod

    /// True when the user tapped stop before this reply finished streaming.
    /// Renders a subtle "stopped" tag below the bubble so the user can
    /// tell a truncated reply from a completed short one. Only ever true
    /// on `.assistant` messages; default false everywhere else.
    ///
    /// Persisted via the `v3_was_cancelled` migration. Safe to default to
    /// false on decoding old JSON (WAL replay) via the default argument.
    let wasCancelled: Bool

    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String = "",
        wasCancelled: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.wasCancelled = wasCancelled
        self.createdAt = createdAt
    }

    // Custom Codable so old WAL entries (no wasCancelled key) decode
    // cleanly instead of throwing.
    enum CodingKeys: String, CodingKey {
        case id, role, text, wasCancelled, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.role = try c.decode(Role.self, forKey: .role)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.wasCancelled = try c.decodeIfPresent(Bool.self, forKey: .wasCancelled) ?? false
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}
