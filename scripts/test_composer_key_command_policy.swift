import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ComposerKeyCommandPolicyTest {
    static func main() {
        let shortcuts = ComposerKeyCommandPolicy.desktopShortcutSpecs

        expect(
            shortcuts.contains {
                $0.input == "v"
                    && $0.modifiers == [.control]
                    && $0.intent == .paste
                    && $0.wantsPriorityOverSystemBehavior
            },
            "desktop composer should map Control-V to paste"
        )

        expect(
            shortcuts.contains {
                $0.input == "v"
                    && $0.modifiers == [.command]
                    && $0.intent == .paste
                    && $0.wantsPriorityOverSystemBehavior
            },
            "desktop composer should explicitly map Command-V to paste"
        )

        expect(
            ComposerKeyCommandPolicy.includesSystemTextCommands,
            "desktop composer should preserve inherited text edit commands such as Command-V"
        )

        expect(
            ChatSendKeyboardShortcutPolicy.shouldInstallReturnShortcut(
                hasPendingPhoto: true,
                isSending: false,
                isCompressingPhoto: false,
                isDeclined: false
            ),
            "pending photo should install a Return send shortcut"
        )

        expect(
            !ChatSendKeyboardShortcutPolicy.shouldInstallReturnShortcut(
                hasPendingPhoto: false,
                isSending: false,
                isCompressingPhoto: false,
                isDeclined: false
            ),
            "normal text composer should rely on the text view Return command"
        )

        expect(
            !ChatSendKeyboardShortcutPolicy.shouldInstallReturnShortcut(
                hasPendingPhoto: true,
                isSending: true,
                isCompressingPhoto: false,
                isDeclined: false
            ),
            "pending photo should not install Return shortcut while already sending"
        )

        expect(
            !ChatSendKeyboardShortcutPolicy.shouldInstallReturnShortcut(
                hasPendingPhoto: true,
                isSending: false,
                isCompressingPhoto: true,
                isDeclined: false
            ),
            "pending photo should not install Return shortcut while compressing"
        )

        expect(
            !ChatSendKeyboardShortcutPolicy.shouldInstallReturnShortcut(
                hasPendingPhoto: true,
                isSending: false,
                isCompressingPhoto: false,
                isDeclined: true
            ),
            "declined chats should not install Return shortcut for pending photos"
        )
    }
}
