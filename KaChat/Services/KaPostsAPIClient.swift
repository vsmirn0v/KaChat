import Foundation
import P256K

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

    /// One user's posts (by K pubkey).
    func fetchUserPosts(pubkey: String, limit: Int = 50, before: String? = nil) async throws -> (posts: [KPost], pagination: KPagination?) {
        var query = ["user": pubkey, "requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if let before { query["before"] = before }
        let response: PostsResponse = try await get("get-posts", query: query)
        return (Self.filterKaChat(response.posts), response.pagination)
    }

    /// Replies to a post. KaChat-filtered like everything else.
    func fetchReplies(postId: String, limit: Int = 100, before: String? = nil) async throws -> (posts: [KPost], pagination: KPagination?) {
        var query = ["post": postId, "requesterPubkey": try requesterPubkey(), "limit": "\(limit)"]
        if let before { query["before"] = before }
        let response: RepliesResponse = try await get("get-replies", query: query)
        return (Self.filterKaChat(response.replies), response.pagination)
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
