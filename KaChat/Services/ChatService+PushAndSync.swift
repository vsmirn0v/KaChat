import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

// MARK: - Push notifications, sync orchestration, UTXO subscriptions, archive

extension ChatService {
    /// Retry RPC subscription with 1s wait when all nodes exhausted
    /// Public method to re-setup UTXO subscription after manual reconnect
    /// Pause UTXO subscription on iOS when remote push is enabled and app goes to background
    /// Resume UTXO subscription on iOS when app becomes active in remote push mode
    /// Update UTXO subscription to include a new contact address
    /// Force a one-contact historical contextual sync from genesis (`blockTime = 0`).
    /// Used after manually adding a new contact so old messages are not skipped by adaptive cursors.
    /// Check if resubscription is needed due to new conversations/contacts
    /// Defers resubscription until sync completes to avoid interrupting sync
    /// Called at the end of sync to trigger deferred resubscription if needed
    // MARK: - Push Notification Message Handling

    /// Add a message that was decrypted by the notification extension or fetched from push
    struct ChatHistoryImportSummary {
        let conversationCount: Int
        let messageCount: Int
        let filledSentContentCount: Int
    }

    enum ChatHistoryArchiveError: LocalizedError {
        case encryptionKeyUnavailable
        case unsupportedVersion(Int)
        case emptyArchive

        var errorDescription: String? {
            switch self {
            case .encryptionKeyUnavailable:
                return "Failed to access wallet encryption key."
            case .unsupportedVersion(let version):
                return "Unsupported chat history format (version \(version))."
            case .emptyArchive:
                return "No messages found in the selected archive."
            }
        }
    }

    func exportChatHistoryArchive() throws -> URL {
        guard let key = messageEncryptionKey() else {
            throw ChatHistoryArchiveError.encryptionKeyUnavailable
        }

        let storedMessages = messageStore.fetchAllMessages(decryptionKey: key)
        let metaByAddress = messageStore.fetchConversationMeta()
        var messagesByAddress: [String: [String: ChatMessage]] = [:]

        for stored in storedMessages {
            let contactAddress = stored.contactAddress
            let txId = stored.message.txId
            guard !contactAddress.isEmpty, !txId.isEmpty else { continue }
            var bucket = messagesByAddress[contactAddress, default: [:]]
            if let existing = bucket[txId] {
                bucket[txId] = preferMessage(existing, stored.message)
            } else {
                bucket[txId] = stored.message
            }
            messagesByAddress[contactAddress] = bucket
        }

        let allAddresses = Set(messagesByAddress.keys).union(metaByAddress.keys)
        let exportedConversations = allAddresses.map { contactAddress in
            let messages = Array(messagesByAddress[contactAddress, default: [:]].values)
                .sorted(by: isMessageOrderedBefore)
            let meta = metaByAddress[contactAddress]
            let inMemory = conversations.first(where: { $0.contact.address == contactAddress })
            let alias = contactsManager.getContact(byAddress: contactAddress)?.alias ?? inMemory?.contact.alias
            return ChatHistoryArchiveConversation(
                conversationId: meta?.id ?? inMemory?.id,
                contactAddress: contactAddress,
                contactAlias: alias,
                unreadCount: max(0, meta?.unreadCount ?? inMemory?.unreadCount ?? 0),
                messages: messages
            )
        }
        .sorted { $0.contactAddress < $1.contactAddress }

        let archive = ChatHistoryArchive(
            schemaVersion: chatHistoryArchiveVersion,
            exportedAt: Date(),
            walletAddress: WalletManager.shared.currentWallet?.publicAddress,
            conversations: exportedConversations
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileName = "kachat-history-\(timestamp).json"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func importChatHistoryArchive(_ data: Data) async throws -> ChatHistoryImportSummary {
        guard let key = messageEncryptionKey() else {
            throw ChatHistoryArchiveError.encryptionKeyUnavailable
        }

        let archive: ChatHistoryArchive
        do {
            let isoDecoder = JSONDecoder()
            isoDecoder.dateDecodingStrategy = .iso8601
            archive = try isoDecoder.decode(ChatHistoryArchive.self, from: data)
        } catch {
            archive = try JSONDecoder().decode(ChatHistoryArchive.self, from: data)
        }
        guard archive.schemaVersion == chatHistoryArchiveVersion else {
            throw ChatHistoryArchiveError.unsupportedVersion(archive.schemaVersion)
        }

        let existingBefore = messageStore.fetchAllMessages(decryptionKey: key)
        let existingOutgoingPlaceholderTxIds = Set(
            existingBefore.compactMap { stored -> String? in
                guard stored.message.isOutgoing, isPlaceholderContent(stored.message.content) else { return nil }
                return stored.message.txId
            }
        )

        var importedByAddress: [String: Conversation] = [:]
        var importedOutgoingWithContentTxIds = Set<String>()

        for archivedConversation in archive.conversations {
            let contactAddress = archivedConversation.contactAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contactAddress.isEmpty else { continue }

            var importedMessages = archivedConversation.messages.filter { !$0.txId.isEmpty }
            guard !importedMessages.isEmpty else { continue }
            importedMessages = dedupeMessages(importedMessages)

            for message in importedMessages where message.isOutgoing && !isPlaceholderContent(message.content) {
                importedOutgoingWithContentTxIds.insert(message.txId)
            }

            let importedAlias = archivedConversation.contactAlias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let contact = contactsManager.getOrCreateContact(address: contactAddress, alias: importedAlias)
            if !importedAlias.isEmpty {
                let autoAlias = Contact.generateDefaultAlias(from: contactAddress)
                if contact.alias == autoAlias && importedAlias != autoAlias {
                    var updated = contact
                    updated.alias = importedAlias
                    contactsManager.updateContact(updated)
                }
            }

            let archived = Conversation(
                id: archivedConversation.conversationId ?? UUID(),
                contact: contact,
                messages: importedMessages,
                unreadCount: max(0, archivedConversation.unreadCount)
            )

            if var existing = importedByAddress[contactAddress] {
                existing.messages = dedupeMessages(existing.messages + archived.messages)
                existing.unreadCount = max(existing.unreadCount, archived.unreadCount)
                importedByAddress[contactAddress] = existing
            } else {
                importedByAddress[contactAddress] = archived
            }
        }

        let importedConversations = Array(importedByAddress.values)
        guard !importedConversations.isEmpty else {
            throw ChatHistoryArchiveError.emptyArchive
        }

        let importedMessageCount = Set(
            importedConversations.flatMap { conversation in
                conversation.messages.map(\.txId)
            }
        ).count

        let retention = currentSettings.messageRetention
        let didWrite = await messageStore.syncFromConversations(
            importedConversations,
            encryptionKey: key,
            retention: retention,
            performMaintenance: false
        )
        if didWrite {
            recordLocalSave()
        }

        for conversation in importedConversations {
            if let lastDate = conversation.lastMessage?.timestamp {
                contactsManager.updateContactLastMessage(conversation.contact.id, at: lastDate)
            }
        }

        loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

        let filledSentContentCount = existingOutgoingPlaceholderTxIds
            .intersection(importedOutgoingWithContentTxIds)
            .count

        return ChatHistoryImportSummary(
            conversationCount: importedConversations.count,
            messageCount: importedMessageCount,
            filledSentContentCount: filledSentContentCount
        )
    }

    func recordRemotePushDelivery(txId: String, sender: String, messageType: String?) {
        let normalizedTxId = txId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTxId.isEmpty else { return }

        prunePushReliabilityCaches(now: Date())
        pushSeenByTxId[normalizedTxId] = Date()

        guard let observation = pendingPushObservations.removeValue(forKey: normalizedTxId) else {
            return
        }
        if let task = pushObservationTasks.removeValue(forKey: normalizedTxId) {
            task.cancel()
        }

        NSLog("[ChatService] Push/UTXO matched tx=%@ sender=%@ type=%@",
              String(normalizedTxId.prefix(12)),
              String(sender.suffix(10)),
              messageType ?? "unknown")
        applyPushObservationOutcome(
            txId: normalizedTxId,
            senderAddress: observation.senderAddress,
            didReceivePush: true
        )
    }

    func maybeRunCatchUpSync(trigger: CatchUpSyncTrigger, force: Bool = false) async {
        refreshPushReliabilityPrerequisites()

        let shouldDebounce = !force &&
            isPushChannelOperational() &&
            pushReliabilityState == .reliable

        if shouldDebounce,
           let last = lastCatchUpSyncAt,
           Date().timeIntervalSince(last) < reliablePushCatchUpDebounce {
            NSLog("[ChatService] Skipping catch-up sync (%@) - push reliable and debounce active",
                  trigger.rawValue)
            return
        }

        if catchUpSyncInFlight {
            NSLog("[ChatService] Skipping catch-up sync (%@) - catch-up already in flight",
                  trigger.rawValue)
            return
        }

        catchUpSyncInFlight = true
        defer { catchUpSyncInFlight = false }

        NSLog("[ChatService] Running catch-up sync (%@), pushState=%@ force=%@",
              trigger.rawValue, pushReliabilityState.rawValue, force ? "true" : "false")
        await fetchNewMessages()
        lastCatchUpSyncAt = Date()
        persistPushReliabilityState()
    }

    func startPolling(interval: TimeInterval = 10.0) {
        // If initial sync already completed (e.g. Mac Catalyst window reopen),
        // just ensure subscription/polling is running — skip the heavy 4-phase sync.
        if hasCompletedInitialSync {
            NSLog("[ChatService] Initial sync already done, ensuring subscription/polling")
            let isRemotePushEnabled = settingsViewModel?.settings.notificationMode == .remotePush
            if !isRemotePushEnabled && !isUtxoSubscribed && pollTask == nil {
                startFallbackPolling()
            }
            return
        }

        stopPollingTimerOnly()
        subscriptionRetryTask?.cancel()
        subscriptionRetryTask = nil
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = nil
        subscriptionBalanceRefreshTask?.cancel()
        subscriptionBalanceRefreshTask = nil
        needsResubscriptionAfterSync = false
        NSLog("[ChatService] Starting message sync...")

        Task {
            NSLog("[ChatService] Sync task started")
            let isRemotePushEnabled = settingsViewModel?.settings.notificationMode == .remotePush
            let settings = currentSettings
            let cloudKitEnabled = settings.storeMessagesInICloud

            NSLog("[ChatService] Configuring API...")
            await configureAPIIfNeeded()
            NSLog("[ChatService] API configured")

            // Phase 1: Fetch handshakes first (needed to decrypt messages)
            // This is lightweight and establishes encryption keys
            NSLog("[ChatService] Phase 1: Fetching handshakes...")
            await fetchHandshakesOnly()
            NSLog("[ChatService] Phase 1 complete")

            // Phase 2: Setup UTXO subscription for real-time updates
            // This can run while CloudKit syncs
            NSLog("[ChatService] Phase 2: Setting up UTXO subscription...")
            await setupUtxoSubscription()
            NSLog("[ChatService] Phase 2 complete, isUtxoSubscribed=%d", isUtxoSubscribed ? 1 : 0)

            // Phase 3: Wait for CloudKit to complete (no timeout)
            // CloudKit may have all our messages already
            if cloudKitEnabled {
                NSLog("[ChatService] Phase 3: Waiting for CloudKit sync to complete...")
                await messageStore.waitForCloudKitSync(timeout: 0) // 0 = no timeout
                NSLog("[ChatService] Phase 3 complete - CloudKit sync done")

                // Phase 3.5: Load CloudKit-synced messages BEFORE indexer sync
                // This ensures we have any messages sent from other devices before
                // the indexer creates placeholder entries for them
                NSLog("[ChatService] Phase 3.5: Loading CloudKit-synced messages...")
                loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

                // Brief pause to allow any in-flight CloudKit syncs to complete
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                NSLog("[ChatService] Phase 3.5 complete")
            } else {
                NSLog("[ChatService] Phase 3 skipped - CloudKit disabled")
            }

            // Phase 4: Full indexer sync (diff-only writes to reduce DB churn)
            // NOTE: syncFromConversations() will preserve CloudKit content and not
            // overwrite with placeholders thanks to the !isPlaceholder check
            NSLog("[ChatService] Phase 4: Full indexer sync...")
            await fetchNewMessages()
            NSLog("[ChatService] Phase 4 complete")

            // After initial sync, enable notifications (they were suppressed during wallet import)
            suppressNotificationsUntilSynced = false
            hasCompletedInitialSync = true

            if isRemotePushEnabled {
                NSLog("[ChatService] Remote push enabled - skipping local polling")
                return
            }

            if isUtxoSubscribed {
                // RPC subscription active - no polling needed, rely on notifications
                let protocolName = NodePoolService.shared.activeProtocol
                NSLog("[ChatService] %@ subscription active - using real-time notifications (no polling)", protocolName)
            } else {
                // RPC subscription failed - use polling as fallback
                // Poll with 60s delay after each sync completes (not fixed interval)
                self.startFallbackPolling()
                NSLog("[ChatService] RPC unavailable - using fallback polling (%.0fs delay after each sync)", pollDelayAfterSync)
            }
        }
    }

    func startFallbackPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Wait before next sync
                try? await Task.sleep(nanoseconds: UInt64(self.pollDelayAfterSync * 1_000_000_000))

                guard !Task.isCancelled else { break }

                // Perform sync
                await self.fetchNewMessages()
            }
        }
    }

    func setupUtxoSubscription() async {
        guard let wallet = WalletManager.shared.currentWallet else {
            NSLog("[ChatService] setupUtxoSubscription: No wallet available")
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil
            return
        }

        NSLog("[ChatService] setupUtxoSubscription: Starting, isConnected=%@",
              NodePoolService.shared.isConnected ? "true" : "false")

        // Remove old subscription handler if any
        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        isUtxoSubscribed = false

        do {
            try await connectRpcIfNeeded()
            let nodePool = NodePoolService.shared
            NSLog("[ChatService] setupUtxoSubscription: RPC connected=%@", nodePool.isConnected ? "true" : "false")

            // Collect all addresses to subscribe: our wallet + active contacts
            var addressesToSubscribe = Set<String>()
            addressesToSubscribe.insert(wallet.publicAddress)

            let contacts = await MainActor.run { contactsManager.activeContacts }
            let contactCount = contacts.count
            for contact in contacts {
                addressesToSubscribe.insert(contact.address)
            }

            NSLog("[ChatService] Subscription setup: %d active contacts", contactCount)

            // TODO: Fix realtimeUpdatesDisabled feature - re-enable polling when fixed
            // Start/restart polling for contacts with realtime disabled
            // startDisabledContactsPolling()

            let addressList = Array(addressesToSubscribe)
            try await nodePool.subscribeUtxosChanged(addresses: addressList)

            // Add notification handler for UTXO changes
            utxoSubscriptionToken = nodePool.addNotificationHandler { [weak self] notification, payload in
                guard let self = self, notification == .utxosChanged else { return }
                self.handleUtxoChangeNotification(payload: payload)
            }

            // Detect if this is a restart (was subscribed before, got disconnected, now resubscribed)
            let isRestart = hasEverBeenSubscribed

            isUtxoSubscribed = true
            hasEverBeenSubscribed = true
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil

            // Stop polling task since we have real-time notifications now
            if pollTask != nil {
                pollTask?.cancel()
                pollTask = nil
                NSLog("[ChatService] Stopped fallback polling - using real-time notifications")
            }

            // Update connected node info
            currentConnectedNode = nodePool.connectedNodeURL
            currentNodeLatencyMs = nodePool.lastPingLatencyMs

            // Track subscribed address count for resubscription detection
            lastSubscribedAddressCount = addressList.count
            lastSubscribedAddresses = Set(addressList)
            NSLog("[ChatService] Real-time notifications active for %d addresses", addressList.count)
            scheduleBalanceRefreshAfterSubscriptionEnabled()

            // If this is a restart, sync messages/payments to catch anything missed during downtime
            if isRestart {
                NSLog("[ChatService] Subscription restarted - evaluating catch-up sync policy")
                Task {
                    await self.maybeRunCatchUpSync(trigger: .subscriptionRestart)
                }
            }

        } catch {
            NSLog("[ChatService] RPC subscription failed: %@", error.localizedDescription)
            isUtxoSubscribed = false

            // Start retry loop with 1s wait between full pool attempts
            scheduleSubscriptionRetry()
        }
    }

    func scheduleSubscriptionRetry() {
        guard WalletManager.shared.currentWallet != nil else {
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil
            return
        }

        // Cancel existing retry if any
        subscriptionRetryTask?.cancel()

        subscriptionRetryTask = Task {
            // Wait 1 second before retrying with all nodes from pool again
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard !Task.isCancelled else { return }

            NSLog("[ChatService] Retrying RPC subscription with all pool nodes...")
            await setupUtxoSubscription()

            guard !Task.isCancelled else { return }

            // If still not subscribed after retry, schedule another retry
            if !isUtxoSubscribed {
                NSLog("[ChatService] All pool nodes failed, retrying in 1s...")
                scheduleSubscriptionRetry()
            }
        }
    }

    func scheduleBalanceRefreshAfterSubscriptionEnabled() {
        subscriptionBalanceRefreshTask?.cancel()
        subscriptionBalanceRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let delaysNs: [UInt64] = [0, 500_000_000, 1_500_000_000]
            for (attemptIndex, delayNs) in delaysNs.enumerated() {
                if delayNs > 0 {
                    try? await Task.sleep(nanoseconds: delayNs)
                }
                guard !Task.isCancelled else { return }
                guard self.isUtxoSubscribed else { return }

                do {
                    let total = try await WalletManager.shared.refreshBalance()
                    NSLog("[ChatService] Post-subscription balance refreshed on attempt %d: %@ sompi",
                          attemptIndex + 1, String(total))
                    return
                } catch {
                    NSLog("[ChatService] Post-subscription balance refresh attempt %d failed: %@",
                          attemptIndex + 1, error.localizedDescription)
                }
            }
        }
    }

    func setupUtxoSubscriptionAfterReconnect() async {
        await setupUtxoSubscription()
    }

    func pauseUtxoSubscriptionForRemotePush() {
#if targetEnvironment(macCatalyst)
        // Keep realtime subscriptions active on desktop while app focus changes.
        return
#else
        guard settingsViewModel?.settings.notificationMode == .remotePush else { return }

        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        NodePoolService.shared.unsubscribeUtxosChanged()
        isUtxoSubscribed = false
        NSLog("[ChatService] Remote push active - UTXO subscription paused for background")
#endif
    }

    func resumeUtxoSubscriptionForRemotePush() async {
#if targetEnvironment(macCatalyst)
        // No-op: Catalyst does not pause on focus loss.
        return
#else
        guard settingsViewModel?.settings.notificationMode == .remotePush else { return }
        guard utxoSubscriptionToken == nil && !isUtxoSubscribed else { return }

        await setupUtxoSubscription()
#endif
    }

    func addContactToUtxoSubscription(_ contactAddress: String) async {
        guard isUtxoSubscribed else { return }
        guard let wallet = WalletManager.shared.currentWallet else { return }

        // Rebuild subscription with all active addresses including the new one
        var addressesToSubscribe = Set<String>()
        addressesToSubscribe.insert(wallet.publicAddress)

        let contactAddresses = await MainActor.run { contactsManager.activeContacts.map { $0.address } }
        for address in contactAddresses {
            addressesToSubscribe.insert(address)
        }
        if !(contactsManager.getContact(byAddress: contactAddress)?.isArchived ?? false) {
            addressesToSubscribe.insert(contactAddress)
        }

        let addressList = Array(addressesToSubscribe)
        lastSubscribedAddressCount = addressList.count
        lastSubscribedAddresses = Set(addressList)
        let _ = try? await NodePoolService.shared.subscribeUtxosChanged(addresses: addressList)
    }

    func syncContactHistoryFromGenesis(_ contactAddress: String) async {
        guard let wallet = WalletManager.shared.currentWallet else { return }

        await configureAPIIfNeeded()
        guard isConfigured else { return }

        let privateKey = WalletManager.shared.getPrivateKey()
        ensureRoutingState(for: contactAddress, privateKey: privateKey)

        // Ensure realtime updates include this new contact as soon as possible.
        await addContactToUtxoSubscription(contactAddress)

        let completed = await fetchContextualMessagesForActive(
            contactAddress: contactAddress,
            myAddress: wallet.publicAddress,
            privateKey: privateKey,
            fallbackSince: 0,
            nowMs: currentTimeMs(),
            forceExactBlockTime: true
        )
        guard completed else { return }

        saveMessages()
    }

    func checkAndResubscribeIfNeeded() {
        guard isUtxoSubscribed else { return }
        guard let wallet = WalletManager.shared.currentWallet else { return }

        // Calculate current active address set
        var addressesToSubscribe = Set<String>()
        addressesToSubscribe.insert(wallet.publicAddress)
        for contact in activeContacts {
            addressesToSubscribe.insert(contact.address)
        }

        let currentAddressCount = addressesToSubscribe.count

        // Resubscribe whenever active address set changes (additions or removals)
        guard addressesToSubscribe != lastSubscribedAddresses else { return }

        // If sync is in progress, mark for resubscription after sync completes
        if isLoading {
            needsResubscriptionAfterSync = true
            NSLog("[ChatService] Address count changed: %d -> %d, deferring resubscription until sync completes",
                  lastSubscribedAddressCount, currentAddressCount)
            return
        }

        NSLog("[ChatService] Address count changed: %d -> %d, executing resubscription",
              lastSubscribedAddressCount, currentAddressCount)

        // Cancel any pending resubscription task
        pendingResubscriptionTask?.cancel()

        // Execute resubscription
        pendingResubscriptionTask = Task {
            await setupUtxoSubscription()
        }
    }

    func executeResubscriptionIfNeeded() {
        guard needsResubscriptionAfterSync else { return }
        needsResubscriptionAfterSync = false

        NSLog("[ChatService] Sync complete, executing deferred resubscription")

        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = Task {
            await setupUtxoSubscription()
        }
    }

    func addMessageFromPush(txId: String, sender: String, content: String, timestamp: Int64) async {
        guard let wallet = WalletManager.shared.currentWallet else {
            NSLog("[ChatService] No wallet for push message")
            return
        }

        // Check if message already exists
        if findLocalMessage(txId: txId) != nil {
            NSLog("[ChatService] Push message already exists: %@", txId)
            return
        }

        // Determine message type
        let msgType: ChatMessage.MessageType = content.hasPrefix("{\"type\":\"audio\"") ? .audio : .contextual

        // Create message using the correct ChatMessage initializer
        let message = ChatMessage(
            txId: txId,
            senderAddress: sender,
            receiverAddress: wallet.publicAddress,
            content: content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
            blockTime: UInt64(timestamp),
            acceptingBlock: nil,
            isOutgoing: false,
            messageType: msgType
        )

        // Add to conversation using existing method
        addMessageToConversation(message, contactAddress: sender)
        saveMessages()

        NSLog("[ChatService] Added message from push: %@ from %@", txId, String(sender.suffix(10)))
    }

    /// Add a payment notification received from push
    func addPaymentFromPush(
        txId: String,
        sender: String,
        amount: UInt64?,
        payload: String?,
        timestamp: Int64
    ) async -> Bool {
        guard let wallet = WalletManager.shared.currentWallet else {
            NSLog("[ChatService] No wallet for push payment")
            return false
        }

        if findLocalMessage(txId: txId) != nil {
            NSLog("[ChatService] Push payment already exists: %@", txId)
            return true
        }

        if isSuppressedPaymentTxId(txId) {
            _ = addKNSTransferMessageFromHintIfNeeded(
                txId: txId,
                myAddress: wallet.publicAddress,
                blockTimeMs: UInt64(max(0, timestamp))
            )
            NSLog("[ChatService] Push payment %@ is already suppressed", String(txId.prefix(12)))
            return false
        }

        let myAddress = wallet.publicAddress
        let isOutgoing = sender == myAddress
        let privateKey = WalletManager.shared.getPrivateKey()

        if let tx = await fetchKaspaTransaction(txId: txId),
           await handleKNSOperationTransactionIfNeeded(
            tx,
            myAddress: myAddress,
            source: "kns-push-payment"
           ) {
            NSLog("[ChatService] Push payment %@ identified as KNS operation, suppressing", String(txId.prefix(12)))
            return false
        }

        if let payload, !payload.isEmpty {
            if isContextualPayload(payload) || isSelfStashPayload(payload) {
                NSLog("[ChatService] Push payment %@ has non-payment payload prefix, skipping", String(txId.prefix(12)))
                return false
            }
        }

        var decryptedPayment: PaymentPayload?
        if let payload, let privateKey {
            if let sealed = await decryptPaymentPayloadFromSealedHex(payload, privateKey: privateKey) {
                decryptedPayment = sealed
            } else {
                decryptedPayment = await decryptPaymentPayloadFromRawPayload(payload, privateKey: privateKey)
            }
        }

        var resolvedAmount = amount ?? decryptedPayment?.amount
        var messagePayloadHex: String?
        if let decryptedPayment,
           let data = try? JSONEncoder().encode(decryptedPayment) {
            messagePayloadHex = data.hexString
        }

        var receiver = myAddress
        if isOutgoing || resolvedAmount == nil {
            if let details = await resolvePaymentDetailsFromKaspa(
                txId: txId,
                senderHint: sender,
                myAddress: myAddress
            ) {
                receiver = details.receiver
                if resolvedAmount == nil {
                    resolvedAmount = details.amount
                }
                if decryptedPayment == nil,
                   let privateKey,
                   let payloadHex = details.payload,
                   let decrypted = await decryptPaymentPayloadFromRawPayload(payloadHex, privateKey: privateKey) {
                    decryptedPayment = decrypted
                    if resolvedAmount == nil {
                        resolvedAmount = decrypted.amount
                    }
                    if let data = try? JSONEncoder().encode(decrypted) {
                        messagePayloadHex = data.hexString
                    }
                }
            } else if isOutgoing {
                NSLog("[ChatService] Outgoing payment push: unable to resolve receiver for %@", txId)
                return false
            }
        }

        let blockTime = timestamp > 0 ? UInt64(timestamp) : nil
        let payment = PaymentResponse(
            txId: txId,
            sender: sender,
            receiver: receiver,
            amount: resolvedAmount,
            message: nil,
            blockTime: blockTime,
            acceptingBlock: nil,
            acceptingDaaScore: nil,
            messagePayload: messagePayloadHex
        )

        await processPayments(
            [payment],
            isOutgoing: isOutgoing,
            myAddress: myAddress,
            privateKey: privateKey
        )
        return true
    }

    /// Fetch a payment by txId (used when push payload is missing)
    func fetchPaymentByTxId(
        _ txId: String,
        sender: String,
        amount: UInt64?,
        timestamp: Int64
    ) async -> Bool {
        guard let wallet = WalletManager.shared.currentWallet else {
            NSLog("[ChatService] No wallet for fetching push payment")
            return false
        }

        if findLocalMessage(txId: txId) != nil {
            NSLog("[ChatService] Payment already exists: %@", txId)
            return true
        }

        let myAddress = wallet.publicAddress
        let isOutgoing = sender == myAddress

        if !isOutgoing, let amount {
            return await addPaymentFromPush(
                txId: txId,
                sender: sender,
                amount: amount,
                payload: nil,
                timestamp: timestamp
            )
        }

        if let entry = await NodePoolService.shared.getMempoolEntry(txId: txId, attempt: 1) {
            if !entry.payload.isEmpty, Self.isPaymentRawPayload(entry.payload) {
                if await addPaymentFromPush(
                    txId: txId,
                    sender: sender,
                    amount: amount,
                    payload: entry.payload,
                    timestamp: timestamp
                ) {
                    return true
                }
            }
        }

        if let fullTx = await fetchKaspaTransaction(txId: txId) {
            return await addPaymentFromPush(
                txId: txId,
                sender: sender,
                amount: amount,
                payload: fullTx.payload,
                timestamp: timestamp
            )
        }

        return false
    }

    /// Fetch a specific message by txId (for large payloads not included in push)
    func fetchMessageByTxId(_ txId: String, sender: String) async -> Bool {
        guard let _ = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey() else {
            NSLog("[ChatService] No wallet for fetching push message")
            return false
        }

        // Check if already exists
        if findLocalMessage(txId: txId) != nil {
            NSLog("[ChatService] Message already exists: %@", txId)
            return true
        }

        let startTime = Date()

        // 1) Try mempool immediately
        if await fetchMessageByTxIdFromMempool(txId: txId, sender: sender, privateKey: privateKey) {
            return true
        }

        // 2) After 1.5s, try indexer
        let elapsed1 = Date().timeIntervalSince(startTime)
        if elapsed1 < 1.5 {
            let delayNs = UInt64((1.5 - elapsed1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
        }
        if await fetchMessageByTxIdFromIndexer(txId: txId, sender: sender, privateKey: privateKey) {
            return true
        }

        // 3) After 3s from start, try Kaspa REST
        let elapsed2 = Date().timeIntervalSince(startTime)
        if elapsed2 < 3.0 {
            let delayNs = UInt64((3.0 - elapsed2) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
        }
        return await fetchMessageByTxIdFromKaspaRest(txId: txId, sender: sender, privateKey: privateKey)
    }

    func fetchMessageByTxIdFromMempool(
        txId: String,
        sender: String,
        privateKey: Data
    ) async -> Bool {
        if let entry = await NodePoolService.shared.getMempoolEntry(txId: txId, attempt: 1),
           !entry.payload.isEmpty {
            if Self.isPaymentRawPayload(entry.payload) {
                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                return await addPaymentFromPush(
                    txId: txId,
                    sender: sender,
                    amount: nil,
                    payload: entry.payload,
                    timestamp: timestamp
                )
            }
            if let decrypted = await decryptContextualMessageFromRawPayload(entry.payload, privateKey: privateKey) {
                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                await addMessageFromPush(txId: txId, sender: sender, content: decrypted, timestamp: timestamp)
                return true
            }
        }
        return false
    }

    func fetchMessageByTxIdFromIndexer(
        txId: String,
        sender: String,
        privateKey: Data
    ) async -> Bool {
        let settings = currentSettings
        guard let url = URL(string: "\(settings.indexerURL)/v1/messages/tx/\(txId)") else {
            NSLog("[ChatService] Invalid URL for fetching message")
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("[ChatService] Failed to fetch message tx: %@ (status=%d, bytes=%d)",
                      txId, status, data.count)
                return false
            }

            // Parse response and decrypt using existing method
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let payload = json["payload"] as? String {
                NSLog("[ChatService] Indexer payload len=%d for %@", payload.count, String(txId.prefix(10)))
                if let decrypted = await decryptContextualMessage(payload, privateKey: privateKey) {
                    let timestamp = (json["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
                    await addMessageFromPush(txId: txId, sender: sender, content: decrypted, timestamp: timestamp)
                    return true
                }

                if let decrypted = await decryptContextualMessageFromRawPayload(payload, privateKey: privateKey) {
                    let timestamp = (json["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
                    await addMessageFromPush(txId: txId, sender: sender, content: decrypted, timestamp: timestamp)
                    return true
                }

                let prefix = payload.prefix(80)
                NSLog("[ChatService] Failed to decrypt push message: %@ (prefix=%@)",
                      txId, String(prefix))
            } else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                NSLog("[ChatService] Indexer tx response missing payload for %@ (body=%@)", txId, snippet)
            }
        } catch {
            NSLog("[ChatService] Error fetching push message: %@", error.localizedDescription)
        }
        return false
    }

    func fetchMessageByTxIdFromKaspaRest(
        txId: String,
        sender: String,
        privateKey: Data
    ) async -> Bool {
        guard let fullTx = await fetchKaspaTransaction(txId: txId) else {
            return false
        }

        if let payload = fullTx.payload, !payload.isEmpty {
            NSLog("[ChatService] Kaspa payload len=%d for %@", payload.count, String(txId.prefix(10)))
            if Self.isPaymentRawPayload(payload) {
                let ts = fullTx.blockTime ?? fullTx.acceptingBlockTime ?? UInt64(Date().timeIntervalSince1970 * 1000)
                return await addPaymentFromPush(
                    txId: txId,
                    sender: sender,
                    amount: nil,
                    payload: payload,
                    timestamp: Int64(ts)
                )
            }
            if let decrypted = await decryptContextualMessageFromRawPayload(payload, privateKey: privateKey) {
                let ts = fullTx.blockTime ?? fullTx.acceptingBlockTime ?? UInt64(Date().timeIntervalSince1970 * 1000)
                await addMessageFromPush(txId: txId, sender: sender, content: decrypted, timestamp: Int64(ts))
                return true
            } else {
                NSLog("[ChatService] Kaspa payload decrypt failed: %@", txId)
            }
        }

        return false
    }

    /// Build a Kaspa REST API URL using URLComponents for safe encoding.
    func kaspaRestURL(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let settings = currentSettings
        guard var components = URLComponents(string: settings.kaspaRestAPIURL) else { return nil }
        components.path += path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    func fetchKaspaTransaction(txId: String) async -> KaspaFullTransactionResponse? {
        guard let url = kaspaRestURL(
            path: "/transactions/\(txId)",
            queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
        ) else {
            NSLog("[ChatService] Invalid Kaspa URL for tx fetch: %@", txId)
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                NSLog("[ChatService] Kaspa API failed to fetch tx: %@", txId)
                return nil
            }
            return try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data)
        } catch {
            NSLog("[ChatService] Kaspa tx fetch error: %@ (%@)", txId, error.localizedDescription)
            return nil
        }
    }

    func resolvePaymentDetailsFromKaspa(
        txId: String,
        senderHint: String,
        myAddress: String
    ) async -> (receiver: String, amount: UInt64, payload: String?)? {
        guard let fullTx = await fetchKaspaTransaction(txId: txId) else {
            return nil
        }

        if await handleKNSOperationTransactionIfNeeded(
            fullTx,
            myAddress: myAddress,
            source: "kns-push-payment-details"
        ) {
            NSLog("[ChatService] Suppressing KNS tx %@ while resolving payment details", String(txId.prefix(12)))
            return nil
        }

        var totalToUs: UInt64 = 0
        var outputsToOthers: [(address: String, amount: UInt64)] = []

        for output in fullTx.outputs {
            guard let addr = output.scriptPublicKeyAddress, !addr.isEmpty else { continue }
            if addr == myAddress {
                totalToUs += output.amount
            } else {
                outputsToOthers.append((address: addr, amount: output.amount))
            }
        }

        if senderHint == myAddress {
            guard let recipient = outputsToOthers.min(by: { $0.amount < $1.amount }) else {
                return nil
            }
            return (receiver: recipient.address, amount: recipient.amount, payload: fullTx.payload)
        }

        guard totalToUs > 0 else {
            return nil
        }
        return (receiver: myAddress, amount: totalToUs, payload: fullTx.payload)
    }

    // MARK: - Realtime Updates Management
    // TODO: Fix realtimeUpdatesDisabled feature - currently broken, all functions in this section are unused until fixed

    /// Called when a contact's realtime updates setting is changed
    /// NOTE: Currently unused - feature disabled
    func updateUtxoSubscriptionForRealtimeChange() async {
        NSLog("[ChatService] Realtime setting changed, updating UTXO subscription")
        await setupUtxoSubscription()
    }

    /// Disable realtime updates for a contact (called from warning popup)
    /// NOTE: Currently unused - feature disabled
    func disableRealtimeForContact(_ contactAddress: String) {
        // Update in contactsManager
        if var contact = contactsManager.contacts.first(where: { $0.address == contactAddress }) {
            contact.realtimeUpdatesDisabled = true
            contactsManager.updateContact(contact)
            NSLog("[ChatService] Disabled realtime updates for %@", String(contactAddress.suffix(10)))

            // Update subscription
            Task {
                await updateUtxoSubscriptionForRealtimeChange()
            }
        }

        // Also update in conversations (need to create new conversation since contact is let)
        if let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            var updatedContact = conversations[index].contact
            updatedContact.realtimeUpdatesDisabled = true
            conversations[index] = Conversation(
                id: conversations[index].id,
                contact: updatedContact,
                messages: conversations[index].messages,
                unreadCount: conversations[index].unreadCount
            )
        }

        // Clear warning
        noisyContactWarning = nil
    }

    /// Dismiss the noisy contact warning without disabling
    /// NOTE: Currently unused - feature disabled
    func dismissNoisyContactWarning() {
        if let warning = noisyContactWarning {
            dismissedSpamWarnings.insert(warning.contactAddress)
            NSLog("[ChatService] Dismissed noisy contact warning for %@", String(warning.contactAddress.suffix(10)))
        }
        noisyContactWarning = nil
    }

    // MARK: - Disabled Contacts Polling
    // TODO: Fix realtimeUpdatesDisabled feature - currently broken, all functions in this section are unused until fixed

    /// Start periodic polling for contacts with realtime updates disabled
    /// NOTE: Currently unused - feature disabled
    func startDisabledContactsPolling() {
        disabledContactsPollingTask?.cancel()

        // Get contacts with realtime disabled
        let disabledContacts = activeContacts.filter { $0.realtimeUpdatesDisabled }
        guard !disabledContacts.isEmpty else {
            NSLog("[ChatService] No contacts with realtime disabled, skipping polling setup")
            return
        }

        NSLog("[ChatService] Starting periodic polling for %d contacts with realtime disabled", disabledContacts.count)

        disabledContactsPollingTask = Task {
            while !Task.isCancelled {
                // Wait for polling interval
                try? await Task.sleep(nanoseconds: UInt64(disabledContactsPollingInterval * 1_000_000_000))

                guard !Task.isCancelled else { break }

                await pollDisabledContacts()
            }
        }
    }

    /// Poll messages for contacts with realtime updates disabled
    /// NOTE: Currently unused - feature disabled
    func pollDisabledContacts() async {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let privateKey = WalletManager.shared.getPrivateKey()
        let nowMs = currentTimeMs()
        let fallbackSince = lastPollTime > syncReorgBufferMs ? lastPollTime - syncReorgBufferMs : lastPollTime

        let disabledContacts = await MainActor.run { contactsManager.activeContacts.filter { $0.realtimeUpdatesDisabled } }
        guard !disabledContacts.isEmpty else { return }

        NSLog("[ChatService] Polling %d contacts with realtime disabled", disabledContacts.count)

        for contact in disabledContacts {
            let contactAddress = contact.address
            let myAddress = wallet.publicAddress

            // Fetch contextual messages (incoming to us)
            let pollAliases = incomingAliases(for: contactAddress)
            if !pollAliases.isEmpty {
                for alias in pollAliases {
                    do {
                        let syncObjectKey = contextualSyncObjectKey(
                            direction: "in",
                            queryAddress: contactAddress,
                            alias: alias,
                            contactAddress: contactAddress
                        )
                        let startBlockTime = syncStartBlockTime(
                            for: syncObjectKey,
                            fallbackBlockTime: fallbackSince,
                            nowMs: nowMs
                        )
                        let effectiveSince = applyMessageRetention(to: startBlockTime)
                        let messages = try await KasiaAPIClient.shared.getContextualMessagesBySender(
                            address: contactAddress,
                            alias: alias,
                            limit: 50,
                            blockTime: effectiveSince
                        )
                        advanceSyncCursor(for: syncObjectKey, maxBlockTime: messages.compactMap { $0.blockTime }.max())

                        for contextMsg in messages {
                            var content = "[Encrypted message]"
                            if let privKey = privateKey {
                                if let decrypted = await decryptContextualMessage(contextMsg.messagePayload, privateKey: privKey) {
                                    content = decrypted
                                }
                            }
                            let msgType = messageType(for: content)

                            let message = ChatMessage(
                                txId: contextMsg.txId,
                                senderAddress: contextMsg.sender,
                                receiverAddress: myAddress,
                                content: content,
                                timestamp: Date(timeIntervalSince1970: TimeInterval((contextMsg.blockTime ?? 0) / 1000)),
                                blockTime: contextMsg.blockTime ?? 0,
                                acceptingBlock: contextMsg.acceptingBlock,
                                isOutgoing: false,
                                messageType: msgType
                            )

                            await MainActor.run {
                                addMessageToConversation(message, contactAddress: contactAddress)
                                if let blockTime = contextMsg.blockTime, blockTime > lastPollTime {
                                    updateLastPollTime(blockTime)
                                }
                            }
                        }
                    } catch {
                        if ChatService.handleDpiPaginationFailure(error, context: "disabled contacts contextual") {
                            continue
                        }
                        NSLog("[ChatService] Failed to poll messages from %@: %@", String(contactAddress.suffix(10)), error.localizedDescription)
                    }
                }
            }

            // Fetch incoming handshakes
            do {
                let handshakeKey = handshakeSyncObjectKey(direction: "in", address: myAddress)
                let handshakeSince = syncStartBlockTime(
                    for: handshakeKey,
                    fallbackBlockTime: fallbackSince,
                    nowMs: nowMs
                )
                let incoming = try await KasiaAPIClient.shared.getHandshakesByReceiver(
                    address: myAddress,
                    limit: 50,
                    blockTime: handshakeSince
                )
                advanceSyncCursor(for: handshakeKey, maxBlockTime: incoming.compactMap { $0.blockTime }.max())
                // Filter to only this contact's handshakes
                let contactHandshakes = incoming.filter { $0.sender == contactAddress }
                if !contactHandshakes.isEmpty, let privateKey = privateKey {
                    await processHandshakes(contactHandshakes, isOutgoing: false, myAddress: myAddress, privateKey: privateKey)
                }
            } catch {
                if ChatService.handleDpiPaginationFailure(error, context: "disabled contacts handshakes") {
                    continue
                }
                NSLog("[ChatService] Failed to poll handshakes from %@: %@", String(contactAddress.suffix(10)), error.localizedDescription)
            }
        }
    }

    // MARK: - Spam Detection
    // TODO: Fix realtimeUpdatesDisabled feature - currently broken, all functions in this section are unused until fixed

    /// Record an irrelevant TX notification for a contact address and check for spam
    /// NOTE: Currently unused - feature disabled
    func recordIrrelevantTxNotification(contactAddress: String) {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)

        // Add current timestamp
        var timestamps = contactTxNotifications[contactAddress] ?? []
        timestamps.append(now)

        // Remove timestamps older than 1 minute
        timestamps = timestamps.filter { $0 > oneMinuteAgo }
        contactTxNotifications[contactAddress] = timestamps

        // Check if threshold exceeded
        let spamThreshold = 20
        if timestamps.count >= spamThreshold {
            // Check if we've already dismissed this warning
            guard !dismissedSpamWarnings.contains(contactAddress) else { return }

            // Check if contact already has realtime disabled
            if let contact = contactsManager.activeContacts.first(where: { $0.address == contactAddress }) {
                guard !contact.realtimeUpdatesDisabled else { return }

                // Show warning
                NSLog("[ChatService] Contact %@ produced %d irrelevant TX notifications in 1 minute - showing warning",
                      String(contactAddress.suffix(10)), timestamps.count)

                noisyContactWarning = NoisyContactWarning(
                    contactAddress: contactAddress,
                    contactAlias: contact.alias,
                    txCount: timestamps.count
                )

                // Clear the timestamps to avoid repeated warnings
                contactTxNotifications[contactAddress] = []
            }
        }
    }

    /// Handle UTXO change notification - show payments immediately, resolve details in background
}
