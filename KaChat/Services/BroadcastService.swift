import Foundation
import Combine
import UIKit
import UserNotifications

/// KaChat 2.0 Broadcast feature: public, unencrypted, many-to-many channels.
/// Swift analog of the Android client's `BroadcastRepository` + `BroadcastScanningService`
/// combined - join/leave channels, send broadcasts, and scan new blocks for messages in
/// channels that are currently "wanted" (always-listen or actively viewed).
@MainActor
final class BroadcastService: ObservableObject {
    static let shared = BroadcastService()

    /// Hardcoded curated channels shown in a "Popular" section, matching Android. These two are
    /// AUTO-JOINED for every account (see `ensureFeaturedChannelsJoined`).
    /// nonisolated: read from BroadcastStore's background prune (retention rule) as well as
    /// main-actor UI - immutable Sendable value, safe from anywhere.
    nonisolated static let featuredChannels = ["kaspa", "kachat-bugs"]

    /// Curated per-language rooms, listed behind the collapsible "Other Languages" row under
    /// Popular. Indexer-tracked exactly like the featured rooms (30-day retention, indexer
    /// history, no retention gear, remote-push eligible) but deliberately NOT auto-joined: a
    /// store row is created on first open or bell tap. Auto-joining eleven more rooms would
    /// multiply push registrations, block-scan subscriptions and cellular cost for every user,
    /// including the vast majority who want none of them.
    /// Ordered alphabetically by display name, Latin scripts first (see `languageDisplayName`).
    nonisolated static let languageChannels = [
        "kaspa-indonesia",
        "kaspa-czech",
        "kaspa-german",
        "kaspa-espanol",
        "kaspa-francais",
        "kaspa-portugues",
        "kaspa-romania",
        "kaspa-slovak",
        "kaspa-russian",
        "kaspa-chinese",
        "kaspa-japanese",
        "kaspa-korean",
        "kaspa-hebrew",
    ]

    /// Every indexer-tracked room. EVERYTHING that follows from "the indexer serves this room's
    /// history" keys off this set - 30-day retention, no per-room retention gear, no Leave,
    /// remote-push registration, the cellular block-stream skip, the push-covered local-banner
    /// skip. Only auto-join and the pinned Popular list use `featuredChannels` alone.
    nonisolated static let indexedChannels = featuredChannels + languageChannels

    /// Rooms the app uses as machinery, never shown as chats: the chess arena
    /// (ONLINE_CHESS.md). Hidden from Public Chats, no unread, no banners.
    nonisolated static let serviceChannels: Set<String> = [ChessTournamentCodec.arenaChannel]

    /// Native-language label for a curated language room, e.g. "kaspa-espanol" -> "Español".
    /// Native names (not English ones) so a speaker scanning the list finds their own language.
    nonisolated static func languageDisplayName(for channel: String) -> String? {
        switch BroadcastChannelName.normalize(channel) {
        case "kaspa-indonesia": return "Bahasa Indonesia"
        case "kaspa-czech": return "Čeština"
        case "kaspa-german": return "Deutsch"
        case "kaspa-espanol": return "Español"
        case "kaspa-francais": return "Français"
        case "kaspa-portugues": return "Português"
        case "kaspa-romania": return "Română"
        case "kaspa-slovak": return "Slovenčina"
        case "kaspa-russian": return "Русский"
        case "kaspa-chinese": return "中文"
        case "kaspa-japanese": return "日本語"
        case "kaspa-korean": return "한국어"
        case "kaspa-hebrew": return "עברית"
        default: return nil
        }
    }

    @Published private(set) var channels: [BroadcastChannel] = []
    @Published private(set) var messagesByChannel: [String: [BroadcastMessage]] = [:]
    /// This wallet's broadcast reactions, keyed by channel then by targetTxId - mirrors
    /// `GroupChatService.reactionsByGroupId`'s shape (and reuses `GroupStore.ReactionSnapshot`,
    /// see `BroadcastStore.fetchReactions`). Loaded per channel on open (`acquire`) and kept
    /// live afterward by `sendBroadcastReaction` / the incoming-reaction interception in
    /// `processBroadcastHits` and `fetchFromIndexerAndMerge`.
    @Published private(set) var reactionsByChannel: [String: [String: [GroupStore.ReactionSnapshot]]] = [:]
    /// The newest edit per message txId, per room - see `MessageEditCodec`.
    @Published private(set) var editsByChannel: [String: [String: MessageEditSnapshot]] = [:]
    /// The room message whose text the composer is editing (the user's own) - see `sendBroadcastEdit`.
    @Published var editingMessage: BroadcastMessage?
    @Published var lastSendError: KasiaError?
    @Published var replyingTo: BroadcastMessage?
    /// Set when a broadcast-room notification is tapped, so the chat list can navigate to that
    /// room - mirrors `ChatService.pendingChatNavigation`'s cold-start handling.
    @Published var pendingBroadcastNavigation: String?

    /// Shows a "Popular" tab of curated channels in the list screen. Default matches Android.
    private let store = BroadcastStore.shared

    /// Reference count of open channel screens ("live viewing"), keyed by normalized name.
    private var liveViewRefCounts: [String: Int] = [:]
    private var blockNotificationHandlerId: UUID?
    private var isScanningActive = false
    /// pendingId of broadcasts with an auto-retry already scheduled - prevents scheduling a
    /// duplicate retry if `sendBroadcastInternal` fails again before the first retry fires.
    private var scheduledSendRetries: Set<String> = []

    /// Fast pre-filter for the broadcast payload prefix, applied to the still-hex-encoded
    /// `Protowire_RpcTransaction.payload` before paying the cost of hex-decoding it - avoids
    /// decoding every transaction in every new block just to reject non-broadcast ones.
    private nonisolated static func hexOf(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
    private nonisolated static let bcastPrefixHex: String = hexOf("kchat:1:bcast:")        // write + read
    private nonisolated static let legacyBcastPrefixHex: String = hexOf("ciph_msg:1:bcast:") // read-only

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // On expensive (cellular/metered) paths, indexer-covered rooms stop block-streaming
        // (see scanWantedChannels) - re-evaluate whenever the path flips either way.
        NetworkEpochMonitor.shared.expensivePathPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateScanningStateIfNeeded()
            }
            .store(in: &cancellables)
        // The closed-room sweep runs only while the app is on screen (see sweepClosedRooms).
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.startForegroundSweep() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stopForegroundSweep() }
            .store(in: &cancellables)
    }

    // MARK: - Wallet lifecycle

    /// Switch to a different wallet's broadcast store. Call alongside
    /// `MessageStore.shared.setCurrentWallet` at every wallet-lifecycle transition.
    func setCurrentWallet(_ walletAddress: String?) {
        store.setCurrentWallet(walletAddress)
        self.walletAddress = walletAddress?.lowercased()
        messagesByChannel = [:]
        reactionsByChannel = [:]
        liveViewRefCounts = [:]
        loadReadState()
        refreshChannels()
        applyFeaturedNotifyDefaultIfNeeded()
        updateScanningStateIfNeeded()
        sweptChannels = []
        if UIApplication.shared.applicationState == .active { startForegroundSweep() }
    }

    // MARK: - Foreground sweep of closed rooms

    /// The loop behind `sweepClosedRooms`, alive while the app is active.
    private var foregroundSweepTask: Task<Void, Never>?
    /// Rooms the sweep has asked about at least once this session: only rows found AFTER that
    /// first pass are news worth a banner - the first pass is history catching up.
    private var sweptChannels: Set<String> = []
    private static let foregroundSweepIntervalNanos: UInt64 = 20 * 1_000_000_000
    /// Rows older than this are not bannered even when new to the store - they are backlog,
    /// not a message that just arrived.
    private static let sweepBannerWindowMs: Int64 = 3 * 60 * 1000

    /// While the app is on screen, a room the user is NOT looking at used to be refreshed only
    /// by the live block scan - which misses blocks whenever the stream reconnects, and is off
    /// altogether for indexed rooms on cellular (`scanWantedChannels`) where the remote push
    /// that covers them is dropped in the foreground. So a message in #kaspa showed up only
    /// once the room was opened. This is the fix, the same shape as 1:1 chat's foreground
    /// contact sweep: every 20 s, each joined room with its bell on that is not open asks the
    /// indexer for its newest rows (one small request per room, sequential). The open room
    /// keeps its own 8 s poll; the block scan stays as the fast path.
    func startForegroundSweep() {
        guard foregroundSweepTask == nil else { return }
        foregroundSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if UIApplication.shared.applicationState == .active {
                    await self.sweepClosedRooms()
                }
                try? await Task.sleep(nanoseconds: Self.foregroundSweepIntervalNanos)
            }
        }
    }

    func stopForegroundSweep() {
        foregroundSweepTask?.cancel()
        foregroundSweepTask = nil
    }

    private func sweepClosedRooms() async {
        let targets = channels.filter {
            $0.notifyEnabled && !isViewing(channel: $0.channelName)
                && !Self.serviceChannels.contains($0.channelName)
                && !Self.indexerBaseURL(forChannel: $0.channelName).isEmpty
        }
        for channel in targets {
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            await fetchNewestAndMerge(channel: channel.channelName)
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// One small newest-page fetch for a closed room, merged like any other indexer page;
    /// rows that are new to the store and recent get the same in-app banner the scan gives.
    /// Asks the indexer for a room's newest rows right now and merges them - what the chess
    /// arena does just before a player picks a room, so the choice is made on the freshest
    /// shared view rather than whatever this phone happened to hold. Returns false when there
    /// is no indexer for the room or the request failed.
    @discardableResult
    func refreshFromIndexerNow(channel rawChannel: String) async -> Bool {
        let channel = BroadcastChannelName.normalize(rawChannel)
        guard !Self.indexerBaseURL(forChannel: channel).isEmpty else { return false }
        return await fetchNewestAndMerge(channel: channel)
    }

    @discardableResult
    private func fetchNewestAndMerge(channel: String) async -> Bool {
        let base = Self.indexerBaseURL(forChannel: channel)
        guard !base.isEmpty else { return false }
        do {
            let page = try await BroadcastIndexerClient.fetchHistoryPage(baseURL: base, channel: channel, limit: 40)
            indexerFetchedChannels.insert(channel)
            let hidden = store.hiddenSenderAddresses(forChannel: channel)
            var editsChanged = false
            for row in page.messages where !hidden.contains(row.senderAddress) {
                guard let edit = MessageEditCodec.parse(row.content) else { continue }
                if applyIncomingEdit(edit, channel: channel, senderAddress: row.senderAddress, editTxId: row.txId, blockTime: row.blockTime) {
                    editsChanged = true
                }
            }
            if editsChanged { loadEdits(for: channel) }
            let rows = page.messages
                .filter { !hidden.contains($0.senderAddress) && MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil }
                .map { (id: $0.txId, channel: channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime) }
            let known = Set(store.messages(forChannel: channel).map(\.id))
            let fresh = rows.filter { !known.contains($0.id) }
            let firstPass = !sweptChannels.contains(channel)
            sweptChannels.insert(channel)
            if Self.serviceChannels.contains(channel) {
                // Our own arena rows take the chain's block time - see processBroadcastHits.
                var changed = false
                for row in rows where store.updateBlockTime(id: row.id, blockTime: row.blockTime) { changed = true }
                if changed { loadMessages(for: channel) }
            }
            guard !fresh.isEmpty else { return true }
            let inserted = await store.insertMessages(fresh)
            guard inserted > 0 else { return true }
            store.pruneExpiredMessages()
            loadMessages(for: channel)
            guard !firstPass else { return true }
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - Self.sweepBannerWindowMs
            for row in fresh where row.blockTime > cutoff {
                notifyIfEnabled(channel: channel, senderAddress: row.senderAddress, content: row.content, txId: row.id)
            }
            return true
        } catch {
            // Best-effort; the next sweep tries again.
            AppLog.log("%@", "[Broadcast] Sweep fetch failed for #\(channel): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Read state (the Public Chats list's unread counts)

    private var walletAddress: String?
    /// Per room, the block time (ms) up to which the reader has seen it. Per wallet.
    @Published private(set) var lastReadByChannel: [String: Int64] = [:]
    /// Rooms marked unread by hand, which show a badge even with nothing new in them.
    @Published private(set) var manuallyUnreadChannels: Set<String> = []

    /// Default (curated) rooms switched off in Public Chats settings: gone from the list, never
    /// notifying, not counted. Per wallet.
    @Published private(set) var hiddenCuratedChannels: Set<String> = []
    private var hiddenCuratedKey: String? { walletAddress.map { "kachat_broadcast_hidden_curated_\($0)" } }

    func isCuratedChannelShown(_ name: String) -> Bool {
        !hiddenCuratedChannels.contains(BroadcastChannelName.normalize(name))
    }

    /// Off: the room leaves the list and its notifications stop (the bell goes off, which also
    /// takes it off the push service's watch list). On: it comes back - #kaspa and
    /// #kachat-bugs with their bell on again, as they start; the language rooms as they were.
    func setCuratedChannel(_ rawName: String, shown: Bool) {
        let name = BroadcastChannelName.normalize(rawName)
        guard Self.indexedChannels.contains(name) else { return }
        if shown {
            hiddenCuratedChannels.remove(name)
        } else {
            hiddenCuratedChannels.insert(name)
        }
        if let key = hiddenCuratedKey {
            UserDefaults.standard.set(Array(hiddenCuratedChannels), forKey: key)
        }
        let isJoined = channels.contains { $0.channelName == name }
        if !shown, isJoined {
            setNotifyEnabled(false, forChannel: name)
        } else if shown, isJoined, Self.featuredChannels.contains(name) {
            setNotifyEnabled(true, forChannel: name)
        }
    }

    private var lastReadKey: String? { walletAddress.map { "kachat_broadcast_last_read_\($0)" } }
    private var manualUnreadKey: String? { walletAddress.map { "kachat_broadcast_manual_unread_\($0)" } }

    private func loadReadState() {
        let defaults = UserDefaults.standard
        if let key = lastReadKey, let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            lastReadByChannel = decoded
        } else {
            lastReadByChannel = [:]
        }
        manuallyUnreadChannels = Set(manualUnreadKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
        hiddenCuratedChannels = Set(hiddenCuratedKey.flatMap { defaults.stringArray(forKey: $0) } ?? [])
    }

    private func persistReadState() {
        let defaults = UserDefaults.standard
        if let key = lastReadKey, let data = try? JSONEncoder().encode(lastReadByChannel) {
            defaults.set(data, forKey: key)
        }
        if let key = manualUnreadKey {
            defaults.set(Array(manuallyUnreadChannels), forKey: key)
        }
    }

    /// Messages from other people newer than the read marker. A room seen for the first time
    /// counts from now, not from the start of its history.
    func unreadCount(forChannel name: String) -> Int {
        let channel = BroadcastChannelName.normalize(name)
        guard !isViewing(channel: channel), !hiddenCuratedChannels.contains(channel) else { return 0 }
        let manual = manuallyUnreadChannels.contains(channel) ? 1 : 0
        guard let marker = lastReadByChannel[channel] else { return manual }
        let mine = WalletManager.shared.currentWallet?.publicAddress
        let count = (messagesByChannel[channel] ?? []).reduce(0) { total, message in
            message.blockTime > marker && message.senderAddress != mine ? total + 1 : total
        }
        return max(count, manual)
    }

    var totalUnreadCount: Int {
        channels.filter { !Self.serviceChannels.contains($0.channelName) }
            .reduce(0) { $0 + unreadCount(forChannel: $1.channelName) }
    }

    func markChannelRead(_ name: String) {
        let channel = BroadcastChannelName.normalize(name)
        let newest = messagesByChannel[channel]?.last?.blockTime ?? 0
        lastReadByChannel[channel] = max(newest, Int64(Date().timeIntervalSince1970 * 1000))
        manuallyUnreadChannels.remove(channel)
        persistReadState()
    }

    func markChannelUnread(_ name: String) {
        manuallyUnreadChannels.insert(BroadcastChannelName.normalize(name))
        persistReadState()
    }

    /// Loads every joined room's stored messages so the list can show last message, time and
    /// unread count, and starts a read marker for rooms that have none.
    func primeChannelSummaries() {
        var seeded = false
        for channel in channels {
            if messagesByChannel[channel.channelName] == nil { loadMessages(for: channel.channelName) }
            if lastReadByChannel[channel.channelName] == nil {
                lastReadByChannel[channel.channelName] = Int64(Date().timeIntervalSince1970 * 1000)
                seeded = true
            }
        }
        if seeded { persistReadState() }
    }

    /// #kaspa and #kachat-bugs notify by default. Applied once per wallet, so a bell the user
    /// later switches off stays off.
    private func applyFeaturedNotifyDefaultIfNeeded() {
        guard let walletAddress else { return }
        let key = "kachat_broadcast_featured_notify_default_\(walletAddress)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let joined = Set(channels.map(\.channelName))
        guard Self.featuredChannels.allSatisfy(joined.contains) else { return }
        for name in Self.featuredChannels where !hiddenCuratedChannels.contains(name) {
            store.setNotifyEnabled(true, forChannel: name)
        }
        UserDefaults.standard.set(true, forKey: key)
        refreshChannels()
        Task { await PushNotificationManager.shared.updateWatchedAddresses() }
    }

    // MARK: - Channel membership

    func refreshChannels() {
        channels = store.joinedChannels()
    }

    var featuredChannelsNotJoined: [String] {
        let joined = Set(channels.map { $0.channelName })
        return Self.featuredChannels.filter { !joined.contains($0) }
    }

    /// The curated Popular rooms are permanent fixtures of the list screen - make sure they
    /// have store rows (bell state etc.) without requiring an explicit join.
    func ensureFeaturedChannelsJoined() {
        for name in Self.featuredChannels {
            _ = store.joinChannel(name)
        }
        refreshChannels()
        applyFeaturedNotifyDefaultIfNeeded()
    }

    @discardableResult
    func joinChannel(_ rawName: String) -> Bool {
        guard store.joinChannel(rawName) else { return false }
        refreshChannels()
        return true
    }

    func leaveChannel(_ name: String) {
        // Curated rooms (Popular and the language rooms alike) can't be left - both are
        // permanent fixtures of the list screen, so no UI offers it; guard against stray paths.
        guard !Self.indexedChannels.contains(BroadcastChannelName.normalize(name)) else { return }
        let normalized = BroadcastChannelName.normalize(name)
        store.leaveChannel(normalized)
        messagesByChannel.removeValue(forKey: normalized)
        reactionsByChannel.removeValue(forKey: normalized)
        liveViewRefCounts.removeValue(forKey: normalized)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    func setNotifyEnabled(_ enabled: Bool, forChannel name: String) {
        // Indexed channels' bells also gate remote push - sync the registration so the push
        // service starts/stops sending for this channel.
        if Self.indexedChannels.contains(BroadcastChannelName.normalize(name)) {
            Task { await PushNotificationManager.shared.updateWatchedAddresses() }
        }
        store.setNotifyEnabled(enabled, forChannel: name)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    // MARK: - Hidden senders

    func hideSender(_ address: String, inChannel channel: String) {
        store.hideSender(address, inChannel: channel)
        syncHiddenSendersToPushIfNeeded(channel: channel)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
    }

    func unhideSender(_ address: String, inChannel channel: String) {
        store.unhideSender(address, inChannel: channel)
        syncHiddenSendersToPushIfNeeded(channel: channel)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
    }

    func hiddenSenderAddresses(forChannel channel: String) -> Set<String> {
        store.hiddenSenderAddresses(forChannel: channel)
    }

    // MARK: - Per-room indexer

    /// Channel -> indexer base URL, for rooms the user pointed somewhere other than the app's
    /// configured broadcast indexer.
    ///
    /// A broadcast is on-chain, so any indexer that watches the same network serves the same
    /// room - which means a room can be read through whichever one you trust or host, without
    /// changing the app-wide setting that every OTHER room uses. Empty here means "use the
    /// app-wide one", which is what the curated Popular rooms do (KaChat's own indexer).
    // nonisolated: `indexerBaseURL(forChannel:)` is nonisolated so callers off the main actor
    // can resolve a room's indexer, and a main-actor-isolated constant is not reachable from it.
    private nonisolated static let indexerOverridesKey = "kachat_broadcast_indexer_overrides"

    private var indexerOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.indexerOverridesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.indexerOverridesKey) }
    }

    /// The indexer this room reads from: its own override, or the app-wide broadcast indexer.
    nonisolated static func indexerBaseURL(forChannel channel: String) -> String {
        let overrides = UserDefaults.standard.dictionary(forKey: indexerOverridesKey) as? [String: String] ?? [:]
        let own = overrides[BroadcastChannelName.normalize(channel)]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let own, !own.isEmpty { return own }
        return AppSettings.load().broadcastIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// This room's override as the user typed it, or "" when it follows the app-wide setting.
    func indexerOverride(forChannel channel: String) -> String {
        indexerOverrides[BroadcastChannelName.normalize(channel)] ?? ""
    }

    /// Points one room at its own indexer. An empty (or whitespace) value clears the override so
    /// the room follows the app-wide setting again. Restarts this room's polling so the change
    /// takes effect without leaving the room.
    func setIndexerOverride(_ url: String, forChannel channel: String) {
        let key = BroadcastChannelName.normalize(channel)
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var overrides = indexerOverrides
        if trimmed.isEmpty { overrides.removeValue(forKey: key) } else { overrides[key] = trimmed }
        indexerOverrides = overrides
        stopIndexerPolling(channel: key)
        if isViewing(channel: key) { startIndexerPollingIfConfigured(channel: key) }
    }

    func hiddenSendersByChannel() -> (global: Set<String>, perChannel: [String: Set<String>]) {
        store.hiddenSendersByChannel()
    }

    /// Hides in the indexed channels also gate server-side push - re-sync the registration so
    /// the push service stops (or resumes) sending for that sender.
    private func syncHiddenSendersToPushIfNeeded(channel: String) {
        guard Self.indexedChannels.contains(BroadcastChannelName.normalize(channel)) else { return }
        Task { await PushNotificationManager.shared.updateWatchedAddresses() }
    }

    // MARK: - Live viewing (reference counted)

    /// Call when a broadcast channel screen appears; pairs with `release`.
    func acquire(_ name: String) {
        let normalized = BroadcastChannelName.normalize(name)
        ChatService.clearDeliveredNotifications(threadIdentifier: "broadcast:\(normalized)")
        liveViewRefCounts[normalized, default: 0] += 1
        store.pruneExpiredMessages()
        loadMessages(for: normalized)
        markChannelRead(normalized)
        loadReactions(for: normalized)
        loadEdits(for: normalized)
        updateScanningStateIfNeeded()
        startIndexerPollingIfConfigured(channel: normalized)
    }

    /// Per-channel indexer poll loops, running while that channel's screen is open.
    private var indexerPollTasks: [String: Task<Void, Never>] = [:]
    /// Channels whose FULL indexer history (up to the 30-day window) was already paged in this
    /// session — the deep backfill runs once per room per launch; the 8s poll then only needs
    /// the newest page to stay fresh.
    private var deepBackfilledChannels: Set<String> = []
    /// Channels the indexer has answered at least once this session - the chess arena waits
    /// for this before letting a player pick a room (`ChessTournamentService.historyReady`).
    @Published private(set) var indexerFetchedChannels: Set<String> = []
    /// Where an interrupted deep backfill picks up: the `before` cursor of the next page to
    /// ask for, and how many pages of the safety valve are left. Session-only, like the
    /// completed set above. Without this a single thrown page - one timeout on page 30 of a
    /// busy room - restarted the whole pager from page 1 on the next 8s tick, and kept doing
    /// so until every page happened to succeed in one go.
    private var deepBackfillResume: [String: (before: Int64, pagesLeft: Int)] = [:]
    private static let indexerPollIntervalNanos: UInt64 = 8 * 1_000_000_000

    /// While a room is open, the KaChat broadcast indexer is polled every few seconds and new
    /// rows merge into the local store (txid-deduped) - live block scanning alone proved
    /// unreliable for freshness (the indexer had messages the app never showed). First fetch
    /// fires immediately on open, so history backfill is included. No-op when the URL is unset;
    /// hidden senders and retention pruning apply exactly like scanned rows.
    private func startIndexerPollingIfConfigured(channel: String) {
        guard indexerPollTasks[channel] == nil else { return }
        let base = Self.indexerBaseURL(forChannel: channel)
        guard !base.isEmpty else { return }
        indexerPollTasks[channel] = Task { [weak self] in
            while !Task.isCancelled {
                // The room view stays mounted (and this loop alive) while the app is in the
                // background, but there is nobody to show a fresh row to - skip the network
                // work until the app is active again, the same gate the open-chat poll uses.
                if UIApplication.shared.applicationState == .active {
                    await self?.fetchFromIndexerAndMerge(baseURL: base, channel: channel)
                }
                try? await Task.sleep(nanoseconds: Self.indexerPollIntervalNanos)
            }
        }
    }

    private func stopIndexerPolling(channel: String) {
        indexerPollTasks[channel]?.cancel()
        indexerPollTasks[channel] = nil
    }

    private func fetchFromIndexerAndMerge(baseURL: String, channel: String) async {
        do {
            // Steady-state polls only need the newest few rows (everything older is already in
            // the store, txid-deduped); re-fetching 200 rows every 8s was pure re-download. The
            // one-shot deep backfill below keeps the full 200-row pages. The indexer's `before`
            // parameter pages OLDER history, so it cannot act as a newest-side floor - the
            // small limit is the mechanism. A burst larger than 30 between two polls is
            // recovered on the next room open (deep backfill re-runs per session).
            let steadyStateLimit = deepBackfilledChannels.contains(channel) ? 30 : 200
            var messages = try await BroadcastIndexerClient.fetchHistoryPage(
                baseURL: baseURL, channel: channel, limit: steadyStateLimit
            )
            indexerFetchedChannels.insert(channel)
            // One-shot deep backfill per room per session: page older history with `before`
            // until the indexer runs out or we reach its 30-day window. Without this, rooms
            // only ever showed the newest single page (200 rows) — busy rooms like
            // #kachat-bugs never loaded anywhere near the 30 days the indexer holds.
            if !deepBackfilledChannels.contains(channel) {
                let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - BroadcastStore.indexerRetentionMillis
                var hasMore: Bool
                var oldest: Int64?
                var pagesLeft: Int
                if let resume = deepBackfillResume[channel] {
                    // Picking up an interrupted pager: everything newer than this cursor is
                    // already in the store from the attempt that recorded it.
                    hasMore = true
                    oldest = resume.before
                    pagesLeft = resume.pagesLeft
                } else {
                    hasMore = messages.hasMore
                    oldest = messages.messages.map(\.blockTime).min()
                    pagesLeft = 50 // safety valve: 50 × 200 = 10k rows, far beyond any real room
                }
                var interrupted = false
                while hasMore, let before = oldest, before > cutoff, pagesLeft > 0 {
                    pagesLeft -= 1
                    let page: (messages: [BroadcastIndexerClient.IndexedBroadcast], hasMore: Bool)
                    do {
                        page = try await BroadcastIndexerClient.fetchHistoryPage(
                            baseURL: baseURL, channel: channel, before: before
                        )
                    } catch {
                        // Keep what this attempt did get: the pages already appended still
                        // merge below, and the cursor recorded after each of them is where the
                        // next 8s tick resumes - not page 1.
                        AppLog.log("%@", "[Broadcast] Deep backfill for #\(channel) paused at before=\(before): \(error.localizedDescription)")
                        interrupted = true
                        break
                    }
                    guard !page.messages.isEmpty else { break }
                    messages.messages.append(contentsOf: page.messages)
                    hasMore = page.hasMore
                    oldest = page.messages.map(\.blockTime).min()
                    if hasMore, let next = oldest {
                        deepBackfillResume[channel] = (before: next, pagesLeft: pagesLeft)
                    }
                }
                // Marked done only once the pager actually finishes; a paused one keeps its
                // resume cursor and the next poll continues from there.
                if !interrupted {
                    deepBackfilledChannels.insert(channel)
                    deepBackfillResume[channel] = nil
                }
            }
            let hidden = store.hiddenSenderAddresses(forChannel: channel)
            let visible = messages.messages.filter { !hidden.contains($0.senderAddress) }

            // Reactions never become visible message rows - route them to the per-channel
            // reactions index instead (newest-blockTime-wins per (target, reactor), so
            // re-serving the same history every poll is idempotent - see
            // `BroadcastStore.applyIncomingReaction`).
            var reactionsChanged = false
            var editsChanged = false
            for row in visible {
                if let edit = MessageEditCodec.parse(row.content) {
                    if applyIncomingEdit(edit, channel: channel, senderAddress: row.senderAddress, editTxId: row.txId, blockTime: row.blockTime) {
                        editsChanged = true
                    }
                    continue
                }
                guard let reaction = MessageReactionCodec.parse(row.content) else { continue }
                let changed = store.applyIncomingReaction(
                    targetTxId: reaction.targetTxId,
                    channel: channel,
                    reactorAddress: row.senderAddress,
                    emoji: reaction.action == "remove" ? nil : reaction.emoji,
                    reactionTxId: row.txId,
                    blockTime: row.blockTime
                )
                reactionsChanged = reactionsChanged || changed
            }
            if reactionsChanged {
                loadReactions(for: channel)
            }
            if editsChanged {
                loadEdits(for: channel)
            }

            let rows = visible
                .filter { MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil }
                .map { (id: $0.txId, channel: channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime) }
            var insertedCount = await store.insertMessages(rows)
            if Self.serviceChannels.contains(channel) {
                // Rows this phone sent carry its own clock until the chain's time reaches us -
                // see processBroadcastHits.
                for row in rows where store.updateBlockTime(id: row.id, blockTime: row.blockTime) {
                    insertedCount += 1
                }
            }
            if insertedCount > 0 {
                store.pruneExpiredMessages()
                loadMessages(for: channel)
            }
            // Global notification center: live (session-gated) incoming channel messages. The
            // center dedupes by txId, so re-serving the same history every poll is a no-op.
            // The center stores the body verbatim, so hand it the FRIENDLY preview rather than
            // the raw wire content: a broadcast reply/voice/photo/chess message is a JSON
            // envelope (`MessageReplyCodec` and friends) and would otherwise show as raw JSON
            // in the bell list. Same call the scan-driven local banner already makes below in
            // `notifyIfEnabled`.
            for row in rows {
                GlobalNotificationCenter.shared.recordBroadcastIfLive(
                    channel: channel, senderAddress: row.senderAddress,
                    content: MessageReplyCodec.previewText(for: row.content),
                    txId: row.id, blockTime: row.blockTime
                )
            }
        } catch {
            // Best-effort on top of live scanning - the loop just tries again next tick.
            AppLog.log("%@", "[Broadcast] Indexer fetch failed for #\(channel): \(error.localizedDescription)")
        }
    }

    /// True while this channel's room screen is open (the acquire/release refcount) - the
    /// notification policy's "currently open conversation": banners for a room the user is
    /// looking at are suppressed (here for scan-driven local banners, and in
    /// `AppDelegate.willPresent` for remote pushes), everything else fires even in-app.
    func isViewing(channel: String) -> Bool {
        liveViewRefCounts[BroadcastChannelName.normalize(channel)] != nil
    }

    /// Call when a broadcast channel screen disappears; pairs with `acquire`.
    func release(_ name: String) {
        let normalized = BroadcastChannelName.normalize(name)
        guard let count = liveViewRefCounts[normalized] else { return }
        if count <= 1 {
            // Everything that arrived while the room was open has been seen.
            markChannelRead(normalized)
            liveViewRefCounts.removeValue(forKey: normalized)
            stopIndexerPolling(channel: normalized)
        } else {
            liveViewRefCounts[normalized] = count - 1
        }
        updateScanningStateIfNeeded()
    }

    private var wantedChannels: Set<String> {
        var wanted = Set(liveViewRefCounts.keys)
        // The bell is the one control: a room with notifications on is listened to while the app
        // is open (that is what lets it notify, and count unread), any room. The separate
        // "listen" switch is gone; a value stored by an older build is no longer read.
        for channel in channels where channel.notifyEnabled {
            wanted.insert(channel.channelName)
        }
        return wanted
    }

    // MARK: - Messages

    func messages(forChannel name: String) -> [BroadcastMessage] {
        messagesByChannel[BroadcastChannelName.normalize(name)] ?? []
    }

    /// Aggregated reactions for a channel, keyed by the reacted-to message's txId.
    func reactions(forChannel name: String) -> [String: [GroupStore.ReactionSnapshot]] {
        reactionsByChannel[BroadcastChannelName.normalize(name)] ?? [:]
    }

    func edits(forChannel name: String) -> [String: MessageEditSnapshot] {
        editsByChannel[BroadcastChannelName.normalize(name)] ?? [:]
    }

    private func loadEdits(for channel: String) {
        let fresh = store.fetchEdits(forChannel: channel)
        guard editsByChannel[channel] != fresh else { return }
        editsByChannel[channel] = fresh
    }

    /// An edit envelope seen in a room (scan, indexer page or sweep): applied if its sender
    /// sent the message it names and that message is text. Returns whether anything changed.
    private func applyIncomingEdit(_ edit: MessageEditContent, channel: String, senderAddress: String, editTxId: String, blockTime: Int64) -> Bool {
        guard let target = store.sender(ofMessage: edit.targetTxId),
              target.senderAddress == senderAddress,
              MessageEditCodec.isEditable(target.content) else { return false }
        return store.upsertEdit(targetTxId: edit.targetTxId, channel: channel, text: edit.text, editTxId: editTxId, blockTime: blockTime, deliveryStatus: nil)
    }

    // MARK: - Edit

    func startEditing(_ message: BroadcastMessage) {
        replyingTo = nil
        editingMessage = message
    }

    func cancelEditing() {
        editingMessage = nil
    }

    /// Edits one of this wallet's own text messages in a room: applied locally at once
    /// (pending), then sent as an edit envelope exactly like a reaction - one transaction, no
    /// message row of its own. Sent or failed follow.
    func sendBroadcastEdit(channel rawChannel: String, targetTxId: String, text: String) async throws {
        let channel = BroadcastChannelName.normalize(rawChannel)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let privateKey = WalletManager.shared.getPrivateKey() else { throw KasiaError.keychainError("Could not get private key") }
        editingMessage = nil
        let payload = MessageEditCodec.encode(targetTxId: targetTxId, text: clean)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        store.upsertEdit(targetTxId: targetTxId, channel: channel, text: clean, editTxId: nil, blockTime: now, deliveryStatus: "pending")
        loadEdits(for: channel)
        do {
            let realTxId = try await ChatService.shared.enqueueOutgoingTxOperation {
                try await self.sendBroadcastInternal(
                    channel: channel, content: payload, walletAddress: wallet.publicAddress,
                    privateKey: privateKey, pendingId: "edit_\(UUID().uuidString)"
                )
            }
            store.upsertEdit(targetTxId: targetTxId, channel: channel, text: clean, editTxId: realTxId, blockTime: now, deliveryStatus: nil)
            loadEdits(for: channel)
        } catch {
            store.upsertEdit(targetTxId: targetTxId, channel: channel, text: clean, editTxId: nil, blockTime: now, deliveryStatus: "failed")
            loadEdits(for: channel)
            throw error
        }
    }

    private func loadReactions(for channel: String) {
        let fresh = store.fetchReactions(forChannel: channel)
        guard reactionsByChannel[channel] != fresh else { return }
        reactionsByChannel[channel] = fresh
    }

    private func loadMessages(for channel: String) {
        // Reaction envelopes are never rendered as message rows - drop any that made it into
        // the message table (rows scanned by an app version that predates reactions).
        let fresh = store.messages(forChannel: channel)
            .filter { MessageReactionCodec.parse($0.content) == nil && MessageEditCodec.parse($0.content) == nil }
        // Only actually publish when the content changed - this is polled once a second while a
        // channel is open (for live retention pruning), and `@Published` fires on every
        // assignment regardless of equality, so an unconditional assignment here was re-rendering
        // the whole message list - including an open avatar menu - about once a second even when
        // nothing had changed.
        guard messagesByChannel[channel] != fresh else { return }
        messagesByChannel[channel] = fresh
    }

    /// Prunes expired messages across all joined channels and refreshes the given channel's
    /// visible list - called on a short timer while a channel screen is open so retention feels
    /// live (a message actually disappears from the room a few seconds after it expires, rather
    /// than only on next open or next incoming message).
    func pruneNowAndRefresh(forChannel name: String) {
        // Only re-fetch/re-map the channel's messages when a prune actually removed something -
        // this is polled once a second while a room is open, and re-reading + re-mapping the whole
        // message list on the main queue every second when nothing expired was pure waste.
        if store.pruneExpiredMessages() {
            loadMessages(for: BroadcastChannelName.normalize(name))
        }
    }

    // MARK: - Reply

    func startReplyTo(_ message: BroadcastMessage) {
        replyingTo = message
    }

    func cancelReply() {
        replyingTo = nil
    }

    // MARK: - Retry

    func retryBroadcast(_ message: BroadcastMessage) {
        guard message.deliveryStatus == .failed else { return }
        guard let wallet = WalletManager.shared.currentWallet, wallet.publicAddress == message.senderAddress else { return }
        guard let privateKey = WalletManager.shared.getPrivateKey() else { return }

        let channel = message.channelName
        let content = message.content
        let pendingId = message.id

        store.updateMessageStatus(id: pendingId, status: .pending)
        loadMessages(for: channel)

        Task {
            do {
                _ = try await ChatService.shared.enqueueOutgoingTxOperation {
                    try await self.sendBroadcastInternal(
                        channel: channel,
                        content: content,
                        walletAddress: wallet.publicAddress,
                        privateKey: privateKey,
                        pendingId: pendingId
                    )
                }
            } catch {
                try? await self.handleSendFailure(
                    error,
                    channel: channel,
                    content: content,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey,
                    pendingId: pendingId
                )
            }
        }
    }

    // MARK: - Reactions

    /// Reacts to `targetTxId` with `emoji` ("add"), or removes this wallet's existing reaction
    /// on it ("remove") - mirroring `GroupChatService.sendGroupReaction`'s optimistic-apply/
    /// status-flip flow. The wire format is a NORMAL broadcast whose content is the shared
    /// `MessageReactionCodec` JSON ({"type":"reaction","targetTxId":...,"emoji":...,"action":
    /// "add"|"remove"}), sent through the exact same tx pipeline as a text broadcast (no reply
    /// wrapping) - Android and desktop speak the identical shape. Never creates a visible
    /// message row; receivers intercept it into their reactions index instead.
    func sendBroadcastReaction(channel rawChannel: String, targetTxId: String, emoji: String, action: String) async throws {
        let channel = BroadcastChannelName.normalize(rawChannel)
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        let payload = MessageReactionCodec.encode(targetTxId: targetTxId, emoji: emoji, action: action)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)

        // Optimistic local apply: pending "add" shows the pill immediately; "remove" clears it.
        // A remove is stored as a tombstone (emoji nil) rather than a row delete - see
        // `BroadcastStore`'s Reactions doc comment for why.
        store.upsertOwnReaction(
            targetTxId: targetTxId,
            channel: channel,
            reactorAddress: wallet.publicAddress,
            emoji: action == "remove" ? nil : emoji,
            reactionTxId: nil,
            blockTime: nowMillis,
            deliveryStatus: action == "remove" ? nil : "pending"
        )
        loadReactions(for: channel)

        do {
            let realTxId = try await ChatService.shared.enqueueOutgoingTxOperation {
                try await self.sendBroadcastInternal(
                    channel: channel,
                    content: payload,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey,
                    pendingId: "reaction_\(UUID().uuidString)"
                )
            }
            store.upsertOwnReaction(
                targetTxId: targetTxId,
                channel: channel,
                reactorAddress: wallet.publicAddress,
                emoji: action == "remove" ? nil : emoji,
                reactionTxId: realTxId,
                blockTime: Int64(Date().timeIntervalSince1970 * 1000),
                deliveryStatus: action == "remove" ? nil : "sent"
            )
            loadReactions(for: channel)
        } catch {
            // The reaction tx failed to send. Flag it failed so the pill shows the red error
            // icon and a Retry appears under the message. A failed "remove" restores the
            // optimistically-cleared emoji (marked failed) so it isn't silently lost - Retry
            // re-attempts the correct action, matching group chat exactly.
            store.upsertOwnReaction(
                targetTxId: targetTxId,
                channel: channel,
                reactorAddress: wallet.publicAddress,
                emoji: emoji,
                reactionTxId: nil,
                blockTime: Int64(Date().timeIntervalSince1970 * 1000),
                deliveryStatus: "failed",
                failedAction: action
            )
            loadReactions(for: channel)
            throw error
        }
    }

    /// Re-attempts a broadcast reaction whose send previously failed. `action` is the failed
    /// reaction's stored `failedAction` ("add"/"remove"). Delegates to `sendBroadcastReaction`,
    /// which clears the failed flag optimistically and re-flags it only if this attempt fails too.
    func retryBroadcastReaction(channel: String, targetTxId: String, emoji: String, action: String) async throws {
        try await sendBroadcastReaction(channel: channel, targetTxId: targetTxId, emoji: emoji, action: action)
    }

    // MARK: - Fee estimation

    /// Estimate the on-chain fee for sending `content` as a broadcast right now, matching how
    /// 1:1 chat shows a live "fee: N sompi" preview while typing (`ChatService.estimateMessageFee`).
    /// Accounts for an active reply, since replies wrap the content in a larger envelope.
    func estimateBroadcastFee(channel rawChannel: String, content: String, feeOverride: UInt64? = nil) async throws -> UInt64 {
        if let feeOverride { return feeOverride }
        let channel = BroadcastChannelName.normalize(rawChannel)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.networkError("Message is empty")
        }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        let payloadText: String
        if let reply = replyingTo {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payloadText = MessageReplyCodec.encode(
                replyToId: reply.id,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payloadText = trimmed
        }

        let payload = KasiaTransactionBuilder.buildBroadcastPayload(channel: channel, content: payloadText)
        let utxos = try await ChatService.shared.fetchUtxosWithFallback(for: wallet.publicAddress)
        guard !utxos.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        return KasiaTransactionBuilder.estimateBroadcastFee(
            payload: payload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    /// Same estimate, but for a payload of a known byte size rather than real text - used for a
    /// live preview while a voice message is still being recorded (its final size isn't known
    /// yet), matching Android's `VoiceMessage.estimatedWirePayloadSize` heuristic.
    func estimateBroadcastFee(channel rawChannel: String, payloadByteCount: Int) -> UInt64? {
        guard let wallet = WalletManager.shared.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            return nil
        }
        let dummyPayload = Data(count: max(0, payloadByteCount))
        return KasiaTransactionBuilder.estimateBroadcastFee(
            payload: dummyPayload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    // MARK: - Sending

    /// Send a voice message - wraps the same inline JSON shape used by 1:1 chat's
    /// `ChatService.sendAudio` (and matching Android's `VoiceMessageContent` field-for-field) so a
    /// voice message recorded on either platform plays back on both, then reuses `sendBroadcast`
    /// for the actual optimistic-send/reply-wrap/retry plumbing.
    func sendBroadcastAudio(
        channel: String,
        audioData: Data,
        fileName: String = "voice.webm",
        mimeType: String = "audio/webm"
    ) async throws {
        let base64 = audioData.base64EncodedString()
        // Deterministic field order (mimeType before content) - see MediaFileEnvelope.
        let jsonString = MediaFileEnvelope.json(
            name: fileName,
            size: audioData.count,
            mimeType: mimeType,
            dataUrlContent: "data:\(mimeType);base64,\(base64)"
        )
        try await sendBroadcast(channel: channel, content: jsonString)
    }

    func sendBroadcast(channel rawChannel: String, content: String, feeOverride: UInt64? = nil) async throws {
        let channel = BroadcastChannelName.normalize(rawChannel)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BroadcastChannelName.isValid(channel) else {
            throw KasiaError.networkError("Invalid channel name")
        }
        guard !trimmed.isEmpty else { return }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        // If replying, wrap the content in the shared reply envelope (matches Android's
        // BroadcastViewModel.sendBroadcast) so the quote survives even if the original message is
        // later pruned or its sender hidden.
        let payload: String
        if let reply = replyingTo {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payload = MessageReplyCodec.encode(
                replyToId: reply.id,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payload = trimmed
        }

        let pendingId = "pending_\(UUID().uuidString)"
        let pendingBlockTime = Int64(Date().timeIntervalSince1970 * 1000)
        store.insertMessage(
            id: pendingId,
            channel: channel,
            senderAddress: wallet.publicAddress,
            content: payload,
            blockTime: pendingBlockTime,
            deliveryStatus: .pending
        )
        loadMessages(for: channel)

        do {
            _ = try await ChatService.shared.enqueueOutgoingTxOperation {
                try await self.sendBroadcastInternal(
                    channel: channel,
                    content: payload,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey,
                    pendingId: pendingId,
                    feeOverride: feeOverride
                )
            }
            replyingTo = nil
        } catch {
            try await handleSendFailure(
                error,
                channel: channel,
                content: payload,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey,
                pendingId: pendingId
            )
        }
    }

    /// If sending too quickly back-to-back races the previous broadcast's not-yet-confirmed
    /// UTXOs, `sendBroadcastInternal` surfaces that as a "no confirmed inputs" error - automatic-
    /// ally retry those with backoff (matches 1:1 chat's `scheduleOutgoingRetry`) instead of
    /// leaving the user to notice and manually tap retry. Any other error still fails immediately.
    private func handleSendFailure(
        _ error: Error,
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String
    ) async throws {
        if ChatService.shared.isNoConfirmedInputsError(error) {
            let delay = ChatService.shared.nextNoInputRetryDelay(for: pendingId)
            AppLog.log("[BroadcastService] Deferred retry (no confirmed inputs) for %@ in %.0fs",
                  String(pendingId.prefix(12)), delay)
            scheduleBroadcastRetry(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                delaySeconds: delay
            )
            return
        }
        ChatService.shared.clearNoInputRetryState(for: pendingId)
        store.markMessageFailed(pendingId: pendingId)
        loadMessages(for: channel)
        // Surface a humanized message (never kaspad's raw "orphan is disallowed" text) - this is
        // what the composer's "Failed to send" toast renders, possibly while the user is already
        // typing their next message.
        let surfaced = KasiaError.networkError(Self.friendlySendErrorMessage(for: error))
        lastSendError = surfaced
        throw surfaced
    }

    private func scheduleBroadcastRetry(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        delaySeconds: TimeInterval
    ) {
        guard !scheduledSendRetries.contains(pendingId) else { return }
        scheduledSendRetries.insert(pendingId)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self else { return }
            self.scheduledSendRetries.remove(pendingId)
            let currentStatus = self.store.messages(forChannel: channel).first { $0.id == pendingId }?.deliveryStatus
            guard currentStatus == .pending else {
                ChatService.shared.clearNoInputRetryState(for: pendingId)
                return
            }
            do {
                _ = try await ChatService.shared.enqueueOutgoingTxOperation {
                    try await self.sendBroadcastInternal(
                        channel: channel,
                        content: content,
                        walletAddress: walletAddress,
                        privateKey: privateKey,
                        pendingId: pendingId
                    )
                }
            } catch {
                try? await self.handleSendFailure(
                    error,
                    channel: channel,
                    content: content,
                    walletAddress: walletAddress,
                    privateKey: privateKey,
                    pendingId: pendingId
                )
            }
        }
    }

    /// Returns the submitted transaction's id. For a normal message send the pending row is
    /// resolved to it in-store; reaction sends (which have no message row - their `pendingId` is
    /// synthetic) use the returned id to stamp the reaction's `reactionTxId`.
    @discardableResult
    private func sendBroadcastInternal(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        feeOverride: UInt64? = nil
    ) async throws -> String {
        let chatService = ChatService.shared

        // Fetch UTXOs fresh (not the 20s-stale `fetchCachedUtxos`) and merge in any pending
        // change output from a just-submitted broadcast, excluding whatever it just spent - the
        // same in-flight UTXO chaining 1:1 messages use, so sending several broadcasts back-to-
        // back doesn't try to double-spend the same not-yet-confirmed UTXO.
        let freshUtxos = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
        let candidateUtxos = chatService.prepareMessageUtxos(confirmed: freshUtxos)
        guard !candidateUtxos.isEmpty else {
            throw KasiaError.networkError(chatService.noSpendableFundsYetMessage())
        }

        do {
            return try await buildSignSubmitBroadcast(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                utxos: candidateUtxos,
                feeOverride: feeOverride
            )
        } catch {
            // The node pool hedges submits across nodes, so the node this landed on can be a few
            // seconds behind the node that served the UTXO snapshot (or behind a just-accepted
            // broadcast whose change we chained). It then rejects with kaspad's raw
            // "... is an orphan, where orphan is disallowed" / "already spent" text. That's a
            // transient state mismatch, not a user error - retry ONCE with a freshly fetched,
            // confirmed-only input set (mirrors the 1:1 path's confirmed-only fallback) before
            // giving up, instead of surfacing raw node text (see friendlySendErrorMessage).
            guard chatService.shouldRetrySendError(error) else { throw error }
            let refetched = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
            let confirmedOnly = chatService.prepareMessageUtxos(confirmed: refetched)
                .filter { $0.blockDaaScore > 0 }
            guard !confirmedOnly.isEmpty else { throw error }
            AppLog.log("[BroadcastService] Submit rejected (%@) for %@ - retrying with confirmed-only inputs",
                       error.localizedDescription, String(pendingId.prefix(12)))
            return try await buildSignSubmitBroadcast(
                channel: channel,
                content: content,
                walletAddress: walletAddress,
                privateKey: privateKey,
                pendingId: pendingId,
                utxos: confirmedOnly,
                feeOverride: feeOverride
            )
        }
    }

    /// One build -> sign -> submit -> bookkeeping attempt against a fixed candidate UTXO set.
    /// Split out of `sendBroadcastInternal` so the orphan/already-spent fallback there can rerun
    /// the whole attempt against a refreshed input set.
    private func buildSignSubmitBroadcast(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        utxos candidateUtxos: [UTXO],
        feeOverride: UInt64?
    ) async throws -> String {
        let chatService = ChatService.shared

        let tx = try KasiaTransactionBuilder.buildBroadcastTx(
            from: walletAddress,
            channel: channel,
            content: content,
            senderPrivateKey: privateKey,
            utxos: candidateUtxos,
            feeOverride: feeOverride
        )
        let spentUtxos = chatService.spentMessageUtxos(from: tx, candidates: candidateUtxos)
        let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }

        do {
            let (txId, _) = try await NodePoolService.shared.submitTransaction(tx, allowOrphan: usesUnconfirmedInputs)
            chatService.reserveMessageOutpoints(spentUtxos)
            chatService.consumePendingUtxos(spentUtxos)
            if let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) {
                chatService.addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: senderScriptPubKey)
            }
            chatService.clearNoInputRetryState(for: pendingId)
            let blockTime = Int64(Date().timeIntervalSince1970 * 1000)
            store.resolvePendingMessage(pendingId: pendingId, realId: txId, blockTime: blockTime)
            loadMessages(for: channel)
            return txId
        } catch {
            chatService.releaseMessageOutpoints()
            throw error
        }
    }

    /// Node-level rejection text ("transaction ... is an orphan, where orphan is disallowed",
    /// "already spent", ...) means "the network hasn't caught up with your previous send yet" -
    /// meaningless and alarming to a user mid-typing. Map it (after retries are exhausted) to a
    /// plain-language message; anything unrecognized passes through unchanged.
    static func friendlySendErrorMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("orphan") || lower.contains("already spent") || lower.contains("double spend") {
            return AppLocalization.string("The network is still confirming your previous send. Please try again in a few seconds.")
        }
        return raw
    }

    // MARK: - Block scanning lifecycle

    /// The channels that justify the block stream on the CURRENT network path. On WiFi this is
    /// every wanted channel. On an expensive (cellular/metered) path, featured rooms are
    /// dropped when the KaChat broadcast indexer is configured: an OPEN featured room is kept
    /// fresh by the existing 8s indexer poll (`startIndexerPollingIfConfigured`), and a closed
    /// one is covered by remote push - so streaming every block for them is pure duplicate
    /// cost. Non-indexed rooms (user-added channels with alwaysListen, or open non-featured
    /// rooms) have NO other delivery path, so they keep the stream even on cellular.
    private var scanWantedChannels: Set<String> {
        var wanted = wantedChannels
        guard NetworkEpochMonitor.shared.isExpensivePath else { return wanted }
        // Per room, since each can point at its own indexer now: a curated room whose override
        // is blank still counts as indexed via the app-wide setting.
        wanted.subtract(Set(Self.indexedChannels.filter { !Self.indexerBaseURL(forChannel: $0).isEmpty }))
        return wanted
    }

    private func updateScanningStateIfNeeded() {
        let shouldScan = !scanWantedChannels.isEmpty
        guard shouldScan != isScanningActive else { return }
        isScanningActive = shouldScan
        if shouldScan {
            startScanning()
        } else {
            stopScanning()
        }
    }

    private nonisolated static let blockScanQueue = DispatchQueue(label: "com.kachat.broadcastBlockScan", qos: .utility)

    /// One fully-parsed broadcast candidate from a scanned block.
    struct BlockScanHit {
        let channel: String
        let txId: String
        let senderAddress: String
        let content: String
        let blockTime: Int64
    }

    /// OFF-MAIN block parsing: protobuf-decoding every ~1s block (and reconnect BURSTS of
    /// them) on the main actor was hard main-thread work - the app-freeze-on-reconnect class
    /// of bug (GroupChatService got the identical treatment). Pure extraction, no state:
    /// wanted/hidden filtering happens on the main hop, which only fires for actual hits
    /// (almost every block has zero).
    private nonisolated static func extractBroadcastHits(_ data: Data, hrp: String) -> [BlockScanHit] {
        guard let notification = try? Protowire_BlockAddedNotificationMessage(serializedBytes: data) else { return [] }
        var hits: [BlockScanHit] = []
        for tx in notification.block.transactions {
            guard tx.payload.hasPrefix(bcastPrefixHex) || tx.payload.hasPrefix(legacyBcastPrefixHex) else { continue }
            guard let payloadData = CryptoUtils.hexToData(tx.payload),
                  let payloadString = String(data: payloadData, encoding: .utf8),
                  let parsed = KasiaTransactionBuilder.parseBroadcastPayload(payloadString) else { continue }
            guard let firstOutput = tx.outputs.first,
                  let scriptData = CryptoUtils.hexToData(firstOutput.scriptPublicKey.scriptPublicKey),
                  let senderAddress = KaspaAddress.address(fromScriptPublicKey: scriptData, hrp: hrp) else { continue }
            let txId = tx.verboseData.transactionID
            guard !txId.isEmpty else { continue }
            hits.append(BlockScanHit(
                channel: BroadcastChannelName.normalize(parsed.channel),
                txId: txId,
                senderAddress: senderAddress,
                content: parsed.content,
                blockTime: Int64(tx.verboseData.blockTime)
            ))
        }
        return hits
    }

    private func startScanning() {
        if blockNotificationHandlerId == nil {
            blockNotificationHandlerId = NodePoolService.shared.addNotificationHandler { [weak self] type, data in
                guard type == .blockAdded else { return }
                Self.blockScanQueue.async {
                    let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
                    let hits = Self.extractBroadcastHits(data, hrp: hrp)
                    guard !hits.isEmpty else { return }
                    Task { @MainActor in
                        self?.processBroadcastHits(hits)
                    }
                }
            }
        }
        Task { await NodePoolService.shared.subscribeBlockAdded(client: "broadcast-scan") }
    }

    private func stopScanning() {
        Task { await NodePoolService.shared.unsubscribeBlockAdded(client: "broadcast-scan") }
        // The notification handler stays registered - see NodePoolService.unsubscribeBlockAdded
        // for why there's no protocol-level way to actually stop the node from pushing them.
        // handleBlockAddedData() bails out immediately when wantedChannels is empty, so this
        // is a cheap no-op rather than wasted scanning work.
    }

    // MARK: - Block scanning

    /// Main-actor tail of the block scan: runs ONLY when a block actually contained broadcast
    /// payloads (rare). State filtering + store insert + UI refresh.
    private func processBroadcastHits(_ hits: [BlockScanHit]) {
        let wanted = wantedChannels
        guard !wanted.isEmpty else { return }
        let hidden = store.hiddenSendersByChannel()
        var touchedChannels = Set<String>()
        var reactionChannels = Set<String>()
        var editChannels = Set<String>()

        for hit in hits {
            guard wanted.contains(hit.channel) else { continue }
            guard !hidden.global.contains(hit.senderAddress),
                  hidden.perChannel[hit.channel]?.contains(hit.senderAddress) != true else { continue }
            // Reactions are never shown as their own bubble (or notified) - just attached to the
            // message they target - so intercept and route to the reactions index before this
            // ever becomes a message row. Our own outgoing reactions already applied their local
            // update at send time (sendBroadcastReaction); newest-blockTime-wins dedupes the echo.
            if let edit = MessageEditCodec.parse(hit.content) {
                if applyIncomingEdit(edit, channel: hit.channel, senderAddress: hit.senderAddress, editTxId: hit.txId, blockTime: hit.blockTime) {
                    editChannels.insert(hit.channel)
                }
                continue
            }
            if let reaction = MessageReactionCodec.parse(hit.content) {
                let changed = store.applyIncomingReaction(
                    targetTxId: reaction.targetTxId,
                    channel: hit.channel,
                    reactorAddress: hit.senderAddress,
                    emoji: reaction.action == "remove" ? nil : reaction.emoji,
                    reactionTxId: hit.txId,
                    blockTime: hit.blockTime
                )
                if changed { reactionChannels.insert(hit.channel) }
                continue
            }
            let inserted = store.insertMessage(
                id: hit.txId,
                channel: hit.channel,
                senderAddress: hit.senderAddress,
                content: hit.content,
                blockTime: hit.blockTime,
                deliveryStatus: .sent
            )
            if inserted {
                touchedChannels.insert(hit.channel)
                notifyIfEnabled(channel: hit.channel, senderAddress: hit.senderAddress, content: hit.content, txId: hit.txId)
            } else if Self.serviceChannels.contains(hit.channel),
                      store.updateBlockTime(id: hit.txId, blockTime: hit.blockTime) {
                // Our own arena row, stamped with this phone's clock when it was submitted: the
                // block's time is what every other phone sees, so take it (the reducer orders
                // joins and runs the clocks by it).
                touchedChannels.insert(hit.channel)
            }
        }

        for channel in reactionChannels {
            loadReactions(for: channel)
        }
        for channel in editChannels {
            loadEdits(for: channel)
        }

        guard !touchedChannels.isEmpty else { return }
        for channel in touchedChannels {
            loadMessages(for: channel)
        }
        store.pruneExpiredMessages()
    }

    // MARK: - Local notifications

    /// Fires a local notification for a newly-scanned message, matching Android's per-channel
    /// "Enable Notifications" toggle - like block scanning itself, this only ever fires while the
    /// app is alive (foreground or briefly backgrounded), never for a fully closed/terminated app.
    private func notifyIfEnabled(channel: String, senderAddress: String, content: String, txId: String) {
        guard !Self.serviceChannels.contains(channel) else { return }
        guard senderAddress != WalletManager.shared.currentWallet?.publicAddress else { return }
        guard channels.first(where: { $0.channelName == channel })?.notifyEnabled == true else { return }
        guard !store.hiddenSenderAddresses(forChannel: channel).contains(senderAddress) else { return }
        let settings = AppSettings.load()
        guard settings.notificationsEnabled else { return }
        // Child Mode removes Broadcasts entirely - no local banners for them either.
        // The remote push is the only banner source - see `ChatService.localBannersEnabled`.
        guard ChatService.localBannersEnabled else { return }
        guard !settings.childModeEnabled else { return }
        // Indexed channels are covered by remote push (registered via
        // watched_broadcast_channels) while the app is backgrounded or closed - skip the
        // scan-driven local banner there so one message can't notify twice. While the app is
        // ACTIVE the scan is the notification source whatever the mode
        // (AppDelegate.willPresent drops broadcast pushes in foreground), so the banner fires.
        if Self.indexedChannels.contains(channel), settings.notificationMode == .remotePush,
           UIApplication.shared.applicationState != .active {
            return
        }
        // Foreground policy: in-app banners fire everywhere (chat list, other chats) EXCEPT the
        // room currently on screen - same rule as 1:1's active conversation and groups'
        // activeGroupId. The refcount alone isn't enough: the screen stays "open" while the app
        // is backgrounded, and then the banner SHOULD fire.
        if isViewing(channel: channel), UIApplication.shared.applicationState == .active {
            return
        }

        let notificationBody = MessageReplyCodec.previewText(for: content)

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = "#\(channel)"
        notificationContent.body = notificationBody
        notificationContent.sound = .default
        notificationContent.threadIdentifier = "broadcast:\(channel)"

        // Keyed by txId: matches the push spec's apns-collapse-id (= message txid), so in the
        // rare cross-state race (local banner posted while active, push displayed after the
        // app backgrounds) the second one replaces the first in Notification Center instead
        // of stacking. Also self-dedupes a re-scanned message.
        let request = UNNotificationRequest(
            identifier: txId,
            content: notificationContent,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLog.log("[BroadcastService] Failed to send local notification: %@", error.localizedDescription)
            }
        }
    }
}


// MARK: - Broadcast indexer client

/// Minimal read client for the KaChat-owned broadcast indexer (see PUBLIC_CHATS_INDEXER.md - the
/// server tracks #kaspa and #kachat-bugs history so clients aren't limited to what they catch
/// live). The API contract this client expects is the source of truth for the server build.
enum BroadcastIndexerClient {
    struct IndexedBroadcast: Decodable {
        let txId: String
        let channel: String?
        let senderAddress: String
        let content: String
        let blockTime: Int64
    }

    private struct HistoryResponse: Decodable {
        let messages: [IndexedBroadcast]
        let hasMore: Bool?
    }

    enum ClientError: LocalizedError {
        case badURL
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid broadcast indexer URL"
            case .badResponse(let code): return "Broadcast indexer returned HTTP \(code)"
            }
        }
    }

    /// GET /get-broadcasts?channel=<name>&limit=<n>[&before=<blockTimeMs>]
    /// -> {"messages":[{txId, channel, senderAddress, content, blockTime}], "hasMore": Bool}
    /// blockTime is ms; results newest-first; `before` pages older history.
    static func fetchHistory(
        baseURL: String,
        channel: String,
        limit: Int = 200,
        before: Int64? = nil
    ) async throws -> [IndexedBroadcast] {
        try await fetchHistoryPage(baseURL: baseURL, channel: channel, limit: limit, before: before).messages
    }

    /// Same fetch, but keeps the server's `hasMore` so callers can page older history with
    /// `before` — the plain fetchHistory silently discarded it, which is why rooms only ever
    /// showed the newest single page.
    static func fetchHistoryPage(
        baseURL: String,
        channel: String,
        limit: Int = 200,
        before: Int64? = nil
    ) async throws -> (messages: [IndexedBroadcast], hasMore: Bool) {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        var components = URLComponents(string: "\(trimmed)/get-broadcasts")
        var query = [
            URLQueryItem(name: "channel", value: channel),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let before {
            query.append(URLQueryItem(name: "before", value: String(before)))
        }
        components?.queryItems = query
        guard let url = components?.url else { throw ClientError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ClientError.badResponse(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(HistoryResponse.self, from: data)
        return (decoded.messages, decoded.hasMore ?? false)
    }
}
