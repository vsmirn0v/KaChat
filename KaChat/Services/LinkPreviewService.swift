import Foundation

// MARK: - Internal KaChat links

/// A link that points back INSIDE KaChat rather than out at the web. Recognized anywhere a
/// message body is rendered so it previews as a native in-app card and opens the target screen
/// on tap, instead of leaving the app (or, for the universal-link form, being scraped over the
/// network like any stranger's URL - see `LinkPreviewService`).
///
/// Wire contract, shared with the Android client (both platforms emit AND accept both forms):
///
/// | Target         | Custom scheme                  | Universal link                                    |
/// |----------------|--------------------------------|---------------------------------------------------|
/// | KaPosts post   | `kachat://kapost/<txid>`       | `https://kachat.duckdns.org/post/<txid>`          |
/// | Broadcast room | `kachat://broadcast/<channel>` | `https://kachat.duckdns.org/broadcast/<channel>`  |
///
/// `<channel>` is the NORMALIZED room name with no leading `#` (see `BroadcastChannelName`).
/// Everything a pasted link carries is attacker-controlled, so `parse` re-validates the channel
/// name from scratch (`normalizeAndValidateChannel`) rather than trusting the URL's text - a
/// malformed or hostile name is rejected outright, never joined.
enum KaChatInternalLink: Equatable {
    case kaPost(txId: String)
    case broadcastRoom(channel: String)

    /// The universal-link host. With the app installed iOS routes these into
    /// `KaChatApp.handleIncomingURL`; without it, the domain 302s to the App Store.
    static let universalLinkHost = "kachat.duckdns.org"

    /// The form the share sheets emit, matching KaPosts' existing share text (`KaPostsView`).
    var shareLinkString: String {
        switch self {
        case .kaPost(let txId): return "kachat://kapost/\(txId)"
        case .broadcastRoom(let channel): return "kachat://broadcast/\(channel)"
        }
    }

    /// The https twin of `shareLinkString` - survives apps that strip unknown schemes, and
    /// falls back to the web/App Store for people who don't have KaChat installed.
    var universalLinkString: String {
        switch self {
        case .kaPost(let txId): return "https://\(Self.universalLinkHost)/post/\(txId)"
        case .broadcastRoom(let channel): return "https://\(Self.universalLinkHost)/broadcast/\(channel)"
        }
    }

    /// The share sheet's text for a broadcast-room invite - one human line, then BOTH accepted
    /// link forms. Shape mirrors KaPosts' existing post-share text (`KaPostsView.shareText`).
    /// Single definition so the room screen's Share button and the list row's share menu can't
    /// drift apart.
    static func broadcastRoomShareText(channel: String) -> String {
        // Through the same gate an INCOMING link goes through, so a share can never emit a link
        // this app would refuse to open (and a stray leading "#" is stripped, not doubled).
        let normalized = normalizeAndValidateChannel(channel) ?? BroadcastChannelName.normalize(channel)
        let link = KaChatInternalLink.broadcastRoom(channel: normalized)
        return """
        Join #\(normalized) on KaChat.

        Open in KaChat: \(link.shareLinkString)
        Or: \(link.universalLinkString)
        """
    }

    // MARK: Parsing

    /// Both link forms -> a validated target, or nil for anything else (including a
    /// well-formed-looking link whose payload fails validation).
    static func parse(_ url: URL) -> KaChatInternalLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        // `pathComponents` percent-decodes for us, and drops the leading "/" marker below.
        let parts = url.pathComponents.filter { $0 != "/" }
        switch scheme {
        case "kachat":
            // kachat://<target>/<payload> - exactly one payload component, so a link with extra
            // path segments (kachat://broadcast/a/b) is rejected rather than silently truncated.
            guard let host = url.host?.lowercased(), parts.count == 1, let payload = parts.first else { return nil }
            switch host {
            case "kapost": return kaPostLink(rawTxId: payload)
            case "broadcast": return broadcastLink(rawChannel: payload)
            default: return nil
            }
        case "http", "https":
            var host = url.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            guard host == universalLinkHost, parts.count == 2 else { return nil }
            switch parts[0].lowercased() {
            case "post": return kaPostLink(rawTxId: parts[1])
            case "broadcast": return broadcastLink(rawChannel: parts[1])
            default: return nil
            }
        default:
            return nil
        }
    }

    /// A KaPosts id is a Kaspa transaction id (hex), but the id charset is the indexer's to
    /// define, so this stays deliberately tolerant: alphanumerics plus `-`/`_` only, bounded
    /// length. That is strict enough to rule out path traversal, embedded schemes and query
    /// smuggling while never rejecting a legitimate id.
    private static func kaPostLink(rawTxId: String) -> KaChatInternalLink? {
        let id = rawTxId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 8, id.count <= 128 else { return nil }
        guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return .kaPost(txId: id)
    }

    private static func broadcastLink(rawChannel: String) -> KaChatInternalLink? {
        guard let channel = normalizeAndValidateChannel(rawChannel) else { return nil }
        return .broadcastRoom(channel: channel)
    }

    /// The single gate every pasted/scanned room name passes through before it can be joined or
    /// opened. Beyond `BroadcastChannelName`'s own rules (non-empty, <= 36 chars, no whitespace,
    /// no colon) this rejects:
    /// - URL-structural characters (`/ \ ? # % @`), which can only come from a malformed link;
    /// - `..`, so no path-traversal-looking name ever reaches the store's file/key paths;
    /// - control characters and Unicode bidi/zero-width formatting, the classic way to make a
    ///   room invite *render* as a different room than the one it actually joins.
    /// A leading `#` is tolerated and stripped (people paste "#kaspa"), matching the contract's
    /// "normalized channel name with no leading #".
    static func normalizeAndValidateChannel(_ rawChannel: String) -> String? {
        var raw = rawChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasPrefix("#") { raw.removeFirst() }
        let normalized = BroadcastChannelName.normalize(raw)
        guard BroadcastChannelName.isValid(normalized) else { return nil }
        guard !normalized.contains("..") else { return nil }
        let structural: Set<Character> = ["/", "\\", "?", "#", "%", "@", "\"", "'", "<", ">"]
        guard !normalized.contains(where: { structural.contains($0) }) else { return nil }
        guard !normalized.unicodeScalars.contains(where: isDisallowedScalar) else { return nil }
        return normalized
    }

    private static func isDisallowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
            return true
        }
        switch scalar.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    // MARK: Detection inside message text

    /// One internal link found inside a message body.
    struct Match: Equatable {
        let link: KaChatInternalLink
        let url: URL
        /// The exact substring matched, so the caller can tell "the message IS this link" from
        /// "the message mentions this link".
        let matchedText: String
        /// True when the trimmed message consists of nothing but this link - the card then
        /// replaces the text bubble entirely (matching how a bare http link already renders).
        let coversWholeMessage: Bool
    }

    /// Both link forms, anywhere in free text. `NSDataDetector` (what `MessageTextRenderPlan`
    /// uses) only ever yields http(s) URLs, so the `kachat://` form needs its own scan; the
    /// universal form is matched here too so it is claimed as INTERNAL before the generic
    /// preview path can fetch it over the network.
    private static let pattern =
        #"(?:kachat://(?:kapost|broadcast)/|https?://(?:www\.)?kachat\.duckdns\.org/(?:post|broadcast)/)[^\s<>"']+"#

    private static let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)

    /// Trailing prose punctuation is not part of the link ("... open kachat://broadcast/kaspa.").
    private static let trailingTrim = CharacterSet(charactersIn: ".,;:!?)]}'\"")

    private final class MatchBox: NSObject {
        let value: Match?
        init(_ value: Match?) { self.value = value }
    }

    /// Same caching convention (and reason) as `MessageTextRenderPlan.firstLinkCache`: this runs
    /// from message-row bodies, several times per row per frame while scrolling.
    private static let matchCache: NSCache<NSString, MatchBox> = {
        let cache = NSCache<NSString, MatchBox>()
        cache.countLimit = 2_048
        return cache
    }()

    static func match(in text: String) -> Match? {
        let key = text as NSString
        if let cached = matchCache.object(forKey: key) { return cached.value }
        let result = uncachedMatch(in: text)
        matchCache.setObject(MatchBox(result), forKey: key)
        return result
    }

    private static func uncachedMatch(in text: String) -> Match? {
        // Cheap bail-out before paying for the regex: neither form can appear without one of
        // these two literals, and the overwhelming majority of messages contain neither.
        let lowered = text.lowercased()
        guard lowered.contains("kachat://") || lowered.contains(universalLinkHost) else { return nil }
        guard let regex else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: Match?
        regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
            guard let result else { return }
            var candidate = ns.substring(with: result.range)
            while let last = candidate.unicodeScalars.last, trailingTrim.contains(last) {
                candidate.removeLast()
            }
            guard let url = URL(string: candidate), let link = parse(url) else { return }
            found = Match(
                link: link,
                url: url,
                matchedText: candidate,
                coversWholeMessage: text.trimmingCharacters(in: .whitespacesAndNewlines) == candidate
            )
            stop.pointee = true
        }
        return found
    }
}

/// The author and text behind a `kachat://kapost/<txid>` link, so a shared post previews in a
/// chat as the post itself rather than as a URL.
///
/// Resolved from the transaction the post IS. The K indexer has no single-post lookup
/// (`get-post?id=` is still listed as NEEDED in KAPOSTS_INDEXER.md), and a post someone shares
/// is usually outside the feed window, so the API cannot answer for it at all. The chain always
/// can: the post id is the transaction id, and the payload holds the same bytes the indexer
/// read. See `KaPostsProtocol.parseChainPayload`. The author's name then comes from the KNS
/// profile cache every other KaPosts surface fills.
///
/// An earlier version of this type was a cache with a `record` hand-off for posts already on
/// screen, and nothing ever called it - so every one of these cards read "KaPosts post / Tap to
/// open this post in KaChat", forever. One resolution path now, and it answers for any post.
///
/// This is the one internal link that goes to the network, and it goes to Kaspa's own REST API
/// with a transaction id - never to the link's host. A pasted KaChat link is still never scraped
/// like a stranger's URL (see `KaChatInternalLink`).
@MainActor
final class KaPostLinkPreviewCache: ObservableObject {
    static let shared = KaPostLinkPreviewCache()

    struct Entry: Equatable {
        /// KNS domain, contact alias, or shortened address of the poster.
        let authorName: String?
        let authorAddress: String?
        /// The author's KNS avatar, once their profile has been fetched.
        let authorAvatarURL: String?
        /// Already trimmed to a card-sized snippet. Empty for a comment-free quote.
        let snippet: String
        /// "post", "reply" or "quote" - the card says which.
        let action: String
    }

    /// Bounded FIFO eviction, matching `LinkPreviewService`'s cache convention.
    @Published private(set) var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    /// Ids the chain had nothing for. Retrying on every scroll would hammer the REST API for a
    /// post that is never going to resolve (a mistyped link, a pruned node, another app's tx).
    private var unresolvable: Set<String> = []
    private let limit = 512
    private static let snippetMaxLength = 240

    private init() {}

    func entry(for postId: String) -> Entry? { entries[postId] }

    /// Resolves a post id that nothing has recorded. Safe to call on every render: an entry
    /// already held, a fetch already running and an id already known to be unresolvable all
    /// return immediately.
    func load(postId: String) async {
        guard !postId.isEmpty, entries[postId] == nil,
              !inFlight.contains(postId), !unresolvable.contains(postId) else { return }
        // Child Mode hides KaPosts entirely, and the router no-ops these links - so there is
        // nothing to preview, and no reason to spend a request finding out.
        guard !AppSettings.load().childModeEnabled else { return }
        inFlight.insert(postId)
        defer { inFlight.remove(postId) }

        guard let record = await KaPostChainReader.fetch(txId: postId) else {
            unresolvable.insert(postId)
            return
        }
        let address = KaPostsAPIClient.kaspaAddress(fromPubkey: record.authorPubkey)
        // Paint the post immediately with whatever name is already known, then upgrade it if the
        // author has a KNS domain nobody has looked up yet. The text is the point of the card;
        // holding it back for a name lookup would leave the URL sitting there for another
        // round trip.
        store(postId: postId, entry: Entry(
            authorName: Self.knownName(for: address),
            authorAddress: address,
            authorAvatarURL: address.flatMap { KNSService.shared.profileCache[$0]?.avatarURL },
            snippet: Self.snippet(from: record.message),
            action: record.action
        ))
        guard let address, !address.isEmpty, KNSService.shared.profileCache[address] == nil else { return }
        _ = await KNSService.shared.fetchProfile(for: address)
        guard let current = entries[postId] else { return }
        store(postId: postId, entry: Entry(
            authorName: Self.knownName(for: address),
            authorAddress: address,
            authorAvatarURL: KNSService.shared.profileCache[address]?.avatarURL,
            snippet: current.snippet,
            action: current.action
        ))
    }

    private func store(postId: String, entry: Entry) {
        if entries[postId] == nil {
            order.append(postId)
            if order.count > limit, !order.isEmpty {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        entries[postId] = entry
    }

    /// The same name KaPosts itself shows: a contact alias first, then the KNS domain, then the
    /// tail of the address.
    private static func knownName(for address: String?) -> String? {
        guard let address, !address.isEmpty else { return nil }
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(alias)
        }
        if let domain = KNSService.shared.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    private static func snippet(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > snippetMaxLength
            ? String(trimmed.prefix(snippetMaxLength)) + "\u{2026}"
            : trimmed
    }

}

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

/// Fetches Open Graph preview metadata for links sent in chat messages. Auto-fetch on render is
/// gated by sender trust (see `LinkPreviewCardView.autoFetch`): accepted 1:1 contacts and group
/// chats fetch automatically; non-accepted senders and broadcast rooms fetch only when the user
/// taps the placeholder card. Each recipient's own device does this fetch when the message
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
