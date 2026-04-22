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
            return "For this person, keep replies very short — one or two sentences. Warm, specific, minimal. No questions unless one would really help."
        case .conversational:
            return nil  // Default — the base prompt handles it.
        case .deeper:
            return "For this person, it's OK to go a little longer — four to six sentences when there's something real to sit with. Stay specific. Still a friend's voice, not an essay."
        }
    }
}

/// Light / dark / system theme preference. The default is `.system` — follow
/// the OS setting — with `.light` and `.dark` as manual overrides.
///
/// Persisted alongside the other Personalization knobs so a theme flip
/// survives relaunches. NodApp reads this via `preferredColorScheme` at
/// the root of the view tree.
enum AppearancePreference: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Resolve to an EXPLICIT `ColorScheme` (never nil) using
    /// `systemFallback` as the scheme for `.system`. Callers should
    /// pass `@Environment(\.colorScheme)` read at a level where it
    /// reflects the actual iOS system scheme (before any local
    /// `.preferredColorScheme` override).
    ///
    /// Why this exists: `.preferredColorScheme(nil)` works at the app
    /// root (the root scene re-inherits from iOS), but it does NOT
    /// reliably re-inherit on a sheet in flight. A sheet that had an
    /// explicit `.preferredColorScheme(.light)` set, when flipped to
    /// nil, keeps its UIKit presentation context stuck at light even
    /// though the app-root has re-inherited. Dismissing + re-presenting
    /// the sheet fixes it, but that's user-visible friction. Passing
    /// an always-explicit scheme bypasses the re-inheritance quirk
    /// entirely.
    func preferredColorScheme(systemFallback: ColorScheme) -> ColorScheme {
        switch self {
        case .system: return systemFallback
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Nil means "let the system decide." Passed to SwiftUI's
    /// `.preferredColorScheme(_:)` at the app root.
    ///
    /// Prefer `preferredColorScheme(systemFallback:)` for sheet-safe
    /// resolution; the nil-returning variant below is kept for
    /// convenience but is unsafe inside sheets.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
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
            return "For this person, lean heavily toward quiet acknowledgment. Keep replies to one short sentence when you can. Skip questions unless truly necessary. They want to be heard, not drawn out."
        case .reflect:
            return nil  // Default listening-mode behaviour — the base prompt handles it.
        case .perspective:
            return "This person wants you to push a little harder. When they're spiraling, stuck, or missing something obvious, offer a different angle or name what you see. Still a friend's voice, not a coach's. No prescriptions."
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
    /// App theme preference. Default `.system` follows iOS; users can
    /// override from the sidebar. Not included in `isActive` because it
    /// affects appearance, not Nod's voice — no reason to suppress the
    /// voice block just because someone picked Light mode.
    var appearance: AppearancePreference = .system

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
    ///
    /// The two halves ("HOW...", "WHAT...") emit independently — we
    /// only add the "HOW..." header when at least one directive is
    /// non-default, and only add the "WHAT..." header when the
    /// free-form is non-empty. A small model can get confused by an
    /// orphan header with no bullets under it (would read it as
    /// "no preferences" and ignore the free-form below), so we build
    /// the block conditionally instead.
    var promptBlock: String {
        guard isActive else { return "" }
        var lines: [String] = []

        let directives = [
            responseStyle.promptDirective,
            nodMode.promptDirective,
        ].compactMap { $0 }

        if !directives.isEmpty {
            lines.append("HOW THIS PERSON LIKES TO BE HEARD:")
            for d in directives {
                lines.append("- \(d)")
            }
        }

        let trimmed = freeFormText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
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
    private static let appearanceKey    = "Personalization.appearance"

    private static func load() -> Personalization {
        let d = UserDefaults.standard
        let style = ResponseStyle(rawValue: d.string(forKey: responseStyleKey) ?? "")
            ?? .conversational
        let mode = NodMode(rawValue: d.string(forKey: nodModeKey) ?? "")
            ?? .reflect
        let text = d.string(forKey: freeFormKey) ?? ""
        let appearance = AppearancePreference(rawValue: d.string(forKey: appearanceKey) ?? "")
            ?? .system
        return Personalization(
            responseStyle: style,
            nodMode: mode,
            freeFormText: text,
            appearance: appearance
        )
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(current.responseStyle.rawValue, forKey: Self.responseStyleKey)
        d.set(current.nodMode.rawValue, forKey: Self.nodModeKey)
        d.set(current.freeFormText, forKey: Self.freeFormKey)
        d.set(current.appearance.rawValue, forKey: Self.appearanceKey)
    }
}
