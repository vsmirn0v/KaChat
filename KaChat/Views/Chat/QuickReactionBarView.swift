import SwiftUI

/// The popup shown when a message bubble is double-tapped: a row of common emoji to react with,
/// plus a reply shortcut in the corner - replaces the old behavior where double-tap jumped
/// straight into reply mode, giving an explicit choice between reacting and replying instead.
/// Matches Android's `QuickReactionBar`. `emojis` is caller-supplied (rather than a fixed global
/// constant) so it reflects the user's Settings > Chats > Quick Reactions customization -
/// defaults to `AppSettings.defaultQuickReactionEmojis` if a caller doesn't have settings handy.
struct QuickReactionBarView: View {
    var emojis: [String] = AppSettings.defaultQuickReactionEmojis
    let onReact: (String) -> Void
    let onReply: () -> Void
    /// Opens the full emoji picker. The HOST presents it, not this view.
    ///
    /// This bar lives inside the message list, and the list carries a `simultaneousGesture` that
    /// closes the bar on any tap in it - including the tap on "+". A sheet owned here was
    /// therefore attached to a view that was being torn down by the very tap that asked for it,
    /// so it never appeared. Presenting from the screen means the picker outlives the bar.
    var onMore: () -> Void = {}

    @ObservedObject private var recents = EmojiRecentsStore.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 10) {
                // Leads the row: the six quick emoji cover the common cases, and this is the way
                // to any of the others without going to Settings to change which six they are.
                Button {
                    onMore()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("More reactions"))

                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        recents.record(emoji)
                        onReact(emoji)
                    } label: {
                        Text(emoji)
                            .font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button(action: onReply) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
        )
    }
}

/// Small rounded pill overlapping a bubble's bottom outer corner, showing the distinct emoji
/// reacted with (and a count when more than one person used the same one). Matches Android's
/// `ReactionPill`. Takes plain emoji strings (not a specific reaction-snapshot type) so it works
/// the same for both 1:1 (`MessageStore.ReactionSnapshot`) and group (`GroupStore.ReactionSnapshot`)
/// reactions.
struct ReactionPillView: View {
    let emojis: [String]
    /// The local user's own reaction status on this message (nil = the user hasn't reacted here, or
    /// it's someone else's reaction). `.failed` shows a red error icon + red outline (the tappable
    /// "Retry" is rendered separately under the message); `.sent` shows a green checkmark once the
    /// reaction goes through; `.pending` (in flight) shows no icon.
    var localReactionStatus: ChatMessage.DeliveryStatus? = nil

    private var statusIcon: (name: String, color: Color)? {
        switch localReactionStatus {
        case .failed: return ("exclamationmark.circle.fill", .red)
        case .sent: return ("checkmark.circle.fill", .green)
        default: return nil
        }
    }

    private var counts: [(emoji: String, count: Int)] {
        var order: [String] = []
        var tally: [String: Int] = [:]
        for emoji in emojis {
            if tally[emoji] == nil { order.append(emoji) }
            tally[emoji, default: 0] += 1
        }
        return order.map { ($0, tally[$0] ?? 0) }
    }

    var body: some View {
        HStack(spacing: 2) {
            if let statusIcon {
                Image(systemName: statusIcon.name)
                    .font(.system(size: 11))
                    .foregroundColor(statusIcon.color)
            }
            ForEach(counts, id: \.emoji) { entry in
                Text(entry.emoji)
                    .font(.system(size: 12))
                if entry.count > 1 {
                    Text("\(entry.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(.regularMaterial)
        )
        .overlay(
            Capsule().strokeBorder(localReactionStatus == .failed ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }
}
