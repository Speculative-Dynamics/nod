// MiniNodFace.swift
// A small rounded-square Nod face with auto-blinking eyes. Used as the
// navigation bar's leading brand element (replaces the "Nod" title). In
// the future, tapping it opens a sidebar — stub action for now.

import SwiftUI

struct MiniNodFace: View {
    var size: CGFloat = 32
    var blinkInterval: TimeInterval = 4.5

    @State private var eyesClosed = false
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(Color("NodAccent"))

            HStack(spacing: size * 0.19) {
                Ellipse()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.08))
                    .frame(width: size * 0.13, height: size * 0.22)
                Ellipse()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.08))
                    .frame(width: size * 0.13, height: size * 0.22)
            }
            .scaleEffect(y: eyesClosed ? 0.1 : 1.0, anchor: .center)
            .animation(.easeInOut(duration: 0.18), value: eyesClosed)
        }
        .frame(width: size, height: size)
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
