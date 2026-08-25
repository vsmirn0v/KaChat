import Foundation
import SwiftUI
import Combine
import UIKit
import UserNotifications
import CryptoKit
import Intents

// MARK: - Conversation state, message sending, handshake sending, fee estimation

extension ChatService {
    func enterConversation(for address: String) {
        activeConversationAddress = address
        AppLog.log("[ChatService] Entered conversation for %@", String(address.suffix(12)))
        startActiveChatPoll(for: address)
        // Nextcloud mirror runs on an adaptive cadence keyed off the open chat; wake its
        // change watcher so this chat picks up other devices' uploads immediately.
        NextcloudService.shared.noteChatOpened()
        loadReactions(for: address)
        // Fresh-address payment pools: lazily offer our pool once per contact, re-check the
        // pool-of-2 replenish (retries a top-up whose send failed when a reservation got
        // funded), and top up theirs if a previous addr_pool_request got lost (all no-ops
        // when nothing to do).
        offerAddressPoolIfNeeded(to: address)
        replenishPoolIfNeeded(for: address)
        if let contact = contactsManager.getContact(byAddress: address) {
            maybeRequestMorePoolAddresses(from: contact)
        }
        // Keep the Share Extension's "Recent" list fresh: opening a chat counts as touching it.
        let alias = ContactsManager.shared.getContact(byAddress: address)?.alias ?? ""
        SharedDataManager.recordRecentConversation(address: address, alias: alias)
    }

    /// Returns total number of stored messages using a background worker to avoid
    /// blocking the main actor during expensive Core Data count queries.
    func storedMessageCountAsync(for contactAddress: String) async -> Int {
        await messageStore.countMessages(contactAddress: contactAddress)
    }

    /// Async/background fetch variant that keeps Core Data page
    /// reads and decrypt work off the main actor. The final in-memory merge still happens on
    /// the main actor for published state consistency.
    @discardableResult
    func loadOlderMessagesPageAsync(for contactAddress: String, pageSize: Int) async -> Int {
        guard pageSize > 0 else { return 0 }
        guard !olderHistoryExhaustedContacts.contains(contactAddress) else { return 0 }
        if let inFlight = olderHistoryPageTasks[contactAddress] {
            return await inFlight.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return 0 }
            return await self.loadOlderMessagesPageInternal(for: contactAddress, pageSize: pageSize)
        }
        olderHistoryPageTasks[contactAddress] = task
        let loaded = await task.value
        olderHistoryPageTasks[contactAddress] = nil
        return loaded
    }

    func loadOlderMessagesPageInternal(for contactAddress: String, pageSize: Int) async -> Int {
        guard let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else { return 0 }
        guard let key = messageEncryptionKey() else { return 0 }
        let cursor = oldestLoadedCursor(in: conversations[index])

        let page = await messageStore.fetchMessagesPageAsync(
            contactAddress: contactAddress,
            decryptionKey: key,
            limit: pageSize,
            olderThan: cursor
        )
        guard !page.messages.isEmpty else {
            olderHistoryExhaustedContacts.insert(contactAddress)
            return 0
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return 0
        }
        var updatedConversations = conversations
        var conversation = updatedConversations[conversationIndex]
        let beforeCount = conversation.messages.count
        conversation.messages = Self.dedupeMessages(page.messages + conversation.messages)
        let loadedCount = max(0, conversation.messages.count - beforeCount)

        if page.hasMore {
            olderHistoryExhaustedContacts.remove(contactAddress)
        } else {
            olderHistoryExhaustedContacts.insert(contactAddress)
        }

        updatedConversations[conversationIndex] = conversation
        conversations = updatedConversations
        return loadedCount
    }

    func oldestLoadedCursor(in conversation: Conversation) -> MessageStore.MessagePageCursor? {
        guard let oldest = conversation.messages.min(by: Self.isMessageOrderedBefore) else { return nil }
        return MessageStore.MessagePageCursor(
            blockTime: Int64(oldest.blockTime),
            timestamp: oldest.timestamp,
            txId: oldest.txId
        )
    }

    /// Called when leaving a chat view - clears active conversation and flushes read status
    func leaveConversation() {
        // Flush read status for this conversation before clearing
        if let address = activeConversationAddress {
            ReadStatusSyncManager.shared.userLeftConversation(address)
        }
        activeChatPollTask?.cancel()
        activeChatPollTask = nil
        activeConversationAddress = nil
        AppLog.log("[ChatService] Left conversation")
    }

    /// While a 1:1 chat is open and the app is foregrounded, poll the indexer for new messages
    /// from that contact every ~2s (mirrors Android's live-UI DM loop). Idempotent with the
    /// utxosChanged push — both dedupe by txId; this just guarantees prompt delivery for the
    /// chat you're looking at instead of waiting on a confirmation-gated notification.
    private func startActiveChatPoll(for address: String) {
        activeChatPollTask?.cancel()
        activeChatPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.activeConversationAddress != address { return }
                if UIApplication.shared.applicationState == .active,
                   let wallet = WalletManager.shared.currentWallet,
                   let privateKey = WalletManager.shared.getPrivateKey() {
                    _ = await self.fetchContextualMessagesFromContact(
                        contactAddress: address, myAddress: wallet.publicAddress, privateKey: privateKey
                    )
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Foreground contact sweep (defense-in-depth for live 1:1 delivery)

    /// Start the global foreground indexer sweep if it isn't already running. Mirrors desktop's
    /// 5s / Android's 2s foreground polls: while the app is active, walk the most recently active
    /// contacts one at a time calling `fetchContextualMessagesFromContact` (the same per-contact
    /// fetch the utxosChanged push and the open-chat poll use), ~5s between full sweeps.
    ///
    /// This is a backstop for any silent failure of the utxosChanged subscription, not the primary
    /// delivery path - so it is deliberately gentle: serial fetches with a short gap (never N
    /// concurrent requests), the next sweep starts only after the previous one finishes, the
    /// currently-open chat is skipped (`startActiveChatPoll` already covers it at 2s), nothing
    /// runs while a full sync is in flight or before the initial sync has completed, and a failed
    /// sweep doubles the interval (up to 60s) until a sweep succeeds again.
    ///
    /// Idempotent with every other fetch path: `fetchContextualMessagesFromContact` skips txIds
    /// already in the store and `addMessageToConversation` re-checks by txId at insert.
    func startForegroundContactSweep() {
        if let task = foregroundSweepTask, !task.isCancelled { return }
        guard WalletManager.shared.currentWallet != nil else { return }
        AppLog.log("[ChatService] Foreground contact sweep started (%.0fs, cap %d)",
                   foregroundSweepBaseInterval, foregroundSweepMaxContacts)
        foregroundSweepTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var interval = self.foregroundSweepBaseInterval
            // Seed the group-catch-up clock: scenePhase .active just ran its own
            // GroupChatService.performCatchUpSync(), so the ride-along below should first
            // fire an interval from now, not duplicate that round trip immediately.
            self.lastForegroundGroupCatchUpAt = Date()
            while !Task.isCancelled {
                let swept = await self.runForegroundContactSweep()
                if Task.isCancelled { return }
                switch swept {
                case .failed:
                    let next = min(interval * 2, self.foregroundSweepMaxInterval)
                    if next != interval {
                        AppLog.log("[ChatService] Foreground contact sweep backing off to %.0fs after indexer failure", next)
                    }
                    interval = next
                case .succeeded:
                    if interval != self.foregroundSweepBaseInterval {
                        AppLog.log("[ChatService] Foreground contact sweep recovered - back to %.0fs", self.foregroundSweepBaseInterval)
                    }
                    interval = self.foregroundSweepBaseInterval
                case .skipped:
                    break  // gated out (inactive / syncing / not ready) - keep the current interval
                }
                // Group-chat backstop (see `lastForegroundGroupCatchUpAt`): groups have no
                // per-contact sweep equivalent - their live path is the blockAdded block-scan,
                // and a block missed during a stream gap only got recovered on the next
                // app-foreground catch-up. Run the cursor-based group catch-up at most once a
                // minute while the app is active so an open app converges on missed group
                // messages without needing a background/foreground cycle.
                if UIApplication.shared.applicationState == .active,
                   WalletManager.shared.currentWallet != nil,
                   self.lastForegroundGroupCatchUpAt.map({ Date().timeIntervalSince($0) >= self.foregroundGroupCatchUpInterval }) ?? true {
                    self.lastForegroundGroupCatchUpAt = Date()
                    await GroupChatService.shared.performCatchUpSync()
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Cancel the foreground sweep (app backgrounded, wallet switch/teardown, logout).
    func stopForegroundContactSweep() {
        guard let task = foregroundSweepTask else { return }
        task.cancel()
        foregroundSweepTask = nil
        AppLog.log("[ChatService] Foreground contact sweep stopped")
    }

    enum ForegroundSweepOutcome {
        case succeeded
        case failed
        case skipped
    }

    /// One serial pass over the sweep targets. Returns `.failed` on the first indexer error (the
    /// rest of the pass is abandoned so an unreachable indexer costs one request per sweep, not
    /// one per contact), `.skipped` when gating kept it from doing any work.
    private func runForegroundContactSweep() async -> ForegroundSweepOutcome {
        guard UIApplication.shared.applicationState == .active,
              isConfigured,
              hasCompletedInitialSync,
              !isSyncInProgress,
              let wallet = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey() else {
            return .skipped
        }
        let myAddress = wallet.publicAddress
        let targets = foregroundSweepTargets(excluding: activeConversationAddress)
        guard !targets.isEmpty else { return .succeeded }

        for address in targets {
            if Task.isCancelled { return .skipped }
            // Re-check live conditions per contact: the app may have gone inactive or the user
            // may have opened this very chat mid-sweep (the open-chat poll owns it from then on).
            guard UIApplication.shared.applicationState == .active else { return .skipped }
            guard isActiveWallet(myAddress) else { return .skipped }
            if activeConversationAddress == address { continue }
            let result = await fetchContextualMessagesFromContact(
                contactAddress: address, myAddress: myAddress, privateKey: privateKey
            )
            if case .failure = result { return .failed }
            // Gentle pacing between contacts so a sweep is a trickle, not a burst.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return .succeeded
    }

    /// Sweep target rule: active contacts that already have an incoming alias (no alias = no
    /// handshake yet = nothing to fetch, and `fetchContextualMessagesFromContact` would return
    /// early anyway), minus the currently-open chat, ordered by most recent activity
    /// (`Contact.lastMessageAt` desc, then newest-added first), capped at
    /// `foregroundSweepMaxContacts`. With hundreds of contacts the long tail is still served by
    /// the push, the app-active catch-up sync and the fallback poll - the sweep just keeps the
    /// conversations you actually use fresh.
    private func foregroundSweepTargets(excluding openAddress: String?) -> [String] {
        let candidates = contactsManager.activeContacts.filter { contact in
            contact.address != openAddress && !incomingAliases(for: contact.address).isEmpty
        }
        let ordered = candidates.sorted { a, b in
            switch (a.lastMessageAt, b.lastMessageAt) {
            case let (la?, lb?) where la != lb: return la > lb
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.addedAt > b.addedAt
            }
        }
        return ordered.prefix(foregroundSweepMaxContacts).map { $0.address }
    }

    /// Fetch only handshakes (lightweight, needed to establish encryption keys)
    /// Call this before CloudKit sync so we have aliases ready
    /// NOTE: Assumes configureAPIIfNeeded() was already called by startup flow
    func fetchHandshakesOnly() async {
        guard let wallet = WalletManager.shared.currentWallet else {
            AppLog.log("[ChatService] fetchHandshakesOnly: No wallet")
            return
        }

        guard isConfigured else {
            AppLog.log("[ChatService] fetchHandshakesOnly: API not configured")
            return
        }

        let nowMs = currentTimeMs()
        let fallbackSince = lastPollTime > syncReorgBufferMs ? lastPollTime - syncReorgBufferMs : lastPollTime
        let incomingHandshakeKey = handshakeSyncObjectKey(direction: "in", address: wallet.publicAddress)
        let outgoingHandshakeKey = handshakeSyncObjectKey(direction: "out", address: wallet.publicAddress)
        let incomingSince = syncStartBlockTime(
            for: incomingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )
        let outgoingSince = syncStartBlockTime(
            for: outgoingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )
        let privateKey = WalletManager.shared.getPrivateKey()

        AppLog.log("[ChatService] Fetching incoming handshakes (since=%llu)...", incomingSince)
        // Phase-isolated like fetchNewMessages: a failed bootstrap phase is logged and skipped,
        // the remaining phases still run, and Phase 4's full sync re-covers whatever was missed
        // (the failed phase's cursor never advanced).
        let incoming: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch incoming handshakes (bootstrap)",
            operation: { [self] in try await fetchIncomingHandshakes(for: wallet.publicAddress, blockTime: incomingSince) }
        ) {
            incoming = fetched
            advanceSyncCursor(for: incomingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
            AppLog.log("[ChatService] Fetched %d incoming handshakes", fetched.count)
        } else {
            incoming = []
            AppLog.log("[ChatService] Failed to fetch incoming handshakes - continuing bootstrap")
        }

        AppLog.log("[ChatService] Fetching outgoing handshakes...")

        let outgoing: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch outgoing handshakes (bootstrap)",
            operation: { [self] in try await fetchOutgoingHandshakes(for: wallet.publicAddress, blockTime: outgoingSince) }
        ) {
            outgoing = fetched
            advanceSyncCursor(for: outgoingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
            AppLog.log("[ChatService] Fetched %d outgoing handshakes", fetched.count)
        } else {
            outgoing = []
            AppLog.log("[ChatService] Failed to fetch outgoing handshakes - continuing bootstrap")
        }

        AppLog.log("[ChatService] Handshake bootstrap: %d incoming, %d outgoing", incoming.count, outgoing.count)

        // Process handshakes to extract aliases
        AppLog.log("[ChatService] Processing handshakes...")
        await processHandshakes(incoming, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
        await processHandshakes(outgoing, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        AppLog.log("[ChatService] Handshakes processed")

        // Fetch saved handshakes from self-stash. Short retry budget: this recovery scan always
        // re-reads from block_time 0, so there is nothing to lose by giving up quickly, and the
        // ~60s default budget would delay Phase 2-4 (and thus the foreground sweep, gated on
        // hasCompletedInitialSync) by a minute while the endpoint is down.
        AppLog.log("[ChatService] Fetching saved handshakes from self-stash...")
        _ = await retryUntilSuccess(
            label: "fetch saved handshakes (bootstrap)",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchSavedHandshakes(myAddress: wallet.publicAddress, privateKey: privateKey) }
        )
        AppLog.log("[ChatService] Self-stash fetch complete")

        saveConversationAliases()
        saveOurAliases()
        saveConversationIds()
        saveRoutingStates()

        AppLog.log("[ChatService] Handshake bootstrap complete. Aliases: %d, Our aliases: %d, Routing: %d", conversationAliases.count, ourAliases.count, routingStates.count)
    }

    func fetchNewMessages(forActiveOnly activeAddress: String? = nil) async {
        guard let wallet = WalletManager.shared.currentWallet else {
            AppLog.log("%@", "[ChatService] Skipping fetch - no wallet")
            return
        }

        // Ensure API is configured
        await configureAPIIfNeeded()
        guard isConfigured else {
            AppLog.log("%@", "[ChatService] Skipping fetch - API not configured")
            return
        }

        // Try to flush pending self-stash transactions if any
        await attemptPendingSelfStashSends()

        var activeFetchSucceeded = false
        if let active = activeAddress {
            chatFetchStates[active] = .loading
        } else {
            isLoading = true
        }
        beginSyncBlockTime()
        isSyncInProgress = true  // Enable batching for Core Data writes
        var syncSucceeded = false
        let shouldSuppressNotifications = activeAddress == nil && lastPollTime == 0
        let previousSuppress = suppressNotificationsUntilSynced
        if shouldSuppressNotifications {
            suppressNotificationsUntilSynced = true
        }
        defer {
            if shouldSuppressNotifications {
                suppressNotificationsUntilSynced = previousSuppress
            }
            isSyncInProgress = false  // Disable batching before final save
            if let active = activeAddress {
                if activeFetchSucceeded {
                    chatFetchStates.removeValue(forKey: active)
                } else {
                    chatFetchStates[active] = .failed
                }
            }
            isLoading = false
            // Check if resubscription was deferred during sync
            executeResubscriptionIfNeeded()
            endSyncBlockTime(success: syncSucceeded)  // This handles batched save
        }

        let isFullFetch = activeAddress == nil
        AppLog.log("%@", "[ChatService] Fetching messages for: \(wallet.publicAddress.suffix(10)), fullFetch=\(isFullFetch), lastPollTime=\(lastPollTime)")

        // Fetch handshakes first (they establish aliases) with per-object cursors.
        let nowMs = currentTimeMs()
        let fallbackSince = lastPollTime > syncReorgBufferMs ? lastPollTime - syncReorgBufferMs : lastPollTime
        let messageSince = applyMessageRetention(to: fallbackSince)
        let incomingHandshakeKey = handshakeSyncObjectKey(direction: "in", address: wallet.publicAddress)
        let outgoingHandshakeKey = handshakeSyncObjectKey(direction: "out", address: wallet.publicAddress)
        let incomingHandshakeSince = syncStartBlockTime(
            for: incomingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )
        let outgoingHandshakeSince = syncStartBlockTime(
            for: outgoingHandshakeKey,
            fallbackBlockTime: fallbackSince,
            nowMs: nowMs
        )

        // PHASE ISOLATION: every fetch phase below is independent. A phase that exhausts its
        // (short) retry budget is logged and SKIPPED for this cycle only - its per-object cursor
        // simply doesn't advance, so the next cycle re-covers the missed window - and all the
        // phases behind it still run. One persistently failing endpoint (seen live: the indexer
        // 500ing /self-stash/by-owner mid-pagination) must never starve contextual message
        // delivery; the old guard-return coupling here is exactly why new messages only appeared
        // on pull-to-refresh while the saved-handshake fetch was failing. `allPhasesSucceeded`
        // stays false when any cursor-bearing phase failed, so endSyncBlockTime never advances
        // the global lastPollTime fallback cursor past an unfetched window.
        var allPhasesSucceeded = true

        let incoming: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch incoming handshakes",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchIncomingHandshakes(for: wallet.publicAddress, blockTime: incomingHandshakeSince) }
        ) {
            incoming = fetched
            advanceSyncCursor(for: incomingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
        } else {
            incoming = []
            allPhasesSucceeded = false
            AppLog.log("%@", "[ChatService] Incoming handshake phase skipped this cycle - continuing with remaining phases")
        }

        let outgoing: [HandshakeResponse]
        if let fetched = await retryUntilSuccess(
            label: "fetch outgoing handshakes",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchOutgoingHandshakes(for: wallet.publicAddress, blockTime: outgoingHandshakeSince) }
        ) {
            outgoing = fetched
            advanceSyncCursor(for: outgoingHandshakeKey, maxBlockTime: fetched.compactMap { $0.blockTime }.max())
        } else {
            outgoing = []
            allPhasesSucceeded = false
            AppLog.log("%@", "[ChatService] Outgoing handshake phase skipped this cycle - continuing with remaining phases")
        }

        var inPayments: [PaymentResponse] = []
        var outPayments: [PaymentResponse] = []
        // Fetch payments only on full fetch AND when not using UTXO subscription
        // (or on initial sync when lastPaymentFetchTime is 0)
        let shouldFetchPayments = activeAddress == nil && (!isUtxoSubscribed || lastPaymentFetchTime == 0)
        var paymentsPhaseSucceeded = true
        if shouldFetchPayments {
            AppLog.log("[ChatService] === FETCHING PAYMENTS (full fetch, utxoSubscribed=%d) ===", isUtxoSubscribed ? 1 : 0)
            if let incomingPayments = await retryUntilSuccess(
                label: "fetch incoming payments",
                maxAttempts: Self.syncPhaseMaxRetryAttempts,
                operation: { [self] in try await fetchIncomingPayments(for: wallet.publicAddress, blockTime: messageSince) }
            ) {
                inPayments = incomingPayments
            } else {
                paymentsPhaseSucceeded = false
                allPhasesSucceeded = false
                AppLog.log("%@", "[ChatService] Incoming payment phase skipped this cycle - continuing with remaining phases")
            }

            if let outgoingPayments = await retryUntilSuccess(
                label: "fetch outgoing payments",
                maxAttempts: Self.syncPhaseMaxRetryAttempts,
                operation: { [self] in try await fetchOutgoingPayments(for: wallet.publicAddress, blockTime: messageSince) }
            ) {
                outPayments = outgoingPayments
            } else {
                paymentsPhaseSucceeded = false
                allPhasesSucceeded = false
                AppLog.log("%@", "[ChatService] Outgoing payment phase skipped this cycle - continuing with remaining phases")
            }
            AppLog.log("[ChatService] === PAYMENT FETCH COMPLETE: in=%d, out=%d ===", inPayments.count, outPayments.count)

            // Update last payment fetch time for UTXO subscription - only when BOTH payment
            // fetches actually succeeded. Advancing this cursor (or setting the initial-sync
            // baseline) off a failed fetch would permanently skip the unfetched window.
            if paymentsPhaseSucceeded {
                if !inPayments.isEmpty || !outPayments.isEmpty {
                    let maxInTime = inPayments.compactMap { $0.blockTime }.max() ?? 0
                    let maxOutTime = outPayments.compactMap { $0.blockTime }.max() ?? 0
                    lastPaymentFetchTime = max(maxInTime, maxOutTime, lastPaymentFetchTime)
                } else if lastPaymentFetchTime == 0 {
                    // Set to current time if no payments found on initial sync
                    lastPaymentFetchTime = fallbackSince > 0 ? fallbackSince : UInt64(Date().timeIntervalSince1970 * 1000)
                }
            }
        } else if activeAddress != nil {
            AppLog.log("[ChatService] Skipping payment fetch - active conversation only")
        } else {
            AppLog.log("[ChatService] Skipping payment fetch - UTXO subscription active")
        }

        AppLog.log("[ChatService] Fetched: %d incoming handshakes, %d outgoing handshakes", incoming.count, outgoing.count)
        if shouldFetchPayments {
            AppLog.log("[ChatService] Fetched: %d incoming payments, %d outgoing payments", inPayments.count, outPayments.count)
        }

        // The fetches above cross many network `await`s. If the user switched/imported a different
        // wallet in that window, applying these results now would write the previous wallet's
        // messages into the new wallet's store. Bail out before touching any shared state.
        guard isActiveWallet(wallet.publicAddress) else {
            AppLog.log("%@", "[ChatService] Wallet changed mid-sync - discarding stale results for \(wallet.publicAddress.suffix(10))")
            return
        }

        // Get private key for decryption
        let privateKey = WalletManager.shared.getPrivateKey()

        // Process handshakes - this extracts aliases
        await processHandshakes(incoming, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
        await processHandshakes(outgoing, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        if shouldFetchPayments {
            // Filter out handshake transactions from payment lists to prevent
            // handshakes being duplicated as payment messages (Bug 4: wallet re-import)
            let handshakeTxIds = Set(incoming.map { $0.txId } + outgoing.map { $0.txId })
            if !handshakeTxIds.isEmpty {
                let inBefore = inPayments.count
                let outBefore = outPayments.count
                inPayments = inPayments.filter { !handshakeTxIds.contains($0.txId) }
                outPayments = outPayments.filter { !handshakeTxIds.contains($0.txId) }
                let filtered = (inBefore - inPayments.count) + (outBefore - outPayments.count)
                if filtered > 0 {
                    AppLog.log("[ChatService] Filtered %d handshake txs from payment results", filtered)
                }
            }
            await processPayments(inPayments, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
            await processPayments(outPayments, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        }

        // Fetch saved handshakes from self-stash to get our aliases for outgoing messages.
        // This is a self-healing RECOVERY scan, not a prerequisite for new-message delivery:
        // it always re-reads the self-stash from block_time 0 (no cursor to corrupt), so a
        // failed attempt loses nothing - the next cycle scans the exact same range. It must
        // never bail out of the sync: when the indexer persistently 5xxes this one endpoint,
        // the contextual-message phases below still have to run.
        if await retryUntilSuccess(
            label: "fetch saved handshakes",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchSavedHandshakes(myAddress: wallet.publicAddress, privateKey: privateKey) }
        ) == nil {
            AppLog.log("%@", "[ChatService] Saved-handshake phase skipped this cycle - continuing to contextual messages")
        }

        // Reclassify misidentified handshakes:
        // If self-stash confirms we have handshakes with a contact but conversation has
        // no handshake messages, the earliest payment is likely the handshake (Bug 4 fix)
        reclassifyMisidentifiedHandshakes()

        // Migrate legacy aliases to deterministic routing states (one-time)
        if let privKey = privateKey {
            migrateToDeterministicAliases(privateKey: privKey)
        }

        // Re-check ownership after the handshake/payment processing awaits, before the contextual
        // message fetch pulls and stores per-conversation history under this wallet.
        guard isActiveWallet(wallet.publicAddress) else {
            AppLog.log("%@", "[ChatService] Wallet changed mid-sync - skipping contextual fetch for \(wallet.publicAddress.suffix(10))")
            return
        }

        // Now fetch contextual messages for all known aliases
        AppLog.log("%@", "[ChatService] Current aliases: \(conversationAliases)")
        AppLog.log("%@", "[ChatService] Our aliases: \(ourAliases)")
        AppLog.log("%@", "[ChatService] Routing states: \(routingStates.count)")
        if let active = activeAddress {
            let completed = await fetchContextualMessagesForActive(
                contactAddress: active,
                myAddress: wallet.publicAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
            activeFetchSucceeded = completed
            if !completed { allPhasesSucceeded = false }
        } else {
            let completed = await fetchContextualMessages(
                myAddress: wallet.publicAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
            if !completed { allPhasesSucceeded = false }
        }

        // A contextual pass can come back false because the wallet changed mid-fetch; never
        // persist this run's aliases/cursors into the new wallet's state in that case.
        guard isActiveWallet(wallet.publicAddress) else {
            AppLog.log("%@", "[ChatService] Wallet changed mid-sync - skipping finalization for \(wallet.publicAddress.suffix(10))")
            return
        }

        await retryIncomingWarningResolutionsOnSync(
            myAddress: wallet.publicAddress,
            privateKey: privateKey
        )

        // Note: saveMessages() is handled by defer block via endSyncBlockTime() to leverage batching
        // Only save metadata that doesn't go through MessageStore
        saveConversationAliases()
        saveOurAliases()
        saveConversationIds()
        saveRoutingStates()

        // Cycle-level success (advances the global lastPollTime fallback cursor via
        // endSyncBlockTime and drives connection status) requires every cursor-bearing phase to
        // have succeeded. The saved-handshake recovery scan is deliberately excluded: it always
        // re-scans from block_time 0, so skipping it has zero cursor cost and must not make an
        // otherwise-healthy cycle look failed while one indexer endpoint is broken.
        if allPhasesSucceeded {
            // Update last successful sync date for connection status
            lastSuccessfulSyncDate = Date()
            if isFullFetch {
                await apiClient.recordIndexerSyncSuccess()
            }
        }

        syncSucceeded = allPhasesSucceeded
        AppLog.log("%@", "[ChatService] Fetch complete (allPhases=\(allPhasesSucceeded ? "ok" : "partial")). Total conversations: \(conversations.count), lastPollTime updated to: \(lastPollTime)")
    }

    func getConversation(for contact: Contact) -> Conversation? {
        return conversations.first { $0.contact.id == contact.id }
    }

    func getOrCreateConversation(for contact: Contact) -> Conversation {
        if let existing = getConversation(for: contact) {
            return existing
        }

        let conversation = Conversation(contact: contact)
        conversations.append(conversation)
        markConversationDirty(contact.address)
        saveMessages()
        return conversation
    }

    func fetchSendUtxos(for walletAddress: String) async throws -> [UTXO] {
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([walletAddress])
        updateWalletBalanceIfNeeded(address: walletAddress, utxos: utxos)
        return utxos
    }

    func formatInsufficientBalanceError(plannedSpendSompi: UInt64, availableSompi: UInt64) -> KasiaError {
        let planned = formatKasAmount(plannedSpendSompi)
        let available = formatKasAmount(availableSompi)
        let template = AppLocalization.string("Planned spend %@ KAS, but available balance %@ KAS is less than required.")
        let message = String(format: template, locale: AppLocalization.locale, planned, available)
        return KasiaError.networkError(
            message
        )
    }

    func noSpendableFundsYetMessage() -> String {
        AppLocalization.string("No spendable funds available yet. Wait for confirmations and try again.")
    }

    func matchesLocalizedTemplate(_ message: String, key: String) -> Bool {
        let lowered = message.lowercased()
        let localized = AppLocalization.string(key).lowercased()
        let segments = localized.components(separatedBy: "%@").filter { !$0.isEmpty }
        guard !segments.isEmpty else { return lowered == localized }

        var searchStart = lowered.startIndex
        for segment in segments {
            guard let range = lowered.range(of: segment, range: searchStart..<lowered.endIndex) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }

    func isInsufficientFundsError(_ error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error {
            return message.lowercased().contains("insufficient funds")
        }
        return error.localizedDescription.lowercased().contains("insufficient funds")
    }

    func isInsufficientBalancePopupError(_ error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error {
            return matchesLocalizedTemplate(
                message,
                key: "Planned spend %@ KAS, but available balance %@ KAS is less than required."
            )
        }
        return false
    }

    func shouldBypassBalancePrecheck(_ error: Error) -> Bool {
        guard case let KasiaError.networkError(message) = error else {
            return false
        }
        if isInsufficientBalancePopupError(error) {
            return false
        }

        let lowered = message.lowercased()
        return lowered.contains("timeout")
            || lowered.contains("connection")
            || lowered.contains("endpoint")
            || lowered.contains("no active nodes")
            || lowered.contains("all endpoints")
            || lowered.contains("unexpected response")
            || lowered.contains("all hedged requests failed")
            || lowered.contains("network path changed")
    }

    func addSompiSafely(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    func enqueueOutgoingTxOperation<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = outgoingTxTail
        let operationTask = Task<T, Error> { @MainActor in
            if let previous {
                await previous.value
            }
            return try await operation()
        }
        outgoingTxTail = Task<Void, Never> { @MainActor in
            _ = try? await operationTask.value
        }
        return try await operationTask.value
    }

    func isNoConfirmedInputsError(_ error: Error) -> Bool {
        let localizedNoSpendableFunds = noSpendableFundsYetMessage().lowercased()
        if case let KasiaError.networkError(message) = error {
            let lowered = message.lowercased()
            return lowered.contains(localizedNoSpendableFunds)
                || lowered.contains("no spendable funds available yet")
                || lowered.contains("no confirmed spendable utxos available")
                || lowered.contains("no spendable utxos available")
                || lowered.contains("no utxos available")
        }
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains(localizedNoSpendableFunds)
            || lowered.contains("no spendable funds available yet")
            || lowered.contains("no confirmed spendable utxos available")
            || lowered.contains("no spendable utxos available")
            || lowered.contains("no utxos available")
    }

    func nextNoInputRetryDelay(for pendingTxId: String) -> TimeInterval {
        let nextAttempt = (noInputRetryCounts[pendingTxId] ?? 0) + 1
        noInputRetryCounts[pendingTxId] = nextAttempt
        let base = min(60.0, pow(2.0, Double(max(0, nextAttempt - 1))))
        let jitter = Double.random(in: 0.10...0.35)
        return base + (base * jitter)
    }

    func clearNoInputRetryState(for pendingTxId: String?) {
        guard let pendingTxId else { return }
        noInputRetryCounts.removeValue(forKey: pendingTxId)
        scheduledSendRetries.remove(pendingTxId)
    }

    func shouldAttemptMessageUtxoCompaction(
        currentMessageTx: KaspaRpcTransaction,
        plannedFeeSompi: UInt64,
        singleInputFeeSompi: UInt64,
        availableUtxos: [UTXO]
    ) -> Bool {
        guard Date().timeIntervalSince(lastMessageCompactionAt) >= messageCompactionCooldown else {
            return false
        }
        let spendableCount = availableUtxos.filter { !$0.isCoinbase }.count
        guard spendableCount >= 2 else { return false }

        if currentMessageTx.inputs.count >= messageCompactionInputThreshold {
            return true
        }
        guard currentMessageTx.inputs.count > 1 else {
            return false
        }

        let extraFeeSompi = plannedFeeSompi > singleInputFeeSompi
            ? plannedFeeSompi - singleInputFeeSompi
            : 0
        return extraFeeSompi >= messageCompactionFeeThresholdSompi
    }

    func messageCompactionTargetOutputSompi(
        alias: String,
        content: String,
        recipientPublicKey: Data,
        senderScriptPubKey: Data
    ) -> UInt64 {
        let fallback = addSompiSafely(KasiaTransactionBuilder.dustThreshold, 30_000)
        guard let burstMultiplier = UInt64(exactly: messageCompactionTargetBurstMessages) else {
            return fallback
        }

        do {
            let payload = try KasiaTransactionBuilder.buildContextualMessagePayload(
                alias: alias,
                message: content,
                recipientPublicKey: recipientPublicKey
            )
            let singleInputFee = KasiaTransactionBuilder.estimateContextualMessageFee(
                payload: payload,
                inputCount: 1,
                senderScriptPubKey: senderScriptPubKey
            )
            let (burstTotal, overflow) = singleInputFee.multipliedReportingOverflow(by: burstMultiplier)
            let safeBurstTotal = overflow ? UInt64.max : burstTotal
            return addSompiSafely(KasiaTransactionBuilder.dustThreshold, safeBurstTotal)
        } catch {
            return fallback
        }
    }

    func autoCompactMessageUtxos(
        rpcManager: NodePoolService,
        walletAddress: String,
        privateKey: Data,
        senderScriptPubKey: Data,
        availableUtxos: [UTXO],
        minOutputAmount: UInt64
    ) async throws -> (txId: String, endpoint: String) {
        let spendableUtxos = availableUtxos.filter { !$0.isCoinbase }
        let compaction = try KasiaTransactionBuilder.buildMessageCompactionTx(
            from: walletAddress,
            senderPrivateKey: privateKey,
            utxos: spendableUtxos,
            minOutputAmount: minOutputAmount,
            maxInputs: messageCompactionMaxInputs
        )

        let usesUnconfirmedInputs = compaction.selectedUtxos.contains { $0.blockDaaScore == 0 }
        let submitted = try await rpcManager.submitTransaction(
            compaction.transaction,
            allowOrphan: usesUnconfirmedInputs
        )
        reserveMessageOutpoints(compaction.selectedUtxos)
        consumePendingUtxos(compaction.selectedUtxos)
        addPendingOutputs(from: compaction.transaction, txId: submitted.txId, senderScriptPubKey: senderScriptPubKey)
        lastMessageCompactionAt = Date()

        AppLog.log("[ChatService] Auto-compaction tx %@ submitted (inputs=%d, output=%llu, allowOrphan=%@)",
              String(submitted.txId.prefix(12)),
              compaction.selectedUtxos.count,
              compaction.outputAmount,
              usesUnconfirmedInputs ? "true" : "false")
        return submitted
    }

    func ensureSufficientBalanceForMessageSend(
        to contact: Contact,
        content: String,
        walletAddress: String,
        privateKey: Data
    ) async throws {
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) else {
            throw KasiaError.invalidAddress
        }

        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)
        let utxos = try await fetchSendUtxos(for: walletAddress)
        let availableUtxos = prepareMessageUtxos(confirmed: utxos)
        let confirmedSpendableTotal = utxos
            .filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
            .reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
        let availableBalance = availableUtxos.reduce(UInt64(0)) { partial, utxo in
            addSompiSafely(partial, utxo.amount)
        }
        let payload = try KasiaTransactionBuilder.buildContextualMessagePayload(
            alias: alias,
            message: content,
            recipientPublicKey: recipientPublicKey
        )
        let estimatedFee = KasiaTransactionBuilder.estimateContextualMessageFee(
            payload: payload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )

        guard !availableUtxos.isEmpty else {
            if confirmedSpendableTotal > 0 {
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }
            throw formatInsufficientBalanceError(
                plannedSpendSompi: estimatedFee,
                availableSompi: availableBalance
            )
        }

        do {
            _ = try KasiaTransactionBuilder.buildContextualMessageTx(
                from: walletAddress,
                to: contact.address,
                alias: alias,
                message: content,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: availableUtxos
            )
        } catch {
            if isInsufficientFundsError(error) {
                throw formatInsufficientBalanceError(
                    plannedSpendSompi: estimatedFee,
                    availableSompi: availableBalance
                )
            }
            throw error
        }
    }

    func ensureSufficientBalanceForPaymentSend(
        to contact: Contact,
        amountSompi: UInt64,
        note: String,
        walletAddress: String,
        privateKey: Data
    ) async throws {
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: contact.address),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: walletAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = try await fetchSendUtxos(for: walletAddress)
        let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
        let totalNonCoinbaseBalance = utxos
            .filter { !$0.isCoinbase }
            .reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
        let availableBalance = spendable.reduce(UInt64(0)) { partial, utxo in
            addSompiSafely(partial, utxo.amount)
        }

        let paymentPayload = try KasiaTransactionBuilder.buildPaymentPayload(
            message: note,
            amount: amountSompi,
            recipientPublicKey: recipientPublicKey
        )
        let estimatedFee = (try? KasiaTransactionBuilder.estimatePaymentFee(
            utxos: spendable,
            payload: paymentPayload,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        )) ?? KasiaTransactionBuilder.estimateSendAllFee(
            utxos: spendable,
            payload: paymentPayload,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        )
        let plannedSpend = addSompiSafely(amountSompi, estimatedFee)

        guard !spendable.isEmpty else {
            if totalNonCoinbaseBalance > 0 {
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }
            throw formatInsufficientBalanceError(
                plannedSpendSompi: plannedSpend,
                availableSompi: availableBalance
            )
        }

        do {
            _ = try KasiaTransactionBuilder.buildPaymentTx(
                from: walletAddress,
                to: contact.address,
                amount: amountSompi,
                note: note,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: spendable
            )
        } catch {
            if isInsufficientFundsError(error) {
                throw formatInsufficientBalanceError(
                    plannedSpendSompi: plannedSpend,
                    availableSompi: availableBalance
                )
            }
            throw error
        }
    }

    func ensureSufficientBalanceForHandshakeSend(
        to contact: Contact,
        isResponse: Bool,
        walletAddress: String,
        alias: String,
        conversationId: String?,
        privateKey: Data,
        recipientPublicKey: Data
    ) async throws {
        let utxos = try await fetchSendUtxos(for: walletAddress)
        let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
        let totalNonCoinbaseBalance = utxos
            .filter { !$0.isCoinbase }
            .reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
        let (handshakeUtxos, _) = splitUtxosForHandshake(spendable)
        let availableBalance = handshakeUtxos.reduce(UInt64(0)) { partial, utxo in
            addSompiSafely(partial, utxo.amount)
        }
        let plannedSpend = KasiaTransactionBuilder.handshakeAmount

        guard !handshakeUtxos.isEmpty else {
            if totalNonCoinbaseBalance > 0 {
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }
            throw formatInsufficientBalanceError(
                plannedSpendSompi: plannedSpend,
                availableSompi: availableBalance
            )
        }

        do {
            _ = try KasiaTransactionBuilder.buildHandshakeTx(
                from: walletAddress,
                to: contact.address,
                alias: alias,
                conversationId: conversationId,
                isResponse: isResponse,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: handshakeUtxos
            )
        } catch {
            if isInsufficientFundsError(error) {
                throw formatInsufficientBalanceError(
                    plannedSpendSompi: plannedSpend,
                    availableSompi: availableBalance
                )
            }
            throw error
        }
    }

    func sendMessage(to contact: Contact, content: String, messageType: ChatMessage.MessageType = .contextual, feeOverride: UInt64? = nil) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        // If replying, wrap the content in the shared reply envelope (matches broadcasts'
        // sendBroadcast) so the quote survives even if the original message is later pruned.
        let payload: String
        if let reply = replyingTo {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            payload = MessageReplyCodec.encode(
                replyToId: reply.txId,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            payload = trimmed
        }

        let pendingTxId = "pending_\(UUID().uuidString)"
        let pendingTimestamp = Date()
        let pendingMessage = ChatMessage(
            txId: pendingTxId,
            senderAddress: wallet.publicAddress,
            receiverAddress: contact.address,
            content: payload,
            timestamp: pendingTimestamp,
            blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
            isOutgoing: true,
            messageType: messageType,
            deliveryStatus: .pending
        )
        addMessageToConversation(pendingMessage, contactAddress: contact.address)
        enqueuePendingOutgoing(contactAddress: contact.address, pendingTxId: pendingTxId, messageType: messageType, timestamp: pendingTimestamp)
        saveMessages()

        do {
            try await ensureSufficientBalanceForMessageSend(
                to: contact,
                content: payload,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey
            )
        } catch {
            if isInsufficientBalancePopupError(error) {
                markPendingMessageFailed(pendingTxId, contactAddress: contact.address)
                throw error
            } else if isNoConfirmedInputsError(error) {
                AppLog.log("[ChatService] Message send precheck deferred: %@", error.localizedDescription)
            } else if shouldBypassBalancePrecheck(error) {
                AppLog.log("[ChatService] Message balance precheck unavailable, continuing send: %@", error.localizedDescription)
            } else {
                markPendingMessageFailed(pendingTxId, contactAddress: contact.address)
                throw error
            }
        }

        try await enqueueOutgoingTxOperation {
            try await self.sendMessageInternal(
                to: contact,
                content: payload,
                messageType: messageType,
                pendingTxId: pendingTxId,
                pendingMessageId: pendingMessage.id,
                feeOverride: feeOverride
            )
        }
        replyingTo = nil

        // Successful send: refresh the Share Extension's recents and donate an
        // INSendMessageIntent so iOS can surface this conversation as a share-sheet
        // direct target (requires IntentsSupported in the extension's Info.plist).
        SharedDataManager.recordRecentConversation(address: contact.address, alias: contact.alias)
        donateSendMessageIntent(for: contact)
    }

    /// Donates an INSendMessageIntent for this conversation. After a few donations iOS shows the
    /// conversation as a suggested direct target in the system share sheet; the Share Extension
    /// reads the donated `conversationIdentifier` (the contact address) back from
    /// `extensionContext.intent` to pre-select the contact.
    private func donateSendMessageIntent(for contact: Contact) {
        let trimmedAlias = contact.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedAlias.isEmpty ? String(contact.address.suffix(8)) : trimmedAlias

        let recipient = INPerson(
            personHandle: INPersonHandle(value: contact.address, type: .unknown),
            nameComponents: nil,
            displayName: displayName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: contact.address
        )

        let intent = INSendMessageIntent(
            recipients: [recipient],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: displayName),
            conversationIdentifier: contact.address,
            serviceName: "KaChat",
            sender: nil,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.groupIdentifier = contact.address
        interaction.direction = .outgoing
        interaction.donate { error in
            if let error {
                AppLog.log("[ChatService] INSendMessageIntent donation failed: %@", error.localizedDescription)
            }
        }
    }

    func sendAudio(
        to contact: Contact,
        audioData: Data,
        fileName: String = "audio.webm",
        mimeType: String = "audio/webm"
    ) async throws {
        guard !audioData.isEmpty else {
            throw KasiaError.networkError("Audio file is empty")
        }

        let resolvedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "audio.webm"
            : fileName
        let resolvedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "audio/webm"
            : mimeType
        let base64 = audioData.base64EncodedString()
        // Deterministic field order (mimeType before the multi-MB content) so every client's
        // head-window preview sniff can identify the media kind - see MediaFileEnvelope.
        let jsonString = MediaFileEnvelope.json(
            name: resolvedFileName,
            size: audioData.count,
            mimeType: resolvedMimeType,
            dataUrlContent: "data:\(resolvedMimeType);base64,\(base64)"
        )

        try await sendMessage(to: contact, content: jsonString, messageType: .audio)
    }

    /// Sends a photo - same inline JSON envelope as `sendAudio`, just an image mimeType, matching
    /// Android's `ImageMessage` (which itself reuses its `VoiceMessageContent` shape). Reuses the
    /// `.audio` message type since rendering already keys off the JSON's `mimeType`, not this.
    func sendImage(
        to contact: Contact,
        imageData: Data,
        fileName: String = "photo.jpg",
        mimeType: String = "image/jpeg"
    ) async throws {
        guard !imageData.isEmpty else {
            throw KasiaError.networkError("Image is empty")
        }

        let resolvedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "photo.jpg"
            : fileName
        let resolvedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "image/jpeg"
            : mimeType
        let base64 = imageData.base64EncodedString()
        let jsonString = MediaFileEnvelope.json(
            name: resolvedFileName,
            size: imageData.count,
            mimeType: resolvedMimeType,
            dataUrlContent: "data:\(resolvedMimeType);base64,\(base64)"
        )

        try await sendMessage(to: contact, content: jsonString, messageType: .audio)
    }

    func retryOutgoingMessage(_ message: ChatMessage, contact: Contact) async throws {
        guard message.isOutgoing else { return }
        switch message.messageType {
        case .contextual, .audio:
            try await enqueueOutgoingTxOperation {
                try await self.sendMessageInternal(
                    to: contact,
                    content: message.content,
                    messageType: message.messageType,
                    pendingTxId: message.txId,
                    pendingMessageId: message.id
                )
            }
        case .handshake:
            let isResponse = shouldRetryHandshakeAsResponse(for: contact.address)
            let pendingTxId = message.txId.hasPrefix("pending_") ? message.txId : nil
            try await sendHandshake(to: contact, isResponse: isResponse, pendingTxId: pendingTxId)
        case .payment:
            return
        }
    }

    func sendMessageInternal(
        to contact: Contact,
        content: String,
        messageType: ChatMessage.MessageType,
        pendingTxId: String?,
        pendingMessageId: UUID? = nil,
        spendableFundsRetryAttempt: Int = 0,
        feeOverride: UInt64? = nil
    ) async throws {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }

        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        // Get recipient's public key from their address
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        // Ensure routing state exists, then get our alias (deterministic preferred)
        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)

        let resolvedPendingTxId = pendingTxId ?? "pending_\(UUID().uuidString)"
        var activePendingMessageId = pendingMessageId
        if pendingTxId == nil {
            let pendingTimestamp = Date()
            let pendingMessage = ChatMessage(
                txId: resolvedPendingTxId,
                senderAddress: wallet.publicAddress,
                receiverAddress: contact.address,
                content: content,
                timestamp: pendingTimestamp,
                blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
                isOutgoing: true,
                messageType: messageType,
                deliveryStatus: .pending
            )
            // Animated publish: the outgoing bubble flows into the list (layout change +
            // the detail view's animated scroll ride the same transaction) - matching the
            // broadcast room's send feel.
            withAnimation(.easeOut(duration: 0.25)) {
                addMessageToConversation(pendingMessage, contactAddress: contact.address)
            }
            enqueuePendingOutgoing(contactAddress: contact.address, pendingTxId: resolvedPendingTxId, messageType: messageType, timestamp: pendingTimestamp)
            activePendingMessageId = pendingMessage.id
        } else {
            resetPendingMessage(resolvedPendingTxId, contactAddress: contact.address)
        }
        saveMessages()

        let activePendingTxId = resolvedPendingTxId
        if activePendingMessageId == nil {
            activePendingMessageId = resolveMessageIdForPending(contactAddress: contact.address, pendingTxId: activePendingTxId)
        }
        if let activePendingMessageId {
            registerOutgoingAttempt(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: messageType
            )
            markOutgoingAttemptSubmitting(messageId: activePendingMessageId)
        }

        do {
            // Connect to Kaspa node
            let rpcManager = NodePoolService.shared
            let settings = currentSettings

            AppLog.log("%@", "[ChatService] Starting message send to \(contact.address.suffix(10))")

            // Connect via gRPC manager
            if !rpcManager.isConnected {
                AppLog.log("%@", "[ChatService] RPC not connected, connecting...")
                try await rpcManager.connect(network: settings.networkType)
            } else {
                AppLog.log("%@", "[ChatService] RPC already connected")
            }

            // Fetch UTXOs for our address
            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let availableUtxos = prepareMessageUtxos(confirmed: utxos)
            guard !availableUtxos.isEmpty else {
                let totalBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
                if totalBalanceSompi == 0 {
                    AppLog.log("[ChatService] No confirmed UTXOs available - wallet balance is zero for %@",
                          String(activePendingTxId.prefix(12)))
                    throw KasiaError.networkError("Zero balance: add funds to your wallet and try again.")
                }

                AppLog.log("[ChatService] No confirmed spendable UTXOs available for %@",
                      String(activePendingTxId.prefix(12)))
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }

            AppLog.log("%@", "[ChatService] Found \(availableUtxos.count) available UTXOs for sending")

            let buildMessageTransaction: ([UTXO]) throws -> KaspaRpcTransaction = { candidateUtxos in
                try KasiaTransactionBuilder.buildContextualMessageTx(
                    from: wallet.publicAddress,
                    to: contact.address,
                    alias: alias,
                    message: content,
                    senderPrivateKey: privateKey,
                    recipientPublicKey: recipientPublicKey,
                    utxos: candidateUtxos,
                    feeOverride: feeOverride
                )
            }

            var candidateUtxos = availableUtxos
            var transaction = try buildMessageTransaction(candidateUtxos)
            var spentUtxos = spentMessageUtxos(from: transaction, candidates: candidateUtxos)
            let initialMessageInputCount = transaction.inputs.count
            var totalInputSompi = spentUtxos.reduce(UInt64(0)) { partial, utxo in
                addSompiSafely(partial, utxo.amount)
            }
            var totalOutputSompi = transaction.outputs.reduce(UInt64(0)) { partial, output in
                addSompiSafely(partial, output.value)
            }
            var effectiveFeeSompi = totalInputSompi > totalOutputSompi
                ? totalInputSompi - totalOutputSompi
                : 0
            let singleInputFeeSompi = KasiaTransactionBuilder.estimateContextualMessageFee(
                payload: transaction.payload,
                inputCount: 1,
                senderScriptPubKey: senderScriptPubKey
            )

            if shouldAttemptMessageUtxoCompaction(
                currentMessageTx: transaction,
                plannedFeeSompi: effectiveFeeSompi,
                singleInputFeeSompi: singleInputFeeSompi,
                availableUtxos: candidateUtxos
            ) {
                let compactionTarget = messageCompactionTargetOutputSompi(
                    alias: alias,
                    content: content,
                    recipientPublicKey: recipientPublicKey,
                    senderScriptPubKey: senderScriptPubKey
                )
                var didSubmitCompaction = false
                do {
                    let compactionResult = try await autoCompactMessageUtxos(
                        rpcManager: rpcManager,
                        walletAddress: wallet.publicAddress,
                        privateKey: privateKey,
                        senderScriptPubKey: senderScriptPubKey,
                        availableUtxos: candidateUtxos,
                        minOutputAmount: compactionTarget
                    )
                    didSubmitCompaction = true
                    AppLog.log("%@", "[ChatService] Auto-compaction submitted: \(compactionResult.txId) via \(compactionResult.endpoint)")

                    candidateUtxos = prepareMessageUtxos(confirmed: utxos)
                    transaction = try buildMessageTransaction(candidateUtxos)
                    spentUtxos = spentMessageUtxos(from: transaction, candidates: candidateUtxos)
                    totalInputSompi = spentUtxos.reduce(UInt64(0)) { partial, utxo in
                        addSompiSafely(partial, utxo.amount)
                    }
                    totalOutputSompi = transaction.outputs.reduce(UInt64(0)) { partial, output in
                        addSompiSafely(partial, output.value)
                    }
                    effectiveFeeSompi = totalInputSompi > totalOutputSompi
                        ? totalInputSompi - totalOutputSompi
                        : 0
                    AppLog.log("[ChatService] Auto-compaction refreshed message inputs for %@: %d -> %d",
                          String(activePendingTxId.prefix(12)),
                          initialMessageInputCount,
                          transaction.inputs.count)
                } catch {
                    if didSubmitCompaction {
                        throw error
                    }
                    AppLog.log("[ChatService] Auto-compaction skipped for %@: %@",
                          String(activePendingTxId.prefix(12)),
                          error.localizedDescription)
                }
            }

            let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }
            let extraFeeSompi = effectiveFeeSompi > singleInputFeeSompi
                ? effectiveFeeSompi - singleInputFeeSompi
                : 0
            AppLog.log("[ChatService] Message tx plan %@: inputs=%d fee=%llu singleInputFee=%llu extra=%llu allowOrphan=%@",
                  String(activePendingTxId.prefix(12)),
                  transaction.inputs.count,
                  effectiveFeeSompi,
                  singleInputFeeSompi,
                  extraFeeSompi,
                  usesUnconfirmedInputs ? "true" : "false")

            let txId: String
            let endpoint: String
            do {
                let submitted = try await rpcManager.submitTransaction(
                    transaction,
                    allowOrphan: usesUnconfirmedInputs
                )
                txId = submitted.txId
                endpoint = submitted.endpoint
            } catch {
                let shouldFallbackToConfirmed = usesUnconfirmedInputs &&
                    (shouldRetrySendError(error) || shouldRetryNoSpendableFundsError(error))
                guard shouldFallbackToConfirmed else { throw error }

                let confirmedOnlyUtxos = candidateUtxos.filter { $0.blockDaaScore > 0 }
                guard !confirmedOnlyUtxos.isEmpty else { throw error }

                AppLog.log("[ChatService] Message submit fallback to confirmed-only inputs for %@",
                      String(activePendingTxId.prefix(12)))

                let confirmedOnlyTransaction = try buildMessageTransaction(confirmedOnlyUtxos)
                let confirmedOnlyInputs = confirmedOnlyTransaction.inputs.count
                if confirmedOnlyInputs > 2 {
                    AppLog.log("[ChatService] Skipping expensive confirmed-only fallback for %@ (inputs=%d)",
                          String(activePendingTxId.prefix(12)),
                          confirmedOnlyInputs)
                    throw error
                }

                transaction = confirmedOnlyTransaction
                spentUtxos = spentMessageUtxos(from: transaction, candidates: confirmedOnlyUtxos)

                let submitted = try await rpcManager.submitTransaction(transaction, allowOrphan: false)
                txId = submitted.txId
                endpoint = submitted.endpoint
            }

            AppLog.log("%@", "[ChatService] Transaction submitted: \(txId) via \(endpoint)")

            reserveMessageOutpoints(spentUtxos)
            consumePendingUtxos(spentUtxos)
            addPendingOutputs(from: transaction, txId: txId, senderScriptPubKey: senderScriptPubKey)
            clearNoInputRetryState(for: activePendingTxId)

            // Update the pending message with the real transaction ID
            if let activePendingMessageId {
                _ = updatePendingMessageById(
                    activePendingMessageId,
                    newTxId: txId,
                    contactAddress: contact.address
                )
            } else {
                _ = updatePendingMessage(activePendingTxId, withRealTxId: txId, contactAddress: contact.address)
            }
            markOutgoingAttemptSubmitted(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: messageType,
                txId: txId
            )

            // Store our alias for future messages
            addOurAlias(alias, for: contact.address, blockTime: nil)
            saveOurAliases()
            if conversationIds[contact.address] == nil, let pendingConvId = conversationIds["pending_\(contact.address)"] {
                conversationIds[contact.address] = pendingConvId
                conversationIds.removeValue(forKey: "pending_\(contact.address)")
                saveConversationIds()
            }

            saveMessages(triggerExport: true)

        } catch {
            releaseMessageOutpoints()
            if let acceptedTxId = acceptedTransactionId(from: error) {
                AppLog.log("[ChatService] Message already accepted by consensus for %@ -> promoting pending to %@",
                      String(activePendingTxId.prefix(12)),
                      String(acceptedTxId.prefix(12)))
                if let activePendingMessageId {
                    _ = updatePendingMessageById(
                        activePendingMessageId,
                        newTxId: acceptedTxId,
                        contactAddress: contact.address
                    )
                } else {
                    _ = updatePendingMessage(activePendingTxId, withRealTxId: acceptedTxId, contactAddress: contact.address)
                }
                markOutgoingAttemptSubmitted(
                    messageId: activePendingMessageId,
                    pendingTxId: activePendingTxId,
                    contactAddress: contact.address,
                    messageType: messageType,
                    txId: acceptedTxId
                )
                clearNoInputRetryState(for: activePendingTxId)
                saveMessages(triggerExport: true)
                return
            }
            if shouldRetryNoSpendableFundsError(error),
               spendableFundsRetryAttempt < spendableFundsRetryAttempts {
                let retryNumber = spendableFundsRetryAttempt + 1
                let retryDelay = spendableFundsRetryDelay(for: retryNumber)
                if let jitterRatio = retryDelay.jitterRatio {
                    AppLog.log(
                        "[ChatService] Retrying send (no spendable funds) for %@ (%d/%d) in %.0fms (+%.0f%% jitter)",
                        String(activePendingTxId.prefix(12)),
                        retryNumber,
                        spendableFundsRetryAttempts,
                        retryDelay.seconds * 1000,
                        jitterRatio * 100
                    )
                } else {
                    AppLog.log(
                        "[ChatService] Retrying send (no spendable funds) for %@ (%d/%d) in %.0fms",
                        String(activePendingTxId.prefix(12)),
                        retryNumber,
                        spendableFundsRetryAttempts,
                        retryDelay.seconds * 1000
                    )
                }
                try await Task.sleep(nanoseconds: UInt64(retryDelay.seconds * 1_000_000_000))
                try await sendMessageInternal(
                    to: contact,
                    content: content,
                    messageType: messageType,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    spendableFundsRetryAttempt: retryNumber
                )
                return
            }
            if shouldRetryNoSpendableFundsError(error) {
                let delay = nextNoInputRetryDelay(for: activePendingTxId)
                AppLog.log(
                    "[ChatService] Deferred retry (no confirmed inputs) for %@ in %.0fs",
                    String(activePendingTxId.prefix(12)),
                    delay
                )
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    messageType: messageType,
                    delaySeconds: delay
                )
                return
            }
            if shouldRetrySendError(error) {
                AppLog.log("[ChatService] Message send retry scheduled for %@: %@",
                      String(activePendingTxId.prefix(12)), error.localizedDescription)
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    messageType: messageType,
                    delaySeconds: 4
                )
                return
            }
            markOutgoingAttemptFailed(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId
            )
            markPendingMessageFailed(activePendingTxId, contactAddress: contact.address)
            saveMessages()
            throw error
        }
    }

    func resolveMessageIdForPending(contactAddress: String, pendingTxId: String) -> UUID? {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return nil
        }
        return conversations[convIndex].messages.first(where: { $0.txId == pendingTxId })?.id
    }

    func resolveMessageIdForTx(contactAddress: String, txId: String) -> UUID? {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return nil
        }
        return conversations[convIndex].messages.first(where: { $0.txId == txId })?.id
    }

    func pruneOutgoingAttempts(now: Date = Date()) {
        let staleIds = outgoingAttemptsByMessageId.compactMap { messageId, attempt -> UUID? in
            if now.timeIntervalSince(attempt.updatedAt) > outgoingAttemptTTL {
                return messageId
            }
            return nil
        }

        for staleId in staleIds {
            guard let attempt = outgoingAttemptsByMessageId.removeValue(forKey: staleId) else { continue }
            outgoingAttemptByPendingTxId.removeValue(forKey: attempt.pendingTxId)
            if let txId = attempt.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: txId)
            }
        }
    }

    func registerOutgoingAttempt(
        messageId: UUID,
        pendingTxId: String,
        contactAddress: String,
        messageType: ChatMessage.MessageType
    ) {
        pruneOutgoingAttempts()
        if let existing = outgoingAttemptsByMessageId[messageId] {
            outgoingAttemptByPendingTxId.removeValue(forKey: existing.pendingTxId)
            if let txId = existing.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: txId)
            }
        }
        let now = Date()
        let attempt = OutgoingTxAttempt(
            messageId: messageId,
            pendingTxId: pendingTxId,
            contactAddress: contactAddress,
            messageType: messageType,
            txId: nil,
            phase: .queued,
            updatedAt: now
        )
        outgoingAttemptsByMessageId[messageId] = attempt
        outgoingAttemptByPendingTxId[pendingTxId] = messageId
    }

    func markOutgoingAttemptSubmitting(messageId: UUID?) {
        guard let messageId else { return }
        pruneOutgoingAttempts()
        guard var attempt = outgoingAttemptsByMessageId[messageId] else { return }
        attempt.phase = .submitting
        attempt.updatedAt = Date()
        outgoingAttemptsByMessageId[messageId] = attempt
    }

    func markOutgoingAttemptSubmitted(
        messageId: UUID?,
        pendingTxId: String,
        contactAddress: String,
        messageType: ChatMessage.MessageType,
        txId: String
    ) {
        pruneOutgoingAttempts()
        let resolvedMessageId = messageId
            ?? outgoingAttemptByPendingTxId[pendingTxId]
            ?? resolveMessageIdForTx(contactAddress: contactAddress, txId: txId)
            ?? resolveMessageIdForPending(contactAddress: contactAddress, pendingTxId: pendingTxId)

        guard let resolvedMessageId else { return }

        if let existing = outgoingAttemptsByMessageId[resolvedMessageId] {
            outgoingAttemptByPendingTxId.removeValue(forKey: existing.pendingTxId)
            if let existingTxId = existing.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: existingTxId)
            }
        }

        let attempt = OutgoingTxAttempt(
            messageId: resolvedMessageId,
            pendingTxId: pendingTxId,
            contactAddress: contactAddress,
            messageType: messageType,
            txId: txId,
            phase: .submitted,
            updatedAt: Date()
        )
        outgoingAttemptsByMessageId[resolvedMessageId] = attempt
        outgoingAttemptByRealTxId[txId] = resolvedMessageId
    }

    func markOutgoingAttemptFailed(messageId: UUID?, pendingTxId: String?) {
        pruneOutgoingAttempts()

        if let messageId,
           let existing = outgoingAttemptsByMessageId.removeValue(forKey: messageId) {
            outgoingAttemptByPendingTxId.removeValue(forKey: existing.pendingTxId)
            if let existingTxId = existing.txId {
                outgoingAttemptByRealTxId.removeValue(forKey: existingTxId)
            }
            return
        }

        if let pendingTxId,
           let mappedMessageId = outgoingAttemptByPendingTxId.removeValue(forKey: pendingTxId),
           let existing = outgoingAttemptsByMessageId.removeValue(forKey: mappedMessageId),
           let existingTxId = existing.txId {
            outgoingAttemptByRealTxId.removeValue(forKey: existingTxId)
        }
    }

    func hasInFlightOutgoingAttemptWithoutTxId(for contactAddress: String) -> Bool {
        pruneOutgoingAttempts()
        return outgoingAttemptsByMessageId.values.contains {
            $0.contactAddress == contactAddress &&
            $0.txId == nil &&
            ($0.phase == .queued || $0.phase == .submitting)
        }
    }

    func isKnownOutgoingAttemptTxId(_ txId: String) -> Bool {
        pruneOutgoingAttempts()
        return outgoingAttemptByRealTxId[txId] != nil
    }

    func shouldDeferClassification(
        txId: String,
        txAddedAddresses: Set<String>,
        contactAddresses: Set<String>
    ) -> Bool {
        if isKnownOutgoingAttemptTxId(txId) {
            return false
        }

        let touchedContacts = txAddedAddresses.intersection(contactAddresses)
        guard !touchedContacts.isEmpty else { return false }

        for contact in touchedContacts {
            if hasInFlightOutgoingAttemptWithoutTxId(for: contact) {
                return true
            }
        }
        return false
    }

    func promoteKnownOutgoingAttempt(contactAddress: String, newTxId: String) -> Bool {
        pruneOutgoingAttempts()

        if let attemptId = outgoingAttemptByRealTxId[newTxId],
           let existing = outgoingAttemptsByMessageId[attemptId],
           existing.contactAddress == contactAddress {
            return true
        }

        let candidate = outgoingAttemptsByMessageId.values
            .filter {
                $0.contactAddress == contactAddress &&
                $0.txId == nil &&
                ($0.phase == .queued || $0.phase == .submitting)
            }
            .sorted { $0.updatedAt < $1.updatedAt }
            .first

        if let candidate,
           updatePendingMessageById(candidate.messageId, newTxId: newTxId, contactAddress: contactAddress) {
            markOutgoingAttemptSubmitted(
                messageId: candidate.messageId,
                pendingTxId: candidate.pendingTxId,
                contactAddress: contactAddress,
                messageType: candidate.messageType,
                txId: newTxId
            )
            saveMessages()
            return true
        }

        if updatePendingFromQueue(contactAddress: contactAddress, newTxId: newTxId, messageType: .payment) ||
            updateOldestPendingOutgoingMessage(contactAddress: contactAddress, newTxId: newTxId, messageType: .payment) {
            return true
        }

        return false
    }

    func outpointKey(_ outpoint: UTXO.Outpoint) -> String {
        "\(outpoint.transactionId):\(outpoint.index)"
    }

    func spentMessageUtxos(from transaction: KaspaRpcTransaction, candidates: [UTXO]) -> [UTXO] {
        let spentKeys = Set(transaction.inputs.map { outpointKey($0.previousOutpoint) })
        return candidates.filter { spentKeys.contains(outpointKey($0.outpoint)) }
    }

    func prepareMessageUtxos(confirmed: [UTXO]) -> [UTXO] {
        let now = Date()
        pruneMessageUtxoCaches(confirmed: confirmed, now: now)
        let confirmedSpendable = confirmed
            .filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
        let pendingSpendable = pendingMessageUtxos.values
            .map(\.utxo)
            .filter { !$0.isCoinbase }

        var merged: [UTXO] = []
        var seenOutpoints = Set<String>()
        for utxo in pendingSpendable + confirmedSpendable {
            let key = outpointKey(utxo.outpoint)
            guard reservedMessageOutpoints[key] == nil else { continue }
            guard seenOutpoints.insert(key).inserted else { continue }
            merged.append(utxo)
        }
        return merged
    }

    func pruneMessageUtxoCaches(confirmed: [UTXO], now: Date) {
        reservedMessageOutpoints = reservedMessageOutpoints.filter { $0.value > now }
        let confirmedKeys = Set(confirmed.map { outpointKey($0.outpoint) })
        pendingMessageUtxos = pendingMessageUtxos.filter { key, entry in
            entry.expiresAt > now && !confirmedKeys.contains(key)
        }
    }

    func reserveMessageOutpoints(_ utxos: [UTXO]) {
        let expiration = Date().addingTimeInterval(pendingMessageUtxoTTL)
        for utxo in utxos {
            reservedMessageOutpoints[outpointKey(utxo.outpoint)] = expiration
        }
    }

    func consumePendingUtxos(_ utxos: [UTXO]) {
        for utxo in utxos {
            pendingMessageUtxos.removeValue(forKey: outpointKey(utxo.outpoint))
        }
    }

    func addPendingOutputs(from transaction: KaspaRpcTransaction, txId: String, senderScriptPubKey: Data) {
        let expiration = Date().addingTimeInterval(pendingMessageUtxoTTL)
        for (index, output) in transaction.outputs.enumerated() {
            guard output.scriptPublicKey.script == senderScriptPubKey else { continue }
            let utxo = UTXO(
                address: "",
                outpoint: UTXO.Outpoint(transactionId: txId, index: UInt32(index)),
                amount: output.value,
                scriptPublicKey: senderScriptPubKey,
                blockDaaScore: 0,
                isCoinbase: false
            )
            pendingMessageUtxos[outpointKey(utxo.outpoint)] = (utxo, expiration)
        }
    }

    func releaseMessageOutpoints() {
        let now = Date()
        reservedMessageOutpoints = reservedMessageOutpoints.filter { $0.value > now }
        pendingMessageUtxos = pendingMessageUtxos.filter { $0.value.expiresAt > now }
    }

    func shouldRetrySendError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("orphan") || message.contains("already spent")
    }

    func shouldRetryNoSpendableFundsError(_ error: Error) -> Bool {
        isNoConfirmedInputsError(error)
    }

    func spendableFundsRetryDelay(for retryNumber: Int) -> (seconds: TimeInterval, jitterRatio: Double?) {
        let normalizedRetry = max(1, retryNumber)
        let baseDelay = spendableFundsRetryBaseDelay * pow(2.0, Double(normalizedRetry - 1))
        guard normalizedRetry > 2 else {
            return (baseDelay, nil)
        }

        let jitterRatio = Double.random(in: 0.10...0.40)
        let jitterDelay = baseDelay * jitterRatio
        return (baseDelay + jitterDelay, jitterRatio)
    }

    func acceptedTransactionId(from error: Error) -> String? {
        let message = error.localizedDescription
        guard message.lowercased().contains("already accepted by the consensus") else { return nil }
        return extractLikelyTxId(from: message)
    }

    func extractLikelyTxId(from text: String) -> String? {
        if let txIdAfterKeyword = extractTxId(after: "transaction", in: text) {
            return txIdAfterKeyword
        }
        return extractFirstHex64(in: text)
    }

    func extractTxId(after keyword: String, in text: String) -> String? {
        let lowered = text.lowercased()
        guard let range = lowered.range(of: keyword) else { return nil }
        let tail = String(lowered[range.upperBound...])
        return extractFirstHex64AllowingWhitespace(in: tail)
    }

    func extractFirstHex64(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[0-9a-fA-F]{64}") else { return nil }
        let full = text as NSString
        let range = NSRange(location: 0, length: full.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return full.substring(with: match.range).lowercased()
    }

    func extractFirstHex64AllowingWhitespace(in text: String) -> String? {
        // Some node errors wrap txId across newlines/spaces. Accept and compact it.
        guard let regex = try? NSRegularExpression(pattern: "([0-9a-fA-F][0-9a-fA-F\\s]{63,200})") else { return nil }
        let full = text as NSString
        let range = NSRange(location: 0, length: full.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        let raw = full.substring(with: match.range)
        let compact = raw.filter { $0.isHexDigit }
        guard compact.count >= 64 else { return nil }
        return String(compact.prefix(64)).lowercased()
    }

    func scheduleOutgoingRetry(
        contact: Contact,
        pendingTxId: String,
        pendingMessageId: UUID?,
        messageType: ChatMessage.MessageType,
        delaySeconds: TimeInterval,
        paymentAmountSompi: UInt64? = nil,
        paymentNote: String = "",
        handshakeIsResponse: Bool? = nil
    ) {
        guard !scheduledSendRetries.contains(pendingTxId) else { return }
        scheduledSendRetries.insert(pendingTxId)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self else { return }
            self.scheduledSendRetries.remove(pendingTxId)
            guard let convIndex = self.conversations.firstIndex(where: { $0.contact.address == contact.address }),
                  let message = self.conversations[convIndex].messages.first(where: { $0.txId == pendingTxId || $0.id == pendingMessageId }) else {
                self.clearNoInputRetryState(for: pendingTxId)
                return
            }
            guard message.deliveryStatus != .sent else {
                self.clearNoInputRetryState(for: pendingTxId)
                return
            }

            let retryPendingTxId = message.txId
            let retryPendingMessageId = message.id
            do {
                try await self.enqueueOutgoingTxOperation {
                    switch messageType {
                    case .contextual, .audio:
                        try await self.sendMessageInternal(
                            to: contact,
                            content: message.content,
                            messageType: messageType,
                            pendingTxId: retryPendingTxId,
                            pendingMessageId: retryPendingMessageId
                        )
                    case .payment:
                        guard let paymentAmountSompi else { return }
                        try await self.sendPaymentInternal(
                            to: contact,
                            amountSompi: paymentAmountSompi,
                            note: paymentNote,
                            pendingTxId: retryPendingTxId
                        )
                    case .handshake:
                        let isResponse = handshakeIsResponse ?? self.shouldRetryHandshakeAsResponse(for: contact.address)
                        try await self.sendHandshakeInternal(
                            to: contact,
                            isResponse: isResponse,
                            pendingTxId: retryPendingTxId
                        )
                    }
                }
            } catch {
                // Individual send handlers decide whether to reschedule or fail.
            }
        }
    }

    func sendPayment(
        to contact: Contact,
        amountSompi: UInt64,
        note: String = "",
        pendingTxId: String? = nil,
        extraFeeSompi: UInt64 = 0
    ) async throws {
        try await enqueueOutgoingTxOperation {
            try await self.sendPaymentInternal(
                to: contact,
                amountSompi: amountSompi,
                note: note,
                pendingTxId: pendingTxId,
                extraFeeSompi: extraFeeSompi
            )
        }
    }

    func sendPaymentInternal(
        to contact: Contact,
        amountSompi: UInt64,
        note: String = "",
        pendingTxId: String? = nil,
        /// Extra priority fee (Fast/Priority tiers) on top of the computed base fee.
        extraFeeSompi: UInt64 = 0
    ) async throws {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        // FUNDING SOURCE - keyed on the per-account Chats Payment Privacy toggle:
        //
        // ON (default): payments spend from the spending chain (not the chatting/identity
        // address) - same "Pay in Kaspa" balance already shown elsewhere in the app - with
        // change always routed to a genuinely never-used address rather than back to the
        // address just spent from, then that fresh index becomes active once the send actually
        // succeeds. This mirrors ManageAddressesView/Swap's own spending-address model instead
        // of paying straight out of the identity address every time.
        //
        // OFF: chatting-to-chatting end to end - funded from the CHATTING address with the
        // identity key, change back to the chatting address (builder default), no spending
        // index rotation. Matches the toggle copy: sent AND received Kaspa uses public chatting
        // addresses. Estimators must agree - see `paymentFundingSourceAddress`.
        let chatsPrivacyOn = AppSettings.chatsPrivacyEnabled(for: wallet.publicAddress)
        let sourceAddress: String
        let sourcePrivateKey: Data
        let changeAddress: String?
        let freshChangeIndex: Int?
        if chatsPrivacyOn {
            let spendingIndex = WalletManager.shared.currentSpendingAddressIndex
            guard let spendingAddress = WalletManager.shared.spendingAddress(at: spendingIndex),
                  let spendingPrivateKey = WalletManager.shared.spendingPrivateKey(at: spendingIndex) else {
                throw KasiaError.keychainError("Could not derive spending address")
            }
            // One past the highest index this wallet has EVER revealed/used (not just
            // spendingIndex + 1) - guarantees change never lands on an address that's already
            // been used before, even if the active spending index was manually set backward via
            // Manage Addresses. (Payment-pool reservations bump the same max, so this can never
            // collide with an address reserved for a contact - both run serialized through the
            // outgoing queue.)
            let index = max(WalletManager.shared.maxSpendingAddressIndex, spendingIndex) + 1
            sourceAddress = spendingAddress
            sourcePrivateKey = spendingPrivateKey
            changeAddress = WalletManager.shared.spendingAddress(at: index)
            freshChangeIndex = index
        } else {
            guard let identityKey = WalletManager.shared.getPrivateKey() else {
                throw KasiaError.keychainError("Could not get private key")
            }
            sourceAddress = wallet.publicAddress
            sourcePrivateKey = identityKey
            changeAddress = nil
            freshChangeIndex = nil
        }

        if pendingTxId == nil {
            do {
                try await ensureSufficientBalanceForPaymentSend(
                    to: contact,
                    amountSompi: amountSompi,
                    note: note,
                    walletAddress: sourceAddress,
                    privateKey: sourcePrivateKey
                )
            } catch {
                if isInsufficientBalancePopupError(error) {
                    throw error
                } else if isNoConfirmedInputsError(error) {
                    AppLog.log("[ChatService] Payment send precheck deferred: %@", error.localizedDescription)
                } else if shouldBypassBalancePrecheck(error) {
                    AppLog.log("[ChatService] Payment balance precheck unavailable, continuing send: %@", error.localizedDescription)
                } else {
                    throw error
                }
            }
        }

        let activePendingTxId = pendingTxId ?? "pending_\(UUID().uuidString)"
        let pendingMessageId: UUID
        if pendingTxId == nil {
            let formattedAmount = formatKasAmount(amountSompi)
            let pendingTimestamp = Date()
            let pendingTemplate = AppLocalization.string("Sent %@ KAS")
            let pendingMessage = ChatMessage(
                txId: activePendingTxId,
                senderAddress: wallet.publicAddress,
                receiverAddress: contact.address,
                content: String(format: pendingTemplate, formattedAmount),
                timestamp: pendingTimestamp,
                blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
                acceptingBlock: nil,
                isOutgoing: true,
                messageType: .payment,
                deliveryStatus: .pending
            )
            pendingMessageId = pendingMessage.id
            addMessageToConversation(pendingMessage, contactAddress: contact.address)
            enqueuePendingOutgoing(contactAddress: contact.address, pendingTxId: activePendingTxId, messageType: .payment, timestamp: pendingTimestamp)
            saveMessages()
        } else {
            resetPendingMessage(activePendingTxId, contactAddress: contact.address)
            guard let existing = resolveMessageIdForPending(contactAddress: contact.address, pendingTxId: activePendingTxId) else {
                throw KasiaError.networkError("Pending payment not found for retry")
            }
            pendingMessageId = existing
        }

        registerOutgoingAttempt(
            messageId: pendingMessageId,
            pendingTxId: activePendingTxId,
            contactAddress: contact.address,
            messageType: .payment
        )
        markOutgoingAttemptSubmitting(messageId: pendingMessageId)

        // Fresh-address payment pools: pay a fresh address from the contact's stored pool when
        // one is available (chain observers can't link the payment to their chat identity),
        // falling back to the chatting address when no pool exists. Consumed at selection and
        // remembered per pending id so retries reuse the same destination. async: it probes
        // each candidate's on-chain history first, so a pool address already paid by another
        // device running the same seed is skipped instead of reused. See
        // `ChatService+PaymentPools.swift` / MESSAGING.md.
        let destinationAddress = await poolPaymentDestination(for: contact, pendingTxId: activePendingTxId)

        do {
            let rpcManager = NodePoolService.shared
            let settings = currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([sourceAddress])
            let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            guard let recipientPublicKey = KaspaAddress.publicKey(from: destinationAddress) else {
                throw KasiaError.invalidAddress
            }

            let tx = try KasiaTransactionBuilder.buildPaymentTx(
                from: sourceAddress,
                to: destinationAddress,
                amount: amountSompi,
                note: note,
                senderPrivateKey: sourcePrivateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: spendable,
                changeAddress: changeAddress,
                extraFeeSompi: extraFeeSompi
            )

            // Submit via RPC manager
            AppLog.log("[ChatService] Submitting payment via RPC manager...")
            let (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            AppLog.log("[ChatService] Payment submitted: \(txId) via \(endpoint)")
            if !chatsPrivacyOn, let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: sourceAddress) {
                // Chatting-address-funded payment (privacy OFF) spends from the SAME UTXO set
                // message sends use - the same outpoint bookkeeping every message send does
                // keeps an immediately-following message from racing onto the just-spent
                // outpoints before the node reflects them. Spending-chain payments (ON) don't
                // touch that set, so they skip this exactly as before.
                let spentUtxos = spentMessageUtxos(from: tx, candidates: spendable)
                reserveMessageOutpoints(spentUtxos)
                consumePendingUtxos(spentUtxos)
                addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: senderScriptPubKey)
            }
            _ = updatePendingMessageById(pendingMessageId, newTxId: txId, contactAddress: contact.address)
            markOutgoingAttemptSubmitted(
                messageId: pendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: .payment,
                txId: txId
            )
            clearNoInputRetryState(for: activePendingTxId)
            saveMessages(triggerExport: true)
            if let freshChangeIndex {
                await WalletManager.shared.setActiveSpendingAddress(freshChangeIndex)
            }
            handlePoolPaymentSubmitted(
                contact: contact,
                txId: txId,
                amountSompi: amountSompi,
                destinationAddress: destinationAddress,
                pendingTxId: activePendingTxId
            )
        } catch {
            if let acceptedTxId = acceptedTransactionId(from: error) {
                AppLog.log("[ChatService] Payment already accepted by consensus for %@ -> promoting pending to %@",
                      String(activePendingTxId.prefix(12)),
                      String(acceptedTxId.prefix(12)))
                _ = updatePendingMessageById(pendingMessageId, newTxId: acceptedTxId, contactAddress: contact.address)
                markOutgoingAttemptSubmitted(
                    messageId: pendingMessageId,
                    pendingTxId: activePendingTxId,
                    contactAddress: contact.address,
                    messageType: .payment,
                    txId: acceptedTxId
                )
                clearNoInputRetryState(for: activePendingTxId)
                saveMessages(triggerExport: true)
                if let freshChangeIndex {
                    await WalletManager.shared.setActiveSpendingAddress(freshChangeIndex)
                }
                handlePoolPaymentSubmitted(
                    contact: contact,
                    txId: acceptedTxId,
                    amountSompi: amountSompi,
                    destinationAddress: destinationAddress,
                    pendingTxId: activePendingTxId
                )
                return
            }

            if isNoConfirmedInputsError(error) {
                let delay = nextNoInputRetryDelay(for: activePendingTxId)
                AppLog.log(
                    "[ChatService] Payment deferred retry %@ in %.0fs (no confirmed inputs)",
                    String(activePendingTxId.prefix(12)),
                    delay
                )
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: pendingMessageId,
                    messageType: .payment,
                    delaySeconds: delay,
                    paymentAmountSompi: amountSompi,
                    paymentNote: note
                )
                return
            }

            markOutgoingAttemptFailed(messageId: pendingMessageId, pendingTxId: activePendingTxId)
            markPendingMessageFailed(activePendingTxId, contactAddress: contact.address)
            clearNoInputRetryState(for: activePendingTxId)
            saveMessages()
            throw error
        }
    }

    /// Sends a plain KAS transfer from the wallet's identity address to an arbitrary
    /// recipient address (Profile > Chatting Address > Withdraw Kaspa). Unlike sendPayment,
    /// this carries no KaChat protocol payload and has no chat/conversation bookkeeping
    /// (pending message, delivery status, etc.) since the recipient isn't necessarily a
    /// contact. Returns the submitted transaction id.
    func sendWithdrawal(toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0) async throws -> String {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard KaspaAddress.scriptPublicKey(from: toAddress) != nil else {
            throw KasiaError.invalidAddress
        }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        return try await enqueueOutgoingTxOperation {
            let rpcManager = NodePoolService.shared
            let settings = self.currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            self.updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            // Coin control passes back whichever UTXOs the user picked in the picker sheet,
            // which may be stale by the time the send actually fires - re-resolve by outpoint
            // against the fresh `spendable` fetch above rather than trusting the picker's
            // snapshot outright. Same pattern as sendFromSpendingAddress.
            var resolvedManualUtxos: [UTXO]?
            if let manualUtxos, !manualUtxos.isEmpty {
                func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
                let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
                let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
                guard !resolved.isEmpty else {
                    throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
                }
                resolvedManualUtxos = resolved
            }

            let tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                from: wallet.publicAddress,
                to: toAddress,
                amount: amountSompi,
                senderPrivateKey: privateKey,
                utxos: spendable,
                manualUtxos: resolvedManualUtxos,
                extraFeeSompi: extraFeeSompi
            )

            AppLog.log("[ChatService] Submitting withdrawal via RPC manager...")
            let (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            AppLog.log("[ChatService] Withdrawal submitted: \(txId) via \(endpoint)")
            return txId
        }
    }

    /// Estimates the total fee (base + optional priority tip) for a withdrawal, without
    /// requiring a gRPC connection (uses the same REST-fallback UTXO fetch as other fee
    /// previews, since this only needs read access for the estimate).
    func estimateWithdrawalFee(toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0) async throws -> UInt64 {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = try await fetchUtxosWithFallback(for: wallet.publicAddress)
        let spendable = utxos.filter { !$0.isCoinbase }
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = resolveManualUtxos(manualUtxos, against: spendable)

        return try KasiaTransactionBuilder.estimatePlainTransferFee(
            utxos: spendable,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi
        )
    }

    /// Maximum sendable amount for a withdrawal (balance minus the send-all fee, no change
    /// output). Mirrors estimateMaxPaymentAmount's approach for in-chat payments. With
    /// [manualUtxos] set (coin control active), "max" means max spendable from just that
    /// selected subset - same semantics as estimateMaxSpendingAddressAmount.
    func estimateMaxWithdrawalAmount(toAddress: String, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0) async throws -> UInt64 {
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = try await fetchUtxosWithFallback(for: wallet.publicAddress)
        let spendable = utxos.filter { !$0.isCoinbase }
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = resolveManualUtxos(manualUtxos, against: spendable)

        let totalBalance = (resolvedManualUtxos ?? spendable).reduce(0) { $0 + $1.amount }

        let fee = KasiaTransactionBuilder.estimateSendAllFee(
            utxos: spendable,
            payload: Data(),
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi
        )

        guard totalBalance > fee else {
            throw KasiaError.networkError("Balance too low to cover fee")
        }

        return totalBalance - fee
    }

    /// Sends a plain KAS transfer from a specific spending-chain address (Manage Addresses'
    /// per-row Withdraw action). Change stays on the *same* spending address — unlike
    /// advanceSpendingAddressIndex-driven sends, this is a scoped, explicit single-address
    /// operation and doesn't rotate which address is "primary."
    func sendFromSpendingAddress(index: Int, toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0) async throws -> String {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard KaspaAddress.scriptPublicKey(from: toAddress) != nil else {
            throw KasiaError.invalidAddress
        }
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index),
              let privateKey = WalletManager.shared.spendingPrivateKey(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }

        return try await enqueueOutgoingTxOperation {
            let rpcManager = NodePoolService.shared
            let settings = self.currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            // Spendable = non-coinbase + matured coinbase (mining rewards). The old `!isCoinbase`
            // gate dropped every coinbase UTXO, which is why compounding/withdrawing a mining
            // address failed with a bare "No spendable UTXOs".
            let vds = await self.resolveVirtualDaaScore(nil, utxos: utxos)
            var spendable = ChatService.spendableUtxos(utxos, virtualDaaScore: vds)
            if spendable.isEmpty, let manualUtxos, !manualUtxos.isEmpty {
                // The fresh fetch came back empty (transient pool/node condition) but the caller
                // pinned an explicit set (e.g. a compound chunk) - fall back to it; the node will
                // reject any of those inputs that were actually already spent.
                spendable = ChatService.spendableUtxos(manualUtxos, virtualDaaScore: vds)
            }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            // Coin control passes back whichever UTXOs the user picked in the picker sheet,
            // which may be stale by the time the send actually fires (spent by another device,
            // aged out, etc.) - re-resolve by outpoint against the fresh `spendable` fetch above
            // rather than trusting the picker's snapshot outright.
            var resolvedManualUtxos: [UTXO]?
            if let manualUtxos, !manualUtxos.isEmpty {
                func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
                let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
                let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
                guard !resolved.isEmpty else {
                    throw KasiaError.networkError("Selected UTXOs are no longer available - please reselect")
                }
                resolvedManualUtxos = resolved
            }

            let tx = try KasiaTransactionBuilder.buildPlainTransferTx(
                from: fromAddress,
                to: toAddress,
                amount: amountSompi,
                senderPrivateKey: privateKey,
                utxos: spendable,
                manualUtxos: resolvedManualUtxos,
                extraFeeSompi: extraFeeSompi,
                virtualDaaScore: vds
            )

            AppLog.log("[ChatService] Submitting spending-address withdrawal via RPC manager...")
            let (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            AppLog.log("[ChatService] Spending-address withdrawal submitted: \(txId) via \(endpoint)")
            return txId
        }
    }

    /// Kaspa coinbase (mining-reward) maturity, in DAA-score units: a coinbase UTXO is only
    /// spendable once `blockDaaScore + coinbaseMaturity < virtualDaaScore`. Matches Kaspa consensus
    /// and Kaspium (which uses the same 1000).
    static let coinbaseMaturity: UInt64 = 1000

    /// Filters a UTXO set to what's actually spendable *right now*. Non-coinbase UTXOs always are;
    /// coinbase (mining rewards) only once matured against `virtualDaaScore`. When the score is
    /// unknown (nil) coinbase is included and the node arbitrates - better than silently hiding a
    /// mining balance. This is why an address full of coinbase UTXOs used to fail every send/
    /// compound with a bare "No spendable UTXOs" (the old `!isCoinbase` filter dropped them all).
    static func spendableUtxos(_ utxos: [UTXO], virtualDaaScore: UInt64?) -> [UTXO] {
        utxos.filter { utxo in
            guard utxo.isCoinbase else { return true }
            guard let vds = virtualDaaScore else { return true }
            return utxo.blockDaaScore + coinbaseMaturity < vds
        }
    }

    /// Resolves the virtual DAA score needed for coinbase-maturity checks, fetching it from the
    /// pool only when it matters (the UTXO set actually contains coinbase). Non-mining addresses
    /// - the common case - never pay for a network round trip.
    func resolveVirtualDaaScore(_ provided: UInt64?, utxos: [UTXO]) async -> UInt64? {
        if let provided { return provided }
        guard utxos.contains(where: { $0.isCoinbase }) else { return nil }
        return await NodePoolService.shared.currentVirtualDaaScore()
    }

    /// The largest set of UTXOs that fit in a single mass-safe transaction (up to
    /// `KasiaTransactionBuilder.maxInputsPerTransaction`, largest-first), plus the max self-send
    /// amount for exactly that set. Kaspa caps a transaction's mass (~89 inputs), so the compound
    /// UI's "Max" uses this to reflect *one transaction's worth* of consolidatable value instead of
    /// the whole (over-mass) balance - the user consolidates that chunk, then repeats to reduce
    /// further. Returns the chunk so the send spends exactly those inputs.
    func maxConsolidatableChunk(index: Int, extraFeeSompi: UInt64 = 0, availableUtxos: [UTXO] = []) async throws -> (amountSompi: UInt64, utxos: [UTXO]) {
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        // Prefer the UTXOs the caller already loaded for this address (exactly what the user sees
        // in the list) so the estimate never depends on a second pooled fetch that can transiently
        // come back empty while the first succeeded. Only fetch (with one retry) if none supplied.
        var utxos = availableUtxos
        if utxos.isEmpty {
            let rpcManager = NodePoolService.shared
            if !rpcManager.isConnected {
                try await rpcManager.connect(network: currentSettings.networkType)
            }
            utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            if utxos.isEmpty {
                utxos = try await rpcManager.getUtxosByAddresses([fromAddress])
            }
        }
        // Spendable = non-coinbase (always) + matured coinbase. A pure `!isCoinbase` gate is what
        // broke compounding on mining-reward addresses: it dropped every one of their coinbase
        // UTXOs. Fetch the virtual DAA score only when coinbase is actually present.
        let virtualDaaScore = await resolveVirtualDaaScore(nil, utxos: utxos)
        let spendable = ChatService.spendableUtxos(utxos, virtualDaaScore: virtualDaaScore)
        guard !spendable.isEmpty else {
            if utxos.contains(where: { $0.isCoinbase }) {
                throw KasiaError.networkError("These are mining (coinbase) rewards that haven't matured yet. Each becomes spendable a short time (about 1–2 minutes) after it's mined - try again shortly.")
            }
            throw KasiaError.networkError("No spendable UTXOs available")
        }
        // Largest-first, capped to what fits one transaction's mass.
        let chunk = Array(spendable.sorted { $0.amount > $1.amount }.prefix(KasiaTransactionBuilder.maxInputsPerTransaction))
        let amount = try await estimateMaxSpendingAddressAmount(index: index, toAddress: fromAddress, manualUtxos: chunk, extraFeeSompi: extraFeeSompi, availableUtxos: utxos, virtualDaaScore: virtualDaaScore)
        return (amount, chunk)
    }

    /// Estimates the total fee for a spending-address withdrawal. Calls NodePoolService
    /// directly rather than fetchUtxosWithFallback, whose single-address UTXO cache would
    /// return the wrong address's data when estimating for anything but the identity address.
    func estimateSpendingAddressWithdrawalFee(index: Int, toAddress: String, amountSompi: UInt64, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, availableUtxos: [UTXO] = [], virtualDaaScore: UInt64? = nil) async throws -> UInt64 {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: fromAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = availableUtxos.isEmpty ? try await NodePoolService.shared.getUtxosByAddresses([fromAddress]) : availableUtxos
        let vds = await resolveVirtualDaaScore(virtualDaaScore, utxos: utxos)
        let spendable = ChatService.spendableUtxos(utxos, virtualDaaScore: vds)
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = resolveManualUtxos(manualUtxos, against: spendable)

        return try KasiaTransactionBuilder.estimatePlainTransferFee(
            utxos: spendable,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi,
            virtualDaaScore: vds
        )
    }

    /// Maximum sendable amount from a specific spending address (balance minus the send-all
    /// fee, no change output). With coin control active (`manualUtxos` non-empty and still
    /// resolvable), "max" means max spendable from just the selected UTXOs, not the whole
    /// address - same semantics `KasiaTransactionBuilder.estimateSendAllFee` already applies.
    func estimateMaxSpendingAddressAmount(index: Int, toAddress: String, manualUtxos: [UTXO]? = nil, extraFeeSompi: UInt64 = 0, availableUtxos: [UTXO] = [], virtualDaaScore: UInt64? = nil) async throws -> UInt64 {
        guard let fromAddress = WalletManager.shared.spendingAddress(at: index) else {
            throw KasiaError.keychainError("Could not derive this spending address")
        }
        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: toAddress),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: fromAddress) else {
            throw KasiaError.invalidAddress
        }

        let utxos = availableUtxos.isEmpty ? try await NodePoolService.shared.getUtxosByAddresses([fromAddress]) : availableUtxos
        let vds = await resolveVirtualDaaScore(virtualDaaScore, utxos: utxos)
        let spendable = ChatService.spendableUtxos(utxos, virtualDaaScore: vds)
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }
        let resolvedManualUtxos = resolveManualUtxos(manualUtxos, against: spendable)

        let totalBalance = (resolvedManualUtxos ?? spendable).reduce(UInt64(0)) { $0 + $1.amount }

        let fee = KasiaTransactionBuilder.estimateSendAllFee(
            utxos: spendable,
            payload: Data(),
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            manualUtxos: resolvedManualUtxos,
            extraFeeSompi: extraFeeSompi,
            virtualDaaScore: vds
        )

        guard totalBalance > fee else {
            throw KasiaError.networkError("Balance too low to cover fee")
        }

        return totalBalance - fee
    }

    /// Re-resolves a coin-control selection by outpoint against a freshly-fetched spendable
    /// list, since the selection may be stale by the time a fee/max preview or the actual send
    /// runs (spent by another device, aged out, etc.). Returns nil (fall back to automatic
    /// selection) if nothing manual was passed, or if every previously-selected UTXO is gone -
    /// callers that need to distinguish "gone" from "never selected" (i.e. the actual send,
    /// where silently falling back to automatic would spend UTXOs the user didn't choose) do
    /// their own stricter check instead of using this helper - see `sendFromSpendingAddress`.
    private func resolveManualUtxos(_ manualUtxos: [UTXO]?, against spendable: [UTXO]) -> [UTXO]? {
        guard let manualUtxos, !manualUtxos.isEmpty else { return nil }
        func outpointKey(_ utxo: UTXO) -> String { "\(utxo.outpoint.transactionId):\(utxo.outpoint.index)" }
        let spendableByOutpoint = Dictionary(uniqueKeysWithValues: spendable.map { (outpointKey($0), $0) })
        let resolved = manualUtxos.compactMap { spendableByOutpoint[outpointKey($0)] }
        return resolved.isEmpty ? nil : resolved
    }

    /// Whether an address has ever appeared in a transaction, independent of its current
    /// balance (a swept-to-zero address still counts as used) — powers the "Used"/"Unused"
    /// badge in Manage Addresses. A transaction-count lookup, not a balance check.
    ///
    /// "Used" is MONOTONIC and address-intrinsic: once true it can never become false again,
    /// so positive answers are cached persistently and answered without a network round-trip
    /// forever after. Negative ("unused") answers are cached ONLY for this process's lifetime
    /// (`sessionUnusedAddresses`) — an unused address can become used at any moment, but only
    /// via our own sends or an external deposit, and a deposit means a nonzero balance, which
    /// every list load short-circuits to "used" before consulting any cache. Never persisted
    /// across launches. This is what makes Manage Addresses / Address Visibility (and cold
    /// storage discovery, which shares this primitive) open instantly instead of re-deriving
    /// used-ness over the network every time.
    private static let usedAddressCacheKey = "kachat_used_addresses_v1"
    /// Session-only memory of CONFIRMED-unused probe results. In-memory by design: it must
    /// die with the process so a stale "unused" can never survive into a later launch.
    private static var sessionUnusedAddresses: Set<String> = []
    func hasSpendingAddressBeenUsed(_ address: String) async -> Bool {
        await spendingAddressUsedState(address) ?? false
    }

    /// Cache-only, synchronous view of used-ness: `true` = persistently confirmed used,
    /// `false` = confirmed unused earlier THIS session, `nil` = no cached answer (a network
    /// probe is needed). Lets list loads label rows on the first frame without a round-trip.
    func cachedSpendingAddressUsedState(_ address: String) -> Bool? {
        let cached = UserDefaults.standard.array(forKey: Self.usedAddressCacheKey) as? [String] ?? []
        if cached.contains(address) { return true }
        if Self.sessionUnusedAddresses.contains(address) { return false }
        return nil
    }

    /// Marks an address confirmed-used without a probe — e.g. it holds a balance right now,
    /// which proves history. "Used" is monotonic, so persisting this is always safe and makes
    /// every future launch answer instantly even after the balance is swept back to zero.
    func markSpendingAddressUsed(_ address: String) {
        Self.sessionUnusedAddresses.remove(address)
        var updated = UserDefaults.standard.array(forKey: Self.usedAddressCacheKey) as? [String] ?? []
        guard !updated.contains(address) else { return }
        updated.append(address)
        UserDefaults.standard.set(updated, forKey: Self.usedAddressCacheKey)
    }

    /// Tri-state variant of `hasSpendingAddressBeenUsed`: `true` = confirmed used (cached or a
    /// successful count lookup found history), `false` = CONFIRMED unused (the REST probe
    /// succeeded and the count is genuinely zero), `nil` = the probe FAILED (network error,
    /// non-2xx, decode failure) so used-ness is unknown right now. Callers that make
    /// decisions off "unused" (the Generate recyclers, the Used/Unused badge) must treat `nil`
    /// as "don't know" - never as "unused" - so a rate-limited or offline probe can't recycle
    /// or mislabel an address that actually has history.
    ///
    /// The network probe is `GET /addresses/{address}/transactions-count` — a one-integer JSON
    /// body ({"total": N}, ~14 bytes) instead of the old `full-transactions?limit=1&
    /// resolve_previous_outpoints=light`, which made the server assemble (and us download and
    /// decode) an entire transaction with resolved outpoints just to answer a yes/no question.
    /// A short per-request timeout keeps a hung host from pinning a sweep's concurrency slot.
    func spendingAddressUsedState(_ address: String) async -> Bool? {
        if let cached = cachedSpendingAddressUsedState(address) { return cached }
        guard let url = kaspaRestURL(path: "/addresses/\(address)/transactions-count") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let count = try JSONDecoder().decode(KaspaAddressTransactionsCountResponse.self, from: data)
            let used = count.total > 0
            if used {
                markSpendingAddressUsed(address)
            } else {
                Self.sessionUnusedAddresses.insert(address)
            }
            return used
        } catch {
            return nil
        }
    }

    /// Uncached on-chain history probe for an address that is NOT one of our own - a contact's
    /// pool address (cross-device double-pay protection in `poolPaymentDestination`). Same
    /// one-integer transactions-count fetch as `spendingAddressUsedState`, but it deliberately
    /// bypasses BOTH used-address caches: those are keyed by bare address and exist for THIS
    /// wallet's own spending chain (Manage Addresses badges, Generate recycling, cold storage
    /// discovery), so recording a foreign contact address in them would pollute lookups that
    /// assume every entry is ours. `true` = the address has on-chain history, `false` =
    /// confirmed empty, `nil` = the probe failed (network error, non-2xx, decode failure) so
    /// history is unknown right now.
    func addressHasOnChainHistory(_ address: String) async -> Bool? {
        guard let url = kaspaRestURL(path: "/addresses/\(address)/transactions-count") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let count = try JSONDecoder().decode(KaspaAddressTransactionsCountResponse.self, from: data)
            return count.total > 0
        } catch {
            return nil
        }
    }

    func estimateMessageFee(to contact: Contact, content: String, feeOverride: UInt64? = nil) async throws -> UInt64 {
        if let feeOverride { return feeOverride }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.networkError("Message is empty")
        }

        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }

        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        let privateKey = WalletManager.shared.getPrivateKey()
        if let privateKey {
            ensureRoutingState(for: contact.address, privateKey: privateKey)
        }
        let alias = outgoingAlias(for: contact.address)
        // Account for the reply envelope's extra bytes, matching the wrapping `sendMessage` does.
        let estimatedContent: String
        if let reply = replyingTo {
            let preview = MessageReplyCodec.previewText(for: reply.content)
            estimatedContent = MessageReplyCodec.encode(
                replyToId: reply.txId,
                replyToSender: reply.senderAddress,
                replyToPreview: preview,
                text: trimmed
            )
        } else {
            estimatedContent = trimmed
        }
        // Detached: ECDH + AEAD payload building is pure CPU work, and this whole method runs
        // on the main actor on a 200ms debounce while the user is TYPING — doing the crypto
        // inline was measurable keystroke lag on older devices.
        let payload = try await Task.detached(priority: .userInitiated) {
            try KasiaTransactionBuilder.buildContextualMessagePayload(
                alias: alias,
                message: estimatedContent,
                recipientPublicKey: recipientPublicKey
            )
        }.value

        // Use fallback method - doesn't require gRPC connection
        let utxos = try await fetchUtxosWithFallback(for: wallet.publicAddress)

        let availableUtxos = prepareMessageUtxos(confirmed: utxos)
        guard !availableUtxos.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }

        guard let privateKey else {
            return KasiaTransactionBuilder.estimateContextualMessageFee(
                payload: payload,
                inputCount: 1,
                senderScriptPubKey: senderScriptPubKey
            )
        }

        let estimateFeeFromBuiltTx: (KaspaRpcTransaction, [UTXO]) -> UInt64 = { transaction, candidates in
            let spent = self.spentMessageUtxos(from: transaction, candidates: candidates)
            let totalInputSompi = spent.reduce(UInt64(0)) { partial, utxo in
                self.addSompiSafely(partial, utxo.amount)
            }
            let totalOutputSompi = transaction.outputs.reduce(UInt64(0)) { partial, output in
                self.addSompiSafely(partial, output.value)
            }
            return totalInputSompi > totalOutputSompi
                ? totalInputSompi - totalOutputSompi
                : 0
        }

        // Detached for the same reason: this fully builds AND Schnorr-signs a transaction.
        let walletAddress = wallet.publicAddress
        let contactAddress = contact.address
        var messageTx = try await Task.detached(priority: .userInitiated) {
            try KasiaTransactionBuilder.buildContextualMessageTx(
                from: walletAddress,
                to: contactAddress,
                alias: alias,
                message: trimmed,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: availableUtxos
            )
        }.value
        var messageFee = estimateFeeFromBuiltTx(messageTx, availableUtxos)
        let singleInputFeeSompi = KasiaTransactionBuilder.estimateContextualMessageFee(
            payload: messageTx.payload,
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )

        // Mirror send-time heuristic: if message would be expensive, estimate post-compaction send fee.
        if shouldAttemptMessageUtxoCompaction(
            currentMessageTx: messageTx,
            plannedFeeSompi: messageFee,
            singleInputFeeSompi: singleInputFeeSompi,
            availableUtxos: availableUtxos
        ) {
            let compactionTarget = messageCompactionTargetOutputSompi(
                alias: alias,
                content: trimmed,
                recipientPublicKey: recipientPublicKey,
                senderScriptPubKey: senderScriptPubKey
            )

            if let compaction = try? KasiaTransactionBuilder.buildMessageCompactionTx(
                from: wallet.publicAddress,
                senderPrivateKey: privateKey,
                utxos: availableUtxos.filter { !$0.isCoinbase },
                minOutputAmount: compactionTarget,
                maxInputs: messageCompactionMaxInputs
            ) {
                let spentKeys = Set(compaction.selectedUtxos.map { outpointKey($0.outpoint) })
                var compactedCandidates = availableUtxos.filter { !spentKeys.contains(outpointKey($0.outpoint)) }

                if let compactionOutput = compaction.transaction.outputs.first {
                    let syntheticCompactionUtxo = UTXO(
                        address: "",
                        outpoint: UTXO.Outpoint(
                            transactionId: String(repeating: "a", count: 64),
                            index: 0
                        ),
                        amount: compactionOutput.value,
                        scriptPublicKey: senderScriptPubKey,
                        blockDaaScore: 0,
                        isCoinbase: false
                    )
                    compactedCandidates.insert(syntheticCompactionUtxo, at: 0)
                }

                messageTx = try KasiaTransactionBuilder.buildContextualMessageTx(
                    from: wallet.publicAddress,
                    to: contact.address,
                    alias: alias,
                    message: trimmed,
                    senderPrivateKey: privateKey,
                    recipientPublicKey: recipientPublicKey,
                    utxos: compactedCandidates
                )
                messageFee = estimateFeeFromBuiltTx(messageTx, compactedCandidates)
            }
        }

        return messageFee
    }

    func estimatePaymentFee(to contact: Contact, amountSompi: UInt64, note: String = "") async throws -> UInt64 {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        // Must source from whatever `sendPaymentInternal` will actually spend from - the
        // spending chain with Chats Payment Privacy ON, the chatting address with it OFF (see
        // `paymentFundingSourceAddress`). Estimating from a hardcoded source here used to
        // silently compute against the wrong balance/UTXO set whenever it differed from the
        // address actually spent from.
        let sourceAddress = try paymentFundingSourceAddress()
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        let payload = try KasiaTransactionBuilder.buildPaymentPayload(message: note, amount: amountSompi, recipientPublicKey: recipientPublicKey)
        // Use fallback method - doesn't require gRPC connection
        let utxos = try await fetchUtxosWithFallback(for: sourceAddress)
        let spendable = utxos.filter { !$0.isCoinbase }
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }

        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: sourceAddress),
              let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        return try KasiaTransactionBuilder.estimatePaymentFee(
            utxos: spendable,
            payload: payload,
            amount: amountSompi,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    /// Calculate maximum sendable amount (balance - fee for send-all transaction with no change output)
    func estimateMaxPaymentAmount(to contact: Contact, note: String = "") async throws -> UInt64 {
        // Same toggle-aware sourcing as `estimatePaymentFee` above - see its doc comment.
        let sourceAddress = try paymentFundingSourceAddress()
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        // Use fallback method - doesn't require gRPC connection
        let utxos = try await fetchUtxosWithFallback(for: sourceAddress)
        let spendable = utxos.filter { !$0.isCoinbase }
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }

        let totalBalance = spendable.reduce(0) { $0 + $1.amount }

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: contact.address),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: sourceAddress) else {
            throw KasiaError.invalidAddress
        }

        // Build payload with a placeholder amount (doesn't affect fee calculation significantly)
        let payload = try KasiaTransactionBuilder.buildPaymentPayload(
            message: note,
            amount: totalBalance,
            recipientPublicKey: recipientPublicKey
        )

        // Calculate fee for send-all (uses 2 outputs to match selectUtxosForPayment behavior)
        let fee = KasiaTransactionBuilder.estimateSendAllFee(
            utxos: spendable,
            payload: payload,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        )

        guard totalBalance > fee else {
            throw KasiaError.networkError("Balance too low to cover fee")
        }

        return totalBalance - fee
    }

    func sendHandshake(to contact: Contact, isResponse: Bool, pendingTxId: String? = nil) async throws {
        try await enqueueOutgoingTxOperation {
            try await self.sendHandshakeInternal(to: contact, isResponse: isResponse, pendingTxId: pendingTxId)
        }
    }

    func sendHandshakeInternal(to contact: Contact, isResponse: Bool, pendingTxId: String? = nil) async throws {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }

        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        // Ensure routing state exists for this contact before sending
        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)
        let conversationId = conversationIds[contact.address] ?? generateConversationId()

        if pendingTxId == nil {
            do {
                try await ensureSufficientBalanceForHandshakeSend(
                    to: contact,
                    isResponse: isResponse,
                    walletAddress: wallet.publicAddress,
                    alias: alias,
                    conversationId: conversationId,
                    privateKey: privateKey,
                    recipientPublicKey: recipientPublicKey
                )
            } catch {
                if isInsufficientBalancePopupError(error) {
                    throw error
                } else if isNoConfirmedInputsError(error) {
                    AppLog.log("[ChatService] Handshake send precheck deferred: %@", error.localizedDescription)
                } else if shouldBypassBalancePrecheck(error) {
                    AppLog.log("[ChatService] Handshake balance precheck unavailable, continuing send: %@", error.localizedDescription)
                } else {
                    throw error
                }
            }
        }

        let activePendingTxId = pendingTxId ?? "pending_\(UUID().uuidString)"
        var activePendingMessageId: UUID?
        if pendingTxId == nil {
            let pendingTimestamp = Date()
            let handshakeContent = isResponse ? "[Request accepted]" : "[Request to communicate]"
            let pendingMessage = ChatMessage(
                txId: activePendingTxId,
                senderAddress: wallet.publicAddress,
                receiverAddress: contact.address,
                content: handshakeContent,
                timestamp: pendingTimestamp,
                blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
                isOutgoing: true,
                messageType: .handshake,
                deliveryStatus: .pending
            )
            activePendingMessageId = pendingMessage.id
            addMessageToConversation(pendingMessage, contactAddress: contact.address)
            enqueuePendingOutgoing(
                contactAddress: contact.address,
                pendingTxId: activePendingTxId,
                messageType: .handshake,
                timestamp: pendingTimestamp
            )
        } else {
            resetPendingMessage(activePendingTxId, contactAddress: contact.address)
            activePendingMessageId = resolveMessageIdForPending(contactAddress: contact.address, pendingTxId: activePendingTxId)
        }
        saveMessages()
        if let activePendingMessageId {
            registerOutgoingAttempt(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: .handshake
            )
            markOutgoingAttemptSubmitting(messageId: activePendingMessageId)
        }

        do {
            let rpcManager = NodePoolService.shared
            let settings = currentSettings

            if !rpcManager.isConnected {
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let spendable = utxos.filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
            guard !spendable.isEmpty else {
                throw KasiaError.networkError("No UTXOs available. Your account may be empty.")
            }

            // Split UTXOs so we can send self-stash as a second tx without double-spend
            let (handshakeUtxos, stashUtxos) = splitUtxosForHandshake(spendable)

            let transaction = try KasiaTransactionBuilder.buildHandshakeTx(
                from: wallet.publicAddress,
                to: contact.address,
                alias: alias,
                conversationId: conversationId,
                isResponse: isResponse,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: handshakeUtxos
            )

            let (txId, endpoint) = try await rpcManager.submitTransaction(transaction, allowOrphan: false)
            AppLog.log("[ChatService] Handshake submitted: \(txId) via \(endpoint)")
            if let activePendingMessageId {
                _ = updatePendingMessageById(activePendingMessageId, newTxId: txId, contactAddress: contact.address)
            } else {
                _ = updatePendingMessage(activePendingTxId, withRealTxId: txId, contactAddress: contact.address)
            }
            markOutgoingAttemptSubmitted(
                messageId: activePendingMessageId,
                pendingTxId: activePendingTxId,
                contactAddress: contact.address,
                messageType: .handshake,
                txId: txId
            )
            clearNoInputRetryState(for: activePendingTxId)

            addOurAlias(alias, for: contact.address, blockTime: nil)
            saveOurAliases()
            conversationIds[contact.address] = conversationId
            saveConversationIds()

            saveMessages(triggerExport: true)

            // Create self-stash to persist handshake metadata (separate tx)
            await sendOrQueueSelfStash(
                contactAddress: contact.address,
                ourAlias: alias,
                theirAlias: primaryConversationAlias(for: contact.address),
                isResponse: isResponse,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey,
                utxos: stashUtxos,
                handshakeTx: transaction,
                handshakeTxId: txId,
                senderScriptPubKey: senderScriptPubKey
            )
        } catch {
            if let acceptedTxId = acceptedTransactionId(from: error) {
                AppLog.log("[ChatService] Handshake already accepted by consensus for %@ -> promoting pending to %@",
                      String(activePendingTxId.prefix(12)),
                      String(acceptedTxId.prefix(12)))
                if let activePendingMessageId {
                    _ = updatePendingMessageById(activePendingMessageId, newTxId: acceptedTxId, contactAddress: contact.address)
                } else {
                    _ = updatePendingMessage(activePendingTxId, withRealTxId: acceptedTxId, contactAddress: contact.address)
                }
                markOutgoingAttemptSubmitted(
                    messageId: activePendingMessageId,
                    pendingTxId: activePendingTxId,
                    contactAddress: contact.address,
                    messageType: .handshake,
                    txId: acceptedTxId
                )
                clearNoInputRetryState(for: activePendingTxId)
                saveMessages(triggerExport: true)
                return
            }

            if isNoConfirmedInputsError(error) {
                let delay = nextNoInputRetryDelay(for: activePendingTxId)
                AppLog.log(
                    "[ChatService] Handshake deferred retry %@ in %.0fs (no confirmed inputs)",
                    String(activePendingTxId.prefix(12)),
                    delay
                )
                scheduleOutgoingRetry(
                    contact: contact,
                    pendingTxId: activePendingTxId,
                    pendingMessageId: activePendingMessageId,
                    messageType: .handshake,
                    delaySeconds: delay,
                    handshakeIsResponse: isResponse
                )
                return
            }

            markOutgoingAttemptFailed(messageId: activePendingMessageId, pendingTxId: activePendingTxId)
            markPendingMessageFailed(activePendingTxId, contactAddress: contact.address)
            clearNoInputRetryState(for: activePendingTxId)
            saveMessages()
            throw error
        }
    }

    func shouldRetryHandshakeAsResponse(for contactAddress: String) -> Bool {
        guard let conversation = conversations.first(where: { $0.contact.address == contactAddress }) else {
            return false
        }
        return conversation.messages.contains {
            $0.messageType == .handshake && !$0.isOutgoing && $0.deliveryStatus != .failed
        }
    }

    func respondToHandshake(for contact: Contact, accept: Bool) async throws {
        if accept {
            try await sendHandshake(to: contact, isResponse: true)
            clearDeclined(contact.address)
        } else {
            declineContact(contact.address)
        }
    }

    func isConversationDeclined(_ address: String) -> Bool {
        declinedContacts.contains(address)
    }

    /// Drops the in-memory conversation and its routing bookkeeping for a permanently-deleted
    /// contact - pairs with `ContactsManager.deleteContact`, which handles the persisted
    /// contact/message/tombstone side of the same delete.
    func removeConversation(for address: String) {
        conversations.removeAll { $0.contact.address == address }
        routingStates.removeValue(forKey: address)
        conversationAliases.removeValue(forKey: address)
        declinedContacts.remove(address)
        chatFetchStates.removeValue(forKey: address)
        chatFetchCounts.removeValue(forKey: address)
        chatFetchFailed.remove(address)
    }

    /// Deletes the given messages from this device only - purely local (Core Data + in-memory),
    /// never on-chain. The recipient still has their own copy, and the underlying transaction
    /// remains permanently visible/scannable on the Kaspa blockchain - see the confirmation
    /// alert's wording in `ChatDetailView` for why that distinction is surfaced to the user.
    /// `unreadCount` isn't explicitly adjusted here even if a deleted message was unread - it's a
    /// stored counter, but self-corrects the next time `buildMergedConversations` runs (a cold
    /// start/reload), since it recomputes by filtering messages against `lastReadBlockTime` and a
    /// deleted message simply won't be there to count anymore.
    func deleteMessages(_ txIds: Set<String>, from contact: Contact) {
        guard !txIds.isEmpty,
              let index = conversations.firstIndex(where: { $0.contact.address == contact.address }) else { return }

        updateConversation(at: index, persist: false) { updated in
            updated.messages.removeAll { txIds.contains($0.txId) }
        }

        for txId in txIds {
            messageStore.deleteMessage(txId: txId)
        }

        // Contact.lastMessageAt is a stored/denormalized field that's only ever bumped forward
        // elsewhere - recompute it down here in case the deleted message(s) included the most
        // recent one, so Chat Info / contact sort order don't keep showing a deleted message's time.
        if let newest = conversations[index].messages.map({ $0.timestamp }).max() {
            contactsManager.updateContactLastMessage(contact.id, at: newest)
        }
    }

    func isConversationVisibleInChatList(_ conversation: Conversation, settings: AppSettings? = nil) -> Bool {
        !isConversationDeclined(conversation.contact.address)
    }

    func pushEligibleConversationAddresses(settings: AppSettings? = nil) -> [String] {
        let settings = settings ?? currentSettings
        var addresses = Set<String>()
        for conversation in conversations {
            guard isConversationVisibleInChatList(conversation, settings: settings) else { continue }
            let contact = contactsManager.getContact(byAddress: conversation.contact.address) ?? conversation.contact
            guard settings.shouldDeliverIncomingNotification(for: contact) else { continue }
            let candidate = contact.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard contactsManager.isValidKaspaAddress(candidate) else { continue }
            addresses.insert(candidate.lowercased())
        }
        return Array(addresses)
    }

    func hasOurAlias(for address: String) -> Bool {
        routingStates[address] != nil || !(ourAliases[address]?.isEmpty ?? true)
    }

    func hasTheirAlias(for address: String) -> Bool {
        routingStates[address] != nil || !(conversationAliases[address]?.isEmpty ?? true)
    }

    /// Generate a random alias for a new conversation
    func generateAlias() -> String {
        // Generate 6 random bytes and convert to hex (12 characters)
        var bytes = [UInt8](repeating: 0, count: 6)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Fallback: use UUID bytes for non-security-critical alias
            let uuid = UUID()
            return withUnsafeBytes(of: uuid.uuid) { Data($0).prefix(6).map { String(format: "%02x", $0) }.joined() }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func generateConversationId() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return String(uuid.prefix(12)).lowercased()
    }

    func updateWalletBalanceIfNeeded(address: String, utxos: [UTXO]) {
        WalletManager.shared.updateBalanceIfCurrentWallet(address: address, utxos: utxos)
    }

    /// Split UTXOs so that handshake gets a minimal covering set and self-stash can use the rest
    func splitUtxosForHandshake(_ utxos: [UTXO]) -> ([UTXO], [UTXO]) {
        guard utxos.count > 1 else {
            return (utxos, [])
        }

        // Reserve the smallest UTXO for self-stash if possible
        let sortedAsc = utxos.sorted { $0.amount < $1.amount }
        let remaining = Array(sortedAsc.dropFirst())

        let target: UInt64 = KasiaTransactionBuilder.handshakeAmount + 50_000 // padding for fee
        var selected: [UTXO] = []
        var total: UInt64 = 0
        for utxo in remaining {
            selected.append(utxo)
            let (nextTotal, overflow) = total.addingReportingOverflow(utxo.amount)
            if overflow {
                AppLog.log("[ChatService] Overflow while splitting handshake UTXOs; falling back to full set")
                return (utxos, [])
            }
            total = nextTotal
            if total >= target {
                break
            }
        }

        if total >= target {
            let handshakeIds = Set(selected.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" })
            let stashUtxos = utxos.filter { !handshakeIds.contains("\($0.outpoint.transactionId):\($0.outpoint.index)") }
            return (selected, stashUtxos)
        } else {
            // Not enough without reserved; fall back to all UTXOs (stash later)
            return (utxos, [])
        }
    }

    func connectRpcIfNeeded(timeout: TimeInterval = 30.0) async throws {
        let rpcManager = NodePoolService.shared
        if rpcManager.isConnected {
            return
        }

        let settings = currentSettings

        // Use gRPC manager for connection with timeout
        AppLog.log("[ChatService] Connecting via RPC manager (timeout: %.1fs)...", timeout)

        // Race between connection and timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await rpcManager.connect(network: settings.networkType)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw KasiaError.networkError("RPC connection timeout")
            }

            // Wait for first to complete (either success or timeout)
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func fetchCachedUtxos(for address: String) async throws -> [UTXO] {
        if let timestamp = cachedUtxosTimestamp,
           Date().timeIntervalSince(timestamp) < utxoCacheInterval,
           !cachedUtxos.isEmpty {
            return cachedUtxos
        }

        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        updateWalletBalanceIfNeeded(address: address, utxos: utxos)
        cachedUtxos = utxos
        cachedUtxosTimestamp = Date()
        return utxos
    }

    /// Fetch UTXOs with automatic fallback - tries gRPC if connected, otherwise uses REST API
    /// This is useful for fee estimation where we don't want to block waiting for gRPC connection
    func fetchUtxosWithFallback(for address: String) async throws -> [UTXO] {
        // Check cache first
        if let timestamp = cachedUtxosTimestamp,
           Date().timeIntervalSince(timestamp) < utxoCacheInterval,
           !cachedUtxos.isEmpty {
            return cachedUtxos
        }

        // getUtxosByAddresses already has REST fallback built in
        let utxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        updateWalletBalanceIfNeeded(address: address, utxos: utxos)
        cachedUtxos = utxos
        cachedUtxosTimestamp = Date()
        return utxos
    }

    func splitUtxosForSelfStash(_ utxos: [UTXO]) -> ([UTXO], [UTXO]) {
        guard let first = utxos.first else { return ([], []) }
        return ([first], Array(utxos.dropFirst()))
    }

    func sendOrQueueSelfStash(
        contactAddress: String,
        ourAlias: String,
        theirAlias: String?,
        isResponse: Bool,
        walletAddress: String,
        privateKey: Data,
        utxos: [UTXO],
        handshakeTx: KaspaRpcTransaction?,
        handshakeTxId: String?,
        senderScriptPubKey: Data?
    ) async {
        guard !utxos.isEmpty else {
            // Try to build from handshake change if possible
            if let handshakeTx = handshakeTx,
               let senderScriptPubKey = senderScriptPubKey,
               let change = changeUtxo(from: handshakeTx, txId: handshakeTxId, senderScript: senderScriptPubKey) {
                await submitSelfStashTx(
                    contactAddress: contactAddress,
                    ourAlias: ourAlias,
                    theirAlias: theirAlias,
                    isResponse: isResponse,
                    walletAddress: walletAddress,
                    privateKey: privateKey,
                    utxos: [change],
                    allowOrphan: true
                )
                return
            }

            queueSelfStash(contactAddress: contactAddress, ourAlias: ourAlias, theirAlias: theirAlias, isResponse: isResponse)
            return
        }
        await submitSelfStashTx(
            contactAddress: contactAddress,
            ourAlias: ourAlias,
            theirAlias: theirAlias,
            isResponse: isResponse,
            walletAddress: walletAddress,
            privateKey: privateKey,
            utxos: utxos,
            allowOrphan: false
        )
    }

    func queueSelfStash(contactAddress: String, ourAlias: String, theirAlias: String?, isResponse: Bool) {
        let job = PendingSelfStash(partnerAddress: contactAddress, ourAlias: ourAlias, theirAlias: theirAlias, isResponse: isResponse)
        pendingSelfStash.append(job)
        savePendingSelfStash()
        AppLog.log("%@", "[ChatService] Queued self-stash for \(contactAddress.suffix(10))")
    }

    func submitSelfStashTx(
        contactAddress: String,
        ourAlias: String,
        theirAlias: String?,
        isResponse: Bool,
        walletAddress: String,
        privateKey: Data,
        utxos: [UTXO],
        allowOrphan: Bool
    ) async {
        do {
            let stashTx = try KasiaTransactionBuilder.buildHandshakeSelfStashTx(
                from: walletAddress,
                partnerAddress: contactAddress,
                ourAlias: ourAlias,
                theirAlias: theirAlias,
                isResponse: isResponse,
                senderPrivateKey: privateKey,
                utxos: utxos
            )
            let txId = try await NodePoolService.shared.submitTransaction(stashTx, allowOrphan: allowOrphan)
            AppLog.log("%@", "[ChatService] Self-stash handshake submitted: \(txId)")
        } catch {
            AppLog.log("%@", "[ChatService] Failed to submit self-stash handshake tx: \(error.localizedDescription)")
            queueSelfStash(contactAddress: contactAddress, ourAlias: ourAlias, theirAlias: theirAlias, isResponse: isResponse)
        }
    }

    func changeUtxo(from handshakeTx: KaspaRpcTransaction, txId: String?, senderScript: Data) -> UTXO? {
        guard let txId = txId else { return nil }
        for (idx, output) in handshakeTx.outputs.enumerated() {
            if output.scriptPublicKey.script == senderScript, output.value > 0 {
                return UTXO(
                    address: "",
                    outpoint: UTXO.Outpoint(transactionId: txId, index: UInt32(idx)),
                    amount: output.value,
                    scriptPublicKey: senderScript,
                    blockDaaScore: 0,
                    isCoinbase: false
                )
            }
        }
        return nil
    }

    /// Attempt to send any queued self-stash handshake transactions using current UTXOs
    func attemptPendingSelfStashSends() async {
        guard let wallet = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey(),
              !pendingSelfStash.isEmpty else { return }

        do {
            let rpcManager = NodePoolService.shared
            if !rpcManager.isConnected {
                let settings = currentSettings
                try await rpcManager.connect(network: settings.networkType)
            }

            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            guard !utxos.isEmpty else { return }

            var remaining = utxos
            var succeeded: [PendingSelfStash] = []

            for job in pendingSelfStash {
                guard !remaining.isEmpty else { break }
                let (first, rest) = splitUtxosForSelfStash(remaining)
                remaining = rest
                do {
                    let stashTx = try KasiaTransactionBuilder.buildHandshakeSelfStashTx(
                        from: wallet.publicAddress,
                        partnerAddress: job.partnerAddress,
                        ourAlias: job.ourAlias,
                        theirAlias: job.theirAlias,
                        isResponse: job.isResponse,
                        senderPrivateKey: privateKey,
                        utxos: first
                    )
                    let (txId, endpoint) = try await rpcManager.submitTransaction(stashTx, allowOrphan: false)
                    AppLog.log("[ChatService] Self-stash submitted: \(txId) via \(endpoint)")
                    succeeded.append(job)
                } catch {
                    AppLog.log("%@", "[ChatService] Pending self-stash failed: \(error.localizedDescription)")
                }
            }

            if !succeeded.isEmpty {
                pendingSelfStash.removeAll { job in
                    succeeded.contains(where: { $0.id == job.id })
                }
                savePendingSelfStash()
            }
        } catch {
            AppLog.log("%@", "[ChatService] attemptPendingSelfStashSends error: \(error.localizedDescription)")
        }
    }

    /// Update a pending message with the real transaction ID
    @discardableResult
    func updatePendingMessage(_ pendingTxId: String, withRealTxId txId: String, contactAddress: String) -> Bool {
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            if updatePendingMessage(in: convIndex, pendingTxId: pendingTxId, withRealTxId: txId) {
                removePendingOutgoingGlobally(pendingTxId)
                return true
            }
        }

        if let convIndex = conversations.firstIndex(where: { conversation in
            conversation.messages.contains(where: { $0.txId == pendingTxId })
        }) {
            if updatePendingMessage(in: convIndex, pendingTxId: pendingTxId, withRealTxId: txId) {
                removePendingOutgoingGlobally(pendingTxId)
                return true
            }
        }

        return false
    }

    @discardableResult
    func updatePendingMessage(in convIndex: Int, pendingTxId: String, withRealTxId txId: String) -> Bool {
        updateConversation(at: convIndex) { conversation in
            guard let msgIndex = conversation.messages.firstIndex(where: { $0.txId == pendingTxId }) else { return }
            let oldMessage = conversation.messages[msgIndex]
            if pendingTxId != txId {
                conversation.messages.removeAll(where: { $0.txId == txId })
            }
            let newMessage = ChatMessage(
                id: oldMessage.id,
                txId: txId,
                senderAddress: oldMessage.senderAddress,
                receiverAddress: oldMessage.receiverAddress,
                content: oldMessage.content,
                timestamp: oldMessage.timestamp,
                blockTime: oldMessage.blockTime,
                acceptingBlock: "mempool",
                isOutgoing: oldMessage.isOutgoing,
                messageType: oldMessage.messageType,
                deliveryStatus: .sent
            )
            conversation.messages[msgIndex] = newMessage
        }

        return true
    }

    /// Mark a pending message as failed (keeps it in the conversation for retry)
    func markPendingMessageFailed(_ pendingTxId: String, contactAddress: String) {
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            updateConversation(at: convIndex) { conversation in
                if let msgIndex = conversation.messages.firstIndex(where: { $0.txId == pendingTxId }) {
                    let oldMessage = conversation.messages[msgIndex]
                    let updatedMessage = ChatMessage(
                        id: oldMessage.id,
                        txId: oldMessage.txId,
                        senderAddress: oldMessage.senderAddress,
                        receiverAddress: oldMessage.receiverAddress,
                        content: oldMessage.content,
                        timestamp: oldMessage.timestamp,
                        blockTime: oldMessage.blockTime,
                        acceptingBlock: oldMessage.acceptingBlock,
                        isOutgoing: oldMessage.isOutgoing,
                        messageType: oldMessage.messageType,
                        deliveryStatus: .failed
                    )
                    conversation.messages[msgIndex] = updatedMessage
                }
            }
        }
        markOutgoingAttemptFailed(messageId: resolveMessageIdForPending(contactAddress: contactAddress, pendingTxId: pendingTxId), pendingTxId: pendingTxId)
        removePendingOutgoing(contactAddress: contactAddress, pendingTxId: pendingTxId)
        clearNoInputRetryState(for: pendingTxId)
    }

    func resetPendingMessage(_ pendingTxId: String, contactAddress: String) {
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            updateConversation(at: convIndex) { conversation in
                if let msgIndex = conversation.messages.firstIndex(where: { $0.txId == pendingTxId }) {
                    let oldMessage = conversation.messages[msgIndex]
                    let updatedMessage = ChatMessage(
                        id: oldMessage.id,
                        txId: oldMessage.txId,
                        senderAddress: oldMessage.senderAddress,
                        receiverAddress: oldMessage.receiverAddress,
                        content: oldMessage.content,
                        timestamp: oldMessage.timestamp,
                        blockTime: oldMessage.blockTime,
                        acceptingBlock: oldMessage.acceptingBlock,
                        isOutgoing: oldMessage.isOutgoing,
                        messageType: oldMessage.messageType,
                        deliveryStatus: .pending
                    )
                    conversation.messages[msgIndex] = updatedMessage
                }
            }
        }
        if let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            let pending = conversations[convIndex].messages.first(where: { $0.txId == pendingTxId })
            if let pending {
                enqueuePendingOutgoing(contactAddress: contactAddress, pendingTxId: pendingTxId, messageType: pending.messageType, timestamp: pending.timestamp)
            }
        }
    }

    func updateOutgoingPendingMessageIfMatch(
        contactAddress: String,
        newTxId: String,
        content: String,
        messageType: ChatMessage.MessageType
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return false
        }

        var didUpdate = false
        updateConversation(at: convIndex) { conversation in
            if let existingIndex = conversation.messages.firstIndex(where: { $0.txId == newTxId }) {
                let existing = conversation.messages[existingIndex]
                if existing.isOutgoing && existing.deliveryStatus != .sent {
                    let updated = ChatMessage(
                        id: existing.id,
                        txId: existing.txId,
                        senderAddress: existing.senderAddress,
                        receiverAddress: existing.receiverAddress,
                        content: existing.content,
                        timestamp: existing.timestamp,
                        blockTime: existing.blockTime,
                        acceptingBlock: existing.acceptingBlock ?? "mempool",
                        isOutgoing: existing.isOutgoing,
                        messageType: existing.messageType,
                        deliveryStatus: .sent
                    )
                    conversation.messages[existingIndex] = updated
                }
                didUpdate = true
                return
            }

            // Do not match by content; duplicates are allowed. Pending promotion is handled by queue order.
        }

        return didUpdate
    }

    @discardableResult
    func updatePendingMessageById(
        _ messageId: UUID,
        newTxId: String,
        contactAddress: String? = nil
    ) -> Bool {
        let targetIndex: Int?
        if let contactAddress,
           let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            targetIndex = index
        } else {
            targetIndex = conversations.firstIndex(where: { conversation in
                conversation.messages.contains(where: { $0.id == messageId })
            })
        }

        guard let convIndex = targetIndex else { return false }

        var didUpdate = false
        var oldPendingTxId: String?
        updateConversation(at: convIndex) { conversation in
            guard let msgIndex = conversation.messages.firstIndex(where: { $0.id == messageId }) else { return }
            let oldMessage = conversation.messages[msgIndex]
            oldPendingTxId = oldMessage.txId
            if oldMessage.txId != newTxId {
                conversation.messages.removeAll(where: { $0.txId == newTxId })
            }
            let newMessage = ChatMessage(
                id: oldMessage.id,
                txId: newTxId,
                senderAddress: oldMessage.senderAddress,
                receiverAddress: oldMessage.receiverAddress,
                content: oldMessage.content,
                timestamp: oldMessage.timestamp,
                blockTime: oldMessage.blockTime,
                acceptingBlock: "mempool",
                isOutgoing: oldMessage.isOutgoing,
                messageType: oldMessage.messageType,
                deliveryStatus: .sent
            )
            conversation.messages[msgIndex] = newMessage
            didUpdate = true
        }

        guard didUpdate, let oldPendingTxId else { return false }
        removePendingOutgoingGlobally(oldPendingTxId)
        return true
    }

    func updateOldestPendingOutgoingMessage(
        contactAddress: String,
        newTxId: String,
        messageType: ChatMessage.MessageType
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return false
        }

        var didUpdate = false
        var oldPendingTxId: String?
        updateConversation(at: convIndex) { conversation in
            let candidates = conversation.messages
                .filter { $0.isOutgoing && $0.deliveryStatus != .sent && $0.messageType == messageType }
                .sorted(by: Self.isMessageOrderedBefore)
            guard let candidate = candidates.first,
                  let msgIndex = conversation.messages.firstIndex(where: { $0.id == candidate.id }) else { return }

            if candidate.txId != newTxId {
                conversation.messages.removeAll(where: { $0.txId == newTxId })
            }
            oldPendingTxId = candidate.txId
            let newMessage = ChatMessage(
                id: candidate.id,
                txId: newTxId,
                senderAddress: candidate.senderAddress,
                receiverAddress: candidate.receiverAddress,
                content: candidate.content,
                timestamp: candidate.timestamp,
                blockTime: candidate.blockTime,
                acceptingBlock: candidate.acceptingBlock ?? "mempool",
                isOutgoing: candidate.isOutgoing,
                messageType: candidate.messageType,
                deliveryStatus: .sent
            )
            conversation.messages[msgIndex] = newMessage
            didUpdate = true
        }

        guard didUpdate, let oldPendingTxId else { return false }
        removePendingOutgoing(contactAddress: contactAddress, pendingTxId: oldPendingTxId)
        return true
    }

    func updateMostRecentPendingOutgoingMessage(
        contactAddress: String,
        newTxId: String,
        messageType: ChatMessage.MessageType
    ) -> Bool {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return false
        }

        var didUpdate = false
        updateConversation(at: convIndex) { conversation in
            let candidates = conversation.messages
                .filter { $0.isOutgoing && $0.deliveryStatus != .sent && $0.messageType == messageType }
                .sorted(by: Self.isMessageOrderedBefore)

            guard let candidate = candidates.first,
                  let msgIndex = conversation.messages.firstIndex(where: { $0.id == candidate.id }) else { return }

            conversation.messages.removeAll(where: { $0.txId == newTxId })
            let newMessage = ChatMessage(
                id: candidate.id,
                txId: newTxId,
                senderAddress: candidate.senderAddress,
                receiverAddress: candidate.receiverAddress,
                content: candidate.content,
                timestamp: candidate.timestamp,
                blockTime: candidate.blockTime,
                acceptingBlock: candidate.acceptingBlock ?? "mempool",
                isOutgoing: candidate.isOutgoing,
                messageType: candidate.messageType,
                deliveryStatus: .sent
            )
            conversation.messages[msgIndex] = newMessage
            didUpdate = true
        }

        return didUpdate
    }

    func markConversationAsRead(_ conversation: Conversation) async {
        Self.clearDeliveredNotifications(threadIdentifier: conversation.contact.address)
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            // Use both in-memory window and persistent store cursor so pagination does not
            // block read marker advancement.
            let lastInMemoryIncoming = conversation.messages
                .filter { !$0.isOutgoing }
                .max(by: { $0.blockTime < $1.blockTime })
            let storeCursor = await messageStore.fetchLatestIncomingCursor(contactAddress: conversation.contact.address)
            let inMemoryBlockTime = Int64(lastInMemoryIncoming?.blockTime ?? 0)
            let storeBlockTime = storeCursor?.blockTime ?? 0

            updateConversation(at: index, persist: false) { updated in
                updated.unreadCount = 0
            }
            // Persist unread reset immediately so reloads/CloudKit merges cannot resurrect
            // a stale unread badge when the read cursor does not advance.
            messageStore.updateConversationUnread(contactAddress: conversation.contact.address, unreadCount: 0)

            // Sync read status to CloudKit (debounced)
            let targetBlockTime = max(inMemoryBlockTime, storeBlockTime)
            if targetBlockTime > 0 {
                // Keep the in-memory read cursor current so a later full re-sync doesn't re-mark
                // these just-read messages as unread (see `readCursorByAddress`).
                readCursorByAddress[conversation.contact.address] = max(readCursorByAddress[conversation.contact.address] ?? 0, targetBlockTime)
                let targetTxId: String?
                if storeBlockTime > inMemoryBlockTime {
                    targetTxId = storeCursor?.txId
                } else {
                    targetTxId = lastInMemoryIncoming?.txId
                }
                AppLog.log(
                    "[ChatService] Marking conversation %@ as read at blockTime=%lld (inMemory=%lld, store=%lld)",
                    String(conversation.contact.address.suffix(8)),
                    targetBlockTime,
                    inMemoryBlockTime,
                    storeBlockTime
                )
                // Awaited (not fire-and-forget) so this function's caller only returns once the
                // read cursor is durably on disk - otherwise a force-quit landing between "read
                // the chat" and the still-in-flight Core Data save could lose it, and a whole
                // batch of already-read messages would come back as unread on next launch.
                await ReadStatusSyncManager.shared.markAsReadAndWait(
                    contactAddress: conversation.contact.address,
                    lastReadTxId: targetTxId,
                    lastReadBlockTime: UInt64(targetBlockTime)
                )
            }
        }
    }

    /// Manually flags a whole conversation as unread again (chat list swipe/bulk action) - the
    /// counterpart to `markConversationAsRead`. Sets a nominal unread count of 1 rather than
    /// recomputing an exact unseen-message tally, matching how "mark as unread" works in other
    /// mail/chat apps: a manual triage flag for the badge, not a literal count. Doesn't touch the
    /// `lastReadTxId`/`lastReadBlockTime` read cursor - that cursor drives push-reliability/backfill
    /// bookkeeping, a separate concern from this local, user-initiated triage flag.
    func markConversationAsUnread(_ conversation: Conversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }),
              conversation.unreadCount == 0 else { return }
        updateConversation(at: index, persist: false) { updated in
            updated.unreadCount = 1
        }
        messageStore.updateConversationUnread(contactAddress: conversation.contact.address, unreadCount: 1)
    }

    /// Bulk "Mark as Read" for multi-selected conversations in the chat list.
    func markConversationsAsRead(_ conversations: [Conversation]) async {
        for conversation in conversations where conversation.unreadCount > 0 {
            await markConversationAsRead(conversation)
        }
    }

    /// Bulk "Mark as Unread" for multi-selected conversations in the chat list.
    func markConversationsAsUnread(_ conversations: [Conversation]) {
        for conversation in conversations where conversation.unreadCount == 0 {
            markConversationAsUnread(conversation)
        }
    }

    // MARK: - Private Methods

    /// Check the Kasia indexer for a handshake matching the given txId
    /// Used as fallback when the Kaspa REST API doesn't return the transaction payload
}

/// Response of `GET /addresses/{address}/transactions-count` on the Kaspa REST API — the
/// one-integer body backing `spendingAddressUsedState`. Extra fields (e.g. `limit_exceeded`
/// on newer servers) are ignored by the decoder.
private struct KaspaAddressTransactionsCountResponse: Decodable {
    let total: Int
}
