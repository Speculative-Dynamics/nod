// NodAnimation.swift
// The eye-blink — Nod's brand gesture.
//
// Two oval eyes (matching the app icon's identity) blink once when the AI
// acknowledges a message. The blink fires at two specific moments:
//   1. Just before the AI responds to a user message
//   2. As the complete response when the user taps "just nod"
//
// Visual: 28pt round container, two oval eyes inside.
// Timing: eye height animates 1.0 → 0.1 → 1.0 over 280ms (easeInOut).
// Reduce Motion: single opacity fade instead of scale.

import SwiftUI

struct NodAnimation: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drive the animation by flipping this Bool. When it changes, the eyes blink.
    let trigger: Int

    @State private var eyeScaleY: CGFloat = 1.0
    @State private var opacity: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            eye
            eye
        }
        .frame(width: 28, height: 28)
        .onChange(of: trigger) { _, _ in
            blink()
        }
    }

    private var eye: some View {
        Ellipse()
            .fill(Color.primary)
            .frame(width: 8, height: 12)
            .scaleEffect(y: reduceMotion ? 1.0 : eyeScaleY, anchor: .center)
            .opacity(opacity)
    }

    private func blink() {
        if reduceMotion {
            // Opacity-only fallback for Reduce Motion users.
            withAnimation(.easeInOut(duration: 0.14)) { opacity = 0.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeInOut(duration: 0.14)) { opacity = 1.0 }
            }
        } else {
            // Eye close
            withAnimation(.easeInOut(duration: 0.14)) { eyeScaleY = 0.1 }
            // Eye open again
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeInOut(duration: 0.14)) { eyeScaleY = 1.0 }
            }
        }
    }
}

#Preview {
    @Previewable @State var trigger = 0
    VStack(spacing: 40) {
        NodAnimation(trigger: trigger)
        Button("Blink") { trigger += 1 }
    }
    .padding()
    .preferredColorScheme(.dark)
}
