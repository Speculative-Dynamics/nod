// MemoryView.swift
// The "What Nod knows about you" screen. Reached from the Memory row
// in the sidebar. Read-only list of every entity Nod has stored, grouped
// by type, with per-row swipe-to-delete (Forget).
//
// Design (from /plan-design-review 9/10):
//   - Sections ordered by emotional weight: People first, then
//     Ongoing situations, then Projects, then Places. Hide empty ones.
//   - Row layout is 3 lines: semibold name + role, secondary note,
//     tertiary metadata. Names never truncate; notes cap at 3 lines.
//   - Preamble paragraph ONLY on populated state ("What Nod has picked
//     up..."), empty state has its own copy.
//   - Forget confirmation is honest about the re-remember behavior
//     (see Architecture Issue 1 in eng review): tapping Forget removes
//     the entity from the current list, but if you keep mentioning them
//     Nod will re-identify them, and the older summary isn't scrubbed.
//   - Full Dynamic Type + VoiceOver + Reduce Motion support.

import SwiftUI
import UIKit

struct MemoryView: View {

    @ObservedObject var entityStore: EntityStore
    @State private var pendingDelete: Entity?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Section order chosen in the design review: People first (the
    /// "knows-who-you-are" payload is the whole reason this exists),
    /// then Ongoing situations (the through-line of what's happening
    /// in the user's life), Projects, Places. Empty types are hidden.
    private let sectionOrder: [(type: EntityType, header: String)] = [
        (.person, "People Nod knows about"),
        (.situation, "Ongoing situations"),
        (.project, "Projects"),
        (.place, "Places"),
    ]

    var body: some View {
        contents
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.large)
            // Confirmation alert for Forget. `pendingDelete` is the
            // presentation key; presenting the alert via .alert(item:)
            // guarantees cancel + confirm both clear it.
            .alert(
                pendingDelete.map { "Forget \($0.canonicalName)?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { entity in
                Button("Cancel", role: .cancel) { }
                Button("Forget", role: .destructive) {
                    entityStore.delete(entity)
                    // Confirmation haptic — a release, not an alarm.
                    UINotificationFeedbackGenerator()
                        .notificationOccurred(.success)
                }
            } message: { _ in
                // Honest copy from eng review Issue 1: we can't actually
                // prevent re-extraction of a forgotten name via this
                // action alone. Setting the expectation here.
                Text("Nod won't use them as context until you mention them again. Older summary isn't affected.")
            }
    }

    @ViewBuilder
    private var contents: some View {
        if entityStore.entities.isEmpty {
            emptyState
        } else {
            populatedList
        }
    }

    // MARK: - Populated list

    private var populatedList: some View {
        List {
            // Preamble only on populated state (per design review).
            // Plain Section without a header renders the text as a
            // leading block, outside the grouped-list card style.
            Section {
                Text("What Nod has picked up about your life, as you've mentioned them. You can forget any of these.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
            }

            ForEach(sectionOrder, id: \.type) { entry in
                let rows = entityStore.entities.filter { $0.type == entry.type }
                if !rows.isEmpty {
                    Section(entry.header) {
                        ForEach(rows) { entity in
                            EntityRow(entity: entity)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDelete = entity
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .accessibilityAction(named: "Forget") {
                                    pendingDelete = entity
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                   value: entityStore.entities.count)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        // `note.text` is a confirmed-real SF Symbol (note-page with
        // lines). Earlier draft used `square.text.square` which doesn't
        // exist — SF Symbols falls back to a placeholder square that
        // would look broken.
        ContentUnavailableView {
            Label("Nothing yet.", systemImage: "note.text")
        } description: {
            Text("Nod will remember the people, places, and situations you mention — they'll appear here as you talk.")
        }
    }
}

// MARK: - Row

/// One entity row. Three lines, calibrated weights per design review
/// (semibold name + secondary note + tertiary metadata). Lines have
/// deliberate line-limits: the name never truncates (full-bleed),
/// the note caps at 3 lines, metadata stays one line.
///
/// VoiceOver: the whole row is one accessibility element with a
/// combined natural-language label. Individual line reads would be
/// clunky ("M", "manager", "former manager", "mentioned 8 times",
/// "July 15"). One phrase flows better.
private struct EntityRow: View {
    let entity: Entity

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleLine)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(nil)

            if !entity.notes.isEmpty {
                Text(entity.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }

            Text(metadataLine)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityPhrase)
    }

    private var titleLine: String {
        if let role = entity.role, !role.isEmpty {
            return "\(entity.canonicalName) (\(role))"
        }
        return entity.canonicalName
    }

    private var metadataLine: String {
        let mention = entity.mentionCount == 1
            ? "Mentioned once"
            : "Mentioned \(entity.mentionCount) times"
        return "\(mention) · \(Self.formatDate(entity.firstMentionedAt))"
    }

    /// Full VoiceOver phrase that reads like a sentence a human would
    /// say, rather than concatenating the three visual lines verbatim.
    private var accessibilityPhrase: String {
        var parts: [String] = [entity.canonicalName]
        if let role = entity.role, !role.isEmpty {
            parts.append(role)
        }
        if !entity.notes.isEmpty {
            parts.append(entity.notes)
        }
        parts.append(metadataLine.replacingOccurrences(of: "·", with: ","))
        return parts.joined(separator: ". ")
    }

    /// Date formatting per design review: Today / Yesterday / Mon DD /
    /// Mon DD, YYYY. Keeps recent events warm and far-past events
    /// disambiguated by year.
    private static func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date)     { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        let now = Date()
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

#Preview("Populated") {
    struct PreviewHarness: View {
        @StateObject var store: EntityStore = {
            let db = try! MessageDatabase()
            let s = EntityStore(database: db)
            return s
        }()
        var body: some View {
            NavigationStack {
                MemoryView(entityStore: store)
            }
            .preferredColorScheme(.dark)
        }
    }
    return PreviewHarness()
}
