import Foundation
import P256K
import UIKit
import UserNotifications

/// REST client for the K social-network indexer (Settings > Connection Settings > KaPost
/// Indexer URL, default mainnet.kaspatalk.net) - the read side of KaPosts wiring.
///
/// Division of responsibilities (deliberate):
/// - The K indexer supplies SOCIAL data only: posts, replies, votes, follows, counts.
/// - KNS supplies ALL identity: names/avatars/profiles. Responses' `userNickname` /
///   `userProfileImage` fields are ignored entirely - a poster's identity is derived by mapping
///   their pubkey to a Kaspa address and resolving through the app's existing KNS/contacts chain.
/// - Writes never touch this API: every K action is an on-chain Kaspa self-send transaction
///   whose payload the indexer ingests from the chain (Phase B - see KaPostsProtocol notes).
///
/// EXCLUSIVITY: KaPosts is KaChat-only. KaChat-authored posts carry an invisible marker
/// (word-joiner) prefixed to the message content, and every feed read here filters to marked
/// posts - so K-website content never appears in KaPosts. (Full two-way exclusivity - K users
/// not seeing KaChat posts - requires running our own indexer fork later.)
@MainActor
final class KaPostsAPIClient: ObservableObject {
    static let shared = KaPostsAPIClient()
    private init() {}

    // MARK: - KaChat exclusivity marker

    /// U+2060 WORD JOINER: invisible everywhere, survives base64 round-trips, and comes back in
    /// `postContent` so feeds can filter on it (the raw tx payload is NOT exposed by the API,
    /// which is why the marker must live inside the message itself).
    static let kaChatMarker = "\u{2060}"

    static func isKaChatContent(_ text: String) -> Bool {
        text.hasPrefix(kaChatMarker)
    }

    static func stripMarker(_ text: String) -> String {
        text.hasPrefix(kaChatMarker) ? String(text.dropFirst(kaChatMarker.count)) : text
    }

    // MARK: - Errors

    enum KaPostsAPIError: LocalizedError {
        case badURL
        case api(code: String, message: String)
        case badResponse
        case missingWallet

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid KaPost indexer URL"
            case .api(_, let message): return message
            case .badResponse: return "Unexpected response from the KaPost indexer"
            case .missingWallet: return "No active wallet"
            }
        }
    }

    // MARK: - Wire models (verbatim K field names; identity fields deliberately ignored)

    /// Embedded reference the indexer attaches to quote posts - the quoted post's id, content
    /// and author, so feeds can render the quote card without a second fetch.
    struct KQuoteRef: Decodable {
        let referencedContentId: String?
        let referencedMessage: String?
        let referencedSenderPubkey: String?

        var decodedMessage: String? {
            guard let referencedMessage,
                  let data = Data(base64Encoded: referencedMessage),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
    }

    struct KPost: Decodable {
        let id: String
        let userPublicKey: String
        let postContent: String
        let timestamp: Int64
        let repliesCount: Int?
        let quotesCount: Int?
        let upVotesCount: Int?
        let downVotesCount: Int?
        let parentPostId: String?
        let mentionedPubkeys: [String]?
        let isUpvoted: Bool?
        let isDownvoted: Bool?
        let blockedUser: Bool?
        let contentType: String?
        let isQuote: Bool?
        let quote: KQuoteRef?

        /// Base64 -> plain text (K encodes all content fields).
        var decodedContent: String? {
            guard let data = Data(base64Encoded: postContent),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
    }

    struct KPagination: Decodable {
        let hasMore: Bool
        let nextCursor: String?
        let prevCursor: String?
    }

    private struct PostsResponse: Decodable {
        let posts: [KPost]
        let pagination: KPagination?
    }

    private struct RepliesResponse: Decodable {
        let replies: [KPost]
        let pagination: KPagination?
    }

    struct KNotification: Decodable {
        let id: String
        let userPublicKey: String
        let postContent: String?
        let timestamp: Int64
        let contentType: String?
        let voteType: String?
        let contentId: String?

        var decodedContent: String? {
            guard let postContent, let data = Data(base64Encoded: postContent),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
    }

    private struct NotificationsResponse: Decodable {
        let notifications: [KNotification]
        /// Present on the K webserver's paginated notifications response; optional so older
        /// deployments (no pagination block) simply read as "one page, no more".
        let pagination: KPagination?
    }

    /// One actor row from get-post-engagement (KaChat indexer fork): who did what to a post,
    /// with the ACTION's txid for explorer deep-links.
    struct KEngagementEntry: Decodable {
        let actorPubkey: String
        let actionTxId: String
        let timestamp: Int64
        let kind: String    // upvote | downvote | repost | quote
    }

    private struct EngagementResponse: Decodable {
        let engagement: [KEngagementEntry]
        let pagination: KPagination?
    }

    struct KFollowUser: Decodable, Identifiable {
        let userPublicKey: String
        let timestamp: Int64?
        var id: String { userPublicKey }
    }

    /// The users-list endpoints wrap their items under "posts" (verified live) - keep the other
    /// plausible keys as fallbacks in case deployments differ.
    private struct FollowListResponse: Decodable {
        let posts: [KFollowUser]?
        let users: [KFollowUser]?
        let following: [KFollowUser]?
        let followers: [KFollowUser]?
        let pagination: KPagination?
        var items: [KFollowUser] { posts ?? users ?? following ?? followers ?? [] }
    }

    struct KUserDetails: Decodable {
        let userPublicKey: String?
        let followersCount: Int?
        let followingCount: Int?
        let followedUser: Bool?
    }

    private struct APIErrorBody: Decodable {
        let error: String
        let code: String
    }

    // MARK: - Requester identity (own compressed pubkey, derived once per wallet)

    private var cachedRequesterPubkey: String?
    private var cachedRequesterAddress: String?

    /// K identifies users by 66-hex COMPRESSED secp256k1 pubkey. The wallet stores x-only, so
    /// derive compressed from the private key and cache per wallet address.
    func requesterPubkey() throws -> String {
        guard let wallet = WalletManager.shared.currentWallet else { throw KaPostsAPIError.missingWallet }
        if let cached = cachedRequesterPubkey, cachedRequesterAddress == wallet.publicAddress {
            return cached
        }
        guard let privateKeyData = WalletManager.shared.getPrivateKey() else {
            throw KaPostsAPIError.missingWallet
        }
        let signingKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyData)
        // P256K Schnorr public keys expose the x-only bytes; compressed = parity prefix + x.
        // Recover the full compressed form via the ECDSA key view of the same scalar.
        let ecdsaKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKeyData, format: .compressed)
        let compressed = ecdsaKey.publicKey.dataRepresentation.hexString
        _ = signingKey // same scalar; kept for clarity that Schnorr signing uses this key later
        cachedRequesterPubkey = compressed
        cachedRequesterAddress = wallet.publicAddress
        return compressed
    }

    // MARK: - Identity mapping (K pubkey -> Kaspa address, so KNS owns display)

    /// Compressed (02/03 + x) or raw x-only pubkey hex -> Kaspa address for the current network.
    /// This is THE bridge that keeps identity in KNS: every K pubkey is mapped to an address and
    /// then resolved through the app's normal contacts/KNS chain.
    static func kaspaAddress(fromPubkey pubkeyHex: String) -> String? {
        guard let raw = Data(hexString: pubkeyHex) else { return nil }
        let xOnly: Data
        if raw.count == 33 {
            xOnly = raw.dropFirst()
        } else if raw.count == 32 {
            xOnly = raw
        } else {
            return nil
        }
        let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
        return KaspaAddress(hrp: hrp, type: .pubKey, payload: xOnly).address
    }

    // MARK: - Requests

    private func baseURL() throws -> URL {
        let raw = AppSettings.load().kaPostIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw.isEmpty ? AppSettings.defaultKaPostIndexerURL : raw) else {
            throw KaPostsAPIError.badURL
        }
        return url
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: try baseURL().appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw KaPostsAPIError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KaPostsAPIError.badResponse }
        guard http.statusCode == 200 else {
            if let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
                throw KaPostsAPIError.api(code: body.code, message: body.error)
            }
            throw KaPostsAPIError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Reads (KaChat-filtered)

    /// Global feed (K "watching" = all posts). Filtered to KaChat-marked posts.
    func fetchGlobalFeed(limit: Int = 50, before: String? = nil) async throws -> (posts: [KPost], pagination: KPagination?) {
        var query = ["requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if let before { query["before"] = before }
        let response: PostsResponse = try await get("get-posts-watching", query: query)
        return (Self.filterKaChat(response.posts), response.pagination)
    }

    /// Content (posts+replies+quotes) from accounts the requester follows on K.
    func fetchFollowingFeed(limit: Int = 50, before: String? = nil) async throws -> (posts: [KPost], pagination: KPagination?) {
        var query = ["requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if let before { query["before"] = before }
        let response: PostsResponse = try await get("get-contents-following", query: query)
        // Top-level content only in the feed - replies live under their post's thread.
        return (Self.filterKaChat(response.posts).filter { ($0.contentType ?? "post") != "reply" }, response.pagination)
    }

    /// One user's posts (by K pubkey). NOTE: the deployed indexer ignores includeReplies
    /// (get-posts serves content_type post/quote only) - use fetchUserReplies for replies.
    func fetchUserPosts(pubkey: String, limit: Int = 50, before: String? = nil, includeReplies: Bool = false) async throws -> (posts: [KPost], pagination: KPagination?) {
        var query = ["user": pubkey, "requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if includeReplies { query["includeReplies"] = "true" }
        if let before { query["before"] = before }
        let response: PostsResponse = try await get("get-posts", query: query)
        return (Self.filterKaChat(response.posts), response.pagination)
    }

    /// One user's replies across ALL threads: get-replies with `user` instead of `post`
    /// (verified live). The indexer's get-posts only serves content_type post/quote and
    /// ignores includeReplies, so the profile Replies tab must read this endpoint.
    /// Items carry parentPostId. KaChat-filtered like everything else.
    func fetchUserReplies(pubkey: String, limit: Int = 50, before: String? = nil) async throws -> (posts: [KPost], pagination: KPagination?) {
        var query = ["user": pubkey, "requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if let before { query["before"] = before }
        let response: RepliesResponse = try await get("get-replies", query: query)
        return (Self.filterKaChat(response.replies), response.pagination)
    }

    /// Replies to a post. KaChat-filtered like everything else.
    func fetchReplies(postId: String, limit: Int = 100, before: String? = nil) async throws -> (posts: [KPost], pagination: KPagination?) {
        var query = ["post": postId, "requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if let before { query["before"] = before }
        let response: RepliesResponse = try await get("get-replies", query: query)
        return (Self.filterKaChat(response.replies), response.pagination)
    }

    /// The requester's notification stream - votes/replies/quotes on OUR content. This is the
    /// only documented source of per-action actor identity + action txid (the notification id),
    /// which is why the engagement screen can list actors for your own posts only.
    func fetchNotifications(limit: Int = 100, before: String? = nil) async throws -> (notifications: [KNotification], pagination: KPagination?) {
        var query = ["requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if let before { query["before"] = before }
        let response: NotificationsResponse = try await get("get-notifications", query: query)
        return (response.notifications, response.pagination)
    }

    /// Per-post actor lists from the KaChat indexer fork - works for ANY post, unlike the
    /// notifications stream (own posts only).
    func fetchPostEngagement(postId: String, type: String = "all", limit: Int = 100, before: String? = nil) async throws -> (entries: [KEngagementEntry], pagination: KPagination?) {
        var query = [
            "postId": postId,
            "type": type,
            "requesterPubkey": try requesterPubkey(),
            "limit": "\(limit)"
        ]
        if let before { query["before"] = before }
        let response: EngagementResponse = try await get("get-post-engagement", query: query)
        return (response.engagement, response.pagination)
    }

    /// Who `pubkey` follows (followers=false) or who follows them (followers=true).
    func fetchFollowList(ofPubkey pubkey: String, followers: Bool, limit: Int = 100, before: String? = nil) async throws -> (users: [KFollowUser], pagination: KPagination?) {
        let path = followers ? "get-users-followers" : "get-users-following"
        var query = [
            "requesterPubkey": try requesterPubkey(),
            "userPubkey": pubkey,
            "limit": "\(limit)"
        ]
        if let before { query["before"] = before }
        let response: FollowListResponse = try await get(path, query: query)
        return (response.items, response.pagination)
    }

    /// Follower/following counts etc. for an address's K identity.
    func fetchUserDetails(pubkey: String) async throws -> KUserDetails {
        try await get("get-user-details", query: ["user": pubkey, "requesterPubkey": try requesterPubkey()])
    }

    /// KaChat-only filter: keep posts whose decoded content carries the invisible marker, and
    /// drop content the indexer masked for blocked users.
    private static func filterKaChat(_ posts: [KPost]) -> [KPost] {
        posts.filter { post in
            guard post.blockedUser != true, let content = post.decodedContent else { return false }
            return isKaChatContent(content)
        }
    }
}


// MARK: - Endless-scroll driver (server cursors + client-filter shrinkage)

/// Shared pagination engine for every KaPosts list.
///
/// The problem it solves: KaPosts filters everything the indexer returns down to KaChat-marked
/// content and then drops muted/blocked authors, so a server page of 50 can collapse to 2
/// visible rows. A naive one-request-per-scroll pager would stall on those pages and look
/// broken. `collect` therefore keeps following the server's `nextCursor` until it has
/// accumulated `target` rows that actually survive filtering, the server says there is nothing
/// left, or it hits `maxRequests` (so a single scroll trigger can never hammer the indexer).
///
/// Cursors are the server's own opaque `pagination.nextCursor` values - no client-side offset
/// math anywhere. A missing/empty cursor, or `hasMore == false`, means the surface is exhausted;
/// endpoints on older deployments that return no pagination block degrade to a single page.
@MainActor
enum KaPostsPaginator {
    /// Server page size. The indexer caps `limit` at 100 on every endpoint.
    /// (`nonisolated` so the tuning constants can be used as default arguments, which are
    /// evaluated outside the enum's main-actor isolation.)
    nonisolated static let pageSize = 50
    /// How many post-filter rows one scroll trigger tries to add.
    nonisolated static let targetNewRows = 18
    /// Hard cap on requests per trigger.
    nonisolated static let maxRequestsPerTrigger = 5

    /// Everything a surface needs to append a page and update its own paging state.
    /// `Row` is the VIEW's model (already mapped), not the wire type.
    struct Batch<Row> {
        /// Rows that survived mapping + filtering + dedup, in server order.
        var items: [Row] = []
        /// Cursor to pass as `before` on the NEXT trigger (nil once exhausted).
        var cursor: String?
        var hasMore = false
        var requests = 0
        /// True when the loop burned its whole request budget and NOTHING survived filtering.
        /// The surface then shows an explicit "Load more" instead of auto-firing again, so a
        /// heavily-filtered stretch of history can't turn into an API hammer loop. (A partial
        /// batch - some rows, just fewer than `target` - is progress, so it keeps auto-loading.)
        var stalled = false
    }

    /// - Parameters:
    ///   - startCursor: `nil` for a first page / refresh, otherwise the surface's stored cursor.
    ///   - fetch: performs ONE request for the given cursor and page size.
    ///   - keep: maps + filters a server page down to the rows the surface will actually show
    ///     (dedup by id belongs here - the server can repeat items across pages).
    static func collect<Item, Row>(
        from startCursor: String?,
        pageSize: Int = pageSize,
        target: Int = targetNewRows,
        maxRequests: Int = maxRequestsPerTrigger,
        fetch: (_ before: String?, _ limit: Int) async throws -> (items: [Item], pagination: KaPostsAPIClient.KPagination?),
        keep: ([Item]) -> [Row]
    ) async throws -> Batch<Row> {
        var batch = Batch<Row>(cursor: startCursor, hasMore: true)
        while batch.requests < maxRequests {
            let page = try await fetch(batch.cursor, pageSize)
            batch.requests += 1
            batch.items.append(contentsOf: keep(page.items))
            guard let pagination = page.pagination,
                  pagination.hasMore,
                  let next = pagination.nextCursor, !next.isEmpty else {
                // End of the line: no cursor to continue with.
                batch.cursor = nil
                batch.hasMore = false
                return batch
            }
            batch.cursor = next
            if batch.items.count >= target { return batch }
            if Task.isCancelled { return batch }
        }
        batch.stalled = batch.items.isEmpty
        return batch
    }
}


// MARK: - K protocol writes (Phase B: on-chain self-send transactions)

/// Builds K protocol payloads exactly as the indexer's parser/verifier expects
/// (K-transaction-processor/k_protocol.rs). Every write is a colon-delimited payload on a Kaspa
/// self-send transaction; the signature is Kaspa personal-message signing
/// (schnorr(blake2b256(key: "PersonalMessageSigningHash", msg))) over the action's canonical
/// field string - the app's WalletManager.signArbitraryMessage(.kaspaPersonalMessage) scheme.
enum KaPostsProtocol {
    // `kchat:` migration: KaPosts now writes the `kchat:1:<action>:` root (was `k:1:`). Reads come
    // pre-parsed from the K indexer (dual-reads server-side), so only the write shape changes.
    static let prefix = "kchat:1:"

    static func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    // Signed strings (canonical field joins, verified server-side):
    static func postSigningString(b64Message: String, mentionsJSON: String) -> String {
        "\(b64Message):\(mentionsJSON)"
    }
    static func replySigningString(postId: String, b64Message: String, mentionsJSON: String) -> String {
        "\(postId):\(b64Message):\(mentionsJSON)"
    }
    static func voteSigningString(postId: String, vote: String, authorPubkey: String) -> String {
        "\(postId):\(vote):\(authorPubkey)"
    }
    static func followSigningString(action: String, followedPubkey: String) -> String {
        "\(action):\(followedPubkey)"
    }
    static func quoteSigningString(contentId: String, b64Message: String, quotedAuthorPubkey: String) -> String {
        "\(contentId):\(b64Message):\(quotedAuthorPubkey)"
    }
    static func unquoteSigningString(contentId: String) -> String {
        contentId
    }

    // Full payloads:
    static func postPayload(pubkey: String, signature: String, b64Message: String, mentionsJSON: String) -> String {
        "\(prefix)post:\(pubkey):\(signature):\(b64Message):\(mentionsJSON)"
    }
    static func replyPayload(pubkey: String, signature: String, postId: String, b64Message: String, mentionsJSON: String) -> String {
        "\(prefix)reply:\(pubkey):\(signature):\(postId):\(b64Message):\(mentionsJSON)"
    }
    static func votePayload(pubkey: String, signature: String, postId: String, vote: String, authorPubkey: String) -> String {
        "\(prefix)vote:\(pubkey):\(signature):\(postId):\(vote):\(authorPubkey)"
    }
    static func followPayload(pubkey: String, signature: String, action: String, followedPubkey: String) -> String {
        "\(prefix)follow:\(pubkey):\(signature):\(action):\(followedPubkey)"
    }
    static func quotePayload(pubkey: String, signature: String, contentId: String, b64Message: String, quotedAuthorPubkey: String) -> String {
        "\(prefix)quote:\(pubkey):\(signature):\(contentId):\(b64Message):\(quotedAuthorPubkey)"
    }
    static func unquotePayload(pubkey: String, signature: String, contentId: String) -> String {
        "\(prefix)unquote:\(pubkey):\(signature):\(contentId)"
    }
}

extension KaPostsAPIClient {
    /// Publishes a KaChat post on-chain. The KaChat exclusivity marker is prepended INSIDE the
    /// message (the only channel the read API surfaces). Returns the transaction id = post id.
    func submitPost(text: String, mentionedPubkeys: [String] = []) async throws -> String {
        let marked = Self.kaChatMarker + text
        let b64 = KaPostsProtocol.b64(marked)
        let pubkey = try requesterPubkey()
        // Client-resolved @mentions: dedupe, drop bad shapes and self, then serialize into the
        // signed mentioned_pubkeys array. The indexer turns each into a `mention` notification.
        let me = pubkey.lowercased()
        let clean = Array(Set(mentionedPubkeys
            .map { $0.lowercased() }
            .filter { $0.range(of: "^0[23][0-9a-f]{64}$", options: .regularExpression) != nil && $0 != me }))
        let mentions = "[" + clean.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let signature = try WalletManager.shared.signArbitraryMessage(
            KaPostsProtocol.postSigningString(b64Message: b64, mentionsJSON: mentions),
            mode: .kaspaPersonalMessage
        )
        return try await submitPayloadTx(
            KaPostsProtocol.postPayload(pubkey: pubkey, signature: signature, b64Message: b64, mentionsJSON: mentions)
        )
    }

    /// The compressed KaPost pubkey (even-Y convention) for a Kaspa address, or nil. The whole
    /// KaChat/Kasia stack is address-derived, so this mirrors desktop's kapostPubkeyForAddress and
    /// lets us fill mentioned_pubkeys from a KNS-domain contact's address alone.
    static func kapostPubkey(fromAddress address: String) -> String? {
        guard let xOnly = KaspaAddress.publicKey(from: address), xOnly.count == 32 else { return nil }
        return "02" + xOnly.hexString
    }

    /// Replies to a post (its K txid). mentioned_pubkeys carries the parent author (the spec's
    /// reply-notification hook) PLUS any @mentions the comment text resolved to - same dedupe/
    /// validate/self-drop rules as submitPost, so @someone works in comments exactly like in
    /// top-level posts.
    func submitReply(text: String, postId: String, parentAuthorPubkey: String?, mentionedPubkeys: [String] = []) async throws -> String {
        let marked = Self.kaChatMarker + text
        let b64 = KaPostsProtocol.b64(marked)
        let pubkey = try requesterPubkey()
        let me = pubkey.lowercased()
        var seen = Set<String>()
        let clean = ([parentAuthorPubkey].compactMap { $0 } + mentionedPubkeys)
            .map { $0.lowercased() }
            .filter { $0.range(of: "^0[23][0-9a-f]{64}$", options: .regularExpression) != nil && $0 != me && seen.insert($0).inserted }
        let mentions = "[" + clean.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let signature = try WalletManager.shared.signArbitraryMessage(
            KaPostsProtocol.replySigningString(postId: postId, b64Message: b64, mentionsJSON: mentions),
            mode: .kaspaPersonalMessage
        )
        return try await submitPayloadTx(
            KaPostsProtocol.replyPayload(pubkey: pubkey, signature: signature, postId: postId, b64Message: b64, mentionsJSON: mentions)
        )
    }

    /// Casts an upvote/downvote on a post. (K has no un-vote action in the spec - local unlike
    /// stays client-side only for now.)
    func submitVote(postId: String, upvote: Bool, authorPubkey: String) async throws -> String {
        try await submitVoteAction(postId: postId, vote: upvote ? "upvote" : "downvote", authorPubkey: authorPubkey)
    }

    /// Removal counter-action (KaChat indexer fork): withdraws our existing up/down vote on a
    /// post. The chain keeps both transactions; the indexer's interpretation nets them out.
    func submitUnvote(postId: String, authorPubkey: String) async throws -> String {
        try await submitVoteAction(postId: postId, vote: "unvote", authorPubkey: authorPubkey)
    }

    private func submitVoteAction(postId: String, vote: String, authorPubkey: String) async throws -> String {
        let pubkey = try requesterPubkey()
        let signature = try WalletManager.shared.signArbitraryMessage(
            KaPostsProtocol.voteSigningString(postId: postId, vote: vote, authorPubkey: authorPubkey),
            mode: .kaspaPersonalMessage
        )
        return try await submitPayloadTx(
            KaPostsProtocol.votePayload(pubkey: pubkey, signature: signature, postId: postId, vote: vote, authorPubkey: authorPubkey)
        )
    }

    /// Removal counter-action: withdraws our quote/repost of `contentId` (the quoted post's
    /// id, same field meaning as in the quote payload).
    func submitUnquote(contentId: String) async throws -> String {
        let pubkey = try requesterPubkey()
        let signature = try WalletManager.shared.signArbitraryMessage(
            KaPostsProtocol.unquoteSigningString(contentId: contentId),
            mode: .kaspaPersonalMessage
        )
        return try await submitPayloadTx(
            KaPostsProtocol.unquotePayload(pubkey: pubkey, signature: signature, contentId: contentId)
        )
    }

    /// Follows/unfollows a K identity (66-hex compressed pubkey - only available from post data,
    /// which is why profile-sheet follows without a pubkey stay local-only).
    func submitFollow(_ follow: Bool, followedPubkey: String) async throws -> String {
        let action = follow ? "follow" : "unfollow"
        let pubkey = try requesterPubkey()
        let signature = try WalletManager.shared.signArbitraryMessage(
            KaPostsProtocol.followSigningString(action: action, followedPubkey: followedPubkey),
            mode: .kaspaPersonalMessage
        )
        return try await submitPayloadTx(
            KaPostsProtocol.followPayload(pubkey: pubkey, signature: signature, action: action, followedPubkey: followedPubkey)
        )
    }

    /// Quotes a post - K's repost mechanism (there is no separate repost action; quotesCount is
    /// the live counter). A PLAIN repost is a quote whose message is just the KaChat marker; a
    /// quote-with-commentary carries marker + text.
    func submitQuote(text: String?, contentId: String, quotedAuthorPubkey: String) async throws -> String {
        let marked = Self.kaChatMarker + (text ?? "")
        let b64 = KaPostsProtocol.b64(marked)
        let pubkey = try requesterPubkey()
        let signature = try WalletManager.shared.signArbitraryMessage(
            KaPostsProtocol.quoteSigningString(contentId: contentId, b64Message: b64, quotedAuthorPubkey: quotedAuthorPubkey),
            mode: .kaspaPersonalMessage
        )
        return try await submitPayloadTx(
            KaPostsProtocol.quotePayload(pubkey: pubkey, signature: signature, contentId: contentId, b64Message: b64, quotedAuthorPubkey: quotedAuthorPubkey)
        )
    }

    /// Live fee estimate for a post of `text` - builds the exact payload shape (dummy sig/pubkey
    /// of the real fixed lengths, marker included) so the size-driven estimate matches what the
    /// actual submit will pay with the typical single input.
    static func estimatePostFee(text: String) -> UInt64? {
        guard let wallet = WalletManager.shared.currentWallet,
              let script = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else { return nil }
        let b64 = KaPostsProtocol.b64(kaChatMarker + text)
        let dummySignature = String(repeating: "0", count: 128)
        let dummyPubkey = String(repeating: "0", count: 66)
        let payload = KaPostsProtocol.postPayload(
            pubkey: dummyPubkey, signature: dummySignature, b64Message: b64, mentionsJSON: "[]"
        )
        return KasiaTransactionBuilder.estimateContextualMessageFee(
            payload: Data(payload.utf8), inputCount: 1, senderScriptPubKey: script
        )
    }

    /// Shared write core: build the self-send tx from the chatting address's UTXOs with the K
    /// payload attached, sign, submit. The indexer ingests it from the chain (no REST submit).
    private func submitPayloadTx(_ payload: String) async throws -> String {
        guard let wallet = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KaPostsAPIError.missingWallet
        }
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([wallet.publicAddress])
        let signedTx = try KasiaTransactionBuilder.buildPayloadSelfSendTx(
            from: wallet.publicAddress,
            senderPrivateKey: privateKey,
            utxos: utxos,
            payload: Data(payload.utf8)
        )
        let (txId, _) = try await NodePoolService.shared.submitTransaction(signedTx, allowOrphan: false)
        AppLog.log("[KaPosts] Submitted %@ action tx %@", String(payload.prefix(12)), String(txId.prefix(12)))
        // Refresh the wallet balance so the header updates live with the fee just spent - once
        // immediately, once after the UTXO change settles (Kaspa blocks are ~1s, so the second
        // pass reliably catches it).
        Task { @MainActor in
            _ = try? await WalletManager.shared.refreshBalance()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = try? await WalletManager.shared.refreshBalance()
        }
        return txId
    }
}


// MARK: - KaPosts local notification pings

/// In-app notification pings for KaPosts, mirroring how 1:1/group chats notify: while the app
/// is running it polls the indexer's notification stream (30s) and posts local iOS
/// notifications for new actions on your content ("alice liked your post"). Needs no indexer
/// changes; push while the app is CLOSED arrives with the KaChat-owned indexer fork
/// (KAPOSTS_INDEXER.md).
///
/// This poller is THE foreground banner source for KaPosts: `AppDelegate.willPresent` drops
/// remote kaposts pushes while the app is active and this poller is running, because only
/// this side knows the per-type Settings toggles (the push payload carries no action type).
/// The displayed-action ledger below dedupes across the two sources at their boundary.
@MainActor
final class KaPostsNotificationService {
    static let shared = KaPostsNotificationService()

    private var pollTask: Task<Void, Never>?
    private static let pollIntervalNanos: UInt64 = 30 * 1_000_000_000

    /// True while the poll loop is alive - `AppDelegate.willPresent` consults this: with the
    /// poller running it is the foreground banner source and kaposts pushes are dropped; with
    /// it stopped (in-app browser powers it down) the push presents instead, matching the
    /// browser's "closed-app path" design.
    var isPolling: Bool { pollTask != nil }

    /// True while KaPostsNotificationsView is on screen - mirrors the open-conversation rule:
    /// no banner for the very stream the user is looking at (set from that view's
    /// onAppear/onDisappear; consulted by `AppDelegate.willPresent`).
    var isNotificationsScreenVisible = false

    private init() {}

    // MARK: Displayed-action ledger (App Group)

    /// Ledger of KaPosts ACTION txids already shown as a banner, by EITHER source: this
    /// poller's local banners (claimed before posting) or a remote push `willPresent`
    /// presented / the user tapped. The kaposts push carries no `tx_id` in userInfo, but its
    /// `apns-collapse-id` IS the action's txid (PUSH_EXTENSIONS.md) and iOS surfaces that as
    /// `UNNotificationRequest.identifier` - the stable key both sides share. Bounded FIFO,
    /// mirroring `ChatService.localPostedTxIdsKey`.
    ///
    /// Residual race this cannot close: a push delivered while BACKGROUNDED never passes
    /// through willPresent, so it is only recorded when tapped or while it still sits in
    /// Notification Center (pollOnce checks deliveredNotifications). A background push the
    /// user swipe-dismissed can therefore re-banner on the next foreground poll.
    private static let displayedActionIdsKey = "kaposts_displayed_action_ids"

    func hasDisplayed(actionId: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.com.kachat.app") else { return false }
        return (defaults.stringArray(forKey: Self.displayedActionIdsKey) ?? []).contains(actionId)
    }

    func recordDisplayed(actionId: String) {
        guard let defaults = UserDefaults(suiteName: "group.com.kachat.app") else { return }
        var displayed = defaults.stringArray(forKey: Self.displayedActionIdsKey) ?? []
        guard !displayed.contains(actionId) else { return }
        displayed.append(actionId)
        if displayed.count > 300 { displayed.removeFirst(displayed.count - 300) }
        defaults.set(displayed, forKey: Self.displayedActionIdsKey)
    }

    /// Last notification timestamp already surfaced (banner or Notifications screen), per
    /// wallet - anything at or before this never pings.
    private var lastSeenKey: String? {
        guard let address = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return "kaposts_notifications_last_seen_\(address)"
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The Notifications screen calls this with the newest timestamp it displayed - what the
    /// user has seen on screen shouldn't ping later.
    func markSeen(upTo timestamp: Int64) {
        ChatService.clearDeliveredNotifications(threadIdentifier: "kaposts")
        guard let key = lastSeenKey else { return }
        let current = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value ?? 0
        if timestamp > current {
            UserDefaults.standard.set(NSNumber(value: timestamp), forKey: key)
        }
    }

    private func pollOnce() async {
        let settings = AppSettings.load()
        guard WalletManager.shared.currentWallet != nil,
              let key = lastSeenKey else { return }
        // Child Mode removes KaPosts entirely - no notification pings for it either.
        guard !settings.childModeEnabled else { return }
        do {
            let notifications = try await KaPostsAPIClient.shared.fetchNotifications(limit: 50).notifications
            // Single fetch, two consumers: the bell center ingests EVERY page (it has its own
            // baseline and ignores the OS-ping gates below) — it used to run a second,
            // duplicate 90s poll of this same endpoint in parallel.
            await GlobalNotificationCenter.shared.ingestKaPostsNotifications(notifications)
            // OS banner gates apply only from here down. Remote-push mode: the push service
            // delivers KaPosts pings (registered via kaposts_pubkey) while the app is
            // backgrounded or closed - local pings there would double-notify, mirroring the
            // broadcast guard. While the app is ACTIVE this poll is the notification source
            // whatever the mode (AppDelegate.willPresent drops REMOTE kaposts pushes while
            // this poller is running - the poller's own local banners present).
            guard settings.notificationsEnabled else { return }
            if settings.notificationMode == .remotePush,
               UIApplication.shared.applicationState != .active { return }
            guard let newest = notifications.map(\.timestamp).max() else { return }
            guard let lastSeen = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value else {
                // First run for this wallet: baseline silently instead of replaying history.
                UserDefaults.standard.set(NSNumber(value: newest), forKey: key)
                return
            }
            // Per-type toggles (Settings > Notifications > KaPosts): disabled kinds are
            // dropped HERE, after lastSeen already advanced past them above - silently
            // skipped for good, never queued to ping later, and never eating a slot in the
            // burst cap below.
            let fresh = notifications.filter {
                $0.timestamp > lastSeen &&
                settings.shouldNotifyKaPostsAction(contentType: $0.contentType, voteType: $0.voteType)
            }
            guard !fresh.isEmpty else {
                UserDefaults.standard.set(NSNumber(value: max(newest, lastSeen)), forKey: key)
                return
            }
            UserDefaults.standard.set(NSNumber(value: max(newest, lastSeen)), forKey: key)
            // Actions a remote push already bannered must not banner again: the ledger holds
            // ids willPresent presented or the user tapped, and deliveredNotifications covers
            // pushes delivered while backgrounded that still sit in Notification Center
            // (their request identifier is the apns-collapse-id, i.e. the action's txid).
            // Those get recorded into the ledger too, so clearing the center later doesn't
            // resurrect them.
            let deliveredIds = Set(
                await UNUserNotificationCenter.current().deliveredNotifications()
                    .filter { $0.request.content.threadIdentifier == "kaposts" }
                    .map(\.request.identifier)
            )
            // Oldest first so banners arrive in order; cap a burst so a viral post doesn't
            // fire fifty banners at once.
            for notification in fresh.sorted(by: { $0.timestamp < $1.timestamp }).suffix(5) {
                if deliveredIds.contains(notification.id) {
                    recordDisplayed(actionId: notification.id)
                    continue
                }
                guard !hasDisplayed(actionId: notification.id) else { continue }
                // Claim BEFORE posting so a racing push in willPresent sees it.
                recordDisplayed(actionId: notification.id)
                await postLocal(notification)
            }
        } catch {
            AppLog.log("[KaPosts] Notification poll failed: %@", error.localizedDescription)
        }
    }

    private func postLocal(_ notification: KaPostsAPIClient.KNotification) async {
        guard let address = KaPostsAPIClient.kaspaAddress(fromPubkey: notification.userPublicKey),
              address != WalletManager.shared.currentWallet?.publicAddress,
              !KaPostsModerationStore.shared.isHidden(address) else { return }

        let text = KaPostsAPIClient.stripMarker(notification.decodedContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let action: String
        switch notification.contentType {
        case "vote": action = notification.voteType == "downvote" ? "disliked your post" : "liked your post"
        case "reply": action = "replied to your post"
        case "quote": action = text.isEmpty ? "reposted your post" : "quoted your post"
        case "follow": action = "followed you"
        case "mention": action = "mentioned you in a post"
        default: action = "interacted with your post"
        }

        let content = UNMutableNotificationContent()
        content.title = "KaPosts"
        content.body = "\(await actorName(for: address)) \(action)" + (text.isEmpty ? "" : ": \(text)")
        content.sound = .default
        content.threadIdentifier = "kaposts"
        // A tap deep-opens the exact post/comment (KaChatApp reads userInfo["postId"]).
        // Per-kind target rule matches the in-app notifications sheet: reply/quote-with-text
        // open the reply itself; vote/mention open the containing post.
        let targetTxId: String?
        switch notification.contentType {
        case "reply": targetTxId = notification.id
        case "quote": targetTxId = text.isEmpty ? notification.contentId : notification.id
        case "follow": targetTxId = nil
        // A mention's acting content IS the post/comment mentioning you — fall back to the
        // notification's own txid when contentId is empty, else the tap has no target.
        case "mention": targetTxId = (notification.contentId?.isEmpty == false) ? notification.contentId : notification.id
        default: targetTxId = notification.contentId
        }
        if let targetTxId, !targetTxId.isEmpty {
            content.userInfo = ["postId": targetTxId]
        }

        let request = UNNotificationRequest(
            identifier: "kaposts-\(notification.id)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppLog.log("[KaPosts] Failed to post local notification: %@", error.localizedDescription)
        }
    }

    /// Contact alias > KNS primary domain (fetched when not cached) > shortened address, .kas
    /// stripped - the same identity chain as everywhere else in KaPosts.
    private func actorName(for address: String) async -> String {
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(alias)
        }
        if KNSService.shared.profileCache[address] == nil {
            _ = await KNSService.shared.fetchProfile(for: address)
        }
        if let domain = KNSService.shared.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }
}
