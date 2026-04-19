// SplashView.swift
// Animated launch sequence: full orange → condenses to icon size while
// black background reveals → eyes open → gentle blink → hand off to chat.
//
// Seamless with iOS's own launch screen (Info.plist → UILaunchScreen uses
// the same NodAccent color), so there's no flash when SwiftUI takes over.
//
// Total duration: ~2.4s. Plays on every cold launch. Warm launches skip
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
            // Background black reveals as the orange shrinks below the screen
            // edges. ignoresSafeArea so we cover notch/home-indicator areas.
            Color.black
                .ignoresSafeArea()

            // The orange rounded square. Starts oversized to fill the screen,
            // animates down to restingSize. Corner radius scales with size
            // automatically because it's derived inline.
            RoundedRectangle(
                cornerRadius: orangeSize * 0.2237,
                style: .continuous
            )
            .fill(Color("NodAccent"))
            .frame(width: orangeSize, height: orangeSize)

            // Eyes. Scale from near-zero to 1.0 with a bouncy spring.
            // Independent blink state for the in-sequence blink moment.
            HStack(spacing: restingSize * 0.19) {
                eye
                eye
            }
            .scaleEffect(eyesScale)
            .opacity(eyesOpacity)
            .scaleEffect(y: eyesClosedForBlink ? 0.1 : 1.0, anchor: .center)
        }
        .onAppear {
            runSequence()
        }
        .accessibilityLabel("Nod is waking up")
    }

    private var eye: some View {
        Ellipse()
            .fill(Color(red: 0.08, green: 0.08, blue: 0.08))
            .frame(width: restingSize * 0.13, height: restingSize * 0.22)
    }

    private func runSequence() {
        Task { @MainActor in
            // Phase 1 — full orange hold. Gives iOS's native launch screen a
            // moment to hand off cleanly before we start animating.
            try? await Task.sleep(for: .milliseconds(250))

            // Phase 2 — condense. Orange shrinks to icon size over ~650ms
            // with a soft spring. Black background reveals as the square
            // crosses below the screen edges.
            withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) {
                orangeSize = restingSize
            }
            try? await Task.sleep(for: .milliseconds(700))

            // Phase 3 — eyes open. Scale up from near-zero with a bouncy
            // spring so it feels alive, not mechanical.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                eyesScale = 1.0
                eyesOpacity = 1.0
            }
            try? await Task.sleep(for: .milliseconds(550))

            // Phase 4 — one gentle blink. "Hello, I see you."
            withAnimation(.easeInOut(duration: 0.14)) {
                eyesClosedForBlink = true
            }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.easeInOut(duration: 0.14)) {
                eyesClosedForBlink = false
            }
            try? await Task.sleep(for: .milliseconds(500))

            // Phase 5 — hand back to the app.
            onComplete()
        }
    }
}

#Preview {
    SplashView(onComplete: {})
}
