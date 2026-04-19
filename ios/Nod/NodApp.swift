// NodApp.swift
// Entry point. Sets the app-wide accent color and forces dark appearance.
//
// Nod — for when you just need to be heard.
// Open source, fully on-device, native iOS.

import SwiftUI

@main
struct NodApp: App {

    // Resets to true on every cold launch (the @State default). Warm launches
    // (resume from background) skip the splash because the process — and thus
    // this State — is preserved. Standard iOS splash behavior.
    @State private var isLaunching = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                // ChatView mounts behind the splash so it's ready to reveal
                // the moment the splash animation completes. Fast perceived
                // launch — the main app is already "there," just hidden.
                ChatView()

                if isLaunching {
                    SplashView(onComplete: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            isLaunching = false
                        }
                    })
                    .transition(.opacity)
                }
            }
            // Dark mode is the brand default. Users can override in Settings
            // if they want light mode; the app still works because all colors
            // are semantic (systemBackground, .primary, etc.) except the
            // accent which is defined in Assets.xcassets with both variants.
            .preferredColorScheme(.dark)
            // The accent color ("NodAccent") is defined in Assets.xcassets
            // with dark variant #E07C40 and light variant #DD6D2C.
            .tint(Color("NodAccent"))
        }
    }
}
