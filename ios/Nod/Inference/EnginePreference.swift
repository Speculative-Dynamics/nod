// EnginePreference.swift
// User's choice of inference engine. Persisted in UserDefaults so it
// survives app restarts.
//
// Default is Apple FoundationModels (.apple) — zero download, works on
// any Apple-Intelligence-capable device. MLX models are opt-in because
// each one costs a 2.3-3.0 GB download and won't fit on older iPhones.
//
// Sidebar ordering: Apple first (always-special), then MLX in
// release-date DESC order — newest on-device model up top to invite
// exploration. Matches the allCases iteration used by SidebarView.

import Foundation

enum EnginePreference: String, CaseIterable, Sendable {
    case apple      // Apple FoundationModels (AFM). Zero download, gated by Apple Intelligence.
    case gemma4     // Gemma 4 E2B Text (Apr 2026) via MLX. ~2.6 GB download.
    case qwen35     // Qwen 3.5 4B (Mar 2026) via MLX. ~3.0 GB download.

    // Raw value `"qwen"` preserves backwards compatibility with the old
    // two-engine world. Users who selected Qwen before this refactor
    // still land on Qwen 3 Instruct 2507 after upgrade, no migration
    // code needed — their UserDefaults value already matches.
    case qwen3 = "qwen"

    /// Human-readable label for the sidebar row.
    var displayName: String {
        switch self {
        case .apple:   return "Apple Intelligence"
        case .qwen3:   return "Qwen 3 Instruct 2507"
        case .qwen35:  return "Qwen 3.5 4B"
        case .gemma4:  return "Gemma 4 E2B Text"
        }
    }

    /// One-line description. For AFM this is the metadata line (there's
    /// no release month / size to show). For MLX engines, the sidebar
    /// composes date + size instead; tagline is unused there.
    var tagline: String {
        switch self {
        case .apple:   return "Built-in · fast · works offline"
        case .qwen3:   return "Text-only · tuned for chat"
        case .qwen35:  return "Multimodal arch · text-only use"
        case .gemma4:  return "Text-only · fresh training data"
        }
    }

    /// The MLX model spec backing this preference. `nil` for `.apple`
    /// (which uses FoundationModelsClient, not MLXEngineClient).
    var mlxSpec: MLXModelSpec? {
        switch self {
        case .apple:   return nil
        case .qwen3:   return .qwen3_instruct_2507
        case .qwen35:  return .qwen35_4b
        case .gemma4:  return .gemma4_e2b_text
        }
    }

    /// Whether this engine can run on the current device. AFM is assumed
    /// available (the runtime check lives in FoundationModelsClient and
    /// surfaces as a modelNotReady error if Apple Intelligence is off).
    /// MLX 4B-class models need ~6 GB resident — we gate on total
    /// physical memory.
    var isAvailable: Bool {
        switch self {
        case .apple:
            return true
        case .qwen3, .qwen35, .gemma4:
            return DeviceCapability.canRunMLX4BClass
        }
    }

    /// One-line reason shown when the engine row is disabled. nil if available.
    var unavailabilityReason: String? {
        guard !isAvailable else { return nil }
        switch self {
        case .apple:
            return nil
        case .qwen3, .qwen35, .gemma4:
            return "Needs iPhone 15 Pro or newer"
        }
    }
}

/// Runtime device checks for engine availability.
enum DeviceCapability {

    /// Minimum physical RAM to run a 4B-class MLX model (4-bit)
    /// comfortably. 5.5 GB covers iPhone 14/15 base (6 GB), iPhone 15
    /// Pro+ (8 GB), and excludes iPhone 13 / 12 / 11 (4 GB). Threshold
    /// set slightly under the advertised spec to absorb reporting
    /// variance.
    private static let mlx4BMemoryBytes: UInt64 = 5_500_000_000

    /// All current MLX specs (Qwen 3, Qwen 3.5, Gemma 4 E2B) fall under
    /// the same memory envelope — they're all quantized to 4-bit and
    /// all target iPhone 15 Pro as the baseline.
    static var canRunMLX4BClass: Bool {
        ProcessInfo.processInfo.physicalMemory >= mlx4BMemoryBytes
    }
}

/// Tiny read/write shim over UserDefaults. Keeping this out of ChatView
/// means the sidebar can bind directly to the same source.
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
