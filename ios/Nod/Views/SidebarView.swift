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
import UIKit

struct SidebarView: View {

    @ObservedObject var store: ConversationStore
    @ObservedObject var engineHolder: EngineHolder
    @EnvironmentObject private var appLock: AppLockManager
    @ObservedObject private var personalization = PersonalizationStore.shared
    /// Observed separately from `store` so the Memory row's count badge
    /// updates reactively when entities are added / deleted. Same
    /// instance as `store.entityStore` — SwiftUI's @ObservedObject needs
    /// the direct reference to track changes.
    @ObservedObject var entityStore: EntityStore
    @Environment(\.dismiss) private var dismiss
    /// Color scheme of the host view (ChatView) at the moment this
    /// sheet renders. Passed as a prop (not read from @Environment
    /// in-sheet) because `preferredColorScheme(nil)` at the app root
    /// doesn't propagate reliably into an already-presented sheet.
    /// ChatView's @Environment tracks the app's current scheme
    /// correctly; we forward the value.
    let hostColorScheme: ColorScheme

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

                // Memory section. Own section because "what Nod remembers"
                // is a top-level product concept, not a sub-feature of
                // the conversation. Placed between "Your conversation"
                // (what's in here) and "Personalisation" (how Nod speaks
                // to you) so the flow reads: content → memory → voice.
                Section {
                    NavigationLink {
                        MemoryView(entityStore: entityStore)
                    } label: {
                        HStack {
                            Text("What Nod knows about you")
                            Spacer()
                            Text("\(entityStore.entities.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel(
                        "What Nod knows about you. \(entityStore.entities.count) \(entityStore.entities.count == 1 ? "item" : "items")"
                    )
                } header: {
                    Text("Memory")
                }

                // Personalisation section. Right after Memory because
                // both are about customising Nod for this specific user.
                // Memory is the passive side (what Nod picks up),
                // Personalisation is the active side (what the user tells
                // Nod to do).
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
                        "How Nod responds",
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
                        HStack(alignment: .firstTextBaseline) {
                            Text("Anything else")
                                .font(.subheadline.weight(.medium))

                            Spacer()

                            if !personalization.current.freeFormText.isEmpty {
                                Button("Clear") {
                                    personalization.current.freeFormText = ""
                                }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .buttonStyle(.plain)
                            }
                        }

                        TextField(
                            "Anything else you want Nod to keep in mind",
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

                        Text("A few sentences is enough.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

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

                // Theme picker. Menu style instead of segmented because
                // segmented caused visible three-band render artifacts
                // during theme transitions (nav bar, content, and
                // bottom safe-area glass materials arrived at
                // different times). Menu style opens a tap-to-reveal
                // dropdown, which momentarily dismisses before the
                // theme flip lands — natural decoupling from the
                // sheet's own render pass. Matches the pattern iOS
                // Settings uses for secondary-frequency choices.
                Section {
                    Picker(
                        "Theme",
                        selection: Binding(
                            get: { personalization.current.appearance },
                            set: { newValue in
                                personalization.current.appearance = newValue
                            }
                        )
                    ) {
                        ForEach(AppearancePreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your iOS setting. Light and Dark override it.")
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
                    Toggle(isOn: Binding(
                        get: { store.isConversationBackupEnabled },
                        set: { store.setConversationBackupEnabled($0) }
                    )) {
                        Label("Back up conversation and memory", systemImage: "icloud")
                    }
                    .tint(Color("NodAccent"))

                    Toggle(isOn: $appLock.isEnabled) {
                        Label("Require Face ID", systemImage: "faceid")
                    }
                    .tint(Color("NodAccent"))
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Nothing is sent to Nod's servers. When this is on, your messages, the running summary, and everything Nod knows about you are included in your own iCloud backup. Off by default.")
                }

                Section {
                    // Plain button keeps the row styling aligned with the
                    // rest of the sidebar while the alert carries the
                    // destructive emphasis.
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
                    if let url = feedbackURL {
                        Link(destination: url) {
                            Label("Send feedback", systemImage: "envelope")
                        }
                        // Link defaults to the accent tint. Override to
                        // primary text color so this row matches "Start
                        // fresh" and other action rows — the orange icon
                        // alone is enough visual signal.
                        .foregroundStyle(.primary)
                    } else {
                        // URLComponents couldn't assemble a valid mailto
                        // (extremely unlikely — shouldn't happen in practice).
                        // Show the row disabled rather than hiding it silently.
                        Label("Send feedback", systemImage: "envelope")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Opens Mail with a prefilled message to hello@usenod.app.")
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
                } footer: {
                    // Product stance, surfaced so the "why doesn't
                    // it talk back?" question has an answer users
                    // can find without asking. Nod listens (voice
                    // in) but writes replies (text out) on purpose —
                    // see design notes in the voice feature plan.
                    Text("Nod listens but never speaks — replies arrive as writing, on purpose.")
                }
            }
            // The Personalisation free-form TextField brings up the
            // keyboard. Interactive-dismiss lets the user swipe down on
            // the List to dismiss it without navigating away. Matches
            // the chat input's dismissal pattern in ChatView.
            .scrollDismissesKeyboard(.interactively)
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
            // Delete Model alert. Match the same cancel/destructive pattern
            // as "Start fresh" so destructive confirmations read the same
            // throughout the app. Attached here (not inside engineRow)
            // because SwiftUI's .alert is one-per-view.
            .alert(
                deleteTarget.map { "Delete \($0.displayName)?" } ?? "",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { }
                Button("Delete Model", role: .destructive) {
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
        // Apply the user's appearance preference to the sidebar sheet
        // itself. Without this, `.preferredColorScheme` applied at the
        // NodApp root doesn't reach into the sheet's separate
        // presentation context — the main chat flips but the settings
        // stays stuck in whatever the OS last gave it. SidebarView
        // already observes PersonalizationStore so this reacts live to
        // the picker. Placed at the outermost view level so every nested
        // alert / toolbar / keyboard inherits it.
        // Apply an explicit color scheme to the sheet. For `.light` /
        // `.dark` this is the user's pick. For `.system`, it's the
        // host's current scheme (iOS system scheme, propagated
        // through NodApp). Always explicit — never nil — because a
        // nil preferredColorScheme on a sheet doesn't re-inherit
        // from the parent when it transitions mid-flight.
        .preferredColorScheme(
            personalization.current.appearance.preferredColorScheme(
                systemFallback: hostColorScheme
            )
        )
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return version
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    private var deviceModel: String {
        // `UIDevice.model` is "iPhone" / "iPad" — uninteresting. The
        // hardware identifier (e.g. "iPhone15,3") requires sysctl, which
        // is heavier than the feedback channel needs. Ship with model
        // name + iOS version; a user on an old device can write the
        // specific model if it matters to the bug.
        UIDevice.current.model
    }

    private var iOSVersion: String {
        UIDevice.current.systemVersion
    }

    /// mailto: URL to hello@usenod.app with subject carrying version +
    /// build and a short triage template in the body. URLComponents
    /// percent-encodes both subject and body so newlines and
    /// parentheses survive the roundtrip.
    ///
    /// nil only if URL assembly fails (shouldn't happen given the
    /// inputs). The Link row shows a disabled fallback in that case.
    private var feedbackURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "hello@usenod.app"
        let subject = "Nod feedback (v\(appVersion) build \(buildNumber))"
        let body = """
            What happened:


            What I expected:


            —
            iOS \(iOSVersion) · \(deviceModel)
            """
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        // URLComponents uses +-encoding for spaces in query values by
        // default. Mail clients typically accept either, but %20 is
        // safer across the board — fix up before handing to the URL.
        let query = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%20")
        components.percentEncodedQuery = query
        return components.url
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
    ///   Line 2:  <metadata-line>                    trash  (if eligible)
    ///
    /// Metadata line varies by engine kind:
    ///   - AFM:  the static tagline ("Built-in · fast · works offline")
    ///   - MLX:  "<Month YYYY> · <size>" with optional " · download on
    ///           use" or " · paused" suffix
    ///
    /// Delete shows only for NON-ACTIVE MLX engines with at least partial
    /// files on disk — there's nothing to delete otherwise. Tapping the
    /// trash affordance opens the confirmation alert at the view level.
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
            // Outer HStack so the trailing icon (✓ or 🗑) is vertically
            // centered against the whole two-line row. Earlier layout put
            // ✓ on line 1 and 🗑 on line 2 — the icons landed at different
            // vertical positions across rows and looked off-center. Both
            // now share the same trailing column, centered in the row,
            // with a consistent 28pt frame for identical tap targets.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pref.displayName)
                        .foregroundStyle(available ? .primary : .secondary)
                    Text(metadataLine(for: pref))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                // Active row → checkmark. Inactive + downloaded → trash.
                // Mutually exclusive (canDelete guards on !isActive), so
                // at most one icon ever shows per row.
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color("NodAccent"))
                        .frame(width: 28, height: 28)
                } else if canDelete {
                    // Not a nested Button: List rows with multiple buttons
                    // have a habit of stealing selection taps. Dedicated
                    // icon target via onTapGesture keeps the row tap
                    // behaviour intact.
                    Image(systemName: "trash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Delete downloaded model")
                        .onTapGesture {
                            deleteTarget = pref
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
    let entities = EntityStore(database: db)
    let store = ConversationStore(
        database: db,
        entityStore: entities,
        summarizer: { [holder] in holder.engine },
        entityFallbackProvider: { [holder] in holder.engine }
    )
    SidebarView(store: store, engineHolder: holder, entityStore: entities, hostColorScheme: .dark, onCleared: {})
        .environmentObject(AppLockManager())
        .preferredColorScheme(.dark)
}
