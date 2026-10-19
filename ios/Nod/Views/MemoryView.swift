// MemoryView.swift
// The "What Nod remembers" screen, reached from the sidebar. A timeline
// of chapter notes — the short notes Nod writes as older stretches of the
// conversation age out — newest first. These are exactly what Nod reads
// back, so what you see is what it knows.
//
// Swipe a note to forget it: the note is deleted and Nod stops recalling
// your messages from that stretch. The messages themselves stay in the
// chat (Start fresh is the way to remove those).
//
// Full Dynamic Type + VoiceOver + Reduce Motion support.

import SwiftUI
import UIKit

struct MemoryView: View {

    @ObservedObject var store: ConversationStore
    @State private var pendingForget: ConversationMemory.Chapter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chapters: [ConversationMemory.Chapter] {
        store.memory.chapters.reversed()
    }

    var body: some View {
        contents
            .navigationTitle("Memory")
            // Inline title matches the sidebar's "Nod" title above it.
            .navigationBarTitleDisplayMode(.inline)
            .alert(
                "Forget this?",
                isPresented: Binding(
                    get: { pendingForget != nil },
                    set: { if !$0 { pendingForget = nil } }
                ),
                presenting: pendingForget
            ) { chapter in
                Button("Cancel", role: .cancel) { }
                Button("Forget", role: .destructive) {
                    store.forgetChapter(chapter)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } message: { _ in
                Text("Nod won't bring up anything from this stretch again. Your messages stay in the chat.")
            }
    }

    @ViewBuilder
    private var contents: some View {
        if chapters.isEmpty {
            emptyState
        } else {
            timeline
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        List {
            Section {
                Text("As your conversation grows, Nod keeps a short note about each stretch. It uses these, and your own words, to remember. Swipe a note to forget it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
            }

            Section {
                ForEach(chapters) { chapter in
                    ChapterRow(chapter: chapter)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingForget = chapter
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                        .accessibilityAction(named: "Forget") {
                            pendingForget = chapter
                        }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chapters.count)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing yet.", systemImage: "note.text")
        } description: {
            Text("As you talk, Nod keeps short notes about what's been going on. They'll appear here.")
        }
    }
}

// MARK: - Row

/// One chapter: when it was, then the note.
private struct ChapterRow: View {
    let chapter: ConversationMemory.Chapter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.span(from: chapter.firstMessageAt, to: chapter.lastMessageAt))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(chapter.text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// "Today", "Yesterday", "Mar 3", "Mar 3 – 5", "Mar 3, 2025".
    static func span(from start: Date, to end: Date) -> String {
        let calendar = Calendar.current
        let startLabel = label(start, calendar: calendar)
        if calendar.isDate(start, inSameDayAs: end) { return startLabel }
        return "\(startLabel) – \(label(end, calendar: calendar))"
    }

    private static func label(_ date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }
}
