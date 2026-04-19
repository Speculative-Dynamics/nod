// EnginePreference.swift
// User's choice of inference engine. Persisted in UserDefaults so it
// survives app restarts.
//
// Default is Apple FoundationModels (.apple) — it's zero-download and
// works on any Apple-Intelligence-capable device. Qwen is opt-in because
// it costs a 2.3GB model download and won't fit on older iPhones.
//
// Commit A: type exists, ChatView reads it, but there's no UI toggle yet.
// Commit B: sidebar toggle to switch between engines.

import Foundation

enum EnginePreference: String, CaseIterable, Sendable {
    case apple  // Apple FoundationModels (AFM). Zero download, gated by Apple Intelligence.
    case qwen   // Qwen 3 4B via MLX. ~2.3GB download, works independent of Apple Intelligence.

    /// Human-readable label for settings UI.
    var displayName: String {
        switch self {
        case .apple: return "Apple Intelligence"
        case .qwen:  return "Qwen 3 (4B)"
        }
    }

    /// One-line description for settings UI.
    var tagline: String {
        switch self {
        case .apple:
            return "Built-in, no download. Requires Apple Intelligence."
        case .qwen:
            return "Open-source. Downloads ~2.3GB on first use."
        }
    }
}

/// Tiny read/write shim over UserDefaults. Keeping this out of ChatView
/// means the sidebar (Commit B) can bind directly to the same source.
enum EnginePreferenceStore {
    private static let key = "app.usenod.nod.enginePreference"

    static var current: EnginePreference {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let value = EnginePreference(rawValue: raw) else {
                return .apple
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
