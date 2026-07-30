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
        /// When true, the insertion replaces the in-progress "@query" token at the cursor
        /// (see `onMentionQuery`) instead of inserting at a zero-length range - used by the
        /// @mention autocomplete to swap what's being typed for the selected suggestion.
        var replacesMentionToken: Bool = false
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
    /// Reports the text after an unclosed "@" run ending at the cursor (e.g. typing "@ali"
    /// reports "ali"; a bare "@" reports ""), or nil when the cursor isn't inside such a run -
    /// drives the @mention autocomplete overlay.
    var onMentionQuery: ((String?) -> Void)? = nil

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
            // Deferred to the next run loop tick, matching the focus-sync dispatch below -
            // insert() writes to the `text` @Binding, and doing that synchronously from within
            // updateUIView is a SwiftUI/UIKit interop hazard: it can trigger a re-entrant update
            // pass that reads a stale `text` value and re-syncs uiView.text back to it, silently
            // reverting what was just inserted. This was especially likely to surface for the
            // @mention picker specifically, since selecting a suggestion also removes a whole
            // sibling view (the suggestions overlay) from the composer's layout in the same
            // update, which appears to trigger exactly that re-entrancy.
            let coordinator = context.coordinator
            DispatchQueue.main.async {
                coordinator.insert(text: request.text, into: uiView, replacesMentionToken: request.replacesMentionToken)
                onInsertionHandled?(request.id)
            }
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

        func insert(text insertedText: String, into textView: UITextView, replacesMentionToken: Bool = false) {
            let original = textView.text ?? ""
            let nsText = original as NSString
            let insertionRange: NSRange
            if replacesMentionToken, let tokenRange = mentionTokenRange(in: textView) {
                insertionRange = NSRange(tokenRange, in: original)
            } else if textView.isFirstResponder {
                let selected = textView.selectedRange
                // Picker taps should insert additional emoji, not replace selected content.
                let insertionLocation = min(max(selected.location + selected.length, 0), nsText.length)
                insertionRange = NSRange(location: insertionLocation, length: 0)
            } else {
                insertionRange = NSRange(location: nsText.length, length: 0)
            }
            let updated = nsText.replacingCharacters(in: insertionRange, with: insertedText)
            let newCursorLocation = insertionRange.location + (insertedText as NSString).length

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

        /// Range of the unclosed "@query" run ending at a collapsed cursor, if any - e.g. with
        /// the cursor right after "...hey @ali", returns the range covering "@ali". Returns nil
        /// when there's an active (non-empty) selection, or the cursor isn't right after such a
        /// run (no "@", or it's separated from the cursor by whitespace).
        private func mentionTokenRange(in textView: UITextView) -> Range<String.Index>? {
            guard let text = textView.text, textView.selectedRange.length == 0,
                  let cursor = Range(textView.selectedRange, in: text)?.lowerBound else {
                return nil
            }
            var start = cursor
            while start > text.startIndex {
                let before = text.index(before: start)
                if text[before].isWhitespace || text[before].isNewline { break }
                start = before
            }
            guard start < cursor, text[start] == "@" else { return nil }
            return start..<cursor
        }

        private func reportMentionQuery(for textView: UITextView) {
            guard let text = textView.text, let range = mentionTokenRange(in: textView) else {
                parent.onMentionQuery?(nil)
                return
            }
            let query = String(text[text.index(after: range.lowerBound)..<range.upperBound])
            parent.onMentionQuery?(query)
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
            reportMentionQuery(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isProgrammaticChange else { return }
            reportMentionQuery(for: textView)
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
