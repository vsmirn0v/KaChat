import Foundation

@main
struct DesktopEmojiLibraryTest {
    static func main() {
        let allEmoji = DesktopEmojiLibrary.allEmoji
        assert(allEmoji.count > 1_000, "Desktop emoji picker should expose a broad emoji library")
        assert(Set(allEmoji).count == allEmoji.count, "Emoji library should not contain duplicates")

        for required in ["😀", "❤️", "👍", "👍🏻", "🚀", "🏳️‍🌈", "🇺🇸"] {
            assert(allEmoji.contains(required), "Emoji library is missing \(required)")
        }

        let smileSearch = DesktopEmojiLibrary.search("smile")
        assert(smileSearch.contains("😀"), "Emoji search should find smileys by keyword")

        let flagSearch = DesktopEmojiLibrary.search("flag us")
        assert(flagSearch.contains("🇺🇸"), "Emoji search should find flags by keyword")

        print("PASS: DesktopEmojiLibrary")
    }
}
