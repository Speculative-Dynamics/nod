// AppLockOverlay.swift
// The locked screen. Soft's warm background (light or dark), a Nod face
// and a single Unlock button. Mounted above ChatView in NodApp; the chat
// stays mounted behind so unlock reveals instantly.
//
// Design choices:
//   - Same visual language as SplashView so the transition from splash →
//     lock → chat feels like one continuous reveal, not a hard cut.
//   - Face blinks at the idle cadence (same as nav bar, onboarding,
//     empty state). The earlier "steady waiting Nod" stance conflated
//     blinking with fidgeting — a 4.5s-interval blink is the minimum
//     life signal, not restlessness. Keeping the lock face alive keeps
//     it from reading as dead on the occasions the user sits with this
//     screen (Face ID cancel, retry, passcode fallback).
//   - Auto-prompt Face ID on appear. If the user cancels, the Unlock
//     button lets them retry on their own schedule.
//   - No "Forgot passcode" affordance. If Face ID fails the system
//     prompt itself offers passcode. That's Apple's job, not ours.

import SwiftUI

struct AppLockOverlay: View {
    @ObservedObject var lock: AppLockManager

    var body: some View {
        ZStack {
            Soft.background
                .ignoresSafeArea()

            VStack(spacing: 28) {
                // Large Nod face. Blinks at the idle cadence so the
                // character still reads as "present" while you're
                // locked out — see the design note at top of file.
                NodMascotBlinker(size: 80)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Nod is locked.")
                        .font(.title.weight(.bold))
                        .foregroundStyle(Soft.ink)
                        .accessibilityAddTraits(.isHeader)

                    Text("Unlock with Face ID to continue your conversation.")
                        .font(.body)
                        .foregroundStyle(Soft.muted)
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
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Soft.accent, in: Capsule())
                    .foregroundStyle(.black)
                }
                .accessibilityLabel("Unlock Nod")
                .padding(.top, 8)
                .disabled(lock.isAuthenticating)
            }
            .padding(.horizontal, 24)
        }
        .overlay(alignment: .bottom) {
            Label("Everything stays on this iPhone.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(Soft.muted)
                .padding(.bottom, 24)
        }
        .fontDesign(.rounded)
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
