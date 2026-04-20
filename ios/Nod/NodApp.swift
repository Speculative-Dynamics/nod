// NodApp.swift
// Entry point. Sets the app-wide accent color and forces dark appearance.
//
// Nod — for when you just need to be heard.
// Open source, fully on-device, native iOS.

import MLX
import SwiftUI

@main
struct NodApp: App {

    init() {
        // MLX's GPU buffer cache is the silent memory hog on iOS. By default
        // it's allowed to grow to ~1 GB alongside model weights, which on a
        // 3 GB-budget iPhone 15 Pro leaves no room for a KV cache to grow.
        // The standard guidance (from Awni Hannun's mlx-swift-on-iPhone
        // walkthrough) is to cap it aggressively — 20 MB is plenty for a
        // chat workload. Pair this with the memory-limit entitlement so the
        // OS doesn't jetsam us mid-inference.
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
    }

    // Resets to true on every cold launch (the @State default). Warm launches
    // (resume from background) skip the splash because the process — and thus
    // this State — is preserved. Standard iOS splash behavior.
    @State private var isLaunching = true

    // Optional Face ID gate. Owned at app level so scenePhase transitions
    // can feed it, and so the sidebar toggle flips state for everyone.
    @StateObject private var appLock = AppLockManager()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                // ChatView mounts behind the splash so it's ready to reveal
                // the moment the splash animation completes. Fast perceived
                // launch — the main app is already "there," just hidden.
                ChatView()
                    .environmentObject(appLock)

                // Lock overlay sits above chat but below splash. When the
                // user enables App Lock, the overlay appears on cold launch
                // and after a long background trip. Chat stays mounted
                // behind so unlocking reveals instantly.
                if appLock.isLocked {
                    AppLockOverlay(lock: appLock)
                        .transition(.opacity)
                        .zIndex(1)
                }

                if isLaunching {
                    SplashView(onComplete: {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            isLaunching = false
                        }
                    })
                    .transition(.opacity)
                    .zIndex(2)
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
            .animation(.easeInOut(duration: 0.25), value: appLock.isLocked)
            // App Lock lifecycle: background → foreground transitions run
            // through the manager so the grace period logic stays in one
            // place. Short trips (app switcher, copy a URL) stay unlocked;
            // anything longer re-locks.
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    appLock.handleBackgrounded()
                case .active:
                    appLock.handleForegrounded()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}
