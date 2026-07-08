import Foundation

@main
struct EmojiInputSupportTest {
    static func main() {
        assert(
            EmojiInputSupport.shouldShowDesktopEmojiButton(isMacCatalyst: true),
            "Mac Catalyst should show an emoji button in the composer"
        )
        assert(
            EmojiInputSupport.presentationMode(isMacCatalyst: true) == .desktopEmojiPicker,
            "Mac Catalyst should use KaChat's desktop emoji picker"
        )
        assert(
            !EmojiInputSupport.shouldShowDesktopEmojiButton(isMacCatalyst: false),
            "iPhone and iPad should rely on the native keyboard emoji switcher"
        )
        assert(
            EmojiInputSupport.presentationMode(isMacCatalyst: false) == .keyboardEmojiInput,
            "Non-Mac targets should not use a limited custom emoji library"
        )

        print("PASS: EmojiInputSupport")
    }
}
