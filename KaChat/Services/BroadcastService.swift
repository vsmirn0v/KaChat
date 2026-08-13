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
    /// nonisolated: read from BroadcastStore's background prune (retention rule) as well as
    /// main-actor UI - immutable Sendable value, safe from anywhere.
    nonisolated static let featuredChannels = ["kaspa", "kachat-bugs"]

    @Published private(set) var channels: [BroadcastChannel] = []
    @Published private(set) var messagesByChannel: [String: [BroadcastMessage]] = [:]
    /// This wallet's broadcast reactions, keyed by channel then by targetTxId - mirrors
    /// `GroupChatService.reactionsByGroupId`'s shape (and reuses `GroupStore.ReactionSnapshot`,
    /// see `BroadcastStore.fetchReactions`). Loaded per channel on open (`acquire`) and kept
    /// live afterward by `sendBroadcastReaction` / the incoming-reaction interception in
    /// `processBroadcastHits` and `fetchFromIndexerAndMerge`.
    @Published private(set) var reactionsByChannel: [String: [String: [GroupStore.ReactionSnapshot]]] = [:]
    @Published var lastSendError: KasiaError?
    @Published var replyingTo: BroadcastMessage?
    /// Set when a broadcast-room notification is tapped, so the chat list can navigate to that
    /// room - mirrors `ChatService.pendingChatNavigation`'s cold-start handling.
    @Published var pendingBroadcastNavigation: String?

    /// Shows a "Popular" tab of curated channels in the list screen. Default matches Android.
    /// Shows senders' KNS avatars in rooms and automatically looks them up as soon as a message
    /// appears; off shows plain initials for everyone and never fetches avatars. Default matches Android.
    @Published private(set) var showKnsAvatarsEnabled: Bool

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
    private nonisolated static let bcastPrefixHex: String = "ciph_msg:1:bcast:".utf8
        .map { String(format: "%02x", $0) }
        .joined()

    private init() {
        let defaults = UserDefaults.standard
        showKnsAvatarsEnabled = (defaults.object(forKey: showKnsAvatarsEnabledKey) as? Bool) ?? true
    }

    // MARK: - Settings

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
        reactionsByChannel = [:]
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

    /// The curated Popular rooms are permanent fixtures of the list screen - make sure they
    /// have store rows (bell state etc.) without requiring an explicit join.
    func ensureFeaturedChannelsJoined() {
        for name in Self.featuredChannels {
            _ = store.joinChannel(name)
        }
        refreshChannels()
    }

    @discardableResult
    func joinChannel(_ rawName: String) -> Bool {
        guard store.joinChannel(rawName) else { return false }
        refreshChannels()
        return true
    }

    func leaveChannel(_ name: String) {
        // Curated rooms can't be left - no UI offers it; guard against stray paths.
        guard !Self.featuredChannels.contains(BroadcastChannelName.normalize(name)) else { return }
        let normalized = BroadcastChannelName.normalize(name)
        store.leaveChannel(normalized)
        messagesByChannel.removeValue(forKey: normalized)
        reactionsByChannel.removeValue(forKey: normalized)
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

    func hiddenSendersByChannel() -> (global: Set<String>, perChannel: [String: Set<String>]) {
        store.hiddenSendersByChannel()
    }

    /// Hides in the indexed channels also gate server-side push - re-sync the registration so
    /// the push service stops (or resumes) sending for that sender.
    private func syncHiddenSendersToPushIfNeeded(channel: String) {
        guard Self.featuredChannels.contains(BroadcastChannelName.normalize(channel)) else { return }
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
        loadReactions(for: normalized)
        updateScanningStateIfNeeded()
        startIndexerPollingIfConfigured(channel: normalized)
    }

    /// Per-channel indexer poll loops, running while that channel's screen is open.
    private var indexerPollTasks: [String: Task<Void, Never>] = [:]
    private static let indexerPollIntervalNanos: UInt64 = 8 * 1_000_000_000

    /// While a room is open, the KaChat broadcast indexer is polled every few seconds and new
    /// rows merge into the local store (txid-deduped) - live block scanning alone proved
    /// unreliable for freshness (the indexer had messages the app never showed). First fetch
    /// fires immediately on open, so history backfill is included. No-op when the URL is unset;
    /// hidden senders and retention pruning apply exactly like scanned rows.
    private func startIndexerPollingIfConfigured(channel: String) {
        guard indexerPollTasks[channel] == nil else { return }
        let base = AppSettings.load().broadcastIndexerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return }
        indexerPollTasks[channel] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchFromIndexerAndMerge(baseURL: base, channel: channel)
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
            let messages = try await BroadcastIndexerClient.fetchHistory(baseURL: baseURL, channel: channel)
            let hidden = store.hiddenSenderAddresses(forChannel: channel)
            let visible = messages.filter { !hidden.contains($0.senderAddress) }

            // Reactions never become visible message rows - route them to the per-channel
            // reactions index instead (newest-blockTime-wins per (target, reactor), so
            // re-serving the same history every poll is idempotent - see
            // `BroadcastStore.applyIncomingReaction`).
            var reactionsChanged = false
            for row in visible {
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

            let rows = visible
                .filter { MessageReactionCodec.parse($0.content) == nil }
                .map { (id: $0.txId, channel: channel, senderAddress: $0.senderAddress, content: $0.content, blockTime: $0.blockTime) }
            let insertedCount = await store.insertMessages(rows)
            if insertedCount > 0 {
                store.pruneExpiredMessages()
                loadMessages(for: channel)
            }
        } catch {
            // Best-effort on top of live scanning - the loop just tries again next tick.
            AppLog.log("%@", "[Broadcast] Indexer fetch failed for #\(channel): \(error.localizedDescription)")
        }
    }

    /// Call when a broadcast channel screen disappears; pairs with `acquire`.
    func release(_ name: String) {
        let normalized = BroadcastChannelName.normalize(name)
        guard let count = liveViewRefCounts[normalized] else { return }
        if count <= 1 {
            liveViewRefCounts.removeValue(forKey: normalized)
            stopIndexerPolling(channel: normalized)
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

    /// Aggregated reactions for a channel, keyed by the reacted-to message's txId.
    func reactions(forChannel name: String) -> [String: [GroupStore.ReactionSnapshot]] {
        reactionsByChannel[BroadcastChannelName.normalize(name)] ?? [:]
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
            .filter { MessageReactionCodec.parse($0.content) == nil }
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
            guard tx.payload.hasPrefix(bcastPrefixHex) else { continue }
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

    /// Main-actor tail of the block scan: runs ONLY when a block actually contained broadcast
    /// payloads (rare). State filtering + store insert + UI refresh.
    private func processBroadcastHits(_ hits: [BlockScanHit]) {
        let wanted = wantedChannels
        guard !wanted.isEmpty else { return }
        let hidden = store.hiddenSendersByChannel()
        var touchedChannels = Set<String>()
        var reactionChannels = Set<String>()

        for hit in hits {
            guard wanted.contains(hit.channel) else { continue }
            guard !hidden.global.contains(hit.senderAddress),
                  hidden.perChannel[hit.channel]?.contains(hit.senderAddress) != true else { continue }
            // Reactions are never shown as their own bubble (or notified) - just attached to the
            // message they target - so intercept and route to the reactions index before this
            // ever becomes a message row. Our own outgoing reactions already applied their local
            // update at send time (sendBroadcastReaction); newest-blockTime-wins dedupes the echo.
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
                notifyIfEnabled(channel: hit.channel, senderAddress: hit.senderAddress, content: hit.content)
            }
        }

        for channel in reactionChannels {
            loadReactions(for: channel)
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
        guard !store.hiddenSenderAddresses(forChannel: channel).contains(senderAddress) else { return }
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
