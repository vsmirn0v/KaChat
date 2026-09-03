import Foundation
import SwiftUI

/// Global notification center backing the bell on the Profile screen - ONE feed aggregating
/// KaPosts activity (likes/replies/quotes/follows/@mentions), group-chat @mentions of your own
/// KNS domain, and live broadcast messages. Mirrors the desktop's top-bar bell: entries are
/// account-scoped, persisted, deduped by id, and capped; opening the list marks everything seen.
///
/// Sources push in via `record(...)`:
///  - KaPosts: fed by KaPostsNotificationService's single 30s poll via
///    `ingestKaPostsNotifications` (independent of the banner pinger's per-type/remote-push
///    gates - the center always lists activity).
///  - Group mentions: GroupChatService calls `recordGroupMentionIfNeeded` on incoming messages.
///  - Broadcasts: BroadcastService records live (session-gated) incoming channel messages.
@MainActor
final class GlobalNotificationCenter: ObservableObject {
    static let shared = GlobalNotificationCenter()

    struct Entry: Identifiable, Codable, Equatable {
        enum Source: String, Codable {
            case kaposts, group, broadcast, wallet

            var label: String {
                switch self {
                case .kaposts: return "KaPosts"
                case .group: return "Group"
                case .broadcast: return "Broadcast"
                case .wallet: return "Wallet"
                }
            }

            var icon: String {
                switch self {
                case .kaposts: return "megaphone"
                case .group: return "person.3"
                case .broadcast: return "dot.radiowaves.left.and.right"
                case .wallet: return "arrow.down.circle"
                }
            }
        }

        let id: String
        let source: Source
        let title: String
        let body: String
        let timestamp: Int64 // ms
        /// group id / channel name / post txid - what tapping the row should open.
        let targetId: String?
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var lastSeenAt: Int64 = 0

    /// Broadcast rows older than app launch are history, not live arrivals - never listed.
    static let sessionStartMs = Int64(Date().timeIntervalSince1970 * 1000)

    private let maxEntries = 100

    var unreadCount: Int {
        entries.filter { $0.timestamp > lastSeenAt }.count
    }

    private init() {
        reload()
        // KaPosts rows arrive via ingestKaPostsNotifications, fed by KaPostsNotificationService's
        // 30s poll — this class used to run its OWN 90s poll of the same endpoint in parallel.
    }

    // MARK: - Persistence (account-scoped)

    private var walletAddress: String { WalletManager.shared.currentWallet?.publicAddress ?? "" }
    private var entriesKey: String { "globalNotifCenter.entries.\(walletAddress)" }
    private var seenKey: String { "globalNotifCenter.seenAt.\(walletAddress)" }
    private var kaPostsBaselineKey: String { "globalNotifCenter.kapostsLastSeen.\(walletAddress)" }

    /// Call on account switch (and at init) to load the active wallet's feed.
    func reload() {
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        lastSeenAt = (UserDefaults.standard.object(forKey: seenKey) as? NSNumber)?.int64Value ?? 0
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(entries.prefix(maxEntries))) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    // MARK: - Feed mutations

    func record(id: String, source: Entry.Source, title: String, body: String, timestamp: Int64, targetId: String?) {
        guard !id.isEmpty, !entries.contains(where: { $0.id == id }) else { return }
        entries.insert(Entry(id: id, source: source, title: title, body: body, timestamp: timestamp, targetId: targetId), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        persist()
    }

    func markAllSeen() {
        lastSeenAt = Int64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(NSNumber(value: lastSeenAt), forKey: seenKey)
    }

    func clearAll() {
        entries = []
        persist()
    }

    // MARK: - Group @mentions (called from GroupChatService on incoming messages)

    /// Records a center entry (the OS banner stays GroupChatService's business) when `text`
    /// @mentions one of the current wallet's own KNS domains.
    func recordGroupMentionIfNeeded(groupId: String, groupName: String, senderAddress: String, text: String, txId: String?, timestampMs: Int64) {
        guard let myAddress = WalletManager.shared.currentWallet?.publicAddress,
              senderAddress != myAddress else { return }
        let myDomains = Self.bareDomains(for: myAddress)
        guard !myDomains.isEmpty, Self.mentionedDomains(in: text).contains(where: myDomains.contains) else { return }
        record(
            id: "group-mention-\(txId ?? UUID().uuidString)",
            source: .group,
            title: "\(displayName(for: senderAddress)) mentioned you in \(groupName)",
            body: String(text.prefix(90)),
            timestamp: timestampMs,
            targetId: groupId
        )
    }

    // MARK: - Broadcasts (called from BroadcastService on merged rows)

    func recordBroadcastIfLive(channel: String, senderAddress: String, content: String, txId: String, blockTime: Int64) {
        guard blockTime >= Self.sessionStartMs,
              senderAddress != WalletManager.shared.currentWallet?.publicAddress else { return }
        record(
            id: "broadcast-\(txId)",
            source: .broadcast,
            title: "\(displayName(for: senderAddress)) in #\(channel)",
            body: String(content.prefix(90)),
            timestamp: blockTime,
            targetId: channel
        )
    }

    // MARK: - KaPosts poll

    /// Feeds the bell center from a notifications page some OTHER poller already fetched
    /// (KaPostsNotificationService's 30s loop) — one request, two consumers. Runs regardless
    /// of the OS-ping gates so the bell fills even with notifications disabled.
    func ingestKaPostsNotifications(_ notifications: [KaPostsAPIClient.KNotification]) async {
        guard WalletManager.shared.currentWallet != nil else { return }
        guard !AppSettings.load().childModeEnabled else { return }
        guard let newest = notifications.map(\.timestamp).max() else { return }
        let baseline = (UserDefaults.standard.object(forKey: kaPostsBaselineKey) as? NSNumber)?.int64Value
        guard let lastSeen = baseline else {
            // First run for this wallet: baseline silently, history never floods the center.
            UserDefaults.standard.set(NSNumber(value: newest), forKey: kaPostsBaselineKey)
            return
        }
        UserDefaults.standard.set(NSNumber(value: max(newest, lastSeen)), forKey: kaPostsBaselineKey)
        let myAddress = WalletManager.shared.currentWallet?.publicAddress
        for notification in notifications where notification.timestamp > lastSeen {
            guard let actorAddress = KaPostsAPIClient.kaspaAddress(fromPubkey: notification.userPublicKey),
                  actorAddress != myAddress,
                  !KaPostsModerationStore.shared.isHidden(actorAddress) else { continue }
            // Warm the KNS cache so displayName can use the actor's domain — a cold
            // cache would fall back to the short address even when they own one.
            if KNSService.shared.domainCache[actorAddress] == nil {
                await KNSService.shared.refreshIfNeeded(for: [actorAddress])
            }
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
            // Per-kind tap target, matching the KaPosts notifications sheet: reply/quote-
            // with-text open the reply itself; vote/mention open the containing post.
            let targetTxId: String?
            switch notification.contentType {
            case "reply": targetTxId = notification.id
            case "quote": targetTxId = text.isEmpty ? notification.contentId : notification.id
            case "follow": targetTxId = nil
            // A mention's acting content IS the post/comment mentioning you — fall back to
            // the notification's own txid when contentId is empty, else the row has no target.
            case "mention": targetTxId = (notification.contentId?.isEmpty == false) ? notification.contentId : notification.id
            default: targetTxId = notification.contentId
            }
            record(
                id: "kaposts-\(notification.id)",
                source: .kaposts,
                title: "\(displayName(for: actorAddress)) \(action)",
                body: String(text.prefix(90)),
                timestamp: notification.timestamp,
                targetId: targetTxId
            )
        }
    }

    // MARK: - Helpers

    private func displayName(for address: String) -> String {
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.strippingKasSuffix(assigned)
        }
        if let domain = KNSService.shared.domainCache[address]?.primaryDomain,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    /// The current wallet's own KNS domains, bare (no .kas), lowercased.
    private static func bareDomains(for address: String) -> Set<String> {
        guard let info = KNSService.shared.domainCache[address] else { return [] }
        var out = Set<String>()
        if let primary = info.primaryDomain { out.insert(bare(primary)) }
        for domain in info.allDomains { out.insert(bare(domain.fullName)) }
        out.remove("")
        return out
    }

    private static func bare(_ domain: String) -> String {
        var value = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".kas") { value = String(value.dropLast(4)) }
        return value
    }

    /// @domain tokens in `text` (bare, lowercased) - same regex as the KaPosts mention parser.
    private static func mentionedDomains(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "(^|[\\s(\\[{<\"'])@([a-z0-9-]+(?:\\.[a-z0-9-]+)*)",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            out.append(bare(ns.substring(with: match.range(at: 2))))
        }
        return out
    }
}

/// The bell's sheet: newest-first feed of all sources, source-tagged rows, Clear all.
/// Opening it marks everything seen (clears the bell badge).
struct GlobalNotificationListView: View {
    @ObservedObject private var center = GlobalNotificationCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if center.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bell")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No notifications yet")
                            .font(.headline)
                        Text("KaPosts activity, group @mentions, and live broadcast messages show up here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(center.entries) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.source.icon)
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.semibold))
                                if !entry.body.isEmpty {
                                    Text(entry.body)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 6) {
                                    Text(entry.source.label)
                                    Text(Date(timeIntervalSince1970: TimeInterval(entry.timestamp) / 1000)
                                        .formatted(.relative(presentation: .named)))
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        // Every row deep-opens its subject through the same pending-deep-link
                        // flow the OS notification taps use: KaPosts rows the exact
                        // post/comment, group rows the group thread, broadcast rows the room,
                        // wallet rows the wallet screen.
                        .contentShape(Rectangle())
                        .onTapGesture { open(entry) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear All") { center.clearAll() }
                        .disabled(center.entries.isEmpty)
                }
            }
            .onAppear { center.markAllSeen() }
        }
    }

    /// Routes a tapped row to its subject. The sheet has to close first (only one sheet presents
    /// at a time), so the pending target is staged now and the tab switch posted after the
    /// dismissal animation - the same two-step every notification tap uses.
    private func open(_ entry: GlobalNotificationCenter.Entry) {
        let target = entry.targetId ?? ""
        let childMode = AppSettings.load().childModeEnabled
        switch entry.source {
        case .kaposts:
            // Child Mode hides KaPosts entirely - a row left over from before it was switched
            // on must not open it (mirrors the notification-tap guard in KaChatApp).
            guard !childMode, !target.isEmpty else { return }
            KaPostsDeepLink.pendingPostTxId = target
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NotificationCenter.default.post(name: .openKaPost, object: nil)
            }
        case .group:
            guard !target.isEmpty else { return }
            GroupChatService.shared.pendingGroupNavigation = target
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NotificationCenter.default.post(
                    name: .openGroup,
                    object: nil,
                    userInfo: ["groupId": target]
                )
            }
        case .broadcast:
            guard !childMode, !target.isEmpty else { return }
            BroadcastService.shared.pendingBroadcastNavigation = target
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NotificationCenter.default.post(
                    name: .openBroadcast,
                    object: nil,
                    userInfo: ["channel": target]
                )
            }
        case .wallet:
            // Receipts carry no target of their own - the wallet screen is the subject.
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NotificationCenter.default.post(name: .openPortfolio, object: nil)
            }
        }
    }
}
