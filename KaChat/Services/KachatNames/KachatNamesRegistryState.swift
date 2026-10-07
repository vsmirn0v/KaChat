import Foundation

/// The `.kachat` registry as data: what a name, gap or offer looks like to the screens, the status
/// rule, the label rule, the address profile record, and the registry walker's state with its
/// transition decoder - a port of the kachat-domains CLI's `registry.rs` (`Registry::apply`,
/// KACHAT_NAMES_INDEXER.md B3). Pure Foundation: no network, no keys, no UI, so it is tested
/// standalone (`scripts/test_kachat_names_registry.swift`).
extension KachatNames {

    // MARK: - Status (KACHAT_NAMES_INDEXER.md B5)

    enum Status: String, Codable, Equatable {
        /// `now < expiresAt`: resolves, everything works.
        case active
        /// `expiresAt <= now < expiresAt + grace`: no longer resolves; only the owner sees it, as
        /// "renew to keep it". Nobody can take it.
        case grace
        /// `now >= expiresAt + grace`, still unspent: anyone may reclaim it.
        case lapsed

        static func of(expiresAt: Int64, graceMs: Int64, nowMs: Int64) -> Status {
            if nowMs < expiresAt { return .active }
            if nowMs < expiresAt + graceMs { return .grace }
            return .lapsed
        }

        var resolves: Bool { self == .active }
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - What the screens read

    /// A registered name, from either source (indexer or chain walker).
    struct NameInfo: Identifiable, Equatable {
        var name: String
        var key: Data
        /// x-only owner key
        var owner: Data
        /// sompi; 0 = not listed
        var price: UInt64
        var expiresAt: Int64
        /// unix ms, the start of the current paid period (registry v2); nil when the source did
        /// not say (an indexer without the field): then the name can't be spent from this record
        /// and Extend isn't offered.
        var periodStart: Int64?
        var outpoint: Outpoint
        /// unix ms of the registration, when known
        var registeredAt: Int64?
        var registeredTxId: String?
        var updatedAt: Int64?

        var id: String { name }
        var display: String { "\(name).kachat" }
        var isListed: Bool { price > 0 }

        /// The on-chain state, when the period start is known.
        var fields: NameFields? {
            periodStart.map { NameFields(key: key, paddedName: Codec.padded(name), owner: owner, price: Int64(price), periodStart: $0, expiresAt: expiresAt) }
        }

        func status(graceMs: Int64, nowMs: Int64 = KachatNames.nowMs()) -> Status {
            .of(expiresAt: expiresAt, graceMs: graceMs, nowMs: nowMs)
        }

        // MARK: The paid period (registry v2, KACHAT_NAMES.md 4.1)

        /// Whole periods `extend` can add now (0 when the period start is unknown).
        func extendableYears(_ p: Params) -> Int64 {
            periodStart.map { p.extendableYears(periodStart: $0, expiresAt: expiresAt) } ?? 0
        }

        /// When the renewal window opens: `expiresAt - renewWindowMs` (unix ms).
        func renewOpens(_ p: Params) -> Int64 { p.renewOpens(expiresAt: expiresAt) }

        /// The renewal window by the wall clock (what the screens show; the transaction itself
        /// waits for the network's median time, a couple of minutes behind).
        func renewOpen(_ p: Params, nowMs: Int64 = KachatNames.nowMs()) -> Bool { nowMs >= renewOpens(p) }
    }

    /// An unregistered interval `(lo, hi)` of the key space.
    struct GapInfo: Equatable {
        var lo: Data
        var hi: Data
        var outpoint: Outpoint

        func contains(_ key: Data) -> Bool {
            lo.lexicographicallyPrecedes(key) && key.lexicographicallyPrecedes(hi)
        }
    }

    /// The answer for a typed name.
    enum Lookup: Equatable {
        case registered(NameInfo)
        /// Free to claim, inside `gap` (nil when the source knows it is free but not where).
        case free(name: String, gap: GapInfo?)
    }

    struct OfferInfo: Identifiable, Equatable {
        var outpoint: Outpoint
        var key: Data
        var name: String?
        var buyer: Data
        /// the name's owner the offer was made to (registry v3): only they can accept or decline it
        var seller: Data
        var amount: UInt64
        /// DAA score from which anyone may refund it
        var refundAfter: Int64
        var createdAt: Int64?

        var id: String { "\(hex(outpoint.txid)):\(outpoint.index)" }
        var fields: OfferFields { OfferFields(key: key, buyer: buyer, seller: seller, refundAfter: refundAfter) }
        func refundable(atDaa daa: UInt64) -> Bool { daa > UInt64(max(refundAfter, 0)) }
        /// Made to an earlier owner of the name (registry v3): it can never be accepted and goes
        /// back to the buyer (withdraw, or a refund once it expires).
        func isDeclined(currentOwner: Data) -> Bool { seller != currentOwner }
    }

    /// One registry event (history, activity). Parties are x-only keys or addresses depending on
    /// the source; the screens show them through `party`.
    struct Event: Codable, Identifiable, Equatable {
        var txId: String
        /// register, transfer, list, delist, sale, extend, renew, release, reclaim, offer_accepted, offer
        var op: String
        var name: String?
        var at: Int64?
        /// previous owner: an address (indexer) or x-only key hex (walker)
        var from: String?
        /// new owner / buyer
        var to: String?
        /// sompi: listing price, sale price, offer amount
        var price: UInt64?
        var years: Int64?

        var id: String { "\(txId):\(op):\(name ?? "")" }
    }

    // MARK: - Label rule (KACHAT_NAMES.md section 7)

    /// The label an address is shown with: its `primaryName` if it owns that name and it is
    /// active; otherwise its oldest active name; otherwise nil (the caller shows the address).
    static func label(owned: [NameInfo], primaryName: String?, graceMs: Int64, nowMs: Int64 = KachatNames.nowMs()) -> String? {
        let active = owned.filter { $0.status(graceMs: graceMs, nowMs: nowMs) == .active }
        if let p = primaryName.map(Codec.normalize), active.contains(where: { $0.name == p }) {
            return p
        }
        let oldest = active.sorted { a, b in
            let ra = a.registeredAt ?? Int64.max
            let rb = b.registeredAt ?? Int64.max
            return ra != rb ? ra < rb : a.name < b.name
        }
        return oldest.first?.name
    }

    // MARK: - Profile record (KACHAT_NAMES.md section 7, KACHAT_NAMES_INDEXER.md Part C)

    struct Profile: Codable, Equatable {
        var v: Int = 1
        /// Where each piece comes from: a profile link on a social platform (`SocialSource`) -
        /// they may be three different accounts. KaChat shows that profile's avatar, banner or bio,
        /// looked up on each device, so the platform's moderation applies. No picture or free text
        /// is ever written to the chain.
        var avatar: String?
        var banner: String?
        var bio: String?
        /// A Linktree page (`https://linktr.ee/<name>`): the one way to link anything else.
        var linktree: String?
        var primaryName: String?

        static let maxBio = 280

        private static func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }

        /// The Linktree username in a stored link (`https://linktr.ee/<name>` → `<name>`).
        static func linktreeUsername(_ link: String?) -> String {
            guard let l = linktreeLink(link) else { return "" }
            return String(l.dropFirst("https://linktr.ee/".count))
        }

        /// What the Linktree field holds - a bare username, or a pasted link - as a stored link.
        static func linktreeLink(username raw: String) -> String? {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if t.lowercased().contains("linktr.ee") { return linktreeLink(t) }
            let name = t.hasPrefix("@") ? String(t.dropFirst()) : t
            return linktreeLink("https://linktr.ee/\(name)")
        }

        /// A pasted Linktree link, normalized to `https://linktr.ee/<name>`; nil for anything else.
        static func linktreeLink(_ raw: String?) -> String? {
            guard var t = clean(raw) else { return nil }
            if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
            guard let comps = URLComponents(string: t), var host = comps.host?.lowercased() else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            guard host == "linktr.ee" else { return nil }
            let parts = comps.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard parts.count == 1, let handle = parts.first, handle.count <= 60,
                  handle.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
            return "https://linktr.ee/\(handle)"
        }

        /// The record as the indexer accepts it: a supported social link and a Linktree link,
        /// normalized, anything else dropped; the primary name normalized.
        func sanitized() -> Profile {
            var p = Profile()
            p.avatar = Profile.clean(avatar).flatMap { SocialSource(link: $0, for: .avatar)?.link }
            p.banner = Profile.clean(banner).flatMap { SocialSource(link: $0, for: .banner)?.link }
            p.bio = Profile.clean(bio).flatMap { SocialSource(link: $0, for: .bio)?.link }
            p.linktree = Profile.linktreeLink(linktree)
            p.primaryName = Profile.clean(primaryName).map(Codec.normalize).flatMap { Codec.isValid($0) ? $0 : nil }
            return p
        }

        /// The JSON of the record: compact, keys sorted, nil fields left out. Throws past 2 KB.
        func recordJSON() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(sanitized())
            guard data.count <= Codec.maxProfileJSONBytes else { throw Failure("the profile is over 2 KB") }
            return data
        }

        /// A record's JSON as the indexer reads it (unknown fields dropped, then sanitized).
        static func parse(_ data: Data) -> Profile? {
            guard data.count <= Codec.maxProfileJSONBytes,
                  let p = try? JSONDecoder().decode(Profile.self, from: data), p.v == 1 else { return nil }
            return p.sanitized()
        }
    }

    /// Where a profile's avatar or banner comes from: a profile link on a platform that moderates
    /// the pictures it shows (X, YouTube, Facebook, ...). The record stores only the link; each
    /// device looks the current picture up and caches it (`KachatSocialImageResolver`), so a
    /// picture the platform takes down disappears here too. No picture is ever uploaded.
    struct SocialSource: Equatable {
        enum Kind: String { case avatar, banner, bio }

        enum Platform: String, CaseIterable {
            case x, youtube, facebook, instagram, tiktok, twitch, kick, github, telegram, linkedin, discord

            /// Platforms whose banner can be read without signing in.
            var hasBanner: Bool { self == .x || self == .youtube || self == .discord }

            /// Platforms whose preview carries the person's own bio (see `bio(for:...)`).
            var hasBio: Bool { [.x, .youtube, .telegram, .twitch, .kick, .github, .discord].contains(self) }

            /// What the handle field shows in front of the handle.
            var prefix: String {
                switch self {
                case .x: return "x.com/"
                case .youtube: return "youtube.com/@"
                case .facebook: return "facebook.com/"
                case .instagram: return "instagram.com/"
                case .tiktok: return "tiktok.com/@"
                case .twitch: return "twitch.tv/"
                case .kick: return "kick.com/"
                case .github: return "github.com/"
                case .telegram: return "t.me/"
                case .linkedin: return "linkedin.com/in/"
                case .discord: return "discord.gg/"
                }
            }

            /// The platforms that can fill a field, in picker order.
            static func choices(for kind: Kind) -> [Platform] {
                switch kind {
                case .avatar: return [.x, .youtube, .instagram, .tiktok, .facebook, .twitch, .kick, .github, .telegram, .linkedin, .discord]
                case .banner: return [.x, .youtube, .discord]
                case .bio: return [.x, .youtube, .telegram, .twitch, .kick, .github, .discord]
                }
            }

            var displayName: String {
                switch self {
                case .x: return "X"
                case .youtube: return "YouTube"
                case .facebook: return "Facebook"
                case .instagram: return "Instagram"
                case .tiktok: return "TikTok"
                case .twitch: return "Twitch"
                case .kick: return "Kick"
                case .github: return "GitHub"
                case .telegram: return "Telegram"
                case .linkedin: return "LinkedIn"
                case .discord: return "Discord"
                }
            }
        }

        let platform: Platform
        /// The normalized profile link, e.g. `https://x.com/name`.
        let link: String
        /// The handle, channel path or invite code inside it.
        let handle: String

        /// Accepts a pasted profile link (with or without `https://`, `www.`, `m.`, trailing
        /// slash or query). Nil for an unsupported site, a post rather than a profile, or a
        /// banner from a platform that has none.
        init?(link raw: String, for kind: Kind) {
            var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if !t.lowercased().hasPrefix("http://") && !t.lowercased().hasPrefix("https://") { t = "https://" + t }
            guard let comps = URLComponents(string: t), var host = comps.host?.lowercased() else { return nil }
            for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
            let parts = comps.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            func ok(_ s: String) -> Bool {
                !s.isEmpty && s.count <= 100 && s.allSatisfy { $0.isLetter || $0.isNumber || "._-@".contains($0) }
            }
            var platform: Platform?
            var handle = ""
            var link = ""
            switch host {
            case "x.com", "twitter.com":
                if parts.count == 1, ok(parts[0]), !["home", "explore", "search", "i", "settings"].contains(parts[0].lowercased()) {
                    platform = .x; handle = parts[0]; link = "https://x.com/\(handle)"
                }
            case "youtube.com":
                if parts.count >= 1, parts[0].hasPrefix("@"), ok(parts[0]) {
                    platform = .youtube; handle = parts[0]; link = "https://www.youtube.com/\(handle)"
                } else if parts.count >= 2, ["channel", "c", "user"].contains(parts[0]), ok(parts[1]) {
                    platform = .youtube; handle = "\(parts[0])/\(parts[1])"; link = "https://www.youtube.com/\(handle)"
                }
            case "facebook.com", "fb.com":
                if parts.count == 1, ok(parts[0]), !["profile.php", "groups", "watch", "events"].contains(parts[0].lowercased()) {
                    platform = .facebook; handle = parts[0]; link = "https://www.facebook.com/\(handle)"
                }
            case "instagram.com":
                if parts.count == 1, ok(parts[0]), !["p", "reel", "reels", "explore", "stories"].contains(parts[0].lowercased()) {
                    platform = .instagram; handle = parts[0]; link = "https://www.instagram.com/\(handle)/"
                }
            case "tiktok.com":
                if parts.count == 1, parts[0].hasPrefix("@"), ok(parts[0]) {
                    platform = .tiktok; handle = parts[0]; link = "https://www.tiktok.com/\(handle)"
                }
            case "twitch.tv":
                if parts.count == 1, ok(parts[0]) { platform = .twitch; handle = parts[0]; link = "https://www.twitch.tv/\(handle)" }
            case "kick.com":
                if parts.count == 1, ok(parts[0]) { platform = .kick; handle = parts[0]; link = "https://kick.com/\(handle)" }
            case "github.com":
                if parts.count == 1, ok(parts[0]) { platform = .github; handle = parts[0]; link = "https://github.com/\(handle)" }
            case "t.me", "telegram.me":
                if parts.count == 1, ok(parts[0]), !parts[0].hasPrefix("+") {
                    platform = .telegram; handle = parts[0]; link = "https://t.me/\(handle)"
                }
            case "linkedin.com":
                if parts.count >= 2, ["in", "company"].contains(parts[0]), ok(parts[1]) {
                    platform = .linkedin; handle = "\(parts[0])/\(parts[1])"; link = "https://www.linkedin.com/\(handle)"
                }
            case "discord.gg":
                if parts.count == 1, ok(parts[0]) { platform = .discord; handle = parts[0]; link = "https://discord.gg/\(handle)" }
            case "discord.com", "discordapp.com":
                if parts.count == 2, parts[0] == "invite", ok(parts[1]) {
                    platform = .discord; handle = parts[1]; link = "https://discord.gg/\(handle)"
                }
            default:
                break
            }
            guard let platform else { return nil }
            if kind == .banner && !platform.hasBanner { return nil }
            if kind == .bio && !platform.hasBio { return nil }
            self.platform = platform
            self.handle = handle
            self.link = link
        }

        /// A handle typed for `platform` (with or without `@`), or a whole pasted profile link -
        /// which may name another platform: the caller switches its picker to `.platform`.
        static func from(platform: Platform, handle raw: String, for kind: Kind) -> SocialSource? {
            var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty else { return nil }
            let lower = h.lowercased()
            if lower.hasPrefix("http") || (h.contains(".") && h.contains("/")) {
                return SocialSource(link: h, for: kind)
            }
            if h.hasPrefix("@") { h.removeFirst() }
            let link: String
            switch platform {
            case .youtube, .tiktok: link = platform.prefix + h
            case .linkedin: link = h.hasPrefix("in/") || h.hasPrefix("company/") ? "linkedin.com/\(h)" : platform.prefix + h
            default: link = platform.prefix + h
            }
            return SocialSource(link: link, for: kind)
        }

        /// The handle as the field shows it after `platform.prefix`.
        var displayHandle: String {
            switch platform {
            case .youtube, .tiktok: return handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
            case .linkedin: return handle.hasPrefix("in/") ? String(handle.dropFirst(3)) : handle
            default: return handle
            }
        }

        // MARK: Reading the picture out of what the platform serves (pure, testable)

        /// The `og:image` (or `twitter:image`) of an HTML page, entities decoded.
        static func openGraphImage(in html: String) -> String? {
            for key in ["og:image", "og:image:secure_url", "twitter:image"] {
                let pattern = "<meta[^>]+(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: key))[\"'][^>]*>"
                guard let tagRange = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
                let tag = String(html[tagRange])
                guard let c = tag.range(of: "content=[\"']([^\"']+)[\"']", options: .regularExpression) else { continue }
                var value = String(tag[c]).replacingOccurrences(of: "content=", with: "")
                value = decodeEntities(value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                if value.lowercased().hasPrefix("https://") { return value }
            }
            return nil
        }

        /// The page's `og:description` (or `description`), entities decoded.
        static func openGraphDescription(in html: String) -> String? {
            for key in ["og:description", "description", "twitter:description"] {
                let pattern = "<meta[^>]+(?:property|name)=[\"']\(NSRegularExpression.escapedPattern(for: key))[\"'][^>]*>"
                guard let tagRange = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
                let tag = String(html[tagRange])
                guard let c = tag.range(of: "content=\"([^\"]*)\"", options: .regularExpression)
                        ?? tag.range(of: "content='([^']*)'", options: .regularExpression) else { continue }
                let raw = String(tag[c]).dropFirst("content=".count).dropFirst().dropLast()
                let value = decodeEntities(String(raw)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
            return nil
        }

        /// The bio a platform shows in its preview, where that text really is the person's own
        /// (X, YouTube, Telegram, Kick, and Twitch without its boilerplate). Instagram, TikTok,
        /// Facebook and LinkedIn only put follower counts or site text there: no bio from them.
        /// GitHub and Discord come from their APIs instead.
        static func bio(for platform: Platform, openGraphDescription d: String?) -> String? {
            guard let d, !d.isEmpty else { return nil }
            let text: String
            switch platform {
            case .x, .youtube, .telegram, .kick:
                text = d
            case .twitch:
                // "<description> — Twitch streams live on Twitch! Check out their videos ..."
                text = d.components(separatedBy: " — ").first ?? d
            default:
                return nil
            }
            return trimmedBio(text)
        }

        static func trimmedBio(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return String(t.prefix(Profile.maxBio))
        }

        /// GitHub's public user API (`api.github.com/users/<name>`): avatar and bio.
        static func githubProfile(fromJSON data: Data) -> (avatar: String?, bio: String?) {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
            return (root["avatar_url"] as? String, trimmedBio(root["bio"] as? String))
        }

        /// FxTwitter's user API (`api.fxtwitter.com/<handle>`): X's avatar (400 px), banner and bio
        /// in one small JSON answer - X's own data, so X's moderation still applies. Nil when the
        /// answer isn't a user (unknown or suspended account answers `code` 404).
        static func fxTwitterProfile(fromJSON data: Data) -> SocialProfile? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            guard (root["code"] as? Int) == 200, let user = root["user"] as? [String: Any] else {
                return (root["code"] as? Int) == 404 ? SocialProfile() : nil
            }
            var p = SocialProfile()
            if let a = user["avatar_url"] as? String, a.hasPrefix("https://") {
                p.avatar = a.replacingOccurrences(of: "_normal.", with: "_400x400.")
            }
            if let b = user["banner_url"] as? String, b.hasPrefix("https://") {
                p.banner = b.hasSuffix("/1500x500") ? b : b + "/1500x500"
            }
            p.bio = trimmedBio(user["description"] as? String)
            return p
        }

        /// A Discord invite's server description.
        static func discordDescription(fromInviteJSON data: Data) -> String? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let guild = root["guild"] as? [String: Any] else { return nil }
            return trimmedBio(guild["description"] as? String)
        }

        /// HTML entities as they appear in meta tags: named basics plus decimal and hex numbers.
        static func decodeEntities(_ s: String) -> String {
            guard s.contains("&") else { return s }
            var out = s
            for (k, v) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
                out = out.replacingOccurrences(of: k, with: v)
            }
            while let r = out.range(of: "&#(x[0-9a-fA-F]+|[0-9]+);", options: .regularExpression) {
                let body = out[r].dropFirst(2).dropLast()
                let scalar: UInt32? = body.first == "x" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                out.replaceSubrange(r, with: scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
            }
            // last, so "&amp;#39;" (double-encoded, as LinkedIn sends) decodes one level only
            return out.replacingOccurrences(of: "&amp;", with: "&")
        }

        /// X's avatar from its page, upgraded from the 200px thumbnail to 400px.
        static func xAvatar(fromOpenGraph url: String) -> String {
            url.replacingOccurrences(of: "_200x200.", with: "_400x400.")
        }

        /// X's banner: the page names it as `profile_banners/<user id>/<version>`.
        static func xBanner(in html: String) -> String? {
            guard let r = html.range(of: "profile_banners/[0-9]+/[0-9]+", options: .regularExpression) else { return nil }
            return "https://pbs.twimg.com/\(html[r])/1500x500"
        }

        /// YouTube's channel banner from the page's embedded data, when the channel has one.
        static func youtubeBanner(in html: String) -> String? {
            // The object itself (the bare name also appears earlier, in a list of renderer types).
            guard let start = html.range(of: "\"imageBannerViewModel\":{") else { return nil }
            let window = html[start.upperBound...].prefix(4000)
            guard let r = window.range(of: "https://yt3\\.googleusercontent\\.com/[^\"\\\\]+", options: .regularExpression) else { return nil }
            return String(window[r])
        }

        /// Discord invite → the server's icon or banner (`/api/v10/invites/{code}`).
        static func discordImage(fromInviteJSON data: Data, kind: Kind) -> String? {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let guild = root["guild"] as? [String: Any],
                  let id = guild["id"] as? String else { return nil }
            switch kind {
            case .avatar:
                guard let icon = guild["icon"] as? String, !icon.isEmpty else { return nil }
                return "https://cdn.discordapp.com/icons/\(id)/\(icon).png?size=256"
            case .banner:
                guard let banner = guild["banner"] as? String, !banner.isEmpty else { return nil }
                return "https://cdn.discordapp.com/banners/\(id)/\(banner).png?size=1024"
            case .bio:
                return nil // the server's description: `discordDescription(fromInviteJSON:)`
            }
        }
    }

    /// What a social profile link shows right now: avatar, banner (X, YouTube, Discord) and bio.
    struct SocialProfile: Codable, Equatable {
        var avatar: String?
        var banner: String?
        var bio: String?
        var isEmpty: Bool { avatar == nil && banner == nil && bio == nil }
    }

    struct Identity: Equatable {
        var address: String
        /// the bare name (no `.kachat`), nil when the address has no active name
        var label: String?
        var names: [String]
        var profile: Profile?
    }

    // MARK: - A transaction as the walker sees it

    struct ViewInput: Equatable {
        var outpoint: Outpoint
        var signatureScript: Data
    }

    struct TxView: Equatable {
        var id: Data
        var inputs: [ViewInput]
        var outputs: [TxOutput]
        var payload: Data
        /// unix ms of the accepting block (or the block), when known
        var at: Int64?

        var idHex: String { hex(id) }

        /// A transaction from the Kaspa REST API (`GET /addresses/{a}/full-transactions` or
        /// `GET /transactions/{id}`, kaspa-rest-server): version-1 outputs carry `covenant_id`
        /// and `covenant_authorizing_input`. Returns nil for one that is not accepted.
        static func fromREST(_ j: [String: Any]) throws -> TxView? {
            func str(_ v: Any?) -> String? { v as? String }
            func num(_ v: Any?) -> UInt64? {
                if let n = v as? NSNumber { return n.uint64Value }
                if let s = v as? String { return UInt64(s) }
                return nil
            }
            if let accepted = j["is_accepted"] as? Bool, !accepted { return nil }
            guard let idHex = str(j["transaction_id"]) else { throw Failure("REST transaction without an id") }
            let id = try unhex32(idHex)
            var inputs: [(Int, ViewInput)] = []
            for (k, any) in ((j["inputs"] as? [[String: Any]]) ?? []).enumerated() {
                guard let prev = str(any["previous_outpoint_hash"]), let idx = num(any["previous_outpoint_index"]) else {
                    throw Failure("\(idHex): input without its outpoint")
                }
                let sig = try unhex(str(any["signature_script"]) ?? "")
                let order = num(any["index"]).map(Int.init) ?? k
                inputs.append((order, ViewInput(outpoint: Outpoint(txid: try unhex32(prev), index: UInt32(idx)), signatureScript: sig)))
            }
            var outputs: [(Int, TxOutput)] = []
            for (k, any) in ((j["outputs"] as? [[String: Any]]) ?? []).enumerated() {
                guard let amount = num(any["amount"]), let spk = str(any["script_public_key"]) else {
                    throw Failure("\(idHex): output without amount or script")
                }
                var covenant: CovenantBinding?
                if let cid = str(any["covenant_id"]), !cid.isEmpty {
                    guard let auth = num(any["covenant_authorizing_input"]) else { throw Failure("\(idHex): covenant output without its authorizing input") }
                    covenant = CovenantBinding(authorizingInput: UInt16(auth), covenantId: try unhex32(cid))
                }
                let order = num(any["index"]).map(Int.init) ?? k
                outputs.append((order, TxOutput(value: amount, scriptVersion: 0, script: try unhex(spk), covenant: covenant)))
            }
            let payload = try unhex(str(j["payload"]) ?? "")
            let at = (j["accepting_block_time"] as? NSNumber)?.int64Value ?? (j["block_time"] as? NSNumber)?.int64Value
            return TxView(
                id: id,
                inputs: inputs.sorted { $0.0 < $1.0 }.map { $0.1 },
                outputs: outputs.sorted { $0.0 < $1.0 }.map { $0.1 },
                payload: payload,
                at: at
            )
        }
    }

    // MARK: - The walker's registry state (cached on disk, per network)

    /// The registry without an indexer: the live gaps and names (and the offers this device made),
    /// decoded, moved forward one spending transaction at a time from the manifest's genesis gap.
    /// Hex strings throughout so the cache file stays readable.
    struct RegistryState: Codable, Equatable {
        struct Gap: Codable, Equatable {
            var txid: String
            var index: UInt32
            var lo: String
            var hi: String
            var value: UInt64
        }

        struct Name: Codable, Equatable {
            var txid: String
            var index: UInt32
            var name: String
            var key: String
            var owner: String
            var price: Int64
            /// unix ms, the start of the current paid period (registry v2)
            var periodStart: Int64
            var expiresAt: Int64
            var value: UInt64
            var registeredAt: Int64?
            var registeredTxId: String?
            var updatedAt: Int64?
        }

        struct Offer: Codable, Equatable {
            var txid: String
            var index: UInt32
            var key: String
            var buyer: String
            var seller: String
            var refundAfter: Int64
            var value: UInt64
            var name: String?
            var createdAt: Int64?
        }

        /// 4: registry v4 (fixed prices: no price shards); an older cache is dropped and walked again.
        static let formatVersion = 4
        static let appliedKeep = 4096
        static let eventsKeep = 1000

        var version = RegistryState.formatVersion
        var network: String
        var registryCovenantId: String
        var gaps: [Gap]
        var names: [Name]
        var offers: [Offer]
        /// transactions already applied (most recent last, bounded)
        var applied: [String]
        /// every registry event the walker has seen (most recent last, bounded)
        var events: [Event]
        /// when the live set was last confirmed against a node (unix ms)
        var verifiedAt: Int64?

        /// The genesis: the lone genesis gap.
        static func atGenesis(_ m: Manifest) -> RegistryState {
            RegistryState(
                network: m.network,
                registryCovenantId: hex(m.registryCovenantId),
                gaps: [Gap(txid: hex(m.genesisTxid), index: 0, lo: hex(m.genesisState.lo), hi: hex(m.genesisState.hi), value: m.params.gapValue)],
                names: [], offers: [], applied: [hex(m.genesisTxid)], events: [], verifiedAt: nil
            )
        }

        /// Whether this cache belongs to `m`'s registry.
        func matches(_ m: Manifest) -> Bool {
            version == RegistryState.formatVersion && network == m.network && registryCovenantId == hex(m.registryCovenantId)
        }

        // MARK: Reading

        func gap(containing key: Data) -> Gap? {
            let k = hex(key)
            return gaps.first { $0.lo < k && k < $0.hi }
        }

        func name(_ name: String) -> Name? {
            let k = hex(Codec.key(name))
            return names.first { $0.key == k }
        }

        /// The gaps on either side of a registered key: `(lo, key)` and `(key, hi)`.
        func neighbours(of key: Data) -> (below: Gap, above: Gap)? {
            let k = hex(key)
            guard let below = gaps.first(where: { $0.hi == k }), let above = gaps.first(where: { $0.lo == k }) else { return nil }
            return (below, above)
        }

        /// The gaps and names tile the key space exactly.
        func checkInvariants() throws {
            let sorted = gaps.sorted { $0.lo < $1.lo }
            let keys = names.map(\.key).sorted()
            guard sorted.count == keys.count + 1 else { throw Failure("\(sorted.count) gaps for \(keys.count) names") }
            var cur = hex(zero32)
            for (i, g) in sorted.enumerated() {
                guard g.lo == cur else { throw Failure("gap \(i) starts at \(g.lo.prefix(8)) instead of \(cur.prefix(8))") }
                guard g.lo < g.hi else { throw Failure("gap \(i) is empty") }
                if i < keys.count {
                    guard keys[i] == g.hi else { throw Failure("gap \(i) ends at \(g.hi.prefix(8)) but the next name is \(keys[i].prefix(8))") }
                    cur = keys[i]
                } else {
                    guard g.hi == hex(ff32) else { throw Failure("the last gap ends at \(g.hi.prefix(8))") }
                }
            }
        }

        static func outpoint(_ txid: String, _ index: UInt32) -> Outpoint {
            Outpoint(txid: (try? unhex32(txid)) ?? zero32, index: index)
        }

        static func info(_ n: Name) -> NameInfo {
            NameInfo(
                name: n.name, key: (try? unhex32(n.key)) ?? zero32, owner: (try? unhex32(n.owner)) ?? zero32,
                price: UInt64(max(n.price, 0)), expiresAt: n.expiresAt, periodStart: n.periodStart, outpoint: outpoint(n.txid, n.index),
                registeredAt: n.registeredAt, registeredTxId: n.registeredTxId, updatedAt: n.updatedAt
            )
        }

        /// A tracked name's on-chain state.
        static func fields(_ n: Name) -> NameFields {
            NameFields(key: (try? unhex32(n.key)) ?? zero32, paddedName: Codec.padded(n.name), owner: (try? unhex32(n.owner)) ?? zero32,
                       price: n.price, periodStart: n.periodStart, expiresAt: n.expiresAt)
        }

        static func info(_ g: Gap) -> GapInfo {
            GapInfo(lo: (try? unhex32(g.lo)) ?? zero32, hi: (try? unhex32(g.hi)) ?? ff32, outpoint: outpoint(g.txid, g.index))
        }

        static func info(_ o: Offer) -> OfferInfo {
            OfferInfo(
                outpoint: outpoint(o.txid, o.index), key: (try? unhex32(o.key)) ?? zero32, name: o.name,
                buyer: (try? unhex32(o.buyer)) ?? zero32, seller: (try? unhex32(o.seller)) ?? zero32,
                amount: o.value, refundAfter: o.refundAfter, createdAt: o.createdAt
            )
        }

        /// Every UTXO the walker follows, with the script it must hold.
        func tracked(_ m: Manifest) -> [(outpoint: String, script: Data, registry: Bool)] {
            var out: [(String, Data, Bool)] = []
            for g in gaps {
                guard let lo = try? unhex32(g.lo), let hi = try? unhex32(g.hi) else { continue }
                out.append(("\(g.txid):\(g.index)", m.gap.script(Codec.gapState(lo: lo, hi: hi)), true))
            }
            for n in names {
                out.append(("\(n.txid):\(n.index)", m.name.script(RegistryState.fields(n).encoded), true))
            }
            for o in offers {
                out.append(("\(o.txid):\(o.index)", m.offer.script(RegistryState.info(o).fields.encoded), false))
            }
            return out
        }

        // MARK: Offers this device made

        mutating func trackOffer(_ o: OfferInfo, at: Int64?) {
            let txid = hex(o.outpoint.txid)
            offers.removeAll { $0.txid == txid && $0.index == o.outpoint.index }
            offers.append(Offer(txid: txid, index: o.outpoint.index, key: hex(o.key), buyer: hex(o.buyer), seller: hex(o.seller),
                                refundAfter: o.refundAfter, value: o.amount, name: o.name, createdAt: at))
        }

        // MARK: Applying a transaction (registry.rs `Registry::apply`)

        private enum Predicted {
            case gap(lo: String, hi: String)
            case name(NameFields, name: String)
        }

        private struct Spend {
            var args: [Data]
            var entry: String
            var redeem: Data
        }

        private static func decodeSpend(_ t: Template, _ sigScript: Data) throws -> Spend {
            var pushes = try Codec.parsePushes(sigScript)
            guard let redeem = pushes.popLast() else { throw Failure("empty signature script") }
            guard let tag = pushes.popLast() else { throw Failure("no dispatch tag") }
            guard let entry = t.dispatchTags.first(where: { $0.value == tag })?.key else {
                throw Failure("unknown \(t.contract) dispatch tag \(hex(tag))")
            }
            return Spend(args: pushes, entry: entry, redeem: redeem)
        }

        private static func arg32(_ a: [Data], _ i: Int) throws -> Data {
            guard i < a.count, a[i].count == 32 else { throw Failure("argument \(i) is not 32 bytes") }
            return a[i]
        }

        private static func argInt(_ a: [Data], _ i: Int) throws -> Int64 {
            guard i < a.count else { throw Failure("missing argument \(i)") }
            return try Codec.scriptNum(a[i])
        }

        /// The offer a transaction announces with the registry v3 marker
        /// `kchat:1:offer:<key>:<buyer>:<seller>:<refundAfter>`, if one of its outputs really is that
        /// offer (KACHAT_NAMES_INDEXER.md B4).
        static func offerFromMarker(_ tx: TxView, _ m: Manifest) -> (index: Int, fields: OfferFields)? {
            guard let text = String(data: tx.payload, encoding: .utf8), text.hasPrefix("kchat:1:offer:") else { return nil }
            let parts = text.dropFirst("kchat:1:offer:".count).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, let key = try? unhex32(String(parts[0])), let buyer = try? unhex32(String(parts[1])),
                  let seller = try? unhex32(String(parts[2])), let refundAfter = Int64(parts[3]), refundAfter >= 0 else { return nil }
            let fields = OfferFields(key: key, buyer: buyer, seller: seller, refundAfter: refundAfter)
            let script = m.offer.script(fields.encoded)
            guard let idx = tx.outputs.firstIndex(where: { $0.script == script && $0.covenant == nil }) else { return nil }
            return (idx, fields)
        }

        /// Whether input `i` spends an offer through `accept` (tracked or not: the redeem script
        /// it reveals is recognised by the offer template).
        private static func isOfferAccept(_ input: ViewInput, _ m: Manifest) -> Bool {
            guard let pushes = try? Codec.parsePushes(input.signatureScript), pushes.count >= 2,
                  (try? m.offer.state(ofRedeem: pushes[pushes.count - 1])) != nil else { return false }
            return pushes[pushes.count - 2] == m.offer.dispatchTags["accept"]
        }

        /// Applies one transaction. Returns its registry events; an unrelated transaction returns
        /// none. Every registry output must be predicted exactly from the tracked inputs it spends
        /// (and authorized by that input), or the transaction is refused and nothing changes.
        @discardableResult
        mutating func apply(_ tx: TxView, manifest m: Manifest) throws -> [Event] {
            let id = tx.idHex
            if applied.contains(id) { return [] }
            let registryId = try unhex32(registryCovenantId)
            let regOuts = tx.outputs.indices.filter { tx.outputs[$0].covenant?.covenantId == registryId }
            func key(_ o: Outpoint) -> (String, UInt32) { (hex(o.txid), o.index) }
            let gapIns: [(Int, Gap)] = tx.inputs.enumerated().compactMap { i, input in
                let (t, x) = key(input.outpoint)
                return gaps.first { $0.txid == t && $0.index == x }.map { (i, $0) }
            }
            let nameIns: [(Int, Name)] = tx.inputs.enumerated().compactMap { i, input in
                let (t, x) = key(input.outpoint)
                return names.first { $0.txid == t && $0.index == x }.map { (i, $0) }
            }
            let offerIns: [(Int, Offer)] = tx.inputs.enumerated().compactMap { i, input in
                let (t, x) = key(input.outpoint)
                return offers.first { $0.txid == t && $0.index == x }.map { (i, $0) }
            }
            let newOffer = RegistryState.offerFromMarker(tx, m)
            if regOuts.isEmpty && gapIns.isEmpty && nameIns.isEmpty && offerIns.isEmpty && newOffer == nil {
                return []
            }
            let short = String(id.prefix(12))
            var events: [Event] = []
            var predicted: [(auth: UInt16, p: Predicted)] = []
            let acceptsOffer = tx.inputs.contains { RegistryState.isOfferAccept($0, m) }

            for (i, g) in gapIns {
                let sp: Spend
                do { sp = try RegistryState.decodeSpend(m.gap, tx.inputs[i].signatureScript) } catch { throw Failure("\(short): gap input \(i): \(error.localizedDescription)") }
                let lo = try unhex32(g.lo), hi = try unhex32(g.hi)
                guard sp.redeem == m.gap.redeem(Codec.gapState(lo: lo, hi: hi)) else {
                    throw Failure("\(short): gap input \(i) reveals a redeem script that is not the tracked gap state")
                }
                switch sp.entry {
                case "register":
                    guard let nameBytes = sp.args.first else { throw Failure("\(short): register without a name") }
                    let owner = try RegistryState.arg32(sp.args, 1)
                    let now = try RegistryState.argInt(sp.args, 3)
                    let years = try RegistryState.argInt(sp.args, 4)
                    let name = String(decoding: nameBytes, as: UTF8.self)
                    let k = blake3(nameBytes)
                    var padded = nameBytes.prefix(32)
                    padded.append(Data(repeating: 0, count: 32 - padded.count))
                    let f = NameFields(key: k, paddedName: Data(padded), owner: owner, price: 0, periodStart: now, expiresAt: now + years * m.params.periodMs)
                    predicted.append((UInt16(i), .gap(lo: g.lo, hi: hex(k))))
                    predicted.append((UInt16(i), .gap(lo: hex(k), hi: g.hi)))
                    predicted.append((UInt16(i), .name(f, name: name)))
                    events.append(Event(txId: id, op: "register", name: name, at: tx.at, from: nil, to: hex(owner), price: nil, years: years))
                case "merge":
                    guard let succ = gapIns.first(where: { $0.0 == 2 && $0.1.lo == g.hi })?.1 else {
                        throw Failure("\(short): merge without the tracked successor gap at input 2")
                    }
                    predicted.append((UInt16(i), .gap(lo: g.lo, hi: succ.hi)))
                case "absorbed":
                    break
                default:
                    throw Failure("\(short): unexpected gap entry \(sp.entry)")
                }
            }

            for (i, n) in nameIns {
                let sp: Spend
                do { sp = try RegistryState.decodeSpend(m.name, tx.inputs[i].signatureScript) } catch { throw Failure("\(short): name input \(i): \(error.localizedDescription)") }
                let f = RegistryState.fields(n)
                guard sp.redeem == m.name.redeem(f.encoded) else {
                    throw Failure("\(short): name input \(i) reveals a redeem script that is not the tracked name state")
                }
                switch sp.entry {
                case "transfer":
                    let to = try RegistryState.arg32(sp.args, 0)
                    predicted.append((UInt16(i), .name(f.withOwner(to), name: n.name)))
                    if acceptsOffer {
                        // the output right after the continuation pays the old owner
                        events.append(Event(txId: id, op: "offer_accepted", name: n.name, at: tx.at, from: n.owner, to: hex(to), price: nil, years: nil))
                    } else {
                        events.append(Event(txId: id, op: "transfer", name: n.name, at: tx.at, from: n.owner, to: hex(to), price: nil, years: nil))
                    }
                case "list":
                    let price = try RegistryState.argInt(sp.args, 0)
                    predicted.append((UInt16(i), .name(f.withPrice(price), name: n.name)))
                    events.append(Event(txId: id, op: price == 0 ? "delist" : "list", name: n.name, at: tx.at, from: n.owner, to: nil,
                                        price: price > 0 ? UInt64(price) : nil, years: nil))
                case "buy":
                    let to = try RegistryState.arg32(sp.args, 0)
                    predicted.append((UInt16(i), .name(f.withOwner(to), name: n.name)))
                    events.append(Event(txId: id, op: "sale", name: n.name, at: tx.at, from: n.owner, to: hex(to), price: UInt64(max(n.price, 0)), years: nil))
                case "extend":
                    // periodStart kept, expiresAt + years (the contract checked the 2-year cap)
                    let years = try RegistryState.argInt(sp.args, 0)
                    predicted.append((UInt16(i), .name(f.extended(years, periodMs: m.params.periodMs), name: n.name)))
                    events.append(Event(txId: id, op: "extend", name: n.name, at: tx.at, from: nil, to: nil, price: nil, years: years))
                case "renew":
                    // a new period from the old expiry
                    let years = try RegistryState.argInt(sp.args, 0)
                    predicted.append((UInt16(i), .name(f.renewed(years, periodMs: m.params.periodMs), name: n.name)))
                    events.append(Event(txId: id, op: "renew", name: n.name, at: tx.at, from: nil, to: nil, price: nil, years: years))
                case "release":
                    events.append(Event(txId: id, op: "release", name: n.name, at: tx.at, from: n.owner, to: nil, price: nil, years: nil))
                case "reclaim":
                    events.append(Event(txId: id, op: "reclaim", name: n.name, at: tx.at, from: n.owner, to: nil, price: nil, years: nil))
                default:
                    throw Failure("\(short): unexpected name entry \(sp.entry)")
                }
            }

            for (i, o) in offerIns {
                let sp: Spend
                do { sp = try RegistryState.decodeSpend(m.offer, tx.inputs[i].signatureScript) } catch { throw Failure("\(short): offer input \(i): \(error.localizedDescription)") }
                guard sp.redeem == m.offer.redeem(RegistryState.info(o).fields.encoded) else {
                    throw Failure("\(short): offer input \(i) reveals a redeem script that is not the tracked offer state")
                }
                events.append(Event(txId: id, op: "offer_\(sp.entry)", name: o.name, at: tx.at, from: nil, to: o.buyer, price: o.value, years: nil))
            }

            // Match the predictions to the registry outputs, one to one, each authorized by the
            // input that predicted it (the P2SH script commits to the whole state).
            var matched: [Int: Predicted] = [:]
            for (auth, p) in predicted {
                let script: Data
                let cov: Data
                switch p {
                case .gap(let lo, let hi): script = m.gap.script(Codec.gapState(lo: try unhex32(lo), hi: try unhex32(hi))); cov = registryId
                case .name(let f, _): script = m.name.script(f.encoded); cov = registryId
                }
                guard let idx = regOuts.first(where: { j in
                    matched[j] == nil && tx.outputs[j].script == script && tx.outputs[j].covenant?.authorizingInput == auth
                        && tx.outputs[j].covenant?.covenantId == cov
                }) else {
                    throw Failure("\(short): predicted registry output not found (authorized by input \(auth))")
                }
                matched[idx] = p
            }
            if let extra = regOuts.first(where: { matched[$0] == nil }) {
                throw Failure("\(short): registry output \(extra) is not explained by any tracked registry input")
            }

            // Commit.
            let spent = Set(tx.inputs.map { "\(hex($0.outpoint.txid)):\($0.outpoint.index)" })
            let carried = Dictionary(nameIns.map { ($0.1.key, $0.1) }, uniquingKeysWith: { a, _ in a })
            gaps.removeAll { spent.contains("\($0.txid):\($0.index)") }
            names.removeAll { spent.contains("\($0.txid):\($0.index)") }
            offers.removeAll { spent.contains("\($0.txid):\($0.index)") }
            for idx in matched.keys.sorted() {
                let value = tx.outputs[idx].value
                switch matched[idx]! {
                case .gap(let lo, let hi):
                    gaps.append(Gap(txid: id, index: UInt32(idx), lo: lo, hi: hi, value: value))
                case .name(let f, let name):
                    let k = hex(f.key)
                    let before = carried[k]
                    names.append(Name(
                        txid: id, index: UInt32(idx), name: name, key: k, owner: hex(f.owner), price: f.price,
                        periodStart: f.periodStart, expiresAt: f.expiresAt,
                        value: value, registeredAt: before?.registeredAt ?? tx.at, registeredTxId: before?.registeredTxId ?? id, updatedAt: tx.at
                    ))
                }
            }
            if let (idx, fields) = newOffer {
                let known = names.first { $0.key == hex(fields.key) }?.name
                offers.removeAll { $0.txid == id && $0.index == UInt32(idx) }
                offers.append(Offer(txid: id, index: UInt32(idx), key: hex(fields.key), buyer: hex(fields.buyer), seller: hex(fields.seller),
                                    refundAfter: fields.refundAfter, value: tx.outputs[idx].value, name: known, createdAt: tx.at))
                events.append(Event(txId: id, op: "offer", name: known, at: tx.at, from: nil, to: hex(fields.buyer), price: tx.outputs[idx].value, years: nil))
            }
            // an accepted offer's payout: the output right after the name continuation
            for k in events.indices where events[k].op == "offer_accepted" {
                if let cont = matched.first(where: { if case .name(_, let nm) = $0.value { return nm == events[k].name } else { return false } })?.key,
                   cont + 1 < tx.outputs.count {
                    events[k].price = tx.outputs[cont + 1].value
                }
            }
            applied.append(id)
            if applied.count > RegistryState.appliedKeep { applied.removeFirst(applied.count - RegistryState.appliedKeep) }
            self.events.append(contentsOf: events)
            if self.events.count > RegistryState.eventsKeep { self.events.removeFirst(self.events.count - RegistryState.eventsKeep) }
            return events
        }
    }
}

// MARK: - Indexer API shapes (KACHAT_NAMES_INDEXER.md Part D)

extension KachatNames {
    enum IndexerAPI {
        struct OutpointJSON: Decodable {
            let txId: String
            let index: UInt32
            var outpoint: Outpoint? { (try? unhex32(txId)).map { Outpoint(txid: $0, index: index) } }
        }

        struct GapJSON: Decodable {
            let lo: String
            let hi: String
            let outpoint: OutpointJSON

            var info: GapInfo? {
                guard let lo = try? unhex32(lo), let hi = try? unhex32(hi), let op = outpoint.outpoint else { return nil }
                return GapInfo(lo: lo, hi: hi, outpoint: op)
            }
        }

        /// `GET /names/{name}` and every name object in lists.
        struct NameJSON: Decodable {
            let name: String
            let key: String?
            let registered: Bool?
            let status: String?
            let owner: String?
            let ownerKey: String?
            let price: String?
            /// registry v2: the start of the current paid period (unix ms); optional
            let periodStart: Int64?
            let expiresAt: Int64?
            let outpoint: OutpointJSON?
            let registeredAt: Int64?
            let registeredTxId: String?
            let updatedAt: Int64?
            let gap: GapJSON?

            /// The record, when registered and complete. `ownerKey` falls back to `keyOf(owner)`.
            func info(keyOf: (String) -> Data?) -> NameInfo? {
                guard registered != false, let expiresAt, let op = outpoint?.outpoint else { return nil }
                let n = Codec.normalize(name)
                guard Codec.isValid(n) else { return nil }
                guard let owner = ownerKey.flatMap({ try? unhex32($0) }) ?? owner.flatMap(keyOf), owner.count == 32 else { return nil }
                return NameInfo(
                    name: n, key: Codec.key(n), owner: owner, price: price.flatMap(UInt64.init) ?? 0, expiresAt: expiresAt,
                    periodStart: periodStart, outpoint: op, registeredAt: registeredAt, registeredTxId: registeredTxId, updatedAt: updatedAt
                )
            }
        }

        struct NamesJSON: Decodable { let names: [NameJSON] }
        struct ListingsJSON: Decodable { let listings: [NameJSON]; let next: String? }

        struct EventJSON: Decodable {
            let txId: String
            let op: String
            let name: String?
            let at: Int64?
            let from: String?
            let to: String?
            let price: String?
            let years: Int64?

            var event: Event { Event(txId: txId, op: op, name: name, at: at, from: from, to: to, price: price.flatMap(UInt64.init), years: years) }
        }

        struct EventsJSON: Decodable { let events: [EventJSON]; let next: String? }

        struct OfferJSON: Decodable {
            let outpoint: OutpointJSON
            let buyer: String
            /// registry v3: the owner the offer was made to (an address)
            let seller: String?
            let amount: String
            let refundAfter: Int64
            let createdAt: Int64?
            let refundable: Bool?
            let name: String?

            /// The offer, when complete. An indexer without the seller (registry v2) gives nothing:
            /// a v3 offer can't be accepted or declined without it.
            func info(name fallback: String?, keyOf: (String) -> Data?) -> OfferInfo? {
                guard let op = outpoint.outpoint, let buyerKey = keyOf(buyer), let sellerKey = seller.flatMap(keyOf),
                      let amount = UInt64(amount) else { return nil }
                guard let n = (name ?? fallback).map(Codec.normalize), Codec.isValid(n) else { return nil }
                return OfferInfo(outpoint: op, key: Codec.key(n), name: n, buyer: buyerKey, seller: sellerKey, amount: amount,
                                 refundAfter: refundAfter, createdAt: createdAt)
            }
        }

        struct OffersJSON: Decodable { let offers: [OfferJSON] }

        struct ProfileJSON: Decodable {
            let address: String
            let profile: Profile?
            let updatedAt: Int64?
            let txId: String?
        }

        struct IdentityJSON: Decodable {
            let address: String
            let label: String?
            let names: [String]?
            let profile: Profile?

            var identity: Identity { Identity(address: address, label: label, names: names ?? [], profile: profile?.sanitized()) }
        }

        struct StatusJSON: Decodable {
            let network: String?
            let registryCovenantId: String?
            let genesisTxId: String?
            let indexedDaa: UInt64?
            let synced: Bool?
        }
    }
}

// MARK: - Key arithmetic for the indexer's gap lookups

extension KachatNames {
    /// `key ± 1` as a 32-byte big-endian number (nil past either end). The gap containing
    /// `key - 1` is `(lo, key)` and the one containing `key + 1` is `(key, hi)`: the neighbours an
    /// exit (release, reclaim) spends.
    static func step(_ key: Data, by delta: Int) -> Data? {
        var b = [UInt8](key)
        guard b.count == 32, delta == 1 || delta == -1 else { return nil }
        var i = 31
        while i >= 0 {
            if delta == 1 {
                if b[i] == 0xff { b[i] = 0; i -= 1 } else { b[i] += 1; return Data(b) }
            } else {
                if b[i] == 0 { b[i] = 0xff; i -= 1 } else { b[i] -= 1; return Data(b) }
            }
        }
        return nil
    }
}

// MARK: - The walk (no indexer)

extension KachatNames.RegistryState {
    struct WalkReport: Equatable {
        var rounds = 0
        var applied: [String] = []
        var events: [KachatNames.Event] = []
        /// tracked UTXOs the node no longer has but whose spending transaction was not found yet
        /// (an indexing delay of the REST API); the next refresh retries
        var unresolved: [String] = []
    }

    /// Moves the state forward to the chain's current registry. `live(addresses)` answers which
    /// of the outpoints ("txid:index") at those P2SH addresses are unspent (a node), and
    /// `transactions(address)` the accepted transactions touching an address (the REST API).
    /// Each round: every tracked UTXO the node no longer has was spent; its spending transaction
    /// is found through its address and applied (`apply`, which decodes the spend and verifies
    /// every new state against its output's script); the new outputs are tracked next round.
    /// A transaction that needs a registry input not tracked yet waits for a later one in the
    /// same round. The state only ever holds outputs a tracked input authorized.
    mutating func walk(
        manifest m: KachatNames.Manifest,
        maxRounds: Int = 64,
        address: (Data) -> String?,
        live: ([String]) async throws -> Set<String>,
        transactions: (String) async throws -> [KachatNames.TxView]
    ) async throws -> WalkReport {
        var report = WalkReport()
        for _ in 0..<maxRounds {
            report.rounds += 1
            let tracked = tracked(m)
            var byAddress: [String: [String]] = [:]
            for t in tracked {
                guard let a = address(t.script) else { throw KachatNames.Failure("no address for a tracked script") }
                byAddress[a, default: []].append(t.outpoint)
            }
            let unspent = try await live(Array(byAddress.keys).sorted())
            let spent = byAddress.flatMap { a, ops in ops.filter { !unspent.contains($0) }.map { (a, $0) } }
            if spent.isEmpty {
                report.unresolved = []
                return report
            }
            var candidates: [String: KachatNames.TxView] = [:]
            var found = Set<String>()
            for a in Set(spent.map { $0.0 }).sorted() {
                let wanted = Set(spent.filter { $0.0 == a }.map { $0.1 })
                for tx in try await transactions(a) {
                    let spends = tx.inputs.map { "\(KachatNames.hex($0.outpoint.txid)):\($0.outpoint.index)" }.filter { wanted.contains($0) }
                    if !spends.isEmpty {
                        candidates[tx.idHex] = tx
                        found.formUnion(spends)
                    }
                }
            }
            report.unresolved = spent.map { $0.1 }.filter { !found.contains($0) }.sorted()
            if candidates.isEmpty { return report }
            var pending = candidates.values.sorted { ($0.at ?? 0, $0.idHex) < ($1.at ?? 0, $1.idHex) }
            var lastError: Error?
            var progressed = true
            var appliedThisRound = 0
            while progressed && !pending.isEmpty {
                progressed = false
                var rest: [KachatNames.TxView] = []
                for tx in pending {
                    do {
                        let before = applied.count
                        let events = try apply(tx, manifest: m)
                        if applied.count != before || applied.contains(tx.idHex) {
                            report.applied.append(tx.idHex)
                            report.events.append(contentsOf: events)
                        }
                        progressed = true
                        appliedThisRound += 1
                    } catch {
                        lastError = error
                        rest.append(tx)
                    }
                }
                pending = rest
            }
            // nothing applied: the same spends would fail again next round
            if appliedThisRound == 0, let lastError { throw lastError }
        }
        return report
    }
}
