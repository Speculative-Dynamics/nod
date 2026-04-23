// AppLockOverlay.swift
// The locked screen. A full-bleed dark surface with a large Nod face and
// a single Unlock button. Mounted above ChatView in NodApp; the chat
// stays mounted behind so unlock reveals instantly.
//
// Design choices:
//   - Same visual language as SplashView so the transition from splash →
//     lock → chat feels like one continuous reveal, not a hard cut.
//   - The face DOESN'T blink while locked. Locked Nod is a waiting Nod,
//     not a fidgeting one. Eyes open, steady, until you unlock.
//   - Auto-prompt Face ID on appear. If the user cancels, the Unlock
//     button lets them retry on their own schedule.
//   - No "Forgot passcode" affordance. If Face ID fails the system
//     prompt itself offers passcode. That's Apple's job, not ours.

import SwiftUI

struct AppLockOverlay: View {
    @ObservedObject var lock: AppLockManager

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // Large Nod face, steady — no blinking while locked.
                // NodMascot is the canonical face, same geometry as the
                // app icon (glimmer included).
                NodMascot(size: 96)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Nod is locked.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)

                    Text("Unlock with Face ID to continue your conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Button {
                    Task { await lock.authenticate() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                            .font(.headline)
                        Text("Unlock")
                            .font(.headline)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color("NodAccent"))
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                }
                .accessibilityLabel("Unlock Nod")
                .padding(.top, 8)
                .disabled(lock.isAuthenticating)
            }
        }
        .onAppear {
            // Auto-prompt Face ID on mount. If the user already canceled
            // once and came back, they'll tap Unlock manually.
            Task { await lock.authenticate() }
        }
    }
}

#Preview {
    AppLockOverlay(lock: AppLockManager())
        .preferredColorScheme(.dark)
}
