// NodAnimation.swift
// The eye-blink — Nod's brand gesture.
//
// Two oval eyes (matching the app icon's identity). Two modes:
//   1. Blink on demand — change `trigger` to make the eyes close and open
//      once. Used when the user sends a message or taps "just nod."
//   2. Thinking loop — set `isThinking: true` to make the eyes slowly scan
//      left, right, back to center, then blink, repeating. Reads as the
//      character actively listening / considering. Stops the moment
//      `isThinking` flips back to false.
//
// Reduce Motion: blink degrades to an opacity fade; thinking mode pauses
// the horizontal scan and only blinks.

import SwiftUI

struct NodAnimation: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drive the one-off blink by incrementing this value.
    let trigger: Int

    /// When true, the eyes animate in a thinking loop (pan + periodic blinks).
    var isThinking: Bool = false

    @State private var eyeScaleY: CGFloat = 1.0
    @State private var opacity: Double = 1.0
    @State private var eyesXOffset: CGFloat = 0
    @State private var thinkingTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            eye
            eye
        }
        .frame(width: 28, height: 28)
        .offset(x: eyesXOffset)
        .onChange(of: trigger) { _, _ in
            blink()
        }
        .onChange(of: isThinking) { _, newValue in
            newValue ? startThinking() : stopThinking()
        }
        .onAppear {
            if isThinking { startThinking() }
        }
        .onDisappear {
            stopThinking()
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
            withAnimation(.easeInOut(duration: 0.14)) { opacity = 0.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeInOut(duration: 0.14)) { opacity = 1.0 }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.14)) { eyeScaleY = 0.1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeInOut(duration: 0.14)) { eyeScaleY = 1.0 }
            }
        }
    }

    private func startThinking() {
        thinkingTask?.cancel()
        thinkingTask = Task { @MainActor in
            while !Task.isCancelled {
                // Look right
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.55)) { eyesXOffset = 3.5 }
                }
                try? await Task.sleep(for: .milliseconds(650))
                if Task.isCancelled { break }

                // Look left
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.55)) { eyesXOffset = -3.5 }
                }
                try? await Task.sleep(for: .milliseconds(650))
                if Task.isCancelled { break }

                // Back to center, brief pause
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.35)) { eyesXOffset = 0 }
                }
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { break }

                // Blink
                blink()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopThinking() {
        thinkingTask?.cancel()
        thinkingTask = nil
        withAnimation(.easeInOut(duration: 0.2)) { eyesXOffset = 0 }
    }
}

#Preview {
    @Previewable @State var trigger = 0
    @Previewable @State var thinking = false
    VStack(spacing: 40) {
        NodAnimation(trigger: trigger, isThinking: thinking)
        HStack(spacing: 16) {
            Button("Blink") { trigger += 1 }
            Toggle("Thinking", isOn: $thinking)
                .frame(maxWidth: 140)
        }
    }
    .padding()
    .preferredColorScheme(.dark)
}
