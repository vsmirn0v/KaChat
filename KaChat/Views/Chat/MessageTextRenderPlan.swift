import Foundation

enum MessageTextRenderPlan {
    private final class BoolBox: NSObject {
        let value: Bool

        init(_ value: Bool) {
            self.value = value
        }
    }

    private static let linkTextViewCache: NSCache<NSString, BoolBox> = {
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
        guard let detector = SharedDetectors.link else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard range.length > 0 else { return false }

        var found = false
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, stop in
            guard let url = match?.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return
            }
            found = true
            stop.pointee = true
        }
        return found
    }
}
