import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

// MARK: - Conversation state, message sending, handshake sending, fee estimation

extension ChatService {
    func enterConversation(for address: String) {
        activeConversationAddress = address
        NSLog("[ChatService] Entered conversation for %@", String(address.suffix(12)))
    }

    /// Returns total number of stored messages for a contact in current wallet scope.
    func storedMessageCount(for contactAddress: String) -> Int {
        messageStore.countMessages(contactAddress: contactAddress)
    }

    /// Returns total number of stored messages using a background worker to avoid
    /// blocking the main actor during expensive Core Data count queries.
    func storedMessageCountAsync(for contactAddress: String) async -> Int {
        await Task.detached(priority: .utility) {
            MessageStore.shared.countMessages(contactAddress: contactAddress)
        }.value
    }

    /// Read cursor for a conversation, preferring effective CloudKit marker status.
    /// Falls back to local conversation read status if no markers are available.
    func readCursor(for contactAddress: String) -> (txId: String?, blockTime: Int64)? {
        if let effective = messageStore.recomputeEffectiveReadStatus(conversationId: contactAddress) {
            return (effective.lastReadTxId, effective.lastReadBlockTime)
        }
        if let status = messageStore.fetchReadStatus(contactAddress: contactAddress) {
            return (status.lastReadTxId, status.lastReadBlockTime)
        }
        return nil
    }

    /// Loads the next older page of messages for a conversation from persistent store.
    /// This avoids holding full history in memory while still allowing on-demand scrolling.
    /// - Returns: number of messages loaded into the in-memory conversation.
    @discardableResult
    func loadOlderMessagesPage(for contactAddress: String, pageSize: Int) -> Int {
        guard pageSize > 0 else { return 0 }
        guard let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else { return 0 }
        guard let key = messageEncryptionKey() else { return 0 }
        guard !olderHistoryExhaustedContacts.contains(contactAddress) else { return 0 }

        let cursor = oldestLoadedCursor(in: conversations[index])
        let page = messageStore.fetchMessagesPage(
            contactAddress: contactAddress,
            decryptionKey: key,
            limit: pageSize,
            olderThan: cursor
        )
        guard !page.messages.isEmpty else {
            olderHistoryExhaustedContacts.insert(contactAddress)
            return 0
        }

        var updatedConversations = conversations
        var conversation = updatedConversations[index]
        let beforeCount = conversation.messages.count
        conversation.messages = dedupeMessages(page.messages + conversation.messages)
        let loadedCount = max(0, conversation.messages.count - beforeCount)
        if page.hasMore {
            olderHistoryExhaustedContacts.remove(contactAddress)
        } else {
            olderHistoryExhaustedContacts.insert(contactAddress)
        }

        updatedConversations[index] = conversation
        conversations = updatedConversations
        return loadedCount
    }

    /// Async/background fetch variant of `loadOlderMessagesPage` that keeps Core Data page
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
        conversation.messages = dedupeMessages(page.messages + conversation.messages)
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
        guard let oldest = conversation.messages.min(by: isMessageOrderedBefore) else { return nil }
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
        activeConversationAddress = nil
        NSLog("[ChatService] Left conversation")
    }

    /// Fetch only handshakes (lightweight, needed to establish encryption keys)
    /// Call this before CloudKit sync so we have aliases ready
    /// NOTE: Assumes configureAPIIfNeeded() was already called by startup flow
    func fetchHandshakesOnly() async {
        guard let wallet = WalletManager.shared.currentWallet else {
            NSLog("[ChatService] fetchHandshakesOnly: No wallet")
            return
        }

        guard isConfigured else {
            NSLog("[ChatService] fetchHandshakesOnly: API not configured")
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

        NSLog("[ChatService] Fetching incoming handshakes (since=%llu)...", incomingSince)
        // Fetch incoming handshakes
        guard let incoming = await retryUntilSuccess(
            label: "fetch incoming handshakes (bootstrap)",
            operation: { [self] in try await fetchIncomingHandshakes(for: wallet.publicAddress, blockTime: incomingSince) }
        ) else {
            NSLog("[ChatService] Failed to fetch incoming handshakes")
            return
        }
        advanceSyncCursor(for: incomingHandshakeKey, maxBlockTime: incoming.compactMap { $0.blockTime }.max())
        NSLog("[ChatService] Fetched %d incoming handshakes", incoming.count)

        NSLog("[ChatService] Fetching outgoing handshakes...")


        guard let outgoing = await retryUntilSuccess(
            label: "fetch outgoing handshakes (bootstrap)",
            operation: { [self] in try await fetchOutgoingHandshakes(for: wallet.publicAddress, blockTime: outgoingSince) }
        ) else {
            NSLog("[ChatService] Failed to fetch outgoing handshakes")
            return
        }
        advanceSyncCursor(for: outgoingHandshakeKey, maxBlockTime: outgoing.compactMap { $0.blockTime }.max())
        NSLog("[ChatService] Fetched %d outgoing handshakes", outgoing.count)

        NSLog("[ChatService] Handshake bootstrap: %d incoming, %d outgoing", incoming.count, outgoing.count)

        // Process handshakes to extract aliases
        NSLog("[ChatService] Processing handshakes...")
        await processHandshakes(incoming, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
        await processHandshakes(outgoing, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        NSLog("[ChatService] Handshakes processed")

        // Fetch saved handshakes from self-stash
        NSLog("[ChatService] Fetching saved handshakes from self-stash...")
        _ = await retryUntilSuccess(
            label: "fetch saved handshakes (bootstrap)",
            operation: { [self] in try await fetchSavedHandshakes(myAddress: wallet.publicAddress, privateKey: privateKey) }
        )
        NSLog("[ChatService] Self-stash fetch complete")

        saveConversationAliases()
        saveOurAliases()
        saveConversationIds()
        saveRoutingStates()

        NSLog("[ChatService] Handshake bootstrap complete. Aliases: %d, Our aliases: %d, Routing: %d", conversationAliases.count, ourAliases.count, routingStates.count)
    }

    func fetchNewMessages(forActiveOnly activeAddress: String? = nil) async {
        guard let wallet = WalletManager.shared.currentWallet else {
            print("[ChatService] Skipping fetch - no wallet")
            return
        }

        // Ensure API is configured
        await configureAPIIfNeeded()
        guard isConfigured else {
            print("[ChatService] Skipping fetch - API not configured")
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
        print("[ChatService] Fetching messages for: \(wallet.publicAddress.suffix(10)), fullFetch=\(isFullFetch), lastPollTime=\(lastPollTime)")

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

        guard let incoming = await retryUntilSuccess(
            label: "fetch incoming handshakes",
            operation: { [self] in try await fetchIncomingHandshakes(for: wallet.publicAddress, blockTime: incomingHandshakeSince) }
        ) else {
            return
        }
        advanceSyncCursor(for: incomingHandshakeKey, maxBlockTime: incoming.compactMap { $0.blockTime }.max())

        guard let outgoing = await retryUntilSuccess(
            label: "fetch outgoing handshakes",
            operation: { [self] in try await fetchOutgoingHandshakes(for: wallet.publicAddress, blockTime: outgoingHandshakeSince) }
        ) else {
            return
        }
        advanceSyncCursor(for: outgoingHandshakeKey, maxBlockTime: outgoing.compactMap { $0.blockTime }.max())

        var inPayments: [PaymentResponse] = []
        var outPayments: [PaymentResponse] = []
        // Fetch payments only on full fetch AND when not using UTXO subscription
        // (or on initial sync when lastPaymentFetchTime is 0)
        let shouldFetchPayments = activeAddress == nil && (!isUtxoSubscribed || lastPaymentFetchTime == 0)
        if shouldFetchPayments {
            NSLog("[ChatService] === FETCHING PAYMENTS (full fetch, utxoSubscribed=%d) ===", isUtxoSubscribed ? 1 : 0)
            guard let incomingPayments = await retryUntilSuccess(
                label: "fetch incoming payments",
                operation: { [self] in try await fetchIncomingPayments(for: wallet.publicAddress, blockTime: messageSince) }
            ) else {
                return
            }
            inPayments = incomingPayments

            guard let outgoingPayments = await retryUntilSuccess(
                label: "fetch outgoing payments",
                operation: { [self] in try await fetchOutgoingPayments(for: wallet.publicAddress, blockTime: messageSince) }
            ) else {
                return
            }
            outPayments = outgoingPayments
            NSLog("[ChatService] === PAYMENT FETCH COMPLETE: in=%d, out=%d ===", inPayments.count, outPayments.count)

            // Update last payment fetch time for UTXO subscription
            if !inPayments.isEmpty || !outPayments.isEmpty {
                let maxInTime = inPayments.compactMap { $0.blockTime }.max() ?? 0
                let maxOutTime = outPayments.compactMap { $0.blockTime }.max() ?? 0
                lastPaymentFetchTime = max(maxInTime, maxOutTime, lastPaymentFetchTime)
            } else if lastPaymentFetchTime == 0 {
                // Set to current time if no payments found on initial sync
                lastPaymentFetchTime = fallbackSince > 0 ? fallbackSince : UInt64(Date().timeIntervalSince1970 * 1000)
            }
        } else if activeAddress != nil {
            NSLog("[ChatService] Skipping payment fetch - active conversation only")
        } else {
            NSLog("[ChatService] Skipping payment fetch - UTXO subscription active")
        }

        NSLog("[ChatService] Fetched: %d incoming handshakes, %d outgoing handshakes", incoming.count, outgoing.count)
        if shouldFetchPayments {
            NSLog("[ChatService] Fetched: %d incoming payments, %d outgoing payments", inPayments.count, outPayments.count)
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
                    NSLog("[ChatService] Filtered %d handshake txs from payment results", filtered)
                }
            }
            await processPayments(inPayments, isOutgoing: false, myAddress: wallet.publicAddress, privateKey: privateKey)
            await processPayments(outPayments, isOutgoing: true, myAddress: wallet.publicAddress, privateKey: privateKey)
        }

        // Fetch saved handshakes from self-stash to get our aliases for outgoing messages
        guard let _ = await retryUntilSuccess(
            label: "fetch saved handshakes",
            operation: { [self] in try await fetchSavedHandshakes(myAddress: wallet.publicAddress, privateKey: privateKey) }
        ) else {
            return
        }

        // Reclassify misidentified handshakes:
        // If self-stash confirms we have handshakes with a contact but conversation has
        // no handshake messages, the earliest payment is likely the handshake (Bug 4 fix)
        reclassifyMisidentifiedHandshakes()

        // Migrate legacy aliases to deterministic routing states (one-time)
        if let privKey = privateKey {
            migrateToDeterministicAliases(privateKey: privKey)
        }

        // Now fetch contextual messages for all known aliases
        print("[ChatService] Current aliases: \(conversationAliases)")
        print("[ChatService] Our aliases: \(ourAliases)")
        print("[ChatService] Routing states: \(routingStates.count)")
        if let active = activeAddress {
            let completed = await fetchContextualMessagesForActive(
                contactAddress: active,
                myAddress: wallet.publicAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
            guard completed else { return }
            activeFetchSucceeded = true
        } else {
            let completed = await fetchContextualMessages(
                myAddress: wallet.publicAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
            guard completed else { return }
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

        // Update last successful sync date for connection status
        lastSuccessfulSyncDate = Date()
        if isFullFetch {
            await apiClient.recordIndexerSyncSuccess()
        }

        syncSucceeded = true
        print("[ChatService] Fetch complete. Total conversations: \(conversations.count), lastPollTime updated to: \(lastPollTime)")
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
        let template = NSLocalizedString(
            "Planned spend %@ KAS, but available balance %@ KAS is less than required.",
            comment: "Shown when balance is below required spend for send operation"
        )
        let message = String(format: template, locale: Locale.current, planned, available)
        return KasiaError.networkError(
            message
        )
    }

    func noSpendableFundsYetMessage() -> String {
        NSLocalizedString(
            "No spendable funds available yet. Wait for confirmations and try again.",
            comment: "Shown when funds exist but not confirmed/spendable yet"
        )
    }

    func matchesLocalizedTemplate(_ message: String, key: String) -> Bool {
        let lowered = message.lowercased()
        let localized = NSLocalizedString(key, comment: "").lowercased()
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

    func sendMessage(to contact: Contact, content: String, messageType: ChatMessage.MessageType = .contextual) async throws {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        do {
            try await ensureSufficientBalanceForMessageSend(
                to: contact,
                content: trimmed,
                walletAddress: wallet.publicAddress,
                privateKey: privateKey
            )
        } catch {
            if isInsufficientBalancePopupError(error) {
                throw error
            } else if isNoConfirmedInputsError(error) {
                NSLog("[ChatService] Message send precheck deferred: %@", error.localizedDescription)
            } else if shouldBypassBalancePrecheck(error) {
                NSLog("[ChatService] Message balance precheck unavailable, continuing send: %@", error.localizedDescription)
            } else {
                throw error
            }
        }

        let pendingTxId = "pending_\(UUID().uuidString)"
        let pendingTimestamp = Date()
        let pendingMessage = ChatMessage(
            txId: pendingTxId,
            senderAddress: wallet.publicAddress,
            receiverAddress: contact.address,
            content: trimmed,
            timestamp: pendingTimestamp,
            blockTime: UInt64(pendingTimestamp.timeIntervalSince1970 * 1000),
            isOutgoing: true,
            messageType: messageType,
            deliveryStatus: .pending
        )
        addMessageToConversation(pendingMessage, contactAddress: contact.address)
        enqueuePendingOutgoing(contactAddress: contact.address, pendingTxId: pendingTxId, messageType: messageType, timestamp: pendingTimestamp)
        saveMessages()

        try await enqueueOutgoingTxOperation {
            try await self.sendMessageInternal(
                to: contact,
                content: trimmed,
                messageType: messageType,
                pendingTxId: pendingTxId,
                pendingMessageId: pendingMessage.id
            )
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
        let payload: [String: Any] = [
            "type": "file",
            "name": resolvedFileName,
            "size": audioData.count,
            "mimeType": resolvedMimeType,
            "content": "data:\(resolvedMimeType);base64,\(base64)"
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw KasiaError.networkError("Failed to prepare audio payload")
        }

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
        spendableFundsRetryAttempt: Int = 0
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
            addMessageToConversation(pendingMessage, contactAddress: contact.address)
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

            print("[ChatService] Starting message send to \(contact.address.suffix(10))")

            // Connect via gRPC manager
            if !rpcManager.isConnected {
                print("[ChatService] RPC not connected, connecting...")
                try await rpcManager.connect(network: settings.networkType)
            } else {
                print("[ChatService] RPC already connected")
            }

            // Fetch UTXOs for our address
            let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
            updateWalletBalanceIfNeeded(address: wallet.publicAddress, utxos: utxos)
            let availableUtxos = prepareMessageUtxos(confirmed: utxos)
            guard !availableUtxos.isEmpty else {
                let totalBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
                if totalBalanceSompi == 0 {
                    NSLog("[ChatService] No confirmed UTXOs available - wallet balance is zero for %@",
                          String(activePendingTxId.prefix(12)))
                    throw KasiaError.networkError("Zero balance: add funds to your wallet and try again.")
                }

                NSLog("[ChatService] No confirmed spendable UTXOs available for %@",
                      String(activePendingTxId.prefix(12)))
                throw KasiaError.networkError(noSpendableFundsYetMessage())
            }

            print("[ChatService] Found \(availableUtxos.count) available UTXOs for sending")

            // Build the transaction
            let transaction = try KasiaTransactionBuilder.buildContextualMessageTx(
                from: wallet.publicAddress,
                to: contact.address,
                alias: alias,
                message: content,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: availableUtxos
            )
            // Submit the transaction
            let (txId, endpoint) = try await rpcManager.submitTransaction(transaction, allowOrphan: false)
            print("[ChatService] Transaction submitted: \(txId) via \(endpoint)")

            let spentUtxos = spentMessageUtxos(from: transaction, candidates: availableUtxos)
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
                NSLog("[ChatService] Message already accepted by consensus for %@ -> promoting pending to %@",
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
                    NSLog(
                        "[ChatService] Retrying send (no spendable funds) for %@ (%d/%d) in %.0fms (+%.0f%% jitter)",
                        String(activePendingTxId.prefix(12)),
                        retryNumber,
                        spendableFundsRetryAttempts,
                        retryDelay.seconds * 1000,
                        jitterRatio * 100
                    )
                } else {
                    NSLog(
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
                NSLog(
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
                NSLog("[ChatService] Message send retry scheduled for %@: %@",
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
        return confirmed
            .filter { $0.blockDaaScore > 0 && !$0.isCoinbase }
            .filter { reservedMessageOutpoints[outpointKey($0.outpoint)] == nil }
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
        pendingTxId: String? = nil
    ) async throws {
        try await enqueueOutgoingTxOperation {
            try await self.sendPaymentInternal(
                to: contact,
                amountSompi: amountSompi,
                note: note,
                pendingTxId: pendingTxId
            )
        }
    }

    func sendPaymentInternal(
        to contact: Contact,
        amountSompi: UInt64,
        note: String = "",
        pendingTxId: String? = nil
    ) async throws {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        if pendingTxId == nil {
            do {
                try await ensureSufficientBalanceForPaymentSend(
                    to: contact,
                    amountSompi: amountSompi,
                    note: note,
                    walletAddress: wallet.publicAddress,
                    privateKey: privateKey
                )
            } catch {
                if isInsufficientBalancePopupError(error) {
                    throw error
                } else if isNoConfirmedInputsError(error) {
                    NSLog("[ChatService] Payment send precheck deferred: %@", error.localizedDescription)
                } else if shouldBypassBalancePrecheck(error) {
                    NSLog("[ChatService] Payment balance precheck unavailable, continuing send: %@", error.localizedDescription)
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
            let pendingMessage = ChatMessage(
                txId: activePendingTxId,
                senderAddress: wallet.publicAddress,
                receiverAddress: contact.address,
                content: "Sent \(formattedAmount) KAS",
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
                throw KasiaError.networkError("No spendable UTXOs available")
            }

            guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
                throw KasiaError.invalidAddress
            }

            let tx = try KasiaTransactionBuilder.buildPaymentTx(
                from: wallet.publicAddress,
                to: contact.address,
                amount: amountSompi,
                note: note,
                senderPrivateKey: privateKey,
                recipientPublicKey: recipientPublicKey,
                utxos: spendable
            )

            // Submit via RPC manager
            NSLog("[ChatService] Submitting payment via RPC manager...")
            let (txId, endpoint) = try await rpcManager.submitTransaction(tx, allowOrphan: false)
            NSLog("[ChatService] Payment submitted: \(txId) via \(endpoint)")
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
        } catch {
            if let acceptedTxId = acceptedTransactionId(from: error) {
                NSLog("[ChatService] Payment already accepted by consensus for %@ -> promoting pending to %@",
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
                return
            }

            if isNoConfirmedInputsError(error) {
                let delay = nextNoInputRetryDelay(for: activePendingTxId)
                NSLog(
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

    func estimateMessageFee(to contact: Contact, content: String) async throws -> UInt64 {
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

        let alias = primaryOurAlias(for: contact.address) ?? String(repeating: "0", count: 12)
        let payload = try KasiaTransactionBuilder.buildContextualMessagePayload(
            alias: alias,
            message: trimmed,
            recipientPublicKey: recipientPublicKey
        )

        // Use fallback method - doesn't require gRPC connection
        let utxos = try await fetchUtxosWithFallback(for: wallet.publicAddress)

        let spendable = utxos.filter { !$0.isCoinbase }
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }

        return KasiaTransactionBuilder.estimateContextualMessageFee(
            payload: payload,
            inputCount: spendable.count,
            senderScriptPubKey: senderScriptPubKey
        )
    }

    func estimatePaymentFee(to contact: Contact, amountSompi: UInt64, note: String = "") async throws -> UInt64 {
        guard amountSompi > 0 else { throw KasiaError.networkError("Amount is zero") }
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        let payload = try KasiaTransactionBuilder.buildPaymentPayload(message: note, amount: amountSompi, recipientPublicKey: recipientPublicKey)
        // Use fallback method - doesn't require gRPC connection
        let utxos = try await fetchUtxosWithFallback(for: wallet.publicAddress)
        let spendable = utxos.filter { !$0.isCoinbase }
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }

        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress),
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
        guard let wallet = WalletManager.shared.currentWallet else { throw KasiaError.walletNotFound }
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }

        // Use fallback method - doesn't require gRPC connection
        let utxos = try await fetchUtxosWithFallback(for: wallet.publicAddress)
        let spendable = utxos.filter { !$0.isCoinbase }
        guard !spendable.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs")
        }

        let totalBalance = spendable.reduce(0) { $0 + $1.amount }

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: contact.address),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
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
                    NSLog("[ChatService] Handshake send precheck deferred: %@", error.localizedDescription)
                } else if shouldBypassBalancePrecheck(error) {
                    NSLog("[ChatService] Handshake balance precheck unavailable, continuing send: %@", error.localizedDescription)
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
            NSLog("[ChatService] Handshake submitted: \(txId) via \(endpoint)")
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
                NSLog("[ChatService] Handshake already accepted by consensus for %@ -> promoting pending to %@",
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
                NSLog(
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

    func isConversationVisibleInChatList(_ conversation: Conversation, settings: AppSettings? = nil) -> Bool {
        let settings = settings ?? currentSettings
        let address = conversation.contact.address
        guard !isConversationDeclined(address) else { return false }

        let effectiveContact = contactsManager.getContact(byAddress: address) ?? conversation.contact
        guard !effectiveContact.isArchived else { return false }

        if settings.hideAutoCreatedPaymentChats &&
            effectiveContact.isAutoAdded &&
            !conversation.messages.contains(where: { $0.messageType != .payment }) {
            return false
        }

        return true
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
                NSLog("[ChatService] Overflow while splitting handshake UTXOs; falling back to full set")
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
        NSLog("[ChatService] Connecting via RPC manager (timeout: %.1fs)...", timeout)

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
        print("[ChatService] Queued self-stash for \(contactAddress.suffix(10))")
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
            print("[ChatService] Self-stash handshake submitted: \(txId)")
        } catch {
            print("[ChatService] Failed to submit self-stash handshake tx: \(error.localizedDescription)")
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
                    NSLog("[ChatService] Self-stash submitted: \(txId) via \(endpoint)")
                    succeeded.append(job)
                } catch {
                    print("[ChatService] Pending self-stash failed: \(error.localizedDescription)")
                }
            }

            if !succeeded.isEmpty {
                pendingSelfStash.removeAll { job in
                    succeeded.contains(where: { $0.id == job.id })
                }
                savePendingSelfStash()
            }
        } catch {
            print("[ChatService] attemptPendingSelfStashSends error: \(error.localizedDescription)")
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
                .sorted(by: isMessageOrderedBefore)
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
                .sorted(by: isMessageOrderedBefore)

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

    func markConversationAsRead(_ conversation: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            // Use both in-memory window and persistent store cursor so pagination does not
            // block read marker advancement.
            let lastInMemoryIncoming = conversation.messages
                .filter { !$0.isOutgoing }
                .max(by: { $0.blockTime < $1.blockTime })
            let storeCursor = messageStore.fetchLatestIncomingCursor(contactAddress: conversation.contact.address)
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
                let targetTxId: String?
                if storeBlockTime > inMemoryBlockTime {
                    targetTxId = storeCursor?.txId
                } else {
                    targetTxId = lastInMemoryIncoming?.txId
                }
                NSLog(
                    "[ChatService] Marking conversation %@ as read at blockTime=%lld (inMemory=%lld, store=%lld)",
                    String(conversation.contact.address.suffix(8)),
                    targetBlockTime,
                    inMemoryBlockTime,
                    storeBlockTime
                )
                ReadStatusSyncManager.shared.markAsRead(
                    contactAddress: conversation.contact.address,
                    lastReadTxId: targetTxId,
                    lastReadBlockTime: UInt64(targetBlockTime)
                )
            }
        }
    }

    // MARK: - Private Methods

    /// Check the Kasia indexer for a handshake matching the given txId
    /// Used as fallback when the Kaspa REST API doesn't return the transaction payload
}
