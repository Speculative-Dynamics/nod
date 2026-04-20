// AppLockManager.swift
// Optional Face ID / passcode gate on the one continuous conversation.
//
// Journaling is intimate. The app defaults to OFF so first-run doesn't
// surprise anyone with a biometric prompt, but users who want privacy
// can flip it on in the sidebar. When enabled:
//   - cold launch shows the lock screen and auto-prompts Face ID
//   - backgrounding for more than `relockGrace` seconds re-locks
//   - brief app switcher trips (copy a link, paste back) stay unlocked
//
// Fallback is whatever the user has set up: Face ID falls back to device
// passcode automatically via LAPolicy.deviceOwnerAuthentication. If the
// device has no passcode at all, authentication always succeeds (Apple's
// LocalAuthentication behavior — we don't try to out-think the system).
//
// Persistence: preference lives in UserDefaults. That's the only state
// we own. All lock state (isLocked, lastBackgroundedAt) is in-memory —
// cold launch always starts locked when the preference is ON.

import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockManager: ObservableObject {

    /// User preference. When false the overlay is never shown.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            // Flipping off unlocks immediately — don't leave the user
            // staring at an overlay they just opted out of.
            if !isEnabled {
                isLocked = false
            }
        }
    }

    /// True while the lock overlay should be shown. Initial value depends
    /// on `isEnabled` at init time: locked on cold launch if enabled.
    @Published private(set) var isLocked: Bool

    /// True while a Face ID prompt is in flight. Used to stop the overlay
    /// from stacking two prompts if onAppear fires twice.
    @Published private(set) var isAuthenticating = false

    /// Timestamp of the last background transition, nil if foregrounded.
    private var lastBackgroundedAt: Date?

    /// Grace period on background → foreground. Short trips (app switcher,
    /// pull a link from Safari) stay unlocked; anything longer re-locks.
    private let relockGrace: TimeInterval = 60

    private static let enabledKey = "AppLock.isEnabled"

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.isLocked = enabled
    }

    // MARK: - Lifecycle hooks (called from NodApp scenePhase observer)

    func handleBackgrounded() {
        guard isEnabled else { return }
        lastBackgroundedAt = Date()
    }

    func handleForegrounded() {
        guard isEnabled else { return }
        guard let at = lastBackgroundedAt else { return }
        if Date().timeIntervalSince(at) > relockGrace {
            isLocked = true
        }
        lastBackgroundedAt = nil
    }

    // MARK: - Authentication

    /// Prompt the system biometric / passcode sheet. On success, unlock.
    /// On failure, stay locked — the user can tap the unlock button again.
    /// Safe to call repeatedly; concurrent calls no-op via `isAuthenticating`.
    func authenticate() async {
        guard isEnabled else { isLocked = false; return }
        guard !isAuthenticating else { return }
        guard isLocked else { return }

        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        // deviceOwnerAuthentication = biometrics with passcode fallback.
        // We don't use .deviceOwnerAuthenticationWithBiometrics because
        // that gives no escape hatch if Face ID is enrolled but currently
        // failing (sunglasses, physical injury, etc.).
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        guard canEvaluate else {
            // Device has no passcode set. Per Apple guidance, a device with
            // no passcode offers no meaningful lock; let the user through.
            isLocked = false
            return
        }

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Nod to read your conversation."
            )
            if ok {
                isLocked = false
                // Clear any stale background timestamp so a successful
                // unlock doesn't immediately re-lock on the next foreground.
                lastBackgroundedAt = nil
            }
        } catch {
            // User canceled, or biometrics failed, or passcode was wrong.
            // Leave locked. The overlay's "Unlock" button lets them retry.
        }
    }
}
