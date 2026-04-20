// SidebarView.swift
// The sidebar sheet triggered by tapping the Nod face in the nav bar.
//
// Per the "one continuous conversation" principle, there is no session
// list or history browser here. The sidebar is a lightweight menu for the
// few things you actually might want to do with your ongoing relationship
// with Nod: see a small stat, start over if you want, check the version.
//
// More settings can be added as rows in their own sections without
// restructuring anything.

import SwiftUI

struct SidebarView: View {

    @ObservedObject var store: ConversationStore
    @ObservedObject var engineHolder: EngineHolder
    @EnvironmentObject private var appLock: AppLockManager
    @Environment(\.dismiss) private var dismiss

    /// Called after the user confirms "Start fresh." ChatView uses this to
    /// reset any local inference state (e.g. the isInferring thinking
    /// indicator) that isn't owned by the store itself.
    let onCleared: () -> Void

    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Messages")
                        Spacer()
                        Text("\(store.messages.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    // "Day N" stat — shows how long the relationship has
                    // been going. Computed from the first message's
                    // createdAt. Hidden until there's at least one message
                    // so first-launch empty state doesn't show "Day 1."
                    if let dayCount = relationshipDayCount {
                        HStack {
                            Text("Relationship")
                            Spacer()
                            Text(dayCount == 1 ? "Day 1" : "Day \(dayCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Your conversation")
                }

                Section {
                    ForEach(EnginePreference.allCases, id: \.self) { pref in
                        engineRow(pref)
                    }
                } header: {
                    Text("Listening model")
                } footer: {
                    Text("Nod runs the AI on your device — nothing is sent to a server. Switching keeps your conversation intact.")
                }

                // Downloads section: only relevant for Qwen (AFM doesn't
                // download), but we show it always because the alternative
                // (conditional reveal) makes the setting feel hidden.
                Section {
                    Toggle(isOn: Binding(
                        get: { engineHolder.cellularAllowed },
                        set: { engineHolder.cellularAllowed = $0 }
                    )) {
                        Label("Download over cellular", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tint(Color("NodAccent"))
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Nod needs Wi-Fi to download the ~2.3 GB Qwen model. Turn this on to allow cellular data.")
                }

                Section {
                    Toggle(isOn: $appLock.isEnabled) {
                        Label("Require Face ID", systemImage: "faceid")
                    }
                    .tint(Color("NodAccent"))
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Ask for Face ID when opening Nod. Your conversation never leaves this device either way.")
                }

                Section {
                    // No `role: .destructive` — the red tint didn't match
                    // the app's muted palette. `.buttonStyle(.plain)` stops
                    // SwiftUI from tinting the whole Label in the accent
                    // color (which was what made the text orange); plain
                    // preserves Label's default "icon=tint, text=primary",
                    // giving us the orange counterclockwise icon next to
                    // white text — matching the rest of the sidebar.
                    // Same pattern as engineRow() above.
                    Button {
                        showingClearConfirmation = true
                    } label: {
                        Label("Start fresh", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Clears every message and Nod's memory of your conversation. This can't be undone.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Nod")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Start fresh?", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear Conversation", role: .destructive) {
                    Task {
                        await store.clear()
                        onCleared()
                        dismiss()
                    }
                }
            } message: {
                Text("This clears every message and Nod's memory of your conversation. It can't be undone.")
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return version
    }

    /// Days between today and the first ever message. 1-indexed (the day
    /// the first message was sent is "Day 1"). nil when the conversation
    /// is empty.
    private var relationshipDayCount: Int? {
        guard let first = store.messages.first else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: first.createdAt)
        let today = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: start, to: today).day ?? 0
        return days + 1
    }

    // MARK: - Engine row

    /// One row for an engine option. Unavailable engines (e.g. Qwen on a
    /// 4GB-RAM iPhone) render dimmed and don't respond to taps, with a
    /// reason line in place of the tagline.
    @ViewBuilder
    private func engineRow(_ pref: EnginePreference) -> some View {
        let available = pref.isAvailable

        Button {
            guard available else { return }
            engineHolder.setPreference(pref)
            // Rigid tap: the engine-switch decision is consequential
            // (different model, different personality). A firm click
            // confirms "I heard you, we're switching" more clearly than
            // the soft receive-tap used elsewhere.
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pref.displayName)
                        .foregroundStyle(available ? .primary : .secondary)
                    Text(pref.unavailabilityReason ?? pref.tagline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if engineHolder.preference == pref {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color("NodAccent"))
                        .font(.body.bold())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
    }
}

#Preview {
    let db = try! MessageDatabase()
    let holder = EngineHolder()
    let store = ConversationStore(database: db, summarizer: { [holder] in holder.engine })
    return SidebarView(store: store, engineHolder: holder, onCleared: {})
        .environmentObject(AppLockManager())
        .preferredColorScheme(.dark)
}
