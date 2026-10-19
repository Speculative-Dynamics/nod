// MemoryView.swift
// The "What Nod remembers" screen, reached from the chat header and
// from Settings. One card per chapter note — the short notes Nod writes
// as older stretches of the conversation age out — newest first. These
// are exactly what Nod reads back, so what you see is what it knows.
// The newest note is the one Nod reads on every reply, so it's marked
// "In use now".
//
// Each card's menu forgets the note: it's deleted and Nod stops
// recalling your messages from that stretch. The messages themselves
// stay in the chat (Start fresh is the way to remove those).
//
// Full Dynamic Type + VoiceOver + Reduce Motion support.

import SwiftUI
import UIKit

struct MemoryView: View {

    @ObservedObject var store: ConversationStore
    @State private var pendingForget: ConversationMemory.Chapter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var chapters: [ConversationMemory.Chapter] {
        store.memory.chapters.reversed()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What Nod remembers")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Soft.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text(chapters.isEmpty
                         ? "As you talk, Nod keeps short notes about what's been going on. They'll appear here."
                         : "Nod keeps a short note as your conversation grows, and reads these to remember.")
                        .font(.subheadline)
                        .foregroundStyle(Soft.muted)
                }

                if !chapters.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(chapters) { chapter in
                            ChapterCard(
                                chapter: chapter,
                                inUse: chapter.id == chapters.first?.id,
                                onForget: { pendingForget = chapter }
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: chapters.count)
                }

                Label("Only on this iPhone", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(Soft.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Soft.background)
        .fontDesign(.rounded)
        .navigationTitle("")
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
}

// MARK: - Card

/// One chapter: when it was, an "In use now" badge on the newest, a
/// menu to forget it, then the note.
private struct ChapterCard: View {
    let chapter: ConversationMemory.Chapter
    let inUse: Bool
    let onForget: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.span(from: chapter.firstMessageAt, to: chapter.lastMessageAt))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Soft.muted)
                if inUse {
                    Text("In use now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Soft.badgeText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Soft.badge, in: Capsule())
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Forget", systemImage: "trash", role: .destructive, action: onForget)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Soft.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Options for this note")
                .padding(.trailing, -10)
            }
            .padding(.vertical, -8)

            Text(chapter.text)
                .font(.body)
                .foregroundStyle(Soft.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Soft.surface, in: shape)
        .softLift(colorScheme, in: shape)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Forget", onForget)
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
