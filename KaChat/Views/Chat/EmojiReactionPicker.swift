import SwiftUI

/// Emoji you have actually reacted with, most recent first.
///
/// Local and shared across every chat type: a reaction is a reaction whether it lands on a 1:1
/// message, a group message or a broadcast, so recents built in one place should be there in the
/// others too.
@MainActor
final class EmojiRecentsStore: ObservableObject {
    static let shared = EmojiRecentsStore()

    @Published private(set) var recents: [String] = []

    private let key = "kachat_emoji_reaction_recents"
    private static let limit = 24

    private init() {
        recents = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func record(_ emoji: String) {
        guard !emoji.isEmpty else { return }
        var updated = recents.filter { $0 != emoji }
        updated.insert(emoji, at: 0)
        if updated.count > Self.limit { updated = Array(updated.prefix(Self.limit)) }
        recents = updated
        UserDefaults.standard.set(updated, forKey: key)
    }
}

/// The full emoji list behind the quick bar's "+", as a half sheet.
///
/// The quick bar holds six; this is everything else, without sending the user to Settings to
/// change what those six are just to react with a seventh.
struct EmojiReactionPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recents = EmojiRecentsStore.shared
    @State private var query = ""

    /// Grouped the way a keyboard groups them, so the sheet is scannable rather than a wall.
    /// Deliberately a curated list rather than every codepoint Unicode defines: the long tail is
    /// unsearchable by eye and inflates the sheet for no practical gain.
    private static let sections: [(title: String, emojis: [String])] = [
        ("Smileys", ["😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩","😘","😗","😚","😙","😋","😛","😜","🤪","😝","🤗","🤭","🤫","🤔","🤐","😐","😑","😶","😏","😒","🙄","😬","😮","😯","😪","😴","😌","😔","😕","🙁","☹️","😣","😖","😫","😩","🥺","😢","😭","😤","😠","😡","🤬","🤯","😳","🥵","🥶","😱","😨","😰","😥","🤗","🤡","💩"]),
        ("Gestures", ["👍","👎","👌","🤌","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","👇","☝️","✋","🤚","🖐️","🖖","👋","🤝","🙏","💪","🫶","👏","🙌","👐","🤲","✊","👊"]),
        ("Hearts", ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝"]),
        ("Celebration", ["🔥","✨","🎉","🎊","🥳","🏆","🥇","💯","⭐","🌟","💫","⚡","💥","🚀","🎯","🎁"]),
        ("Objects", ["👀","🧠","💡","💰","💸","💎","📈","📉","🔒","🔑","⏰","📌","✅","❌","⚠️","❓","❗"]),
        ("Animals & Nature", ["🐶","🐱","🦊","🐻","🐼","🐨","🦁","🐮","🐷","🐸","🐵","🐔","🐧","🦄","🐝","🦋","🌸","🌻","🌈","🌊","🌙","☀️"]),
    ]

    /// Search matches an emoji's own NAME. Matching the character itself (what this used to do)
    /// only ever found something if you already had the emoji to paste, which is not a search.
    /// Names come from Unicode via `localizedName`, so "fire", "heart", "cat" all work without
    /// this file carrying a keyword table that would go stale.
    private var filteredSections: [(title: String, emojis: [String])] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return Self.sections }
        return Self.sections.compactMap { section in
            let matches = section.emojis.filter { emoji in
                emoji.contains(trimmed) || Self.localizedName(for: emoji).contains(trimmed)
            }
            return matches.isEmpty ? nil : (section.title, matches)
        }
    }

    /// The Unicode name for an emoji, lowercased ("fire", "red heart", "grinning face"). Cached
    /// because the transform is not free and the whole grid is filtered on every keystroke.
    private static var nameCache: [String: String] = [:]
    private static func localizedName(for emoji: String) -> String {
        if let cached = nameCache[emoji] { return cached }
        let name = (emoji.applyingTransform(.toUnicodeName, reverse: false) ?? "")
            .replacingOccurrences(of: "\\N{", with: "")
            .replacingOccurrences(of: "}", with: " ")
            .lowercased()
        nameCache[emoji] = name
        return name
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    if !recents.recents.isEmpty, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        section(title: "Recents", emojis: recents.recents)
                    }
                    ForEach(filteredSections, id: \.title) { section(title: $0.title, emojis: $0.emojis) }
                    if filteredSections.isEmpty {
                        Text("No emoji match that.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func section(title: String, emojis: [String]) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in
                    Button {
                        recents.record(emoji)
                        onPick(emoji)
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))
        }
    }
}
