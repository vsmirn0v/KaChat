import Foundation
import SwiftUI

/// The bell on the Profile screen: Kaspa arriving in one of your own wallets - the chatting
/// wallet, a spending address, cold storage (fed by AddressActivityNotifier). Nothing else:
/// KaPosts has its own bell, and group chats and public rooms carry their own unread counts in
/// the Chats tab. Entries are account-scoped, persisted, deduped by id, and capped; opening the
/// list marks everything seen.
@MainActor
final class GlobalNotificationCenter: ObservableObject {
    static let shared = GlobalNotificationCenter()

    struct Entry: Identifiable, Codable, Equatable {
        enum Source: String, Codable {
            case kaposts, group, wallet
            /// Stored entries carry the old name.
            case publicChat = "broadcast"

            var label: String {
                switch self {
                case .kaposts: return "KaPosts"
                case .group: return "Group"
                case .publicChat: return "Public Chat"
                case .wallet: return "Wallet"
                }
            }

            var icon: String {
                switch self {
                case .kaposts: return "megaphone"
                case .group: return "person.3"
                case .publicChat: return "dot.radiowaves.left.and.right"
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

    /// Public Chat rows older than app launch are history, not live arrivals - never listed.
    static let sessionStartMs = Int64(Date().timeIntervalSince1970 * 1000)

    private let maxEntries = 100

    var unreadCount: Int {
        entries.filter { $0.timestamp > lastSeenAt }.count
    }

    /// Unread entries from ONE source, for a tab that wants its own badge rather than the
    /// profile bell's total. Public Chats is the only caller today; the numbers deliberately
    /// overlap, because the bell is the whole feed and a tab badge is that tab's share of it.
    func unreadCount(for source: Entry.Source) -> Int {
        entries.filter { $0.source == source && $0.timestamp > lastSeenAt }.count
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
            // Wallet rows only. KaPosts rows live in KaPosts' own bell, group mentions and public
            // rooms carry their own unread counts in the Chats tab; anything an older build saved
            // for those is dropped here so the bell never double-counts.
            let kept = decoded.filter { $0.source == .wallet }
            entries = kept
            if kept.count != decoded.count { persist() }
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
        // KaPosts activity is counted by KaPostsNotificationCenter and listed by the KaPosts
        // notifications screen. Refused here rather than merely left uncalled, so a future caller
        // cannot quietly reintroduce the double-reporting.
        guard source != .kaposts else { return }
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
    /// Group chats carry their own unread counts and mention handling in the Chats tab, so
    /// mentions no longer go through the bell. Kept as a no-op for the call site; rows an
    /// older build recorded are dropped on load (see `reload`).
    func recordGroupMentionIfNeeded(groupId: String, groupName: String, senderAddress: String, text: String, txId: String?, timestampMs: Int64) {}

    // MARK: - Public Chats (called from PublicChatService on merged rows)

    /// Public rooms live in the Chats tab now, with their own unread counts and long-press
    /// controls, so their messages no longer go through the bell. Kept as a no-op for the
    /// call site; rows an older build recorded are dropped on load (see `load`).
    func recordPublicChatIfLive(channel: String, senderAddress: String, content: String, txId: String, blockTime: Int64) {}

    // MARK: - KaPosts poll

    /// Feeds the bell center from a notifications page some OTHER poller already fetched
    /// (KaPostsNotificationService's 30s loop) — one request, two consumers. Runs regardless
    /// of the OS-ping gates so the bell fills even with notifications disabled.
    /// KaPosts has its own bell inside KaPosts; nothing from it goes through this one. Kept as a
    /// no-op for the poller's call site.
    func ingestKaPostsNotifications(_ notifications: [KaPostsAPIClient.KNotification]) async {}

    // MARK: - Helpers

    private func displayName(for address: String) -> String {
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.displayKasName(assigned)
        }
        if let domain = KNSService.shared.domainCache[address]?.primaryDomain,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.displayKasName(domain)
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
                        Text("Kaspa arriving in your wallets and cold storage shows up here.")
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
                        // post/comment, group rows the group thread, public chat rows the room,
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
        case .publicChat:
            guard !childMode, !target.isEmpty else { return }
            PublicChatService.shared.pendingPublicChatNavigation = target
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NotificationCenter.default.post(
                    name: .openPublicChat,
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
