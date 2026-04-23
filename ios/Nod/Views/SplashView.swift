// SplashView.swift
// Animated launch sequence: full orange → condenses to icon size while
// black background reveals → eyes open → gentle blink → hand off to chat.
//
// Seamless with iOS's own launch screen (Info.plist → UILaunchScreen uses
// the same NodAccent color), so there's no flash when SwiftUI takes over.
//
// Total duration: ~2.0s. Plays on every cold launch. Warm launches skip
// this (the view only mounts when isLaunching resets to true, which only
// happens on app process start).

import SwiftUI

struct SplashView: View {

    let onComplete: () -> Void

    // Animation driver state. Each value drives one phase of the sequence.
    @State private var orangeSize: CGFloat = 1600     // starts oversized (full screen+)
    @State private var eyesScale: CGFloat = 0.01       // eyes invisible at start
    @State private var eyesOpacity: Double = 0
    @State private var eyesClosedForBlink = false

    /// Icon-size at rest. Matches the home-screen app icon's perceived size.
    private let restingSize: CGFloat = 120

    var body: some View {
        ZStack {
            // Background reveals as the orange shrinks below the screen
            // edges. Use semantic `.systemBackground` so it adapts to
            // light/dark theme automatically — black in dark mode
            // matches what ChatView will show, white in light mode
            // matches the same. Without this, the splash was
            // hardcoded black which clashed with the light-themed
            // chat during the handoff. ignoresSafeArea so we cover
            // notch/home-indicator areas.
            Color(.systemBackground)
                .ignoresSafeArea()

            // The orange body. Starts oversized to fill the screen,
            // animates down to restingSize. Uses NodMascotBody so the
            // corner radius and fill color come from the canonical
            // tokens — one edit to the icon, one edit to the tokens,
            // everything follows.
            NodMascotBody(size: orangeSize)

            // Eyes. Scale from near-zero to 1.0 with a bouncy spring.
            // Independent blink state for the in-sequence blink moment.
            // NodMascotEye carries the canonical eye + glimmer so the
            // splash matches the app icon the user just tapped.
            HStack(spacing: restingSize * NodMascotTokens.eyeSpacingRatio) {
                NodMascotEye(faceSize: restingSize)
                NodMascotEye(faceSize: restingSize)
            }
            .scaleEffect(eyesScale)
            .opacity(eyesOpacity)
            .scaleEffect(
                y: eyesClosedForBlink ? NodMascotTokens.blinkClosedScaleY : 1.0,
                anchor: .center
            )
        }
        .onAppear {
            runSequence()
        }
        .accessibilityLabel("Nod is waking up")
    }

    private func runSequence() {
        Task { @MainActor in
            // Phase 1 — full orange hold. Longer than strictly needed so the
            // moment settles before motion starts (anticipation).
            try? await Task.sleep(for: .milliseconds(150))

            // Phase 2 — condense. Longer spring response so the shrink is
            // something the user can visually track, not a snap. Slightly
            // under-damped so it lands with the tiniest bounce at rest size.
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) {
                orangeSize = restingSize
            }
            try? await Task.sleep(for: .milliseconds(700))

            // Phase 2.5 — empty-square hold. A beat of just the orange icon
            // shape without eyes gives the reveal more weight.
            try? await Task.sleep(for: .milliseconds(100))

            // Phase 3 — eyes open. Bouncy spring so it feels alive. Slightly
            // longer response so the open motion reads clearly.
            withAnimation(.spring(response: 0.65, dampingFraction: 0.58)) {
                eyesScale = 1.0
                eyesOpacity = 1.0
            }
            try? await Task.sleep(for: .milliseconds(500))

            // Phase 4 — one gentle blink. "Hello, I see you." Blink is a
            // little slower and more deliberate than the incidental blinks.
            withAnimation(.easeInOut(duration: 0.18)) {
                eyesClosedForBlink = true
            }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeInOut(duration: 0.20)) {
                eyesClosedForBlink = false
            }
            try? await Task.sleep(for: .milliseconds(250))

            // Phase 5 — hand back to the app.
            onComplete()
        }
    }
}

#Preview {
    SplashView(onComplete: {})
}
