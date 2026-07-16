import SwiftUI
import UIKit

// MARK: - UITextView subclass (macCatalyst key commands)

final class ComposerUITextView: UITextView {
    var onReturn: (() -> Void)?
    var onPasteImageData: ((Data) -> Bool)?

    override func paste(_ sender: Any?) {
        if let data = ChatImageAttachmentLoader.imageData(from: .general),
           onPasteImageData?(data) == true {
            return
        }

        super.paste(sender)
    }

    #if targetEnvironment(macCatalyst)
    override var keyCommands: [UIKeyCommand]? {
        let customCommands = ComposerKeyCommandPolicy.desktopShortcutSpecs.map { spec in
            let command = UIKeyCommand(
                input: spec.input,
                modifierFlags: spec.uiModifierFlags,
                action: action(for: spec.intent)
            )
            command.wantsPriorityOverSystemBehavior = spec.wantsPriorityOverSystemBehavior
            return command
        }
        let inheritedCommands = ComposerKeyCommandPolicy.includesSystemTextCommands ? (super.keyCommands ?? []) : []
        return customCommands + inheritedCommands
    }

    @objc private func handleReturn() {
        onReturn?()
    }

    @objc private func handleNewline() {
        insertText("\n")
    }

    @objc private func handlePasteShortcut() {
        paste(nil)
    }

    private func action(for intent: ComposerKeyCommandSpec.Intent) -> Selector {
        switch intent {
        case .newline:
            return #selector(handleNewline)
        case .paste:
            return #selector(handlePasteShortcut)
        case .submit:
            return #selector(handleReturn)
        }
    }
    #endif
}

#if targetEnvironment(macCatalyst)
private extension ComposerKeyCommandSpec {
    var uiModifierFlags: UIKeyModifierFlags {
        modifiers.reduce(into: UIKeyModifierFlags()) { flags, modifier in
            flags.formUnion(modifier.uiModifierFlag)
        }
    }
}

private extension ComposerKeyCommandSpec.Modifier {
    var uiModifierFlag: UIKeyModifierFlags {
        switch self {
        case .alternate:
            return .alternate
        case .command:
            return .command
        case .control:
            return .control
        }
    }
}
#endif

// MARK: - UIViewRepresentable

struct ComposerTextView: UIViewRepresentable {
    struct TextInsertionRequest: Equatable {
        let id: UUID
        let text: String
    }

    @Binding var text: String
    @Binding var isFocused: Bool
    var onTextChange: (String) -> Void
    var onSubmit: () -> Void
    var placeholder: String = String(localized: "Message")
    var maxLines: Int = 5
    var insertionRequest: TextInsertionRequest? = nil
    var onInsertionHandled: ((UUID) -> Void)? = nil
    var onPasteImageData: ((Data) -> Bool)? = nil

    private static let placeholderTag = 999

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        textView.textContentType = .none
        textView.autocorrectionType = .default
        textView.spellCheckingType = .default
        textView.smartQuotesType = .default
        textView.smartDashesType = .default
        textView.smartInsertDeleteType = .default
        textView.dataDetectorTypes = []
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []

        // Placeholder label
        let label = UILabel()
        label.text = placeholder
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .placeholderText
        label.tag = Self.placeholderTag
        label.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            label.topAnchor.constraint(equalTo: textView.topAnchor),
        ])
        label.isHidden = !text.isEmpty

        #if targetEnvironment(macCatalyst)
        textView.onReturn = { [weak coordinator = context.coordinator] in
            coordinator?.handleSubmit()
        }
        #endif
        textView.onPasteImageData = { [weak coordinator = context.coordinator] data in
            coordinator?.handlePasteImageData(data) ?? false
        }

        return textView
    }

    func updateUIView(_ uiView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteImageData = { [weak coordinator = context.coordinator] data in
            coordinator?.handlePasteImageData(data) ?? false
        }

        if uiView.text != text {
            context.coordinator.isProgrammaticChange = true
            uiView.text = text
            context.coordinator.isProgrammaticChange = false
            if let label = uiView.viewWithTag(Self.placeholderTag) as? UILabel {
                label.text = placeholder
                label.isHidden = !text.isEmpty
            }
            uiView.invalidateIntrinsicContentSize()
        } else if let label = uiView.viewWithTag(Self.placeholderTag) as? UILabel,
                  label.text != placeholder {
            label.text = placeholder
        }

        if let request = insertionRequest,
           context.coordinator.lastHandledInsertionID != request.id {
            context.coordinator.lastHandledInsertionID = request.id
            context.coordinator.insert(text: request.text, into: uiView)
            onInsertionHandled?(request.id)
        }

        // Focus sync
        if isFocused && !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !isFocused && uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let lineHeight = uiView.font?.lineHeight ?? 20
        let maxHeight = lineHeight * CGFloat(maxLines)

        // `UITextView.sizeThatFits` only reports the text's true natural height while
        // `isScrollEnabled` is false - once scrolling is on, it just echoes back the view's
        // current bounds instead of measuring content. Toggling `isScrollEnabled` based on a
        // measurement that itself depends on the *current* `isScrollEnabled` value creates a
        // feedback loop where every layout pass flips the value and SwiftUI never converges,
        // pinning the main thread indefinitely. Forcing scrolling off before measuring keeps
        // the result stable regardless of the view's current state.
        uiView.isScrollEnabled = false
        let fittingSize = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let clampedHeight = min(fittingSize.height, maxHeight)
        uiView.isScrollEnabled = fittingSize.height > maxHeight
        return CGSize(width: width, height: clampedHeight)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var isProgrammaticChange = false
        var lastHandledInsertionID: UUID?

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func insert(text insertedText: String, into textView: UITextView) {
            let original = textView.text ?? ""
            let nsText = original as NSString
            let insertionLocation: Int
            if textView.isFirstResponder {
                let selected = textView.selectedRange
                // Picker taps should insert additional emoji, not replace selected content.
                insertionLocation = min(max(selected.location + selected.length, 0), nsText.length)
            } else {
                insertionLocation = nsText.length
            }
            let insertionRange = NSRange(location: insertionLocation, length: 0)
            let updated = nsText.replacingCharacters(in: insertionRange, with: insertedText)
            let newCursorLocation = insertionLocation + (insertedText as NSString).length

            isProgrammaticChange = true
            textView.text = updated
            textView.selectedRange = NSRange(location: newCursorLocation, length: 0)
            isProgrammaticChange = false

            parent.text = updated
            parent.onTextChange(updated)
            if let label = textView.viewWithTag(ComposerTextView.placeholderTag) as? UILabel {
                label.isHidden = !updated.isEmpty
            }
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticChange else { return }
            let newText = textView.text ?? ""
            parent.text = newText
            parent.onTextChange(newText)
            if let label = textView.viewWithTag(ComposerTextView.placeholderTag) as? UILabel {
                label.isHidden = !newText.isEmpty
            }
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func handleSubmit() {
            parent.onSubmit()
        }

        func handlePasteImageData(_ data: Data) -> Bool {
            parent.onPasteImageData?(data) ?? false
        }
    }
}
