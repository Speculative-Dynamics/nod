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
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String = "", createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}
