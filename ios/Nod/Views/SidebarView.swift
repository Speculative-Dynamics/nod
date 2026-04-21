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
    @ObservedObject private var personalization = PersonalizationStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Called after the user confirms "Start fresh." ChatView uses this to
    /// reset any local inference state (e.g. the isInferring thinking
    /// indicator) that isn't owned by the store itself.
    let onCleared: () -> Void

    @State private var showingClearConfirmation = false
    /// Drives the Delete Model confirmation alert. Nil when hidden; set
    /// to the preference whose row was tapped. Using an optional (rather
    /// than a separate bool + state) keeps the "which model?" context
    /// attached to the alert's lifetime, preventing a race where the
    /// user double-taps different rows before the alert opens.
    @State private var deleteTarget: EnginePreference?

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

                // Personalisation section. Right after "Your
                // conversation" because it's about the USER and how
                // they want to be heard — thematically part of that
                // group, not a model-level setting.
                Section {
                    Picker(
                        "Response style",
                        selection: Binding(
                            get: { personalization.current.responseStyle },
                            set: { personalization.current.responseStyle = $0 }
                        )
                    ) {
                        ForEach(ResponseStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }

                    Picker(
                        "When Nod responds",
                        selection: Binding(
                            get: { personalization.current.nodMode },
                            set: { personalization.current.nodMode = $0 }
                        )
                    ) {
                        ForEach(NodMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    // Free-form preferences. TextField with axis: .vertical
                    // + lineLimit(1...4) keeps the field compact when
                    // empty, expands as the user types — matches the
                    // chat input's behavior for consistency. Hard-cap at
                    // 500 chars via onChange (quality over quantity for
                    // the system-prompt budget).
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(
                            "Like a friend checking in, not a therapist",
                            text: Binding(
                                get: { personalization.current.freeFormText },
                                set: { new in
                                    let capped = String(new.prefix(Personalization.maxFreeFormChars))
                                    if capped != personalization.current.freeFormText {
                                        personalization.current.freeFormText = capped
                                    }
                                }
                            ),
                            axis: .vertical
                        )
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityLabel("Anything else for Nod")

                        // Character counter — only appears past 400 so
                        // the empty / normal-length case stays clean.
                        if personalization.current.freeFormText.count > 400 {
                            Text("\(personalization.current.freeFormText.count) / \(Personalization.maxFreeFormChars)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Personalisation")
                } footer: {
                    Text("Nod reads this each time you send a message. Changes take effect on the next reply.")
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

                // Downloads section: only relevant for MLX engines (AFM
                // doesn't download). Shown always — conditional reveal
                // makes the setting feel hidden.
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
                    Text("Nod needs Wi-Fi to download an on-device model (2-3 GB). Turn this on to allow cellular data.")
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
            // Delete Model alert. Same warm "Keep it" / neutral "Delete"
            // pattern as the download-pause alert in ChatView — the
            // consequence (re-download) is real but recoverable, so
            // destructive-red would miscommunicate. Attached here (not
            // inside engineRow) because SwiftUI's .alert is one-per-view.
            .alert(
                deleteTarget.map { "Delete \($0.displayName)?" } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                )
            ) {
                Button("Keep it", role: .cancel) { }
                Button("Delete") {
                    if let pref = deleteTarget {
                        engineHolder.deleteDownloadedModel(for: pref)
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                    deleteTarget = nil
                }
            } message: {
                if let pref = deleteTarget, let spec = pref.mlxSpec {
                    Text("You'll need to download it again (\(formatCoarseSize(spec.totalBytes))) to use it.")
                }
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

    /// One row for an engine option.
    ///
    /// Layout per design review (`plan-design-review`, April 2026):
    ///
    ///   Line 1:  <displayName>                         ✓  (if active)
    ///   Line 2:  <metadata-line>                   Delete  (if eligible)
    ///
    /// Metadata line varies by engine kind:
    ///   - AFM:  the static tagline ("Built-in · fast · works offline")
    ///   - MLX:  "<Month YYYY> · <size>" with optional " · download on
    ///           use" or " · paused" suffix
    ///
    /// Delete shows only for NON-ACTIVE MLX engines with at least partial
    /// files on disk — there's nothing to delete otherwise. Tapping Delete
    /// opens the confirmation alert at the view level.
    ///
    /// Unavailable engines (MLX on an iPhone without enough RAM) render
    /// dimmed with a replacement metadata line ("Needs iPhone 15 Pro or
    /// newer") and don't respond to row taps.
    @ViewBuilder
    private func engineRow(_ pref: EnginePreference) -> some View {
        let available = pref.isAvailable
        let isActive = engineHolder.preference == pref
        let canDelete = engineHolder.canDelete(pref)

        Button {
            guard available else { return }
            engineHolder.setPreference(pref)
            // Rigid tap: the engine-switch decision is consequential
            // (different model, different personality). A firm click
            // confirms "I heard you, we're switching" more clearly than
            // the soft receive-tap used elsewhere.
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // Line 1: name on left, checkmark on right for active
                HStack {
                    Text(pref.displayName)
                        .foregroundStyle(available ? .primary : .secondary)
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color("NodAccent"))
                            .font(.body.bold())
                    }
                }
                // Line 2: metadata on left, Delete on right if eligible
                HStack {
                    Text(metadataLine(for: pref))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if canDelete {
                        // Inline tappable text. Not a nested Button —
                        // nested Buttons in a List row have a documented
                        // history of stealing taps from the outer row.
                        // Using `.onTapGesture` with simultaneousGesture
                        // on just this text keeps the row-tap working
                        // while the Delete label becomes its own target.
                        Text("Delete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                deleteTarget = pref
                            }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.5)
    }

    /// Metadata line text for one engine row.
    /// AFM: the static tagline.
    /// MLX: "Latest · Apr 2026 · 2.6 GB" — role label ("Latest" / "Recent"
    /// / "Proven") prefixed so a normal user can pick between the three
    /// on-device options at a glance without decoding release dates or
    /// model names. Then the status suffix (" · download on use" /
    /// " · paused") is appended based on on-disk state.
    private func metadataLine(for pref: EnginePreference) -> String {
        if let reason = pref.unavailabilityReason {
            return reason
        }
        guard let spec = pref.mlxSpec else {
            // AFM — use the tagline, which doubles as the metadata line.
            return pref.tagline
        }
        let base = "\(spec.roleLabel) · \(spec.releaseMonth) · \(formatCoarseSize(spec.totalBytes))"
        if spec.isFullyDownloaded {
            return base
        }
        if spec.hasPartialDownload {
            return "\(base) · paused"
        }
        return "\(base) · download on use"
    }

    /// "2.3 GB" formatting — reused from the download card so the number
    /// rolls the same way in both places. Snaps to 0.1 GB above 1 GB,
    /// nearest 10 MB below.
    private func formatCoarseSize(_ bytes: Int64) -> String {
        let oneGB: Int64 = 1_000_000_000
        if bytes >= oneGB {
            let gb = Double(bytes) / Double(oneGB)
            return String(format: "%.1f GB", gb)
        } else {
            let mb = Int((Double(bytes) / 1_000_000 / 10).rounded()) * 10
            return "\(mb) MB"
        }
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
