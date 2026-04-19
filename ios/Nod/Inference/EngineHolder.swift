// EngineHolder.swift
// Observable owner of the current inference engine. Bridges the
// UserDefaults-backed EnginePreference into SwiftUI so ChatView and
// SidebarView both see the same live engine and can react when it changes.
//
// Why a holder instead of a plain @State in ChatView: the summarizer
// closure captured by ConversationStore needs to always return the
// CURRENT engine, even after the user switches. Capturing the holder
// gives us that — the closure reads `holder.engine` every time it fires.
//
// Switching engines drops the old instance. For Qwen that means the
// ~2.7GB of in-memory weights is released; switching back later triggers
// a re-load (fast on second run because HubApi caches on disk).

import Foundation
import SwiftUI

@MainActor
final class EngineHolder: ObservableObject {

    @Published private(set) var preference: EnginePreference
    @Published private(set) var engine: (any ListeningEngine)?

    init() {
        let pref = EnginePreferenceStore.current
        self.preference = pref
        self.engine = Self.makeEngine(for: pref)
    }

    /// Switch to a different engine. No-op if already on that preference.
    /// Persists to UserDefaults, rebuilds the engine instance, and notifies
    /// observers.
    func setPreference(_ newValue: EnginePreference) {
        guard newValue != preference else { return }
        EnginePreferenceStore.current = newValue
        preference = newValue
        engine = Self.makeEngine(for: newValue)
    }

    private static func makeEngine(for pref: EnginePreference) -> (any ListeningEngine)? {
        switch pref {
        case .apple: return try? FoundationModelsClient()
        case .qwen:  return try? QwenClient()
        }
    }
}
