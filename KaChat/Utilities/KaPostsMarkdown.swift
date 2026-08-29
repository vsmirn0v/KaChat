import Foundation

/// The formatting KaPosts understands, and the single place its rules are written down.
///
/// This is a deliberately SMALL subset - not CommonMark. Keep it byte-identical to the Android
/// parser (`KaPostsMarkdown.kt`); a post is written on one platform and read on the others, so a
/// rule that differs shows up as one reader seeing asterisks where another sees bold.
///
/// | Feature       | Syntax                          |
/// |---------------|---------------------------------|
/// | Bold          | `**text**`                      |
/// | Italic        | `*text*`                        |
/// | Underline     | `__text__`                      |
/// | Strikethrough | `~~text~~`                      |
/// | Subtext       | `-# text` (whole line)          |
/// | Ordered list  | `1. text` (whole line)          |
/// | Bullet list   | `* text` / `- text` (whole line)|
/// | Link          | `[label](url)`                  |
///
/// Deliberately ABSENT: headings and spoilers. Headings would let one post shout over a feed of
/// body text, and a spoiler needs a tap-to-reveal control that the plain-text bubble has nowhere
/// to put.
///
/// Two ambiguities the rules resolve, in this order:
///  - `__` is UNDERLINE here, not CommonMark's second spelling of bold. The table above is the
///    contract users are shown, so it wins.
///  - A line-leading `* ` is a bullet, never the start of italic; `-# ` is checked before `- `,
///    so a subtext line is not read as a bullet whose text begins with `#`.
///
/// The parser emits the text as it should READ (markers removed, `• ` and `1. ` prefixes
/// materialised) plus style spans addressed by character offset into that output, so callers can
/// run their existing URL/@mention linkifier over the same string and layer these on top.
enum KaPostsMarkdown {

    struct Style: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        /// Whole-line de-emphasis (`-# `), rendered smaller and secondary.
        var subtext = false
        /// Set for `[label](url)` spans; bare URLs are left to the caller's linkifier.
        var link: URL?

        static let plain = Style()
        var isPlain: Bool { self == .plain }
    }

    struct Span: Equatable {
        /// Character offsets into `Rendered.text`.
        let start: Int
        let end: Int
        let style: Style
    }

    struct Rendered: Equatable {
        let text: String
        let spans: [Span]
        /// True when the source actually contained formatting. Callers use it to skip the whole
        /// styling path for the overwhelmingly common plain post.
        var hasFormatting: Bool { !spans.isEmpty }
    }

    /// True if `source` contains anything this parser would style. Cheap enough to gate on.
    static func containsFormatting(_ source: String) -> Bool {
        render(source).hasFormatting
    }

    static func render(_ source: String) -> Rendered {
        var out = ""
        var spans: [Span] = []
        let lines = source.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 { out.append("\n") }
            renderLine(line, into: &out, spans: &spans)
        }
        return Rendered(text: out, spans: mergeAdjacent(spans))
    }

    // MARK: - Block level

    private static func renderLine(_ line: String, into out: inout String, spans: inout [Span]) {
        var content = Substring(line)
        var lineStyle = Style.plain
        var prefix = ""

        // Leading spaces are allowed before a marker so an indented list still reads as one.
        let indent = content.prefix { $0 == " " }
        let body = content.dropFirst(indent.count)

        if body.hasPrefix("-# ") {
            // Checked before the "- " bullet, or "-# x" would become a bullet reading "# x".
            lineStyle.subtext = true
            content = body.dropFirst(3)
            prefix = String(indent)
        } else if body.hasPrefix("* ") || body.hasPrefix("- ") {
            content = body.dropFirst(2)
            prefix = String(indent) + "\u{2022} "
        } else if let marker = orderedMarker(of: body) {
            content = body.dropFirst(marker.consumed)
            prefix = String(indent) + "\(marker.number). "
        }

        out.append(prefix)
        let lineStart = out.count
        parseInline(Array(content), style: lineStyle, into: &out, spans: &spans)
        // The bullet/number prefix carries the line's own style too, so a subtext line is
        // uniformly small rather than starting at body size.
        if lineStyle != .plain, !prefix.isEmpty {
            spans.append(Span(start: lineStart - prefix.count, end: lineStart, style: lineStyle))
        }
    }

    /// `12. ` at the start of a line: the number and how many characters it consumed.
    private static func orderedMarker(of line: Substring) -> (number: Int, consumed: Int)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". "), let number = Int(digits) else { return nil }
        return (number, digits.count + 2)
    }

    // MARK: - Inline level

    /// Delimiters, longest first: `**` must be tried before `*`, or bold would parse as an italic
    /// run whose text starts with `*`.
    private static let inlineDelimiters: [(marker: String, apply: (inout Style) -> Void)] = [
        ("**", { $0.bold = true }),
        ("__", { $0.underline = true }),
        ("~~", { $0.strikethrough = true }),
        ("*", { $0.italic = true }),
    ]

    private static func parseInline(
        _ chars: [Character],
        style: Style,
        into out: inout String,
        spans: inout [Span]
    ) {
        var i = 0
        var runStart = out.count

        func flushPlainRun() {
            guard !style.isPlain, out.count > runStart else { return }
            spans.append(Span(start: runStart, end: out.count, style: style))
        }

        while i < chars.count {
            if let link = matchLink(chars, at: i) {
                flushPlainRun()
                var linkStyle = style
                linkStyle.link = link.url
                parseInline(Array(link.label), style: linkStyle, into: &out, spans: &spans)
                i = link.next
                runStart = out.count
                continue
            }
            if let emphasis = matchEmphasis(chars, at: i) {
                flushPlainRun()
                var inner = style
                emphasis.apply(&inner)
                parseInline(Array(emphasis.content), style: inner, into: &out, spans: &spans)
                i = emphasis.next
                runStart = out.count
                continue
            }
            out.append(chars[i])
            i += 1
        }
        flushPlainRun()
    }

    /// `[label](url)` at `i`. The URL must parse and carry a scheme we are willing to open, so a
    /// post cannot dress `javascript:` up as friendly link text.
    private static func matchLink(
        _ chars: [Character],
        at i: Int
    ) -> (label: String, url: URL, next: Int)? {
        guard chars[i] == "[" else { return nil }
        guard let labelEnd = index(of: "]", in: chars, from: i + 1), labelEnd > i + 1 else { return nil }
        guard labelEnd + 1 < chars.count, chars[labelEnd + 1] == "(" else { return nil }
        guard let urlEnd = index(of: ")", in: chars, from: labelEnd + 2), urlEnd > labelEnd + 2 else { return nil }

        let label = String(chars[(i + 1)..<labelEnd])
        let rawTarget = String(chars[(labelEnd + 2)..<urlEnd]).trimmingCharacters(in: .whitespaces)
        guard let url = resolveLinkTarget(rawTarget) else { return nil }
        return (label, url, urlEnd + 1)
    }

    /// Schemes a post is allowed to send a reader to.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "kachat"]

    /// Turns a link target into a URL we are willing to open, or nil.
    ///
    /// The scheme is decided BEFORE anything is prepended. An earlier version prepended `https://`
    /// to any target without `://` and then checked the scheme, which meant `javascript:alert(1)`
    /// became `https://javascript:alert(1)` and sailed through the allowlist - the check was
    /// inspecting a string it had just rewritten. Anything that already names a scheme must name
    /// an allowed one; only a genuinely bare host gets https assumed for it.
    static func resolveLinkTarget(_ raw: String) -> URL? {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty,
              !target.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 } == true })
        else { return nil }

        // Scheme-relative ("//host/path") keeps its host and just gains https.
        if target.hasPrefix("//") {
            return URL(string: "https:" + target)
        }
        if let schemeEnd = target.firstIndex(of: ":"),
           schemeEnd > target.startIndex,
           target[target.startIndex..<schemeEnd].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
           target[target.startIndex].isLetter {
            let scheme = target[target.startIndex..<schemeEnd].lowercased()
            guard allowedLinkSchemes.contains(scheme) else { return nil }
            return URL(string: target)
        }
        // No scheme at all: a bare host, which is the common case in a social post.
        return URL(string: "https://" + target)
    }

    /// An emphasis run opening at `i`, or nil. Requires a closing marker on the same line with at
    /// least one character between: `****` and a lone `*` stay literal text.
    private static func matchEmphasis(
        _ chars: [Character],
        at i: Int
    ) -> (content: String, apply: (inout Style) -> Void, next: Int)? {
        for (marker, apply) in inlineDelimiters {
            let markerChars = Array(marker)
            guard startsWith(chars, at: i, markerChars) else { continue }
            let contentStart = i + markerChars.count
            // An opening marker followed by whitespace is almost always literal punctuation
            // ("2 * 3 = 6"), not formatting.
            guard contentStart < chars.count, !chars[contentStart].isWhitespace else { continue }
            var j = contentStart
            while j < chars.count {
                if startsWith(chars, at: j, markerChars) {
                    guard j > contentStart else { break }
                    return (String(chars[contentStart..<j]), apply, j + markerChars.count)
                }
                j += 1
            }
        }
        return nil
    }

    private static func startsWith(_ chars: [Character], at i: Int, _ marker: [Character]) -> Bool {
        guard i + marker.count <= chars.count else { return false }
        for (offset, character) in marker.enumerated() where chars[i + offset] != character {
            return false
        }
        return true
    }

    private static func index(of character: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == character { return i }
            i += 1
        }
        return nil
    }

    /// Collapses spans that touch and share a style, so a bold run split by a nested parse does
    /// not become several attribute runs.
    private static func mergeAdjacent(_ spans: [Span]) -> [Span] {
        guard spans.count > 1 else { return spans }
        let sorted = spans.sorted { $0.start < $1.start }
        var merged: [Span] = []
        for span in sorted {
            if let last = merged.last, last.end == span.start, last.style == span.style {
                merged[merged.count - 1] = Span(start: last.start, end: span.end, style: span.style)
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

// MARK: - Toolbar edits

/// What the composer's formatting buttons do to the text.
///
/// Kept beside the parser, and mirrored exactly in `KaPostsMarkdown.kt`, because these are the
/// rules that decide what gets WRITTEN - a platform that wraps a selection differently produces
/// posts the other platform renders differently.
///
/// Every action toggles: applying it to text that already has that formatting removes it, which
/// is what a person expects from a Bold button and what stops a double tap producing `****text****`.
extension KaPostsMarkdown {

    enum ToolbarAction: CaseIterable {
        case bold, italic, underline, strikethrough
        case bulletList, numberedList, subtext, link
    }

    /// Text plus where the selection should sit afterwards, both in character offsets.
    struct Edit: Equatable {
        let text: String
        let selectionStart: Int
        let selectionEnd: Int
    }

    /// Placeholder inserted when a link is added with nothing selected, and the target that is
    /// pre-selected so typing replaces it.
    static let linkLabelPlaceholder = "link text"
    static let linkTargetPlaceholder = "https://"

    static func inlineMarker(for action: ToolbarAction) -> String? {
        switch action {
        case .bold: return "**"
        case .italic: return "*"
        case .underline: return "__"
        case .strikethrough: return "~~"
        default: return nil
        }
    }

    private static func linePrefix(for action: ToolbarAction) -> String? {
        switch action {
        case .bulletList: return "* "
        case .subtext: return "-# "
        default: return nil
        }
    }

    static func apply(
        _ action: ToolbarAction,
        to text: String,
        selectionStart: Int,
        selectionEnd: Int
    ) -> Edit {
        let chars = Array(text)
        let start = max(0, min(selectionStart, chars.count))
        let end = max(start, min(selectionEnd, chars.count))
        if action == .link {
            return applyLink(chars, start: start, end: end)
        }
        if let marker = inlineMarker(for: action) {
            return applyInline(marker, chars, start: start, end: end)
        }
        return applyLine(action, chars, start: start, end: end)
    }

    // MARK: Inline

    private static func applyInline(
        _ marker: String,
        _ chars: [Character],
        start: Int,
        end: Int
    ) -> Edit {
        let markerChars = Array(marker)
        let width = markerChars.count

        // Already wrapped, either inside the selection ("**bold**" highlighted) or just outside it
        // ("bold" highlighted between the markers). Both read as "this is bold" to the user, so
        // both unwrap.
        if end - start >= 2 * width,
           slice(chars, start, start + width) == marker,
           slice(chars, end - width, end) == marker {
            let inner = Array(chars[(start + width)..<(end - width)])
            let result = Array(chars[0..<start]) + inner + Array(chars[end...])
            return Edit(text: String(result), selectionStart: start, selectionEnd: start + inner.count)
        }
        if start >= width, end + width <= chars.count,
           slice(chars, start - width, start) == marker,
           slice(chars, end, end + width) == marker {
            let inner = Array(chars[start..<end])
            let result = Array(chars[0..<(start - width)]) + inner + Array(chars[(end + width)...])
            return Edit(
                text: String(result),
                selectionStart: start - width,
                selectionEnd: start - width + inner.count
            )
        }

        let inner = Array(chars[start..<end])
        let result = Array(chars[0..<start]) + markerChars + inner + markerChars + Array(chars[end...])
        // Nothing selected: leave the caret between the markers, ready to type.
        let caret = start + width
        return Edit(
            text: String(result),
            selectionStart: caret,
            selectionEnd: inner.isEmpty ? caret : caret + inner.count
        )
    }

    // MARK: Line

    /// Applies a line prefix to every line the selection touches, toggling off when they all
    /// already have it. Numbered lists renumber from 1 so a re-ordered selection stays sane.
    private static func applyLine(
        _ action: ToolbarAction,
        _ chars: [Character],
        start: Int,
        end: Int
    ) -> Edit {
        let lineStart = lineStartIndex(chars, before: start)
        let lineEnd = lineEndIndex(chars, after: end)
        let block = String(chars[lineStart..<lineEnd])
        let lines = block.components(separatedBy: "\n")

        let stripped = lines.map(stripLineMarkers)
        let alreadyApplied = lines.allSatisfy { hasMarker(action, $0) } && !lines.isEmpty
        let rebuilt: [String]
        if alreadyApplied {
            rebuilt = stripped
        } else if action == .numberedList {
            rebuilt = stripped.enumerated().map { index, line in "\(index + 1). \(line)" }
        } else if let prefix = linePrefix(for: action) {
            rebuilt = stripped.map { prefix + $0 }
        } else {
            rebuilt = stripped
        }

        let replacement = rebuilt.joined(separator: "\n")
        let result = String(chars[0..<lineStart]) + replacement + String(chars[lineEnd...])
        return Edit(
            text: result,
            selectionStart: lineStart,
            selectionEnd: lineStart + Array(replacement).count
        )
    }

    private static func hasMarker(_ action: ToolbarAction, _ line: String) -> Bool {
        let trimmed = Substring(line).drop { $0 == " " }
        switch action {
        case .bulletList: return trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ")
        case .subtext: return trimmed.hasPrefix("-# ")
        case .numberedList: return orderedMarker(of: trimmed) != nil
        default: return false
        }
    }

    /// Removes whichever block marker a line already carries, so switching a bullet to a number
    /// does not leave "1. * item".
    private static func stripLineMarkers(_ line: String) -> String {
        let body = Substring(line).drop { $0 == " " }
        if body.hasPrefix("-# ") { return String(body.dropFirst(3)) }
        if body.hasPrefix("* ") || body.hasPrefix("- ") { return String(body.dropFirst(2)) }
        if let marker = orderedMarker(of: body) { return String(body.dropFirst(marker.consumed)) }
        return String(body)
    }

    private static func lineStartIndex(_ chars: [Character], before index: Int) -> Int {
        var i = min(index, chars.count)
        while i > 0, chars[i - 1] != "\n" { i -= 1 }
        return i
    }

    private static func lineEndIndex(_ chars: [Character], after index: Int) -> Int {
        var i = min(index, chars.count)
        while i < chars.count, chars[i] != "\n" { i += 1 }
        return i
    }

    // MARK: Link

    private static func applyLink(_ chars: [Character], start: Int, end: Int) -> Edit {
        let selected = String(chars[start..<end])
        let label = selected.isEmpty ? linkLabelPlaceholder : selected
        let inserted = "[\(label)](\(linkTargetPlaceholder))"
        let result = String(chars[0..<start]) + inserted + String(chars[end...])
        // Pre-select the part the user has to replace: the target when they highlighted their own
        // label, the label when they highlighted nothing.
        if selected.isEmpty {
            return Edit(
                text: result,
                selectionStart: start + 1,
                selectionEnd: start + 1 + Array(label).count
            )
        }
        let targetStart = start + 1 + Array(label).count + 2
        return Edit(
            text: result,
            selectionStart: targetStart,
            selectionEnd: targetStart + Array(linkTargetPlaceholder).count
        )
    }

    private static func slice(_ chars: [Character], _ from: Int, _ to: Int) -> String {
        guard from >= 0, to <= chars.count, from < to else { return "" }
        return String(chars[from..<to])
    }
}
