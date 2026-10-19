// NoticeCard.swift
// One layout for every message from the app itself (failed replies,
// banners, download failures), so status never looks like Nod talking
// and every notice lines up the same way:
//
//   [icon]  Title                          [Action]   ← fits on one line
//
//   [icon]  Title that runs long enough
//           to wrap, with a message under
//           it.
//           [Action]                                  ← otherwise
//
// The icon sits in a fixed column; title, message and action share one
// leading edge. Full width, so notices read as app chrome rather than
// as chat bubbles.

import SwiftUI

struct NoticeCard<Icon: View>: View {

    enum Tone {
        case info, error

        var background: Color {
            switch self {
            case .info: return Soft.surface
            case .error: return Color.red
            }
        }
    }

    let tone: Tone
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder let icon: () -> Icon

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 20

    var body: some View {
        layout
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(backgroundFill)
        )
        .overlay {
            // Info notices sit on the warm background as a surface, so
            // they get the same hairline as Soft cards.
            if tone == .info {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Soft.hairline, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// One line when a title-and-action notice fits; stacked otherwise.
    @ViewBuilder
    private var layout: some View {
        if message == nil, actionTitle != nil {
            ViewThatFits(in: .horizontal) {
                singleLine
                stacked
            }
        } else {
            stacked
        }
    }

    private var backgroundFill: Color {
        switch tone {
        case .info: return tone.background
        // Stronger in dark mode, where 8% red disappears on black.
        case .error: return tone.background.opacity(colorScheme == .dark ? 0.18 : 0.08)
        }
    }

    private var singleLine: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                iconView
                titleText.fixedSize()
            }
            Spacer(minLength: 0)
            actionButton
            dismissButton
        }
    }

    private var stacked: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            iconView
            VStack(alignment: .leading, spacing: 4) {
                titleText
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Soft.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if actionTitle != nil {
                    actionButton.padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
            dismissButton
        }
    }

    private var iconView: some View {
        icon()
            .font(.subheadline)
            .frame(width: iconColumn)
            .accessibilityHidden(true)
    }

    private var titleText: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Soft.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Color("NodAccent"))
                .foregroundStyle(.black)
        }
    }

    @ViewBuilder
    private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }
}

extension NoticeCard where Icon == AnyView {
    /// A notice with the tone's standard icon.
    init(
        tone: Tone,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
        self.icon = {
            switch tone {
            case .info:
                AnyView(Image(systemName: "info.circle.fill").foregroundStyle(Soft.muted))
            case .error:
                AnyView(Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red))
            }
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        NoticeCard(tone: .error, title: "Nod couldn't reply this time.", actionTitle: "Try again", action: {})
        NoticeCard(tone: .info, title: "Apple Intelligence isn't available on this iPhone.",
                   message: "Your conversation is safe. Download Nod's own model to keep talking.",
                   actionTitle: "Download", action: {})
        NoticeCard(tone: .error, title: "Not enough space on this iPhone",
                   message: "Free up about 3.1 GB, then try again.", actionTitle: "Try again", action: {})
        NoticeCard(tone: .info, title: "Switched to Apple Intelligence to keep things running.", onDismiss: {})
    }
    .padding()
}
