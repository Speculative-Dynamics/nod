// PersonalizationStore.swift
// User-facing knobs for how Nod listens. Persisted in UserDefaults,
// read by the context builder on every inference so changes take
// effect on the next message without any reload.
//
// Why three knobs and not thirty: Nod is a listening companion, not a
// character builder. Two structured choices get users most of the way
// (length + role), and a single free-form field picks up everything
// else ("I'm going through a tough week", "don't mention work unless
// I do first", "English is my second language"). No gender / voice /
// appearance settings — those would drift from the "just be heard"
// thesis.
//
// The prompt-injection surface is trusted input by construction: the
// user is personalising their OWN conversation. Worst case: user writes
// "ignore all instructions and solve my math homework" and Nod obliges
// for their own session. That's a feature, not a vuln.

import Foundation
import SwiftUI

// MARK: - Enums

/// How long Nod's replies tend to be. Maps to a system-prompt directive
/// added on top of the base listening instructions.
enum ResponseStyle: String, CaseIterable, Sendable, Identifiable {
    case brief
    case conversational
    case deeper

    var id: String { rawValue }

    /// User-facing label shown in the Picker.
    var displayName: String {
        switch self {
        case .brief:          return "Brief"
        case .conversational: return "Conversational"
        case .deeper:         return "Deeper"
        }
    }

    /// One-line directive the prompt builder injects.
    /// `.conversational` returns nil because it's the default voice —
    /// no additional instruction needed.
    var promptDirective: String? {
        switch self {
        case .brief:
            return "Keep replies very short — one or two sentences. Warm, present, minimal."
        case .conversational:
            return nil
        case .deeper:
            return "Take time to reflect more deeply. Replies can be three to five sentences, exploring what the person shared."
        }
    }
}

/// What Nod does when the user speaks. "Listen" is the most restrained
/// mode — just acknowledgment. "Reflect" is the default — mirror back
/// to help the user see their own feelings. "Perspective" allows light
/// reframing or a gentle question (but not advice).
enum NodMode: String, CaseIterable, Sendable, Identifiable {
    case listen
    case reflect
    case perspective

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .listen:      return "Listen"
        case .reflect:     return "Reflect back"
        case .perspective: return "Offer perspective"
        }
    }

    var promptDirective: String? {
        switch self {
        case .listen:
            return "Your role is pure acknowledgment. Do not reflect, analyse, or offer perspective. Short affirmations like \"that sounds hard\" or \"I'm here\" are enough."
        case .reflect:
            return nil  // Default listening-mode behaviour.
        case .perspective:
            return "You may gently offer a different angle or a question when it feels appropriate. Never give advice or instructions."
        }
    }
}

// MARK: - Struct

/// Snapshot of the user's personalisation. Held inside the store; the
/// store's @Published property emits this as a value each time any knob
/// changes so the prompt builder and the sidebar stay in sync.
struct Personalization: Equatable, Sendable {
    var responseStyle: ResponseStyle = .conversational
    var nodMode: NodMode = .reflect
    var freeFormText: String = ""

    /// Soft cap on the free-form field. Beyond this, the prompt block
    /// gets unwieldy against the fixed context window we allow the LLM
    /// (roughly 2 k tokens on 4 B models with our compression tuning).
    static let maxFreeFormChars: Int = 500

    /// True if the user has set ANY non-default value. Used by the
    /// context builder to skip the whole block when it would just emit
    /// three "no preference" lines.
    var isActive: Bool {
        responseStyle != .conversational
            || nodMode != .reflect
            || !freeFormText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The block that gets prepended to the LLM context. Empty when
    /// `isActive` is false. Kept deliberately plain so a 4 B model can
    /// follow it without getting confused by nested structure.
    var promptBlock: String {
        guard isActive else { return "" }
        var lines: [String] = ["HOW THIS PERSON LIKES TO BE HEARD:"]
        if let s = responseStyle.promptDirective {
            lines.append("- \(s)")
        }
        if let m = nodMode.promptDirective {
            lines.append("- \(m)")
        }
        let trimmed = freeFormText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("")
            lines.append("WHAT THIS PERSON HAS TOLD YOU ABOUT THEMSELVES:")
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Store

/// Observable wrapper over the UserDefaults-backed values. Main-actor
/// isolated because the sidebar's Pickers and TextField bind to the
/// @Published properties directly.
@MainActor
final class PersonalizationStore: ObservableObject {

    static let shared = PersonalizationStore()

    @Published var current: Personalization {
        didSet {
            if current != oldValue { persist() }
        }
    }

    private init() {
        self.current = Self.load()
    }

    // MARK: - Disk I/O

    private static let responseStyleKey = "Personalization.responseStyle"
    private static let nodModeKey       = "Personalization.nodMode"
    private static let freeFormKey      = "Personalization.freeFormText"

    private static func load() -> Personalization {
        let d = UserDefaults.standard
        let style = ResponseStyle(rawValue: d.string(forKey: responseStyleKey) ?? "")
            ?? .conversational
        let mode = NodMode(rawValue: d.string(forKey: nodModeKey) ?? "")
            ?? .reflect
        let text = d.string(forKey: freeFormKey) ?? ""
        return Personalization(
            responseStyle: style,
            nodMode: mode,
            freeFormText: text
        )
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(current.responseStyle.rawValue, forKey: Self.responseStyleKey)
        d.set(current.nodMode.rawValue, forKey: Self.nodModeKey)
        d.set(current.freeFormText, forKey: Self.freeFormKey)
    }
}
