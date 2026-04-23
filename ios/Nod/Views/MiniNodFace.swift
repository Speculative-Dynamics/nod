// MiniNodFace.swift
// Blinking variant of the canonical NodMascot, used as the navigation
// bar's leading brand element (replaces the "Nod" title). In the
// future, tapping it opens a sidebar — stub action for now.
//
// The face geometry (body, eyes, glimmer, proportions) lives in
// NodMascot. This view just drives the blink state on top.

import SwiftUI

struct MiniNodFace: View {
    var size: CGFloat = 32
    var blinkInterval: TimeInterval = 4.5

    @State private var eyesClosed = false
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        NodMascot(size: size, eyesClosed: eyesClosed)
            .animation(.easeInOut(duration: 0.18), value: eyesClosed)
            .onAppear { startBlinking() }
            .onDisappear { blinkTask?.cancel() }
    }

    private func startBlinking() {
        blinkTask?.cancel()
        blinkTask = Task { @MainActor in
            while !Task.isCancelled {
                // Small random jitter so multiple instances on-screen don't
                // blink in perfect sync (feels more alive).
                let jitter = Double.random(in: -0.6...0.6)
                try? await Task.sleep(for: .seconds(blinkInterval + jitter))
                if Task.isCancelled { break }
                eyesClosed = true
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { break }
                eyesClosed = false
            }
        }
    }
}

#Preview {
    MiniNodFace()
        .padding()
        .preferredColorScheme(.dark)
}
