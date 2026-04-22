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
import FoundationModels

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
    ///
    /// AFM tagline says "no download" rather than "works offline." The
    /// old "fast · works offline" phrasing was misleading — ALL Nod
    /// engines work offline once loaded; MLX models just download once
    /// first. The only trait genuinely distinctive about AFM is that it
    /// ships with iOS and needs no download. That's what the tagline
    /// says now.
    var tagline: String {
        switch self {
        case .apple:   return "Built-in · no download"
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

    /// Whether this engine can run on the current device.
    ///
    /// AFM: gated on `DeviceCapability.canRunAFM`, which asks iOS at
    /// runtime whether Apple Intelligence is actually available on this
    /// specific device. iPhone 15 base (A16, 6 GB RAM) has enough memory
    /// for MLX but does NOT support AFM — the old hard-coded `true` lied
    /// about this, causing users to hit a send-time error every first
    /// message. Now the sidebar row renders dimmed with an honest reason.
    ///
    /// MLX 4B-class models need ~6 GB resident — we gate on total
    /// physical memory.
    var isAvailable: Bool {
        switch self {
        case .apple:
            return DeviceCapability.canRunAFM
        case .qwen3, .qwen35, .gemma4:
            return DeviceCapability.canRunMLX4BClass
        }
    }

    /// One-line reason shown when the engine row is disabled. nil if available.
    ///
    /// For AFM, the reason is branched on the actual availability reason
    /// iOS reports: "not supported on this device" vs "turned off in
    /// Settings." Users in the second group can fix it; users in the
    /// first can't, and should be told so directly instead of being
    /// pointed at a Settings pane that doesn't exist on their iPhone.
    var unavailabilityReason: String? {
        guard !isAvailable else { return nil }
        switch self {
        case .apple:
            switch DeviceCapability.afmStatus {
            case .available:           return nil  // (unreachable — we're !isAvailable)
            case .disabledInSettings:  return "Turn on in Settings → Apple Intelligence"
            case .notSupported:        return "Not supported on this iPhone"
            }
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

    /// Tri-state for Apple FoundationModels availability on this
    /// device. Distinguishing "hardware doesn't support AFM" from "user
    /// disabled AFM in Settings" matters because the onboarding flow
    /// and error messages differ: the first group has to pick an MLX
    /// model (no Settings path exists for them); the second can flip a
    /// toggle in Settings and come right back.
    ///
    /// - `available`: AFM is ready to generate.
    /// - `disabledInSettings`: device supports AFM but the user hasn't
    ///   turned on Apple Intelligence. Also covers the transient
    ///   "model still downloading" case on first enable (iOS reports
    ///   `modelNotReady` for a few minutes after the toggle flips).
    /// - `notSupported`: hardware can't run AFM (A16 and older, iPhone
    ///   15 base, any iPad without M-series silicon).
    enum AFMStatus: Equatable {
        case available
        case disabledInSettings
        case notSupported
    }

    /// Ask iOS at runtime whether Apple Intelligence is usable. Maps
    /// `SystemLanguageModel.default.availability` into our three-branch
    /// enum. Called from the UI on every body eval (sync, sub-ms), and
    /// at send-time in `respond()` for the error-copy conditional.
    ///
    /// Uses switch-case unwrap for the `.unavailable(reason)` case
    /// because `SystemLanguageModel.UnavailabilityReason` is an enum
    /// with associated values in later iOS betas — pattern matching is
    /// more future-proof than `==` equality.
    static var afmStatus: AFMStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .notSupported
            case .appleIntelligenceNotEnabled:
                return .disabledInSettings
            case .modelNotReady:
                // Transient: iOS reports this while the device is
                // finishing the initial AFM model download after the
                // user just flipped the Settings toggle. From the
                // user's perspective they enabled it, so surface this
                // as "disabled" so the onboarding guidance still
                // matches their mental model.
                return .disabledInSettings
            @unknown default:
                // New availability reason we haven't mapped. Treat as
                // unsupported (more conservative than "probably just
                // disabled") so the user doesn't get pointed at a
                // Settings path that might not apply.
                return .notSupported
            }
        }
    }

    /// Shorthand boolean for callers that only care "can we use AFM
    /// right now?" — row availability, send-button gating, etc.
    static var canRunAFM: Bool {
        afmStatus == .available
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
