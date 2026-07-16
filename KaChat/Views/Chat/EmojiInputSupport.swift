import Foundation

enum EmojiInputPresentationMode: Equatable {
    case desktopEmojiPicker
    case keyboardEmojiInput
}

enum EmojiInputSupport {
    static func shouldShowDesktopEmojiButton(isMacCatalyst: Bool) -> Bool {
        isMacCatalyst
    }

    static func presentationMode(isMacCatalyst: Bool) -> EmojiInputPresentationMode {
        isMacCatalyst ? .desktopEmojiPicker : .keyboardEmojiInput
    }

    static var shouldShowDesktopEmojiButton: Bool {
        shouldShowDesktopEmojiButton(isMacCatalyst: isCurrentPlatformMacCatalyst)
    }

    static var currentPresentationMode: EmojiInputPresentationMode {
        presentationMode(isMacCatalyst: isCurrentPlatformMacCatalyst)
    }

    private static var isCurrentPlatformMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    static var shouldUseDesktopEmojiPicker: Bool {
        currentPresentationMode == .desktopEmojiPicker
    }
}
