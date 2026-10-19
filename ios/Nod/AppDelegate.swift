// AppDelegate.swift
// Minimal UIApplicationDelegate adapter. SwiftUI apps don't have an
// AppDelegate by default; we add one ONLY for the one hook we need:
// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
//
// Without this, our background URLSession cannot deliver completion
// events when the app is relaunched from a terminated state specifically
// to process download finish events. iOS expects us to:
//
//   1. Accept the completion handler iOS hands us.
//   2. Re-instantiate our URLSession using the same identifier, which
//      triggers iOS to replay in-flight delegate callbacks.
//   3. Call the completion handler after
//      `urlSessionDidFinishEvents(forBackgroundURLSession:)` fires.
//
// If we forget step 3, iOS marks the session "misbehaving" and future
// background work on the same identifier gets deprioritised. So it's
// not cosmetic — it's part of the contract.

import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {

    // Cmd+Return sends from a hardware keyboard. Registered here, at the
    // end of the responder chain, with priority over system behavior: a
    // focused text view swallows the press before a SwiftUI
    // keyboardShortcut sees it. ChatView listens for the notification.
    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(sendShortcut))
        send.wantsPriorityOverSystemBehavior = true
        send.discoverabilityTitle = "Send"
        return [send]
    }

    @objc private func sendShortcut() {
        NotificationCenter.default.post(name: .nodSendShortcut, object: nil)
    }


    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Route to the matching session. We only own one, but the guard is
        // cheap insurance against a future second session colliding with
        // someone else's handler.
        guard identifier == DownloadTuning.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        // Hand the completion handler off. The session stashes it and
        // invokes it after its own urlSessionDidFinishEvents fires.
        MLXR2BackgroundSession.shared.handleBackgroundEvents(
            completionHandler: completionHandler
        )
    }
}

extension Notification.Name {
    /// Cmd+Return pressed (see AppDelegate.keyCommands).
    static let nodSendShortcut = Notification.Name("nodSendShortcut")
}
