import SwiftUI

/// Fixed tapback-style set, not a full emoji keyboard - keeps this identical on iOS/Android (see
/// Android's matching `QUICK_REACTION_EMOJIS`).
let quickReactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

/// The popup shown when a message bubble is double-tapped: a row of common emoji to react with,
/// plus a reply shortcut in the corner - replaces the old behavior where double-tap jumped
/// straight into reply mode, giving an explicit choice between reacting and replying instead.
/// Matches Android's `QuickReactionBar`.
struct QuickReactionBarView: View {
    let onReact: (String) -> Void
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(quickReactionEmojis, id: \.self) { emoji in
                    Button {
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
    }
}
