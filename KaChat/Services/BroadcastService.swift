import Foundation
import Combine
import UserNotifications

/// KaChat 2.0 Broadcast feature: public, unencrypted, many-to-many channels.
/// Swift analog of the Android client's `BroadcastRepository` + `BroadcastScanningService`
/// combined - join/leave channels, send broadcasts, and scan new blocks for messages in
/// channels that are currently "wanted" (always-listen or actively viewed).
@MainActor
final class BroadcastService: ObservableObject {
    static let shared = BroadcastService()

    /// Hardcoded curated channels shown in a "Popular" section, matching Android.
    static let featuredChannels = ["kaspa", "kachat-bugs"]

    @Published private(set) var channels: [BroadcastChannel] = []
    @Published private(set) var messagesByChannel: [String: [BroadcastMessage]] = [:]
    @Published var lastSendError: KasiaError?
    @Published var replyingTo: BroadcastMessage?
    /// Set when a broadcast-room notification is tapped, so the chat list can navigate to that
    /// room - mirrors `ChatService.pendingChatNavigation`'s cold-start handling.
    @Published var pendingBroadcastNavigation: String?

    /// Shows a "Popular" tab of curated channels in the list screen. Default matches Android.
    @Published private(set) var popularTabEnabled: Bool
    /// Shows senders' KNS avatars in rooms and automatically looks them up as soon as a message
    /// appears; off shows plain initials for everyone and never fetches avatars. Default matches Android.
    @Published private(set) var showKnsAvatarsEnabled: Bool

    private let popularTabEnabledKey = "kachat_broadcast_popular_enabled"
    private let showKnsAvatarsEnabledKey = "kachat_broadcast_show_kns_avatars"

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
    private static let bcastPrefixHex: String = "ciph_msg:1:bcast:".utf8
        .map { String(format: "%02x", $0) }
        .joined()

    private init() {
        let defaults = UserDefaults.standard
        popularTabEnabled = (defaults.object(forKey: popularTabEnabledKey) as? Bool) ?? true
        showKnsAvatarsEnabled = (defaults.object(forKey: showKnsAvatarsEnabledKey) as? Bool) ?? true
    }

    // MARK: - Settings

    func setPopularTabEnabled(_ enabled: Bool) {
        popularTabEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: popularTabEnabledKey)
    }

    func setShowKnsAvatarsEnabled(_ enabled: Bool) {
        showKnsAvatarsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: showKnsAvatarsEnabledKey)
    }

    // MARK: - Wallet lifecycle

    /// Switch to a different wallet's broadcast store. Call alongside
    /// `MessageStore.shared.setCurrentWallet` at every wallet-lifecycle transition.
    func setCurrentWallet(_ walletAddress: String?) {
        store.setCurrentWallet(walletAddress)
        messagesByChannel = [:]
        liveViewRefCounts = [:]
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    // MARK: - Channel membership

    func refreshChannels() {
        channels = store.joinedChannels()
    }

    var featuredChannelsNotJoined: [String] {
        let joined = Set(channels.map { $0.channelName })
        return Self.featuredChannels.filter { !joined.contains($0) }
    }

    @discardableResult
    func joinChannel(_ rawName: String) -> Bool {
        guard store.joinChannel(rawName) else { return false }
        refreshChannels()
        return true
    }

    func leaveChannel(_ name: String) {
        let normalized = BroadcastChannelName.normalize(name)
        store.leaveChannel(normalized)
        messagesByChannel.removeValue(forKey: normalized)
        liveViewRefCounts.removeValue(forKey: normalized)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    func setAlwaysListen(_ enabled: Bool, forChannel name: String) {
        store.setAlwaysListen(enabled, forChannel: name)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    func setNotifyEnabled(_ enabled: Bool, forChannel name: String) {
        // Indexed channels' bells also gate remote push - sync the registration so the push
        // service starts/stops sending for this channel.
        if Self.featuredChannels.contains(BroadcastChannelName.normalize(name)) {
            Task { await PushNotificationManager.shared.updateWatchedAddresses() }
        }
        store.setNotifyEnabled(enabled, forChannel: name)
        refreshChannels()
        updateScanningStateIfNeeded()
    }

    func setRetentionMillis(_ millis: Int64, forChannel name: String) {
        store.setRetentionMillis(millis, forChannel: name)
        refreshChannels()
        store.pruneExpiredMessages()
        loadMessages(for: BroadcastChannelName.normalize(name))
    }

    // MARK: - Hidden senders

    func hideSender(_ address: String) {
        store.hideSender(address)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
    }

    func unhideSender(_ address: String) {
        store.unhideSender(address)
        for channel in messagesByChannel.keys {
            loadMessages(for: channel)
        }
    }

    func hiddenSenderAddresses() -> Set<String> {
        store.hiddenSenderAddresses()
    }

    // MARK: - Live viewing (reference counted)

    /// Call when a broadcast channel screen appears; pairs with `release`.
    func acquire(_ name: String) {
        let normalized = BroadcastChannelName.normalize(name)
        liveViewRefCounts[normalized, default: 0] += 1
        store.pruneExpiredMessages()
        loadMessages(for: normalized)
        updateScanningStateIfNeeded()
        backfillFromIndexerIfConfigured(channel: normalized)
    }

    /// Channels already history-backfilled this session (one indexer round-trip per channel).
    private var backfilledChannels = Set<String>()

    /// Pulls channel history from the KaChat broadcast indexer (Settings > Connection
    /// Settings > Broadcast Indexer) and merges it into the local store. Live block scanning
    /// only sees messages while the app is listening - the indexer fills in everything missed.
    /// No-op when the URL is unset; store insert dedupes by txid; hidden senders and local
    /// retention pruning apply to backfilled rows exactly like scanned ones.
    private func backfillFromIndexerIfConfigured(channel: String) {
        guard !backfilledChannels.contains(channel) else { return }
        let settings = AppSettings.load()
        let base = settings.broadcastIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        backfilledChannels.insert(channel)
        Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try await BroadcastIndexerClient.fetchHistory(baseURL: base, channel: channel)
                let hidden = self.store.hiddenSenderAddresses()
                var insertedAny = false
                for message in messages where !hidden.contains(message.senderAddress) {
                    let inserted = self.store.insertMessage(
                        id: message.txId,
                        channel: channel,
                        senderAddress: message.senderAddress,
                        content: message.content,
                        blockTime: message.blockTime,
                        deliveryStatus: .sent
                    )
                    insertedAny = insertedAny || inserted
                }
                if insertedAny {
                    self.store.pruneExpiredMessages()
                    self.loadMessages(for: channel)
                }
            } catch {
                // Backfill is best-effort on top of live scanning - allow a retry next open.
                self.backfilledChannels.remove(channel)
                AppLog.log("%@", "[Broadcast] Indexer backfill failed for #\(channel): \(error.localizedDescription)")
            }
        }
    }

    /// Call when a broadcast channel screen disappears; pairs with `acquire`.
    func release(_ name: String) {
        let normalized = BroadcastChannelName.normalize(name)
        guard let count = liveViewRefCounts[normalized] else { return }
        if count <= 1 {
            liveViewRefCounts.removeValue(forKey: normalized)
        } else {
            liveViewRefCounts[normalized] = count - 1
        }
        updateScanningStateIfNeeded()
    }

    private var wantedChannels: Set<String> {
        var wanted = Set(liveViewRefCounts.keys)
        // Indexed channels have no listen toggle - while the app is OPEN they scan whenever
        // their bell is on (so in-app banners fire); remote push covers the closed-app case.
        for channel in channels where channel.alwaysListen
            || (Self.featuredChannels.contains(channel.channelName) && channel.notifyEnabled) {
            wanted.insert(channel.channelName)
        }
        return wanted
    }

    // MARK: - Messages

    func messages(forChannel name: String) -> [BroadcastMessage] {
        messagesByChannel[BroadcastChannelName.normalize(name)] ?? []
    }

    private func loadMessages(for channel: String) {
        let fresh = store.messages(forChannel: channel)
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
                try await ChatService.shared.enqueueOutgoingTxOperation {
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
        let payload: [String: Any] = [
            "type": "file",
            "name": fileName,
            "size": audioData.count,
            "mimeType": mimeType,
            "content": "data:\(mimeType);base64,\(base64)"
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw KasiaError.networkError("Failed to prepare audio payload")
        }
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
            try await ChatService.shared.enqueueOutgoingTxOperation {
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
        lastSendError = error as? KasiaError ?? .networkError(error.localizedDescription)
        throw error
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
                try await ChatService.shared.enqueueOutgoingTxOperation {
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

    private func sendBroadcastInternal(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String,
        feeOverride: UInt64? = nil
    ) async throws {
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
        } catch {
            chatService.releaseMessageOutpoints()
            throw error
        }
    }

    // MARK: - Block scanning lifecycle

    private func updateScanningStateIfNeeded() {
        let shouldScan = !wantedChannels.isEmpty
        guard shouldScan != isScanningActive else { return }
        isScanningActive = shouldScan
        if shouldScan {
            startScanning()
        } else {
            stopScanning()
        }
    }

    private func startScanning() {
        if blockNotificationHandlerId == nil {
            blockNotificationHandlerId = NodePoolService.shared.addNotificationHandler { [weak self] type, data in
                guard type == .blockAdded else { return }
                Task { @MainActor in
                    self?.handleBlockAddedData(data)
                }
            }
        }
        Task { await NodePoolService.shared.subscribeBlockAdded() }
    }

    private func stopScanning() {
        Task { await NodePoolService.shared.unsubscribeBlockAdded() }
        // The notification handler stays registered - see NodePoolService.unsubscribeBlockAdded
        // for why there's no protocol-level way to actually stop the node from pushing them.
        // handleBlockAddedData() bails out immediately when wantedChannels is empty, so this
        // is a cheap no-op rather than wasted scanning work.
    }

    // MARK: - Block scanning

    private func handleBlockAddedData(_ data: Data) {
        let wanted = wantedChannels
        guard !wanted.isEmpty else { return }
        guard let notification = try? Protowire_BlockAddedNotificationMessage(serializedBytes: data) else { return }

        let hidden = store.hiddenSenderAddresses()
        let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
        var touchedChannels = Set<String>()

        for tx in notification.block.transactions {
            guard tx.payload.hasPrefix(Self.bcastPrefixHex) else { continue }
            guard let payloadData = CryptoUtils.hexToData(tx.payload),
                  let payloadString = String(data: payloadData, encoding: .utf8),
                  let parsed = KasiaTransactionBuilder.parseBroadcastPayload(payloadString) else { continue }

            let channel = BroadcastChannelName.normalize(parsed.channel)
            guard wanted.contains(channel) else { continue }

            guard let firstOutput = tx.outputs.first,
                  let scriptData = CryptoUtils.hexToData(firstOutput.scriptPublicKey.scriptPublicKey),
                  let senderAddress = KaspaAddress.address(fromScriptPublicKey: scriptData, hrp: hrp) else { continue }
            guard !hidden.contains(senderAddress) else { continue }

            let txId = tx.verboseData.transactionID
            guard !txId.isEmpty else { continue }

            let inserted = store.insertMessage(
                id: txId,
                channel: channel,
                senderAddress: senderAddress,
                content: parsed.content,
                blockTime: Int64(tx.verboseData.blockTime),
                deliveryStatus: .sent
            )
            if inserted {
                touchedChannels.insert(channel)
                notifyIfEnabled(channel: channel, senderAddress: senderAddress, content: parsed.content)
            }
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
    private func notifyIfEnabled(channel: String, senderAddress: String, content: String) {
        guard senderAddress != WalletManager.shared.currentWallet?.publicAddress else { return }
        guard channels.first(where: { $0.channelName == channel })?.notifyEnabled == true else { return }
        let settings = AppSettings.load()
        guard settings.notificationsEnabled else { return }
        // Indexed channels are covered by remote push (registered via
        // watched_broadcast_channels) - skip the scan-driven local banner in remote-push mode
        // so one message can't notify twice, mirroring sendLocalNotification's chat guard.
        if Self.featuredChannels.contains(channel), settings.notificationMode == .remotePush {
            return
        }

        let notificationBody = MessageReplyCodec.previewText(for: content)

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = "#\(channel)"
        notificationContent.body = notificationBody
        notificationContent.sound = .default
        notificationContent.threadIdentifier = "broadcast:\(channel)"

        let request = UNNotificationRequest(
            identifier: "broadcast:\(channel):\(UUID().uuidString)",
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

/// Minimal read client for the KaChat-owned broadcast indexer (see BROADCAST_INDEXER.md - the
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
        return try JSONDecoder().decode(HistoryResponse.self, from: data).messages
    }
}
