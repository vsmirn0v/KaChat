import SwiftUI

struct DesktopEmojiPickerView: View {
    let onSelect: (String) -> Void

    @State private var selectedCategory: DesktopEmojiCategory = .smileys
    @State private var searchText = ""

    private let columns = [
        GridItem(.adaptive(minimum: 36, maximum: 44), spacing: 6)
    ]

    private var displayedItems: [DesktopEmojiItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DesktopEmojiLibrary.emoji(in: selectedCategory)
        }
        return DesktopEmojiLibrary.searchItems(searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            categoryBar
            searchField
            emojiGrid
        }
        .padding(12)
        #if targetEnvironment(macCatalyst)
        // Fixed size for the Catalyst composer's `.popover` presentation (its only caller until
        // Settings > Chats > Quick Reactions started reusing this view on iPhone/iPad too, where
        // a fixed 420pt width would overflow a narrower sheet - `.frame(maxWidth: .infinity)`
        // there instead lets it fill whatever sheet/container it's placed in).
        .frame(width: 420, height: 360)
        #else
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 420)
        #endif
    }

    private var categoryBar: some View {
        HStack(spacing: 6) {
            ForEach(DesktopEmojiCategory.allCases) { category in
                Button {
                    selectedCategory = category
                    searchText = ""
                } label: {
                    Image(systemName: category.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selectedCategory == category ? Color.accentColor : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle()
                                .fill(selectedCategory == category ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(category.title))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search emoji", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
    }

    private var emojiGrid: some View {
        ScrollView {
            if displayedItems.isEmpty {
                Text("No emoji found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(displayedItems) { item in
                        Button {
                            onSelect(item.emoji)
                        } label: {
                            Text(item.emoji)
                                .font(.system(size: 26))
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(item.keywords))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
