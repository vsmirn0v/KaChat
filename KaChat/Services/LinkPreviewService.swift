import Foundation

/// Open Graph metadata scraped from a message link, for rendering a rich preview card.
struct LinkPreviewData: Equatable {
    let url: URL
    let title: String?
    let description: String?
    let imageURLString: String?
    let siteName: String?
}

/// Fetches Open Graph preview metadata for links sent in chat messages (private/group only -
/// broadcast rooms never call this). Each recipient's own device does this fetch when the message
/// renders, rather than the sender embedding preview data in the encrypted message payload, so
/// link previews never bloat the on-chain/indexer payload. Mirrors `KNSService`'s async-fetch
/// shape (`KNSService.swift` `fetchPrimaryNameResult`) and `MessageTextRenderPlan`'s `NSCache`
/// sizing convention (`countLimit = 2_048`).
actor LinkPreviewService {
    static let shared = LinkPreviewService()

    /// `nil` value = "fetched, but no preview data found" (still worth caching so a bad/plain link
    /// isn't refetched on every scroll). Bounded FIFO eviction, not LRU - simplicity over
    /// optimality for a cosmetic, cheap-to-refetch-on-relaunch cache.
    private var cache: [String: LinkPreviewData?] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 2_048

    /// In-flight fetches keyed by URL, so concurrent callers for the same not-yet-cached link
    /// (e.g. the message row and a re-render both mounting a `LinkPreviewCardView` for the same
    /// URL at once) await the *same* network request instead of each firing their own - avoids
    /// hammering a link's host with duplicate requests, which is a plausible way to trip a site's
    /// rate limiting.
    private var inFlight: [String: Task<LinkPreviewData?, Never>] = [:]

    private let fetchTimeout: TimeInterval = 8
    private let maxBodyBytes = 1_000_000

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = fetchTimeout
        config.timeoutIntervalForResource = fetchTimeout
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (compatible; KaChatLinkPreview/1.0)"
        ]
        return URLSession(configuration: config)
    }()

    private init() {}

    /// Non-actor-isolated mirror of `cache`, synchronously readable. Lets a view for an
    /// already-known URL initialize its `@State` with the final result on its very first render -
    /// zero async gap, so no late height change after the fact (the root cause of link previews
    /// disrupting scroll position when a row's height pops in after the fact).
    nonisolated func cachedResultIfKnown(for url: URL) -> LinkPreviewData?? {
        Self.syncCache.value(for: url.absoluteString)
    }

    private static let syncCache = SyncCacheMirror()

    func preview(for url: URL) async -> LinkPreviewData? {
        let key = url.absoluteString
        if let cached = cache[key] {
            AppLog.log("[LinkPreview] cache hit for %@ -> %@", key, cached == nil ? "no data" : "has data")
            return cached
        }

        if let existing = inFlight[key] {
            AppLog.log("[LinkPreview] joining in-flight fetch for %@", key)
            return await existing.value
        }

        AppLog.log("[LinkPreview] fetching %@", key)
        let task = Task<LinkPreviewData?, Never> { [weak self] in
            await self?.fetchPreview(for: url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        AppLog.log("[LinkPreview] result for %@ -> %@", key, result == nil ? "nil (no preview)" : "title=\(result?.title ?? "nil") image=\(result?.imageURLString ?? "nil")")
        store(result, forKey: key)
        return result
    }

    private func store(_ value: LinkPreviewData?, forKey key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = value
        if cacheOrder.count > cacheLimit, !cacheOrder.isEmpty {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        Self.syncCache.set(value, for: key)
    }

    private static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]

    private func fetchPreview(for url: URL) async -> LinkPreviewData? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            AppLog.log("[LinkPreview] rejected non-http(s) scheme for %@", url.absoluteString)
            return nil
        }

        // YouTube serves a cookie-consent-wall page (no Open Graph tags at all) to plain scraper
        // requests instead of the real video page - confirmed in testing: other sites (e.g.
        // Instagram) return usable og: tags via the generic path below, YouTube consistently
        // didn't. YouTube's own oEmbed endpoint is built exactly for this (no consent wall, no
        // API key needed) and is what most link-preview implementations use for YouTube URLs.
        if let host = url.host?.lowercased(), Self.youTubeHosts.contains(host) {
            if let oEmbedResult = await fetchYouTubeOEmbed(for: url) {
                return oEmbedResult
            }
            // Fall through to the generic scrape below only if oEmbed itself failed (e.g. a
            // private/deleted video) - unlikely to succeed either, but no harm trying.
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("text/html", forHTTPHeaderField: "Accept")

            // Simple whole-response fetch (matches KNSService's fetch pattern) rather than
            // streaming byte-by-byte - a `URLSession.AsyncBytes` loop reading up to a million
            // individual `UInt8` awaits turned out unreliable in practice (device-dependent
            // slowness compounding with the 8s timeout, silently yielding no preview far more
            // often than this simpler approach does). The size cap below is enforced by
            // truncating the *received* data instead of the *streamed* data - a materially
            // weaker DoS guard against a truly adversarial server, acceptable for previewing
            // links the user's own contacts sent.
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLog.log("[LinkPreview] non-HTTP response for %@", url.absoluteString)
                return nil
            }
            AppLog.log("[LinkPreview] HTTP %d, %d bytes for %@", httpResponse.statusCode, data.count, url.absoluteString)
            guard (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let capped = data.count > maxBodyBytes ? data.prefix(maxBodyBytes) : data
            guard let html = String(data: capped, encoding: .utf8) ?? String(data: capped, encoding: .isoLatin1) else {
                AppLog.log("[LinkPreview] could not decode response body as text for %@", url.absoluteString)
                return nil
            }

            return parse(html: html, url: url)
        } catch {
            AppLog.log("[LinkPreview] fetch failed for %@: %@", url.absoluteString, error.localizedDescription)
            return nil
        }
    }

    private struct YouTubeOEmbedResponse: Decodable {
        let title: String?
        let authorName: String?
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    private func fetchYouTubeOEmbed(for url: URL) async -> LinkPreviewData? {
        guard var components = URLComponents(string: "https://www.youtube.com/oembed") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let oEmbedURL = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: oEmbedURL)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            AppLog.log("[LinkPreview] YouTube oEmbed HTTP %d, %d bytes for %@", httpResponse.statusCode, data.count, url.absoluteString)
            guard (200..<300).contains(httpResponse.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data)
            guard decoded.title != nil || decoded.thumbnailURL != nil else { return nil }

            return LinkPreviewData(
                url: url,
                title: decoded.title,
                description: nil,
                imageURLString: decoded.thumbnailURL,
                siteName: "YouTube"
            )
        } catch {
            AppLog.log("[LinkPreview] YouTube oEmbed failed for %@: %@", url.absoluteString, error.localizedDescription)
            return nil
        }
    }

    private func parse(html: String, url: URL) -> LinkPreviewData? {
        let title = metaContent(property: "og:title", in: html) ?? titleTag(in: html)
        let description = metaContent(property: "og:description", in: html) ?? metaContent(name: "description", in: html)
        let imageURLString = metaContent(property: "og:image", in: html).map { resolveURLString($0, relativeTo: url) }
        let siteName = metaContent(property: "og:site_name", in: html) ?? url.host

        guard title != nil || description != nil || imageURLString != nil else {
            AppLog.log("[LinkPreview] no og: tags found in %d chars of HTML for %@", html.count, url.absoluteString)
            return nil
        }

        return LinkPreviewData(
            url: url,
            title: title?.htmlEntityDecoded,
            description: description?.htmlEntityDecoded,
            imageURLString: imageURLString,
            siteName: siteName
        )
    }

    /// Matches `<meta property="og:title" content="...">` in either attribute order, single or
    /// double quotes - real-world OG tags aren't consistent about ordering/quoting.
    private func metaContent(property: String, in html: String) -> String? {
        metaContent(attribute: "property", value: property, in: html)
    }

    private func metaContent(name: String, in html: String) -> String? {
        metaContent(attribute: "name", value: name, in: html)
    }

    private func metaContent(attribute: String, value: String, in html: String) -> String? {
        let escapedValue = NSRegularExpression.escapedPattern(for: value)
        let patterns = [
            #"<meta[^>]+\#(attribute)=["']\#(escapedValue)["'][^>]+content=["']([^"']*)["']"#,
            #"<meta[^>]+content=["']([^"']*)["'][^>]+\#(attribute)=["']\#(escapedValue)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let match = regex.firstMatch(in: html, options: [], range: range),
               let contentRange = Range(match.range(at: 1), in: html) {
                let raw = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            }
        }
        return nil
    }

    private func titleTag(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let contentRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private func resolveURLString(_ raw: String, relativeTo base: URL) -> String {
        guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL else {
            return raw
        }
        return resolved.absoluteString
    }
}

/// Thread-safe, non-actor-isolated cache mirror so `LinkPreviewCardView.init` can synchronously
/// check for an already-known result before the view's first render, without needing `await`.
private final class SyncCacheMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: LinkPreviewData?] = [:]

    /// Returns `nil` (outer) if the URL has never been resolved; `.some(nil)` if it resolved to
    /// "no preview data"; `.some(.some(data))` if it resolved to real preview data.
    func value(for key: String) -> LinkPreviewData?? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: LinkPreviewData?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }
}

private extension String {
    /// Handles the small set of entities that actually show up in OG titles/descriptions -
    /// no need for a full HTML-entity table for this cosmetic use.
    var htmlEntityDecoded: String {
        self
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
