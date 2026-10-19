// EnginePreference.swift
// User's choice of inference engine. Persisted in UserDefaults so it
// survives app restarts.
//
// The lineup, chosen from the evals (ios/evals):
//   - Apple Intelligence: the default. Built in, no download.
//   - Qwen 3.5 4B: the best downloadable model, for 8 GB iPhones.
//   - Qwen 3.5 2B: the light one, for 6 GB iPhones.
// Gemma 4 E2B and Qwen 3 4B were retired; users on them are moved to
// the best model their phone fits (see EnginePreferenceStore).

import Foundation
import FoundationModels

enum EnginePreference: String, CaseIterable, Sendable {
    case apple                      // Apple FoundationModels. Gated by Apple Intelligence.
    case qwen35                     // Qwen 3.5 4B via MLX. ~3.0 GB download.
    case qwen35_2b = "qwen3.5-2b"   // Qwen 3.5 2B via MLX. ~1.75 GB download.

    /// Stored values of engines that no longer exist.
    static let retiredRawValues: Set<String> = ["qwen", "gemma4"]

    /// The best downloadable model this phone can run, if any.
    static var bestDownloadable: EnginePreference? {
        [.qwen35, .qwen35_2b].first { $0.mlxSpec?.fitsThisDevice == true }
    }

    /// Human-readable label for the sidebar row.
    var displayName: String {
        switch self {
        case .apple:     return "Apple Intelligence"
        case .qwen35:    return "Qwen 3.5 4B"
        case .qwen35_2b: return "Qwen 3.5 2B"
        }
    }

    /// One-line description. For MLX engines the sidebar composes role,
    /// date and size instead; tagline is used for Apple only.
    var tagline: String {
        switch self {
        case .apple:     return "Built-in · no download"
        case .qwen35:    return "Most capable download"
        case .qwen35_2b: return "Lighter · smaller download"
        }
    }

    /// The MLX model spec backing this preference. `nil` for `.apple`
    /// (which uses FoundationModelsClient, not MLXEngineClient).
    var mlxSpec: MLXModelSpec? {
        switch self {
        case .apple:   return nil
        case .qwen35:  return .qwen35_4b
        case .qwen35_2b: return .qwen35_2b
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
    /// MLX models are gated per model on physical RAM (see
    /// `MLXModelSpec.minimumDeviceMemory`).
    var isAvailable: Bool {
        if let spec = mlxSpec { return spec.fitsThisDevice }
        return DeviceCapability.canRunAFM
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
        default:
            let gb = Int(((mlxSpec?.minimumDeviceMemory ?? 0) + 500_000_000) / 1_000_000_000)
            return "Needs an iPhone with \(gb) GB of memory or more"
        }
    }
}

/// Runtime device checks for engine availability.
enum DeviceCapability {

    /// Whether at least one downloadable model fits this phone.
    static var canRunAnyMLX: Bool {
        EnginePreference.allCases.contains { $0.mlxSpec?.fitsThisDevice == true }
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
            guard let raw = UserDefaults.standard.string(forKey: key) else { return .apple }
            if let value = EnginePreference(rawValue: raw) { return value }
            // Retired engine: move to the best model this phone fits.
            if EnginePreference.retiredRawValues.contains(raw) {
                let replacement = EnginePreference.bestDownloadable ?? .apple
                UserDefaults.standard.set(replacement.rawValue, forKey: key)
                return replacement
            }
            return .apple
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
