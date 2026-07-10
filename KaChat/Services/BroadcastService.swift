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
    /// Shows senders' KNS avatars in rooms; off shows plain initials for everyone. Default matches Android.
    @Published private(set) var showKnsAvatarsEnabled: Bool
    /// Automatically looks up a sender's KNS avatar as soon as their message appears, rather than
    /// only on demand - off by default since a sender's avatar URL can be used to detect viewing.
    @Published private(set) var autoAvatarSearchEnabled: Bool

    private let popularTabEnabledKey = "kachat_broadcast_popular_enabled"
    private let showKnsAvatarsEnabledKey = "kachat_broadcast_show_kns_avatars"
    private let autoAvatarSearchEnabledKey = "kachat_broadcast_auto_avatar_search"

    private let store = BroadcastStore.shared

    /// Reference count of open channel screens ("live viewing"), keyed by normalized name.
    private var liveViewRefCounts: [String: Int] = [:]
    private var blockNotificationHandlerId: UUID?
    private var isScanningActive = false

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
        autoAvatarSearchEnabled = (defaults.object(forKey: autoAvatarSearchEnabledKey) as? Bool) ?? false
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

    func setAutoAvatarSearchEnabled(_ enabled: Bool) {
        autoAvatarSearchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: autoAvatarSearchEnabledKey)
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
        for channel in channels where channel.alwaysListen {
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
        store.pruneExpiredMessages()
        loadMessages(for: BroadcastChannelName.normalize(name))
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
                store.markMessageFailed(pendingId: pendingId)
                loadMessages(for: channel)
                lastSendError = error as? KasiaError ?? .networkError(error.localizedDescription)
            }
        }
    }

    // MARK: - Fee estimation

    /// Estimate the on-chain fee for sending `content` as a broadcast right now, matching how
    /// 1:1 chat shows a live "fee: N sompi" preview while typing (`ChatService.estimateMessageFee`).
    /// Accounts for an active reply, since replies wrap the content in a larger envelope.
    func estimateBroadcastFee(channel rawChannel: String, content: String) async throws -> UInt64 {
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

    func sendBroadcast(channel rawChannel: String, content: String) async throws {
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
                    pendingId: pendingId
                )
            }
            replyingTo = nil
        } catch {
            store.markMessageFailed(pendingId: pendingId)
            loadMessages(for: channel)
            lastSendError = error as? KasiaError ?? .networkError(error.localizedDescription)
            throw error
        }
    }

    private func sendBroadcastInternal(
        channel: String,
        content: String,
        walletAddress: String,
        privateKey: Data,
        pendingId: String
    ) async throws {
        let utxos = try await ChatService.shared.fetchCachedUtxos(for: walletAddress)
        let tx = try KasiaTransactionBuilder.buildBroadcastTx(
            from: walletAddress,
            channel: channel,
            content: content,
            senderPrivateKey: privateKey,
            utxos: utxos
        )
        let (txId, _) = try await NodePoolService.shared.submitTransaction(tx)
        let blockTime = Int64(Date().timeIntervalSince1970 * 1000)
        store.resolvePendingMessage(pendingId: pendingId, realId: txId, blockTime: blockTime)
        loadMessages(for: channel)
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
        guard AppSettings.load().notificationsEnabled else { return }

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
                NSLog("[BroadcastService] Failed to send local notification: %@", error.localizedDescription)
            }
        }
    }
}
