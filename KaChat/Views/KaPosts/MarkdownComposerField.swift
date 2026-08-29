import SwiftUI
import UIKit

/// The KaPosts composer's text field, and the formatting toolbar that acts on its selection.
///
/// Why this is a `UIViewRepresentable` and not the SwiftUI `TextField` it replaces: neither
/// `TextField` nor `TextEditor` will tell you what the user highlighted, and wrapping the
/// highlighted text is the entire point of a Bold button. A `UITextView` with scrolling turned OFF
/// keeps the property the old `TextField` was chosen for - a real intrinsic height that grows line
/// by line, so the enclosing ScrollView still has a caret to keep above the keyboard - while also
/// publishing `selectedRange`.
struct MarkdownComposerField: UIViewRepresentable {
    @Binding var text: String
    /// The selection, in CHARACTER offsets (not UTF-16), so it lines up with `KaPostsMarkdown`.
    @Binding var selection: ClosedRange<Int>
    @Binding var isFocused: Bool
    let placeholder: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        // Self-sizing: the composer's own ScrollView does the scrolling, and this view reports a
        // height instead of eating the space greedily.
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Smart dashes would rewrite a typed "--" as an em dash mid-post; the markdown here is
        // punctuation, so leave what the user typed alone.
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.setContentCompressionResistancePriority(.required, for: .vertical)

        let placeholderLabel = UILabel()
        placeholderLabel.text = placeholder
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: view.topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
        ])
        context.coordinator.placeholderLabel = placeholderLabel
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        // Guarded: every assignment below fires a delegate callback, and writing straight back
        // into the bindings from there would fight the user's typing.
        context.coordinator.isApplyingExternalUpdate = true
        defer { context.coordinator.isApplyingExternalUpdate = false }

        if uiView.text != text {
            uiView.text = text
        }
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        context.coordinator.placeholderLabel?.text = placeholder

        if let target = Self.nsRange(forCharacters: selection, in: text), uiView.selectedRange != target {
            uiView.selectedRange = target
        }

        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownComposerField
        var placeholderLabel: UILabel?
        var isApplyingExternalUpdate = false

        init(parent: MarkdownComposerField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalUpdate else { return }
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            pushSelection(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingExternalUpdate else { return }
            pushSelection(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        private func pushSelection(_ textView: UITextView) {
            let range = MarkdownComposerField.characterRange(
                of: textView.selectedRange,
                in: textView.text
            )
            if parent.selection != range { parent.selection = range }
        }
    }

    // MARK: - Offset conversion

    /// UIKit counts selections in UTF-16 units; the parser counts Characters. They differ the
    /// moment a post contains an emoji, and an off-by-one there wraps the markers around the
    /// wrong text.
    static func characterRange(of nsRange: NSRange, in text: String) -> ClosedRange<Int> {
        guard let range = Range(nsRange, in: text) else { return 0...0 }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        return start...max(start, end)
    }

    static func nsRange(forCharacters range: ClosedRange<Int>, in text: String) -> NSRange? {
        let count = text.count
        let start = max(0, min(range.lowerBound, count))
        let end = max(start, min(range.upperBound, count))
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(text.startIndex, offsetBy: end)
        return NSRange(lower..<upper, in: text)
    }
}

/// The formatting buttons above the keyboard.
///
/// Exists because the syntax is only discoverable if you already know it: someone who has never
/// typed `~~` cannot guess that it means strikethrough. Every button toggles, and every one of
/// them writes the same markers a person could have typed by hand, so the two ways of formatting
/// a post produce identical text.
struct MarkdownFormattingToolbar: View {
    let onAction: (KaPostsMarkdown.ToolbarAction) -> Void

    /// Order runs from the formatting people reach for most to the least.
    private static let items: [(action: KaPostsMarkdown.ToolbarAction, icon: String, label: String)] = [
        (.bold, "bold", "Bold"),
        (.italic, "italic", "Italic"),
        (.underline, "underline", "Underline"),
        (.strikethrough, "strikethrough", "Strikethrough"),
        (.bulletList, "list.bullet", "Bulleted list"),
        (.numberedList, "list.number", "Numbered list"),
        (.subtext, "textformat.size.smaller", "Small text"),
        (.link, "link", "Link"),
    ]

    var body: some View {
        // Scrolls rather than squeezing: eight buttons at a comfortable tap size do not fit an
        // iPhone SE's width, and shrinking them to fit would make them hard to hit.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Self.items, id: \.action) { item in
                    Button {
                        Haptics.impact(.light)
                        onAction(item.action)
                    } label: {
                        Image(systemName: item.icon)
                            .font(.subheadline)
                            .frame(width: 38, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.primary)
                    .accessibilityLabel(Text(item.label))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 38)
    }
}

extension KaPostsMarkdown.ToolbarAction: Identifiable {
    public var id: Self { self }
}
