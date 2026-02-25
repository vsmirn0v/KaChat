import SwiftUI
import UIKit

// MARK: - UITextView subclass (macCatalyst key commands)

final class ComposerUITextView: UITextView {
    var onReturn: (() -> Void)?

    #if targetEnvironment(macCatalyst)
    override var keyCommands: [UIKeyCommand]? {
        let plainReturn = UIKeyCommand(
            input: "\r",
            modifierFlags: [],
            action: #selector(handleReturn)
        )
        plainReturn.wantsPriorityOverSystemBehavior = true

        let controlReturn = UIKeyCommand(
            input: "\r",
            modifierFlags: [.control],
            action: #selector(handleNewline)
        )
        controlReturn.wantsPriorityOverSystemBehavior = true

        let optionReturn = UIKeyCommand(
            input: "\r",
            modifierFlags: [.alternate],
            action: #selector(handleNewline)
        )
        optionReturn.wantsPriorityOverSystemBehavior = true

        return [plainReturn, controlReturn, optionReturn]
    }

    @objc private func handleReturn() {
        onReturn?()
    }

    @objc private func handleNewline() {
        insertText("\n")
    }
    #endif
}

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

        return textView
    }

    func updateUIView(_ uiView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self

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
    }
}
