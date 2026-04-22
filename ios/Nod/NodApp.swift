// NodApp.swift
// Entry point. Sets the app-wide accent color and forces dark appearance.
//
// Nod — for when you just need to be heard.
// Open source, fully on-device, native iOS.

import MLX
import SwiftUI
import UIKit

@main
struct NodApp: App {

    // SwiftUI's bridge to UIApplicationDelegate. We use this ONLY so iOS
    // can hand us the background URLSession completion handler via the
    // AppDelegate's application(_:handleEvents...:). Everything else stays
    // in the SwiftUI lifecycle.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Boot-crash breaker FIRST — before any heavy allocation. If the
        // previous launch didn't complete (killed by jetsam loading a
        // 2-3 GB MLX model, say), this forces EnginePreferenceStore back
        // to .apple for this run so we break the loop. Safe no-op on a
        // normal launch. Runs synchronously; the work is one UserDefaults
        // read + one UserDefaults write.
        LaunchCrashBreaker.shared.markLaunchStarted()

        // MLX's GPU buffer cache is the silent memory hog on iOS. By default
        // it's allowed to grow to ~1 GB alongside model weights, which on a
        // 3 GB-budget iPhone 15 Pro leaves no room for a KV cache to grow.
        // The standard guidance (from Awni Hannun's mlx-swift-on-iPhone
        // walkthrough) is to cap it aggressively — 20 MB is plenty for a
        // chat workload. Pair this with the memory-limit entitlement so the
        // OS doesn't jetsam us mid-inference.
        Memory.cacheLimit = 20 * 1024 * 1024
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
            // iOS issues a memory warning when we're close to the jetsam
            // ceiling. On an MLX engine, that's our "about to die" signal
            // — flip to Apple Intelligence NOW so the MLXEngineClient
            // releases its 2.6 GB ModelContainer before the OS kills us.
            // Observed app-wide so any view path is covered.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )
            ) { _ in
                LaunchCrashBreaker.shared.handleMemoryWarning()
            }
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
