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
            ComposerKeyCommandPolicy.includesSystemTextCommands,
            "desktop composer should preserve inherited text edit commands such as Command-V"
        )
    }
}
