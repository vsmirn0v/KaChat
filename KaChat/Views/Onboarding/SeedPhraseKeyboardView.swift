import SwiftUI

/// In-app seed-phrase entry: a numbered 12/24-slot grid filled via a custom on-screen QWERTY
/// keyboard with BIP39 word autocomplete. The OS keyboard never appears for the recovery words,
/// so no third-party keyboard, autocorrect/learning dictionary, or clipboard-sync ever sees them.
/// Only letters that can extend the active word into a real BIP39 word are tappable, and a word
/// auto-commits (advancing to the next slot) once it uniquely matches a single wordlist entry.
///
/// The parent owns `words` (sized to at least `wordCount`); this view reads/writes the first
/// `wordCount` entries and tracks the active slot internally.
struct SeedPhraseKeyboardView: View {
    @Binding var words: [String]
    let wordCount: Int

    @State private var activeSlot = 0

    private let wordList = BIP39.shared.englishWordList
    private let keyRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    private var current: String { words.indices.contains(activeSlot) ? words[activeSlot].lowercased() : "" }

    /// All BIP39 words that start with the active slot's current text.
    private var matches: [String] {
        let p = current
        guard !p.isEmpty else { return [] }
        return wordList.filter { $0.hasPrefix(p) }
    }

    /// The next legal letter after the current prefix for every candidate word (plus every valid
    /// first letter when the slot is empty). Keys not in this set are disabled.
    private var enabledKeys: Set<Character> {
        let p = current
        let source = p.isEmpty ? wordList : matches
        let idx = p.count
        var set = Set<Character>()
        for w in source where w.count > idx {
            set.insert(Array(w)[idx])
        }
        return set
    }

    var body: some View {
        VStack(spacing: 10) {
            grid
            suggestionBar
            keyboard
        }
        .onChange(of: wordCount) { _ in
            if activeSlot >= wordCount { activeSlot = max(0, wordCount - 1) }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(0..<wordCount, id: \.self) { i in
                    slot(i)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func slot(_ i: Int) -> some View {
        let word = words.indices.contains(i) ? words[i] : ""
        let isActive = i == activeSlot
        let isValid = !word.isEmpty && BIP39.shared.isValidWord(word)
        return HStack(spacing: 4) {
            Text("\(i + 1)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(word.isEmpty ? "\u{00a0}" : word)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(word.isEmpty ? .secondary : (isValid || isActive ? .primary : .red))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { activeSlot = i }
    }

    // MARK: - Suggestions

    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(matches.prefix(30)), id: \.self) { w in
                    Button {
                        commit(w)
                    } label: {
                        (Text(current).bold() + Text(String(w.dropFirst(current.count))))
                            .font(.callout)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 40)
    }

    // MARK: - Keyboard

    private var keyboard: some View {
        VStack(spacing: 7) {
            ForEach(keyRows.indices, id: \.self) { r in
                HStack(spacing: 5) {
                    if r == 1 { Spacer(minLength: 14) }
                    ForEach(Array(keyRows[r]), id: \.self) { ch in
                        key(ch)
                    }
                    if r == 1 { Spacer(minLength: 14) }
                    if r == 2 { backspaceKey }
                }
            }
        }
    }

    private func key(_ ch: Character) -> some View {
        let enabled = enabledKeys.contains(ch)
        return Button {
            press(ch)
        } label: {
            Text(String(ch))
                .font(.system(size: 20, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(enabled ? Color(.systemGray5) : Color(.systemGray6).opacity(0.5))
                .foregroundColor(enabled ? .primary : Color(.systemGray3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .disabled(!enabled)
    }

    private var backspaceKey: some View {
        Button {
            backspace()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 54, height: 46)
                .background(Color(.systemGray4))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Editing

    private func press(_ ch: Character) {
        guard words.indices.contains(activeSlot) else { return }
        words[activeSlot].append(ch)
        // Auto-commit when the active word uniquely equals a single BIP39 word (e.g. "zoo").
        let m = matches
        if m.count == 1, m[0] == words[activeSlot].lowercased() {
            commit(m[0])
        }
    }

    private func backspace() {
        guard words.indices.contains(activeSlot) else { return }
        if !words[activeSlot].isEmpty {
            words[activeSlot].removeLast()
        } else if activeSlot > 0 {
            activeSlot -= 1
        }
    }

    private func commit(_ word: String) {
        guard words.indices.contains(activeSlot) else { return }
        words[activeSlot] = word
        if activeSlot < wordCount - 1 {
            activeSlot += 1
        }
    }
}
