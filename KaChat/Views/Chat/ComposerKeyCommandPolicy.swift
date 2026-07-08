import Foundation

struct ComposerKeyCommandSpec: Equatable {
    enum Modifier: Hashable {
        case alternate
        case control
        case command
    }

    enum Intent: Equatable {
        case newline
        case paste
        case submit
    }

    let input: String
    let modifiers: Set<Modifier>
    let intent: Intent
    let wantsPriorityOverSystemBehavior: Bool
}

enum ComposerKeyCommandPolicy {
    static let includesSystemTextCommands = true

    static let desktopShortcutSpecs: [ComposerKeyCommandSpec] = [
        ComposerKeyCommandSpec(
            input: "\r",
            modifiers: [],
            intent: .submit,
            wantsPriorityOverSystemBehavior: true
        ),
        ComposerKeyCommandSpec(
            input: "\r",
            modifiers: [.control],
            intent: .newline,
            wantsPriorityOverSystemBehavior: true
        ),
        ComposerKeyCommandSpec(
            input: "\r",
            modifiers: [.alternate],
            intent: .newline,
            wantsPriorityOverSystemBehavior: true
        ),
        ComposerKeyCommandSpec(
            input: "v",
            modifiers: [.control],
            intent: .paste,
            wantsPriorityOverSystemBehavior: true
        )
    ]
}
