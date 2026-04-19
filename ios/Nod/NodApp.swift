// NodApp.swift
// Entry point. Sets the app-wide accent color and forces dark appearance.
//
// Nod — for when you just need to be heard.
// Open source, fully on-device, native iOS.

import SwiftUI

@main
struct NodApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
                // Dark mode is the brand default. Users can override in Settings
                // if they want light mode; the app still works because all colors
                // are semantic (systemBackground, .primary, etc.) except the
                // accent which is defined in Assets.xcassets with both variants.
                .preferredColorScheme(.dark)
                // The accent color ("NodAccent") is defined in Assets.xcassets
                // with dark variant #E89260 and light variant #F27A3B.
                .tint(Color("NodAccent"))
        }
    }
}
