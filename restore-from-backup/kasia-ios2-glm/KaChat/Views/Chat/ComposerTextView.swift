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
    @Binding var text: String
    @Binding var isFocused: Bool
    var onTextChange: (String) -> Void
    var onSubmit: () -> Void
    var placeholder: String = "Message"
    var maxLines: Int = 5

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
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
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
                label.isHidden = !text.isEmpty
            }
            uiView.invalidateIntrinsicContentSize()
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

        init(parent: ComposerTextView) {
            self.parent = parent
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
