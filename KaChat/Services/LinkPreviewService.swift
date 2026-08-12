import Foundation

/// Open Graph metadata scraped from a message link, for rendering a rich preview card.
struct LinkPreviewData: Equatable {
    let url: URL
    let title: String?
    let description: String?
    let imageURLString: String?
    let siteName: String?
    /// Set only for Nextcloud public-share media links (see
    /// KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md): tells the card this link is directly
    /// viewable media and which kind, so tapping opens the in-app viewer instead of Safari.
    var nextcloudMedia: NextcloudMediaKind? = nil
    /// The share's raw-file `/download` URL (streams via range requests) — the viewer's source.
    var mediaDownloadURLString: String? = nil
    /// Content-Length from the type-detection HEAD — shown on attachment cards.
    var mediaByteSize: Int64? = nil
}

enum NextcloudMediaKind: String, Equatable {
    case image
    case video
    case audio
    case pdf
    /// Anything else (Office docs, archives, …) — rendered as an attachment card that opens
    /// in Nextcloud's own web viewer; no native inline rendering exists for these.
    case file
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
    private let maxImageBytes = 5_000_000

    /// Fetches a preview image's bytes using the same browser User-Agent as the scrape, plus a
    /// `Referer` (the page the image belongs to). Image CDNs like cdninstagram/fbcdn reject bare
    /// requests (no browser UA / no Referer) with a 403, which is why `AsyncImage` - which sends
    /// neither - silently failed for Instagram. Returns nil on any failure (card shows no image).
    /// `maxBytes` overrides the default 5 MB cap — the Nextcloud full-quality photo viewer
    /// passes a much higher limit since it deliberately fetches the original file.
    func imageData(_ url: URL, referer: URL, maxBytes: Int? = nil) async -> Data? {
        // First: browser UA (session default) + Referer. Fallback: Meta's crawler UA with no Referer -
        // some cdninstagram/fbcdn image URLs 403 the browser-UA/Referer combo but serve that crawler.
        if let data = await fetchImageBytes(url, userAgentOverride: nil, referer: referer, maxBytes: maxBytes) { return data }
        return await fetchImageBytes(url, userAgentOverride: Self.facebookExternalHitUserAgent, referer: nil, maxBytes: maxBytes)
    }

    private func fetchImageBytes(_ url: URL, userAgentOverride: String?, referer: URL?, maxBytes: Int? = nil) async -> Data? {
        var request = URLRequest(url: url)
        if let userAgentOverride { request.setValue(userAgentOverride, forHTTPHeaderField: "User-Agent") }
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        request.setValue("image/avif,image/webp,image/png,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= (maxBytes ?? maxImageBytes) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// A real desktop-browser User-Agent. A self-identifying bot UA (the old value) makes sites like
    /// Instagram serve a login/consent wall with no post-specific `og:image`; a browser UA gets the
    /// real page with usable Open Graph tags. Shared with the preview image loader so image CDNs
    /// (e.g. cdninstagram/fbcdn) that reject non-browser requests don't 403.
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Meta's own link-scraper User-Agent. Instagram/Facebook serve full Open Graph tags - including
    /// `og:image` - to this crawler, whereas a plain browser UA increasingly gets a login wall whose
    /// HTML has the page title/description but no post-specific image (why the preview showed text but
    /// no picture). Used for the scrape on Meta hosts, and as the image-load fallback everywhere.
    static let facebookExternalHitUserAgent = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"

    private static let metaScrapeHosts: Set<String> = [
        "instagram.com", "www.instagram.com", "m.instagram.com",
        "facebook.com", "www.facebook.com", "m.facebook.com", "fb.watch"
    ]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = fetchTimeout
        config.timeoutIntervalForResource = fetchTimeout
        config.httpAdditionalHeaders = [
            "User-Agent": Self.browserUserAgent,
            "Accept-Language": "en-US,en;q=0.9"
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

    /// Pre-seeds the cache with preview data the caller already knows to be true — the media
    /// send paths use this right after uploading, so the sender's own bubble renders instantly
    /// with zero network instead of waiting on the type probe.
    func seed(_ data: LinkPreviewData) {
        store(data, forKey: data.url.absoluteString)
    }

    func preview(for url: URL) async -> LinkPreviewData? {
        let key = url.absoluteString
        if let cached = cache[key] {
            AppLog.log("[LinkPreview] cache hit for %@ -> %@", key, cached == nil ? "no data" : "has data")
            return cached
        }
        // Failed share probes wait out the cooldown before re-hitting the server.
        if let failedAt = nextcloudFailureAt[key], Date().timeIntervalSince(failedAt) < nextcloudRetryCooldown {
            return nil
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

    /// Share URLs whose probe recently failed, with the failure time — retried after a
    /// cooldown rather than on every render. Unbounded caching of the failure would pin the
    /// message to a bare link forever; retrying every render hammers the server anonymously,
    /// which can trip Nextcloud's brute-force throttle and take ALL previews down with it.
    private var nextcloudFailureAt: [String: Date] = [:]
    private let nextcloudRetryCooldown: TimeInterval = 60

    private func store(_ value: LinkPreviewData?, forKey key: String) {
        if let url = URL(string: key), Self.nextcloudShareEndpoints(for: url) != nil {
            if value == nil {
                nextcloudFailureAt[key] = Date()
                return
            }
            nextcloudFailureAt.removeValue(forKey: key)
        }
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

    // MARK: - Nextcloud public shares (docs: KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md)

    struct NextcloudShareEndpoints: Equatable {
        let downloadURL: URL
        let previewURL: URL
    }

    /// `https://host/s/TOKEN` (or `/index.php/s/TOKEN`, token 10+ url-safe chars) -> the share's
    /// raw-file `/download` and thumbnail `/preview` endpoints; nil for any other URL.
    nonisolated static func nextcloudShareEndpoints(for url: URL) -> NextcloudShareEndpoints? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let path = url.path
        guard let regex = try? NSRegularExpression(pattern: #"^(/index\.php)?/s/([A-Za-z0-9_-]{10,})/?$"#) else { return nil }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, options: [], range: range),
              let tokenRange = Range(match.range(at: 2), in: path),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let prefix = match.range(at: 1).location != NSNotFound ? "/index.php" : ""
        components.path = "\(prefix)/s/\(path[tokenRange])"
        components.query = nil
        components.fragment = nil
        guard let base = components.url else { return nil }
        return NextcloudShareEndpoints(
            downloadURL: base.appendingPathComponent("download"),
            previewURL: base.appendingPathComponent("preview")
        )
    }

    /// The share link itself carries no file type, so `HEAD` the `/download` URL (native HTTP,
    /// no CORS constraints) and branch on `Content-Type`. Non-media shares return nil, which
    /// renders as a plain link. The card's poster is the share's `/preview` thumbnail; the
    /// full-quality fetch/stream only happens when the user taps the card.
    private func fetchNextcloudPreview(for url: URL, endpoints: NextcloudShareEndpoints) async -> LinkPreviewData? {
        do {
            // HEAD first (cheapest); some servers/reverse proxies reject HEAD on public
            // downloads, so fall back to a 2-byte ranged GET — either way we only need the
            // response headers, never the body.
            // A 2-byte ranged GET is the primary probe — universally supported and exactly one
            // round trip (HEAD-then-GET doubled the wait on servers that dislike HEAD). HEAD
            // remains as the rare fallback for servers that mishandle Range.
            var http: HTTPURLResponse?
            var rangeRequest = URLRequest(url: endpoints.downloadURL)
            rangeRequest.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            if let (_, rangeResponse) = try? await session.data(for: rangeRequest),
               let rangeHTTP = rangeResponse as? HTTPURLResponse, (200..<300).contains(rangeHTTP.statusCode) {
                http = rangeHTTP
            } else {
                var headRequest = URLRequest(url: endpoints.downloadURL)
                headRequest.httpMethod = "HEAD"
                let (_, headResponse) = try await session.data(for: headRequest)
                if let headHTTP = headResponse as? HTTPURLResponse, (200..<300).contains(headHTTP.statusCode) {
                    http = headHTTP
                }
            }
            guard let http else {
                AppLog.log("[LinkPreview] Nextcloud HEAD+ranged-GET both failed for %@", url.absoluteString)
                return nil
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let kind: NextcloudMediaKind
            if contentType.hasPrefix("image/") { kind = .image }
            else if contentType.hasPrefix("video/") { kind = .video }
            else if contentType.hasPrefix("audio/") { kind = .audio }
            else if contentType.contains("pdf") { kind = .pdf }
            else { kind = .file }
            let filename = Self.filename(fromContentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"))
            let fallbackTitle: String
            switch kind {
            case .image: fallbackTitle = "Photo"
            case .video: fallbackTitle = "Video"
            case .audio: fallbackTitle = "Audio"
            case .pdf: fallbackTitle = "PDF"
            case .file: fallbackTitle = "File"
            }
            // Via the ranged-GET fallback, Content-Length is the 2-byte slice — the real size
            // lives in Content-Range ("bytes 0-1/12345").
            let byteSize: Int64?
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
               let totalPart = contentRange.split(separator: "/").last, let total = Int64(totalPart) {
                byteSize = total
            } else {
                byteSize = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            }
            return LinkPreviewData(
                url: url,
                title: filename ?? fallbackTitle,
                description: nil,
                imageURLString: endpoints.previewURL.absoluteString,
                siteName: url.host.map { "Nextcloud · \($0)" } ?? "Nextcloud",
                nextcloudMedia: kind,
                mediaDownloadURLString: endpoints.downloadURL.absoluteString,
                mediaByteSize: byteSize
            )
        } catch {
            AppLog.log("[LinkPreview] Nextcloud HEAD failed for %@: %@", url.absoluteString, error.localizedDescription)
            return nil
        }
    }

    /// Pulls the shared file's name out of `Content-Disposition: attachment; filename="x.jpg"`
    /// (or the RFC 5987 `filename*=UTF-8''x.jpg` form) for the card title.
    private nonisolated static func filename(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        if let range = header.range(of: #"filename\*=UTF-8''([^;]+)"#, options: .regularExpression) {
            let raw = String(header[range]).replacingOccurrences(of: "filename*=UTF-8''", with: "")
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            return trimmed.removingPercentEncoding ?? trimmed
        }
        if let range = header.range(of: #"filename="([^"]+)""#, options: .regularExpression) {
            var raw = String(header[range]).replacingOccurrences(of: "filename=\"", with: "")
            if raw.hasSuffix("\"") { raw.removeLast() }
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    private func fetchPreview(for url: URL) async -> LinkPreviewData? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            AppLog.log("[LinkPreview] rejected non-http(s) scheme for %@", url.absoluteString)
            return nil
        }

        // Nextcloud public shares are media files, not pages — no Open Graph to scrape. Type
        // comes from a HEAD on the raw-file endpoint instead (see fetchNextcloudPreview).
        if let endpoints = Self.nextcloudShareEndpoints(for: url) {
            return await fetchNextcloudPreview(for: url, endpoints: endpoints)
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
            // Instagram/Facebook serve a login wall (title/description but no post `og:image`) to a
            // plain browser UA; their own crawler UA gets the full Open Graph including the image.
            if let host = url.host?.lowercased(), Self.metaScrapeHosts.contains(host) {
                request.setValue(Self.facebookExternalHitUserAgent, forHTTPHeaderField: "User-Agent")
            }

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
