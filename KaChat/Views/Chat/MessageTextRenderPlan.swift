import Foundation

enum MessageTextRenderPlan {
    private final class BoolBox: NSObject {
        let value: Bool

        init(_ value: Bool) {
            self.value = value
        }
    }

    private final class URLBox: NSObject {
        let value: URL?

        init(_ value: URL?) {
            self.value = value
        }
    }

    private static let linkTextViewCache: NSCache<NSString, BoolBox> = {
        let cache = NSCache<NSString, BoolBox>()
        cache.countLimit = 2_048
        return cache
    }()

    // `firstHTTPLink`/`isEntirelyLink` each run an `NSDataDetector` scan and are called directly
    // from `MessageBubbleView.body` (up to twice per row - once to decide if a message is a
    // bare link, again to place the preview card for a mixed text+link message), so they're
    // cached the same way `requiresLinkTextView` already is below.
    private static let firstLinkCache: NSCache<NSString, URLBox> = {
        let cache = NSCache<NSString, URLBox>()
        cache.countLimit = 2_048
        return cache
    }()

    private static let entirelyLinkCache: NSCache<NSString, BoolBox> = {
        let cache = NSCache<NSString, BoolBox>()
        cache.countLimit = 2_048
        return cache
    }()

    static func requiresLinkTextView(_ text: String) -> Bool {
        let key = text as NSString
        if let cached = linkTextViewCache.object(forKey: key) {
            return cached.value
        }

        let result = containsHTTPLink(text)
        linkTextViewCache.setObject(BoolBox(result), forKey: key)
        return result
    }

    private static func containsHTTPLink(_ text: String) -> Bool {
        firstHTTPLink(in: text) != nil
    }

    /// The first http(s) link detected in `text`, or nil - used to offer link actions (open/copy)
    /// alongside a message's other actions in a single unified menu.
    static func firstHTTPLink(in text: String) -> URL? {
        let key = text as NSString
        if let cached = firstLinkCache.object(forKey: key) {
            return cached.value
        }

        let result = uncachedFirstHTTPLink(in: text)
        firstLinkCache.setObject(URLBox(result), forKey: key)
        return result
    }

    private static func uncachedFirstHTTPLink(in text: String) -> URL? {
        guard let detector = SharedDetectors.link else { return nil }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard range.length > 0 else { return nil }

        var found: URL?
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let url = match?.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return
            }
            found = url
            stop.pointee = true
        }
        return found
    }

    /// True if `text`, once trimmed, consists of nothing but a single http(s) link - i.e. this
    /// message has no other content, so a rendered link-preview card can replace the plain-text
    /// bubble entirely (matching iMessage) instead of showing both.
    static func isEntirelyLink(_ text: String) -> Bool {
        let key = text as NSString
        if let cached = entirelyLinkCache.object(forKey: key) {
            return cached.value
        }

        let result = uncachedIsEntirelyLink(text)
        entirelyLinkCache.setObject(BoolBox(result), forKey: key)
        return result
    }

    private static func uncachedIsEntirelyLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let detector = SharedDetectors.link else { return false }
        let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: fullRange),
              let scheme = match.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSEqualRanges(match.range, fullRange)
    }
}
