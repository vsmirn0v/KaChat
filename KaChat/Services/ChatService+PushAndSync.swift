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

    /// Stage events emitted by `importChatHistoryArchive` so the restore progress modal can
    /// show a determinate bar. `.importing` advances per conversation as the Core Data write
    /// in `MessageStore.syncFromConversations` progresses (real work, not simulated).
    enum ChatHistoryImportProgress {
        case validating
        case preparing
        case importing(done: Int, total: Int)
        case finalizing
    }

    enum ChatHistoryArchiveError: LocalizedError {
        case encryptionKeyUnavailable
        case unsupportedVersion(Int)
        case emptyArchive
        case remoteBackupUnreadable
        case remoteBackupIncompatible(Int)
        case remoteBackupForeignWallet

        var errorDescription: String? {
            switch self {
            case .encryptionKeyUnavailable:
                return "Failed to access wallet encryption key."
            case .unsupportedVersion(let version):
                return "Unsupported chat history format (version \(version))."
            case .emptyArchive:
                return "No messages found in the selected archive."
            case .remoteBackupUnreadable:
                return "The file already on the server isn't a KaChat backup. Nothing was uploaded and it was left untouched. Pick a different backup folder."
            case .remoteBackupIncompatible(let version):
                return "The backup already on the server uses schema version \(version), which this version can't merge. Nothing was uploaded and it was left untouched."
            case .remoteBackupForeignWallet:
                return "The backup already on the server belongs to a different wallet. Nothing was uploaded. Choose a separate backup folder for this account."
            }
        }
    }

    func exportChatHistoryArchive() async throws -> URL {
        let data = try await buildChatHistoryArchiveData()
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

    /// This device's full archive as JSON bytes - the local half of every backup, shared by the
    /// file export above and the Nextcloud merge-upload path (`buildBackupArchiveData`).
    func buildChatHistoryArchiveData() async throws -> Data {
        guard let key = messageEncryptionKey() else {
            throw ChatHistoryArchiveError.encryptionKeyUnavailable
        }

        let storedMessages = await messageStore.fetchAllMessages(decryptionKey: key)
        let metaByAddress = await messageStore.fetchConversationMeta()
        var messagesByAddress: [String: [String: ChatMessage]] = [:]

        for stored in storedMessages {
            let contactAddress = stored.contactAddress
            let txId = stored.message.txId
            guard !contactAddress.isEmpty, !txId.isEmpty else { continue }
            // In-place via subscript-with-default (_modify) - see the identical fix in
            // ChatService+Persistence's grouping loop (avoids per-insert COW of the whole bucket).
            if let existing = messagesByAddress[contactAddress, default: [:]][txId] {
                messagesByAddress[contactAddress, default: [:]][txId] = Self.preferMessage(existing, stored.message)
            } else {
                messagesByAddress[contactAddress, default: [:]][txId] = stored.message
            }
        }

        // Deleted chats are excluded from the export AND their tombstones travel with the
        // archive, so restoring anywhere never brings them back.
        let allAddresses = Set(messagesByAddress.keys).union(metaByAddress.keys)
            .filter { !contactsManager.isAddressDeleted($0) }
        let exportedConversations = allAddresses.map { contactAddress in
            let messages = Array(messagesByAddress[contactAddress, default: [:]].values)
                .sorted(by: Self.isMessageOrderedBefore)
            let meta = metaByAddress[contactAddress]
            let inMemory = conversations.first(where: { $0.contact.address == contactAddress })
            let contact = contactsManager.getContact(byAddress: contactAddress)
            let alias = contact?.alias ?? inMemory?.contact.alias
            // Carry a cross-platform contact photo: a photo restored from another device wins,
            // else render the (cached) linked system-contact photo to a small JPEG so it travels
            // in the shared backup. Best-effort - an uncached system photo is simply omitted.
            var contactPhoto: String? = nil
            if let stored = contact?.backupPhoto, !stored.isEmpty {
                contactPhoto = stored
            } else if let contact, let image = SystemContactAvatarStore.shared.rawImage(for: contact),
                      let data = image.jpegData(compressionQuality: 0.7) {
                contactPhoto = data.base64EncodedString()
            }
            return ChatHistoryArchiveConversation(
                conversationId: meta?.id ?? inMemory?.id,
                contactAddress: contactAddress,
                contactAlias: alias,
                contactPhoto: contactPhoto,
                unreadCount: max(0, meta?.unreadCount ?? inMemory?.unreadCount ?? 0),
                messages: messages
            )
        }
        .sorted { $0.contactAddress < $1.contactAddress }

        // Groups ARE backed up again - now including decrypted message history (not just keys),
        // so group messages survive even if the indexer has pruned them. Import skips tombstoned
        // (deleted) groups so a restore never resurrects one.
        let archivedGroups = await MainActor.run { GroupChatService.shared.archiveGroups() }
        let archive = ChatHistoryArchive(
            schemaVersion: chatHistoryArchiveVersion,
            exportedAt: Date(),
            walletAddress: WalletManager.shared.currentWallet?.publicAddress,
            conversations: exportedConversations,
            groups: archivedGroups,
            deletedContactAddresses: contactsManager.deletedAddressSnapshot
        )

        // Encode off the main actor: pretty-printed + sorted-keys over a multi-MB archive is
        // real CPU work, and this path runs on every debounced auto-backup upload, not just
        // explicit exports.
        return try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(archive)
        }.value
    }

    /// The upload body for the SHARED `kachat-backup.json` - this device's history UNIONED with
    /// whatever the transport just downloaded from the server, so a backup can only ever ADD to
    /// the shared file (desktop, iOS and Android all write that same file) and no device can
    /// delete another's chat history. `remoteData` nil means no backup exists yet - then this is
    /// simply the local archive.
    ///
    /// Every validation failure THROWS: the caller must abort the upload, leaving a foreign or
    /// unreadable file exactly as it was rather than destroying it. Mirrors Android's
    /// `ChatHistoryExportImportService.buildBackupJson` and desktop's `exportBackupPayload`.
    func buildBackupArchiveData(mergingRemote remoteData: Data?) async throws -> Data {
        let localData = try await buildChatHistoryArchiveData()
        guard let remoteData, !remoteData.isEmpty else { return localData }
        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        let expectedVersion = chatHistoryArchiveVersion
        // The merge is pure JSON-tree work over potentially multi-MB archives - keep it off the
        // main actor.
        return try await Task.detached(priority: .utility) {
            try Self.mergeBackupArchives(
                remoteData: remoteData,
                localData: localData,
                myAddress: myAddress,
                schemaVersion: expectedVersion
            )
        }.value
    }

    /// `progress` (optional) receives stage events on the main actor; see
    /// `ChatHistoryImportProgress`. Used by `BackupRestoreCoordinator` to drive the blocking
    /// restore modal.
    func importChatHistoryArchive(
        _ data: Data,
        progress: (@MainActor @Sendable (ChatHistoryImportProgress) -> Void)? = nil
    ) async throws -> ChatHistoryImportSummary {
        guard let key = messageEncryptionKey() else {
            throw ChatHistoryArchiveError.encryptionKeyUnavailable
        }

        progress?(.validating)

        // Decode off the main actor: this runs not just for the modal restore but also for the
        // silent Nextcloud auto-restore and the foreground ETag watcher's merges, and a
        // multi-MB JSON decode on the main actor is a visible hitch during normal use.
        let archive: ChatHistoryArchive = try await Task.detached(priority: .utility) {
            do {
                let isoDecoder = JSONDecoder()
                isoDecoder.dateDecodingStrategy = .iso8601
                return try isoDecoder.decode(ChatHistoryArchive.self, from: data)
            } catch {
                return try JSONDecoder().decode(ChatHistoryArchive.self, from: data)
            }
        }.value
        guard archive.schemaVersion == chatHistoryArchiveVersion else {
            throw ChatHistoryArchiveError.unsupportedVersion(archive.schemaVersion)
        }

        progress?(.preparing)

        // Restored history is history, not new mail: the shared cross-platform archive carries
        // each conversation's unreadCount from the exporting device, but restoring must never
        // mint unread badges here. Keep only whatever unread state THIS device already has -
        // conversations the restore introduces land with unread 0.
        let existingMeta = await messageStore.fetchConversationMeta()
        var existingUnreadByAddress: [String: Int] = [:]
        for (address, meta) in existingMeta {
            existingUnreadByAddress[address] = max(0, meta.unreadCount)
        }
        for conversation in conversations {
            existingUnreadByAddress[conversation.contact.address] = max(
                existingUnreadByAddress[conversation.contact.address] ?? 0,
                conversation.unreadCount
            )
        }

        let existingBefore = await messageStore.fetchAllMessages(decryptionKey: key)
        let existingOutgoingPlaceholderTxIds = Set(
            existingBefore.compactMap { stored -> String? in
                guard stored.message.isOutgoing, Self.isPlaceholderContent(stored.message.content) else { return nil }
                return stored.message.txId
            }
        )

        var importedByAddress: [String: Conversation] = [:]
        var importedOutgoingWithContentTxIds = Set<String>()

        let archivedTombstones = Set(archive.deletedContactAddresses ?? [])
        for archivedConversation in archive.conversations {
            let contactAddress = archivedConversation.contactAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contactAddress.isEmpty else { continue }
            // Never resurrect a deleted chat: honor this device's tombstones AND the ones the
            // archive itself carries (covers restoring onto a fresh install).
            if contactsManager.isAddressDeleted(contactAddress) || archivedTombstones.contains(contactAddress) { continue }

            var importedMessages = archivedConversation.messages.filter { !$0.txId.isEmpty }
            guard !importedMessages.isEmpty else { continue }
            importedMessages = Self.dedupeMessages(importedMessages)

            for message in importedMessages where message.isOutgoing && !Self.isPlaceholderContent(message.content) {
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
            // Adopt a backed-up photo only when this device has none of its own for the
            // contact (never overwrite a linked system-contact photo the user already has).
            if let photo = archivedConversation.contactPhoto, !photo.isEmpty {
                let current = contactsManager.getContact(byAddress: contactAddress) ?? contact
                if (current.backupPhoto ?? "").isEmpty {
                    var updated = current
                    updated.backupPhoto = photo
                    contactsManager.updateContact(updated)
                }
            }

            // Never adopt the archive's unreadCount (see existingUnreadByAddress above).
            let archived = Conversation(
                id: archivedConversation.conversationId ?? UUID(),
                contact: contact,
                messages: importedMessages,
                unreadCount: existingUnreadByAddress[contactAddress] ?? 0
            )

            if var existing = importedByAddress[contactAddress] {
                existing.messages = Self.dedupeMessages(existing.messages + archived.messages)
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
        // Bridge the per-conversation hook (fires on the Core Data background queue) back
        // to the main actor for the progress callback.
        let onConversationProgress: (@Sendable (Int, Int) -> Void)? = progress.map { report in
            { @Sendable done, total in
                Task { @MainActor in
                    report(.importing(done: done, total: total))
                }
            }
        }
        let didWrite = await messageStore.syncFromConversations(
            importedConversations,
            encryptionKey: key,
            retention: retention,
            performMaintenance: false,
            onConversationProgress: onConversationProgress
        )
        progress?(.finalizing)
        if didWrite {
            recordLocalSave()
        }

        for conversation in importedConversations {
            if let lastDate = conversation.lastMessage?.timestamp {
                contactsManager.updateContactLastMessage(conversation.contact.id, at: lastDate)
            }
        }

        await loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

        // Groups (cross-platform recovery): restore full group key material so this device
        // recovers admin groups it created elsewhere as well as member ones. Optional - older
        // archives omit it.
        if let archivedGroups = archive.groups, !archivedGroups.isEmpty {
            await MainActor.run { GroupChatService.shared.importArchiveGroups(archivedGroups) }
        }

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

        AppLog.log("[ChatService] Push/UTXO matched tx=%@ sender=%@ type=%@",
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
            AppLog.log("[ChatService] Skipping catch-up sync (%@) - push reliable and debounce active",
                  trigger.rawValue)
            return
        }

        if catchUpSyncInFlight {
            AppLog.log("[ChatService] Skipping catch-up sync (%@) - catch-up already in flight",
                  trigger.rawValue)
            return
        }

        catchUpSyncInFlight = true
        defer { catchUpSyncInFlight = false }

        AppLog.log("[ChatService] Running catch-up sync (%@), pushState=%@ force=%@",
              trigger.rawValue, pushReliabilityState.rawValue, force ? "true" : "false")
        await fetchNewMessages()
        lastCatchUpSyncAt = Date()
        persistPushReliabilityState()
    }

    func startPolling(interval: TimeInterval = 10.0) {
        guard WalletManager.shared.currentWallet != nil else {
            startPollingWhenStoreReadyTask?.cancel()
            startPollingWhenStoreReadyTask = nil
            return
        }
        guard isMessageStoreReadyForCurrentWallet() else {
            scheduleStartPollingWhenStoreReady(interval: interval)
            return
        }
        startPollingWhenStoreReadyTask?.cancel()
        startPollingWhenStoreReadyTask = nil

        // Wallet loaded + store ready: make sure the foreground contact sweep is running (no-op
        // if it already is). It self-gates on app-active and on the initial sync having finished,
        // so starting it here is safe on every startPolling() call, including tab re-entry.
        startForegroundContactSweep()

        // If initial sync already completed (e.g. Mac Catalyst window reopen),
        // just ensure subscription/polling is running — skip the heavy 4-phase sync.
        if hasCompletedInitialSync {
            AppLog.log("[ChatService] Initial sync already done, ensuring subscription/polling")
            // Fallback polling keys off the subscription alone, NOT the push mode: while the
            // app runs, its own sync paths must detect everything (new handshakes included)
            // even with remote push on. Backgrounded, the process suspends before the 60s
            // delay elapses, so push stays the background source either way.
            if !isUtxoSubscribed && pollTask == nil {
                startFallbackPolling()
            }
            return
        }

        // An initial sync is already running (the task exists and hasn't been cancelled by a wallet
        // switch/logout). Don't cancel + restart it: repeated startPolling() calls - e.g. re-entering
        // the chat tab, or app-active resyncs - would otherwise keep restarting the heavy 4-phase sync
        // from scratch, hammering the main actor and freezing the UI. Let the in-flight run finish.
        if let task = initialSyncTask, !task.isCancelled {
            AppLog.log("[ChatService] Initial sync already in progress - not restarting")
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
        AppLog.log("[ChatService] Starting message sync...")

        // Tracked in `initialSyncTask` so a wallet switch/import/logout can cancel this run; an
        // untracked Task here would keep syncing the old wallet after the active wallet changed.
        initialSyncTask?.cancel()
        initialSyncTask = Task {
            AppLog.log("[ChatService] Sync task started")
            let settings = currentSettings
            let cloudKitEnabled = settings.storeMessagesInICloud

            AppLog.log("[ChatService] Configuring API...")
            await configureAPIIfNeeded()
            AppLog.log("[ChatService] API configured")

            // Phase 1: Fetch handshakes first (needed to decrypt messages)
            // This is lightweight and establishes encryption keys
            AppLog.log("[ChatService] Phase 1: Fetching handshakes...")
            await fetchHandshakesOnly()
            AppLog.log("[ChatService] Phase 1 complete")

            // Phase 2: Setup UTXO subscription for real-time updates
            // This can run while CloudKit syncs
            AppLog.log("[ChatService] Phase 2: Setting up UTXO subscription...")
            await setupUtxoSubscription()
            AppLog.log("[ChatService] Phase 2 complete, isUtxoSubscribed=%d", isUtxoSubscribed ? 1 : 0)

            // Phase 3: Wait for CloudKit to complete (no timeout)
            // CloudKit may have all our messages already
            if cloudKitEnabled {
                AppLog.log("[ChatService] Phase 3: Waiting for CloudKit sync to complete...")
                await messageStore.waitForCloudKitSync(timeout: 0) // 0 = no timeout
                AppLog.log("[ChatService] Phase 3 complete - CloudKit sync done")
            } else {
                AppLog.log("[ChatService] Phase 3 skipped - CloudKit disabled")
            }

            // Phase 3.5: Hydrate memory from the LOCAL store before the indexer re-sync - ALWAYS,
            // not just when iCloud is on. The local Core Data store holds existing messages and,
            // critically, their persisted read cursors (`CDConversation.lastReadBlockTime`). Loading
            // it first means Phase 4's full re-fetch short-circuits on already-known messages
            // (`addMessageToConversation`'s txId check) instead of recounting every historical
            // message as unread from an empty list. Skipping this when iCloud message storage was
            // OFF is exactly why previously-read chats reappeared unread after logout->login.
            AppLog.log("[ChatService] Phase 3.5: Loading messages from local store...")
            await loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
            if cloudKitEnabled {
                // Brief pause to allow any in-flight CloudKit syncs to complete.
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            }
            AppLog.log("[ChatService] Phase 3.5 complete")

            // Phase 4: Full indexer sync (diff-only writes to reduce DB churn)
            // NOTE: syncFromConversations() will preserve CloudKit content and not
            // overwrite with placeholders thanks to the !isPlaceholder check
            AppLog.log("[ChatService] Phase 4: Full indexer sync...")
            await fetchNewMessages()
            AppLog.log("[ChatService] Phase 4 complete")

            // After initial sync, enable notifications (they were suppressed during wallet import)
            suppressNotificationsUntilSynced = false
            hasCompletedInitialSync = true

            // No remote-push early-out here: fallback polling depends only on whether the
            // subscription came up. While the app runs, its own sync paths must detect
            // everything regardless of push registration; backgrounded, the process suspends
            // before the 60s poll delay elapses, so push stays the background source.
            if isUtxoSubscribed {
                // RPC subscription active - no polling needed, rely on notifications
                let protocolName = NodePoolService.shared.activeProtocol
                AppLog.log("[ChatService] %@ subscription active - using real-time notifications (no polling)", protocolName)
            } else {
                // RPC subscription failed - use polling as fallback
                // Poll with 60s delay after each sync completes (not fixed interval)
                self.startFallbackPolling()
                AppLog.log("[ChatService] RPC unavailable - using fallback polling (%.0fs delay after each sync)", pollDelayAfterSync)
            }
        }
    }

    private func isMessageStoreReadyForCurrentWallet() -> Bool {
        guard let walletAddress = WalletManager.shared.currentWallet?.publicAddress else { return false }
        return messageStore.isStoreLoaded && messageStore.currentWalletAddress == walletAddress
    }

    private func scheduleStartPollingWhenStoreReady(interval: TimeInterval) {
        guard startPollingWhenStoreReadyTask == nil else { return }
        AppLog.log("[ChatService] Delaying message sync until wallet message store is ready")
        startPollingWhenStoreReadyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.startPollingWhenStoreReadyTask = nil
            self.startPolling(interval: interval)
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
            AppLog.log("[ChatService] setupUtxoSubscription: No wallet available")
            subscriptionRetryTask?.cancel()
            subscriptionRetryTask = nil
            return
        }

        AppLog.log("[ChatService] setupUtxoSubscription: Starting, isConnected=%@",
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
            AppLog.log("[ChatService] setupUtxoSubscription: RPC connected=%@", nodePool.isConnected ? "true" : "false")

            // Collect all addresses to subscribe: our wallet + active contacts + spending-chain
            // addresses reserved-and-offered as fresh payment-pool receive addresses (payments to
            // those arrive on otherwise-unwatched addresses and would go unnoticed until a manual
            // balance refresh - see ChatService+PaymentPools.swift). Pool addresses fall through
            // the UTXO classifier's "unknown address" case, so watching them never creates
            // bubbles; the payment_notice envelope does that.
            var addressesToSubscribe = Set<String>()
            addressesToSubscribe.insert(wallet.publicAddress)

            let contacts = await MainActor.run { contactsManager.activeContacts }
            let contactCount = contacts.count
            for contact in contacts {
                addressesToSubscribe.insert(contact.address)
            }
            for poolAddress in PaymentPoolStore.shared.allOfferedReservationAddresses(wallet: wallet.publicAddress) {
                addressesToSubscribe.insert(poolAddress)
            }
            // Own-address receive notifications: also watch every revealed spending-chain
            // address and all cold-storage (watch-only) addresses. Like pool addresses these
            // fall through the classifier's chat cases - AddressActivityNotifier turns their
            // receives into wallet notifications, never chat bubbles (and their appearance
            // among `removed` entries is the self-send fast path).
            for ownAddress in AddressActivityNotifier.shared.watchedOwnAddresses() {
                addressesToSubscribe.insert(ownAddress)
            }

            AppLog.log("[ChatService] Subscription setup: %d active contacts", contactCount)

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
                AppLog.log("[ChatService] Stopped fallback polling - using real-time notifications")
            }

            // Update connected node info
            currentConnectedNode = nodePool.connectedNodeURL
            currentNodeLatencyMs = nodePool.lastPingLatencyMs

            // Track subscribed address count for resubscription detection
            lastSubscribedAddressCount = addressList.count
            lastSubscribedAddresses = Set(addressList)
            AppLog.log("[ChatService] Real-time notifications active for %d addresses", addressList.count)
            scheduleBalanceRefreshAfterSubscriptionEnabled()

            // If this is a restart, sync messages/payments to catch anything missed during downtime
            if isRestart {
                AppLog.log("[ChatService] Subscription restarted - evaluating catch-up sync policy")
                Task {
                    await self.maybeRunCatchUpSync(trigger: .subscriptionRestart)
                }
            }

        } catch {
            AppLog.log("[ChatService] RPC subscription failed: %@", error.localizedDescription)
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

            AppLog.log("[ChatService] Retrying RPC subscription with all pool nodes...")
            await setupUtxoSubscription()

            guard !Task.isCancelled else { return }

            // If still not subscribed after retry, schedule another retry
            if !isUtxoSubscribed {
                AppLog.log("[ChatService] All pool nodes failed, retrying in 1s...")
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
                    AppLog.log("[ChatService] Post-subscription balance refreshed on attempt %d: %@ sompi",
                          attemptIndex + 1, String(total))
                    return
                } catch {
                    AppLog.log("[ChatService] Post-subscription balance refresh attempt %d failed: %@",
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
        AppLog.log("[ChatService] Remote push active - UTXO subscription paused for background")
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

        // Rebuild subscription with all active addresses including the new one (and, as in
        // setupUtxoSubscription, the offered payment-pool reservation addresses).
        var addressesToSubscribe = Set<String>()
        addressesToSubscribe.insert(wallet.publicAddress)

        let contactAddresses = await MainActor.run { contactsManager.activeContacts.map { $0.address } }
        for address in contactAddresses {
            addressesToSubscribe.insert(address)
        }
        addressesToSubscribe.insert(contactAddress)
        for poolAddress in PaymentPoolStore.shared.allOfferedReservationAddresses(wallet: wallet.publicAddress) {
            addressesToSubscribe.insert(poolAddress)
        }
        for ownAddress in AddressActivityNotifier.shared.watchedOwnAddresses() {
            addressesToSubscribe.insert(ownAddress)
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

        // Calculate current active address set. Must mirror setupUtxoSubscription's full set
        // (contacts + offered pool addresses + own spending/cold addresses) - comparing a
        // partial set against lastSubscribedAddresses would read as "changed" on every call
        // and thrash resubscription.
        var addressesToSubscribe = Set<String>()
        addressesToSubscribe.insert(wallet.publicAddress)
        for contact in activeContacts {
            addressesToSubscribe.insert(contact.address)
        }
        for poolAddress in PaymentPoolStore.shared.allOfferedReservationAddresses(wallet: wallet.publicAddress) {
            addressesToSubscribe.insert(poolAddress)
        }
        for ownAddress in AddressActivityNotifier.shared.watchedOwnAddresses() {
            addressesToSubscribe.insert(ownAddress)
        }

        let currentAddressCount = addressesToSubscribe.count

        // Resubscribe whenever active address set changes (additions or removals)
        guard addressesToSubscribe != lastSubscribedAddresses else { return }

        // If sync is in progress, mark for resubscription after sync completes
        if isLoading {
            needsResubscriptionAfterSync = true
            AppLog.log("[ChatService] Address count changed: %d -> %d, deferring resubscription until sync completes",
                  lastSubscribedAddressCount, currentAddressCount)
            return
        }

        AppLog.log("[ChatService] Address count changed: %d -> %d, executing resubscription",
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

        AppLog.log("[ChatService] Sync complete, executing deferred resubscription")

        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = Task {
            await setupUtxoSubscription()
        }
    }

    func addMessageFromPush(txId: String, sender: String, content: String, timestamp: Int64) async {
        guard let wallet = WalletManager.shared.currentWallet else {
            AppLog.log("[ChatService] No wallet for push message")
            return
        }

        // Check if message already exists
        if await findLocalMessage(txId: txId) != nil {
            AppLog.log("[ChatService] Push message already exists: %@", txId)
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

        AppLog.log("[ChatService] Added message from push: %@ from %@", txId, String(sender.suffix(10)))
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
            AppLog.log("[ChatService] No wallet for push payment")
            return false
        }

        if await findLocalMessage(txId: txId) != nil {
            AppLog.log("[ChatService] Push payment already exists: %@", txId)
            return true
        }

        if isSuppressedPaymentTxId(txId) {
            _ = await addKNSTransferMessageFromHintIfNeeded(
                txId: txId,
                myAddress: wallet.publicAddress,
                blockTimeMs: UInt64(max(0, timestamp))
            )
            AppLog.log("[ChatService] Push payment %@ is already suppressed", String(txId.prefix(12)))
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
            AppLog.log("[ChatService] Push payment %@ identified as KNS operation, suppressing", String(txId.prefix(12)))
            return false
        }

        if let payload, !payload.isEmpty {
            if isContextualPayload(payload) || isSelfStashPayload(payload) {
                AppLog.log("[ChatService] Push payment %@ has non-payment payload prefix, skipping", String(txId.prefix(12)))
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
                AppLog.log("[ChatService] Outgoing payment push: unable to resolve receiver for %@", txId)
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
            AppLog.log("[ChatService] No wallet for fetching push payment")
            return false
        }

        if await findLocalMessage(txId: txId) != nil {
            AppLog.log("[ChatService] Payment already exists: %@", txId)
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
            AppLog.log("[ChatService] No wallet for fetching push message")
            return false
        }

        // Check if already exists
        if await findLocalMessage(txId: txId) != nil {
            AppLog.log("[ChatService] Message already exists: %@", txId)
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
            AppLog.log("[ChatService] Invalid URL for fetching message")
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                AppLog.log("[ChatService] Failed to fetch message tx: %@ (status=%d, bytes=%d)",
                      txId, status, data.count)
                return false
            }

            // Parse response and decrypt using existing method
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let payload = json["payload"] as? String {
                AppLog.log("[ChatService] Indexer payload len=%d for %@", payload.count, String(txId.prefix(10)))
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
                AppLog.log("[ChatService] Failed to decrypt push message: %@ (prefix=%@)",
                      txId, String(prefix))
            } else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                AppLog.log("[ChatService] Indexer tx response missing payload for %@ (body=%@)", txId, snippet)
            }
        } catch {
            AppLog.log("[ChatService] Error fetching push message: %@", error.localizedDescription)
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
            AppLog.log("[ChatService] Kaspa payload len=%d for %@", payload.count, String(txId.prefix(10)))
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
                AppLog.log("[ChatService] Kaspa payload decrypt failed: %@", txId)
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
            AppLog.log("[ChatService] Invalid Kaspa URL for tx fetch: %@", txId)
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                AppLog.log("[ChatService] Kaspa API failed to fetch tx: %@", txId)
                return nil
            }
            return try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data)
        } catch {
            AppLog.log("[ChatService] Kaspa tx fetch error: %@ (%@)", txId, error.localizedDescription)
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
            AppLog.log("[ChatService] Suppressing KNS tx %@ while resolving payment details", String(txId.prefix(12)))
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

}

// MARK: - Shared-file backup merge (upload side)
//
// Mirrors Android's `ChatHistoryExportImportService.mergeArchives` and desktop's
// `mergeChatArchives`, including the abort-rather-than-destroy contract. Everything here is
// untyped JSON-tree work on purpose: round-tripping through the typed `ChatHistoryArchive`
// model would silently drop every key this app doesn't model - desktop keeps its whole state
// in an additive `desktopState` key - and wipe it on the next iOS backup. Unknown keys at the
// archive, conversation and message level are all carried through verbatim.
extension ChatService {
    private nonisolated static let archiveStatusPriority: [String: Int] = [
        "pending": 0, "warning": 1, "failed": 2, "sent": 3,
    ]
    private nonisolated static let archiveValidMessageTypes: Set<String> = [
        "handshake", "contextual", "payment", "audio",
    ]
    private nonisolated static let archiveValidDeliveryStatuses: Set<String> = [
        "pending", "sent", "failed", "warning",
    ]

    // MARK: JSON accessors (tolerant of NSNumber/String cross-typing)

    private nonisolated static func jsonString(_ dict: [String: Any], _ key: String) -> String {
        if let value = dict[key] as? String { return value }
        return ""
    }

    private nonisolated static func jsonInt64(_ dict: [String: Any], _ key: String) -> Int64 {
        if let number = dict[key] as? NSNumber { return number.int64Value }
        if let string = dict[key] as? String, let parsed = Int64(string) { return parsed }
        return 0
    }

    private nonisolated static func jsonArray(_ dict: [String: Any], _ key: String) -> [Any] {
        dict[key] as? [Any] ?? []
    }

    private nonisolated static func parseIsoMs(_ value: String) -> Int64? {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        return nil
    }

    /// Whole-second ISO8601 ("2026-08-17T12:34:56Z") - iOS's `.iso8601` decoding strategy
    /// rejects fractional seconds outright, so the shared file never carries them.
    private nonisolated static func isoSeconds(_ epochMs: Int64) -> String {
        let ms = epochMs > 0 ? epochMs : Int64(Date().timeIntervalSince1970 * 1000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms / 1000)))
    }

    private nonisolated static func exportedAtMs(_ archive: [String: Any]) -> Int64 {
        parseIsoMs(jsonString(archive, "exportedAt")) ?? 0
    }

    // MARK: Deterministic archive UUIDs

    /// Byte-identical port of desktop's / Android's `derivedArchiveUuid` hash, so all three
    /// platforms derive the same UUID for the same seed.
    private nonisolated static func derivedArchiveUuid(_ seed: String) -> String {
        var h = Int32(bitPattern: 1779033703) ^ Int32(truncatingIfNeeded: seed.count)
        for scalar in seed.unicodeScalars {
            h = (h ^ Int32(truncatingIfNeeded: Int(scalar.value))) &* Int32(bitPattern: 3432918353)
            h = (h << 13) | Int32(bitPattern: UInt32(bitPattern: h) >> 19)
        }
        var hex = ""
        for _ in 0..<4 {
            h = (h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)) &* Int32(bitPattern: 2246822507)
            h = (h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 13)) &* Int32(bitPattern: 3266489909)
            h = h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16)
            hex += String(format: "%08x", UInt32(bitPattern: h))
        }
        var nibbles = Array(hex)
        nibbles[12] = "4"                                                   // RFC 4122 version
        let variantIndex = Int(String(nibbles[16]), radix: 16) ?? 0
        nibbles[16] = Array("89ab")[variantIndex & 3]                       // RFC 4122 variant
        let flat = String(nibbles)
        let part: (Int, Int) -> Substring = { start, end in
            flat[flat.index(flat.startIndex, offsetBy: start)..<flat.index(flat.startIndex, offsetBy: end)]
        }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }

    /// Passes a real UUID through untouched (lowercased), otherwise derives one.
    private nonisolated static func archiveUuid(_ value: String, seed: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: raw) != nil { return raw.lowercased() }
        return derivedArchiveUuid(raw.isEmpty ? seed : raw)
    }

    // MARK: Message-level merge helpers

    private nonisolated static func isArchivePlaceholderBody(_ content: String) -> Bool {
        content.isEmpty || isPlaceholderContent(content)
    }

    /// Mirrors `preferMessage`: a real body beats a placeholder, then the further-along
    /// delivery status wins, then the later blockTime.
    private nonisolated static func preferArchiveMessage(
        _ existing: [String: Any], _ candidate: [String: Any]
    ) -> [String: Any] {
        let existingPlaceholder = isArchivePlaceholderBody(jsonString(existing, "content"))
        let candidatePlaceholder = isArchivePlaceholderBody(jsonString(candidate, "content"))
        if existingPlaceholder != candidatePlaceholder {
            return candidatePlaceholder ? existing : candidate
        }
        let existingPriority = archiveStatusPriority[jsonString(existing, "deliveryStatus")] ?? 3
        let candidatePriority = archiveStatusPriority[jsonString(candidate, "deliveryStatus")] ?? 3
        if existingPriority != candidatePriority {
            return candidatePriority > existingPriority ? candidate : existing
        }
        return jsonInt64(candidate, "blockTime") > jsonInt64(existing, "blockTime") ? candidate : existing
    }

    /// txId is the real identity; `id` is only the fallback for a message that never made it
    /// on-chain.
    private nonisolated static func archiveMessageKey(_ message: [String: Any]) -> String {
        let txId = jsonString(message, "txId").trimmingCharacters(in: .whitespacesAndNewlines)
        if !txId.isEmpty { return "tx:\(txId)" }
        return "id:\(jsonString(message, "id").trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// Coerces any archive message - including one another device wrote - into the strictest
    /// shape every platform's decoder accepts, without changing what it says. Keys this schema
    /// doesn't model are carried through untouched.
    private nonisolated static func normalizeArchiveMessage(_ message: [String: Any]) -> [String: Any] {
        var out = message
        let txId = jsonString(message, "txId").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawId = jsonString(message, "id").trimmingCharacters(in: .whitespacesAndNewlines)
        let blockTime = max(0, jsonInt64(message, "blockTime"))
        let timestampMs = blockTime > 0
            ? blockTime
            : (parseIsoMs(jsonString(message, "timestamp")) ?? Int64(Date().timeIntervalSince1970 * 1000))
        out["id"] = archiveUuid(rawId, seed: "\(txId):\(rawId)")
        out["txId"] = txId
        out["senderAddress"] = jsonString(message, "senderAddress")
        out["receiverAddress"] = jsonString(message, "receiverAddress")
        out["content"] = jsonString(message, "content")
        out["timestamp"] = isoSeconds(timestampMs)
        out["blockTime"] = NSNumber(value: blockTime)
        out["isOutgoing"] = (message["isOutgoing"] as? NSNumber)?.boolValue ?? false
        let messageType = jsonString(message, "messageType")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        out["messageType"] = archiveValidMessageTypes.contains(messageType) ? messageType : "contextual"
        let deliveryStatus = jsonString(message, "deliveryStatus")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        out["deliveryStatus"] = archiveValidDeliveryStatuses.contains(deliveryStatus) ? deliveryStatus : "sent"
        // Both phone encoders drop nil optionals rather than emitting null - omit an empty
        // acceptingBlock entirely.
        if jsonString(message, "acceptingBlock").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.removeValue(forKey: "acceptingBlock")
        }
        return out
    }

    private nonisolated static func sortedArchiveMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.sorted { lhs, rhs in
            let lhsTime = jsonInt64(lhs, "blockTime")
            let rhsTime = jsonInt64(rhs, "blockTime")
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            let lhsKey = jsonString(lhs, "txId").isEmpty ? jsonString(lhs, "id") : jsonString(lhs, "txId")
            let rhsKey = jsonString(rhs, "txId").isEmpty ? jsonString(rhs, "id") : jsonString(rhs, "txId")
            return lhsKey < rhsKey
        }
    }

    /// Validates the archive already sitting on the server. Every failure path THROWS - the
    /// caller aborts BEFORE uploading, so an unreadable or foreign backup is left exactly as it
    /// was rather than being overwritten with this device's history.
    private nonisolated static func parseRemoteArchive(
        _ data: Data, myAddress: String, schemaVersion expectedVersion: Int
    ) throws -> [String: Any] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let remote = parsed as? [String: Any],
              remote["conversations"] is [Any] else {
            throw ChatHistoryArchiveError.remoteBackupUnreadable
        }
        let remoteVersion = Int(jsonInt64(remote, "schemaVersion"))
        guard remoteVersion == expectedVersion else {
            throw ChatHistoryArchiveError.remoteBackupIncompatible(remoteVersion)
        }
        let remoteWallet = jsonString(remote, "walletAddress").trimmingCharacters(in: .whitespacesAndNewlines)
        if !remoteWallet.isEmpty, !myAddress.isEmpty, remoteWallet != myAddress {
            throw ChatHistoryArchiveError.remoteBackupForeignWallet
        }
        return remote
    }

    private final class ArchiveConversationMerge {
        let contactAddress: String
        var base: [String: Any]
        var conversationId = ""
        var contactAlias = ""
        var contactPhoto = ""
        var unreadCount: Int64 = 0
        var messages: [String: [String: Any]] = [:]
        var messageOrder: [String] = []

        init(contactAddress: String, base: [String: Any]) {
            self.contactAddress = contactAddress
            self.base = base
        }
    }

    /// Union of the archive on the server and this device's archive - what makes the shared
    /// file a sync point rather than last-writer-wins:
    ///   * a conversation present on only ONE side is kept whole;
    ///   * messages dedupe by txId (falling back to `id`), keeping the better copy per
    ///     `preferMessage`'s ordering;
    ///   * conversation metadata (alias / unreadCount) comes from whichever archive was
    ///     exported more recently, and an empty value never overwrites a real one;
    ///   * deletion tombstones union, and tombstoned conversations are dropped;
    ///   * groups union by groupId, with this device's just-exported copy winning;
    ///   * CRITICAL: the result starts as a copy of the REMOTE object, so every key iOS
    ///     doesn't model (desktop's `desktopState`, future fields) survives verbatim.
    nonisolated static func mergeBackupArchives(
        remoteData: Data, localData: Data, myAddress: String, schemaVersion: Int
    ) throws -> Data {
        let remote = try parseRemoteArchive(remoteData, myAddress: myAddress, schemaVersion: schemaVersion)
        guard let localParsed = try? JSONSerialization.jsonObject(with: localData),
              let local = localParsed as? [String: Any] else {
            // The local archive is produced by our own encoder; failing to re-read it means
            // something is deeply wrong - abort rather than upload garbage.
            throw ChatHistoryArchiveError.emptyArchive
        }

        let remoteIsNewer = exportedAtMs(remote) > exportedAtMs(local)
        var merged: [String: ArchiveConversationMerge] = [:]
        var mergedOrder: [String] = []

        func absorb(_ archive: [String: Any], isRemote: Bool) {
            for element in jsonArray(archive, "conversations") {
                guard let conversation = element as? [String: Any] else { continue }
                let contactAddress = jsonString(conversation, "contactAddress")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !contactAddress.isEmpty else { continue }
                let metadataWins = isRemote ? remoteIsNewer : !remoteIsNewer
                let alias = jsonString(conversation, "contactAlias").trimmingCharacters(in: .whitespacesAndNewlines)
                let conversationId = jsonString(conversation, "conversationId").trimmingCharacters(in: .whitespacesAndNewlines)
                let photo = jsonString(conversation, "contactPhoto")
                let unreadCount = max(0, jsonInt64(conversation, "unreadCount"))

                let entry: ArchiveConversationMerge
                if let existing = merged[contactAddress] {
                    entry = existing
                    if !alias.isEmpty, metadataWins || entry.contactAlias.isEmpty { entry.contactAlias = alias }
                    if !conversationId.isEmpty, entry.conversationId.isEmpty { entry.conversationId = conversationId }
                    if !photo.isEmpty, entry.contactPhoto.isEmpty { entry.contactPhoto = photo }
                    if metadataWins { entry.unreadCount = unreadCount }
                } else {
                    entry = ArchiveConversationMerge(contactAddress: contactAddress, base: conversation)
                    entry.conversationId = conversationId
                    entry.contactAlias = alias
                    entry.contactPhoto = photo
                    entry.unreadCount = unreadCount
                    merged[contactAddress] = entry
                    mergedOrder.append(contactAddress)
                }

                for messageElement in jsonArray(conversation, "messages") {
                    guard let message = messageElement as? [String: Any] else { continue }
                    // Phantom scrub (matches Android): entries whose txId is blank or a
                    // provisional pending_ id never reached the chain and can never be
                    // connected to their delivered selves - dropping them here heals a
                    // polluted server file on this device's next upload.
                    let phantomTxId = jsonString(message, "txId").trimmingCharacters(in: .whitespacesAndNewlines)
                    let phantomStatus = jsonString(message, "deliveryStatus")
                    if phantomTxId.isEmpty || phantomTxId.hasPrefix("pending_") {
                        if phantomStatus == "pending" || phantomStatus == "failed" || phantomTxId.hasPrefix("pending_") {
                            continue
                        }
                    }
                    let key = archiveMessageKey(message)
                    if let existing = entry.messages[key] {
                        entry.messages[key] = preferArchiveMessage(existing, message)
                    } else {
                        entry.messages[key] = message
                        entry.messageOrder.append(key)
                    }
                }
            }
        }

        // Remote first so it seeds identity (and unknown per-conversation keys); local second
        // so this device's newer view can win the per-field metadata contest when it is in
        // fact newer.
        absorb(remote, isRemote: true)
        absorb(local, isRemote: false)

        // Deletion tombstones: union of both sides; any tombstoned conversation is dropped
        // from the merged backup, so a chat deleted on one device stays deleted in the shared
        // history instead of resurrecting from the other side's copy.
        var tombstones = Set<String>()
        for side in [local, remote] {
            for element in jsonArray(side, "deletedContactAddresses") {
                if let address = element as? String, !address.isEmpty { tombstones.insert(address) }
            }
        }

        var conversations: [[String: Any]] = []
        for contactAddress in mergedOrder.sorted() {
            guard let entry = merged[contactAddress], !tombstones.contains(contactAddress) else { continue }
            var conversation = entry.base // remote-seeded copy: keeps any unknown keys
            // conversationId is normalized: iOS decodes it as UUID?, so a non-UUID one written
            // by another client would throw on restore.
            conversation["conversationId"] = archiveUuid(
                entry.conversationId, seed: "conversation:\(entry.contactAddress)"
            )
            conversation["contactAddress"] = entry.contactAddress
            if entry.contactAlias.isEmpty {
                conversation.removeValue(forKey: "contactAlias")
            } else {
                conversation["contactAlias"] = entry.contactAlias
            }
            if entry.contactPhoto.isEmpty {
                conversation.removeValue(forKey: "contactPhoto")
            } else {
                conversation["contactPhoto"] = entry.contactPhoto
            }
            conversation["unreadCount"] = NSNumber(value: entry.unreadCount)
            let normalized = entry.messageOrder.compactMap { key in
                entry.messages[key].map { normalizeArchiveMessage($0) }
            }
            conversation["messages"] = sortedArchiveMessages(normalized)
            conversations.append(conversation)
        }

        var result = remote // preserves desktopState and every other foreign key
        result["schemaVersion"] = NSNumber(value: schemaVersion)
        result["exportedAt"] = jsonString(local, "exportedAt")
        let walletAddress = jsonString(local, "walletAddress").isEmpty
            ? jsonString(remote, "walletAddress")
            : jsonString(local, "walletAddress")
        if walletAddress.isEmpty {
            result.removeValue(forKey: "walletAddress")
        } else {
            result["walletAddress"] = walletAddress
        }
        result["conversations"] = conversations

        // Groups: union by groupId so the shared backup accumulates every device's groups.
        // Local is listed first, so for a group both hold the just-exported local copy wins.
        var mergedGroups: [Any] = []
        var seenGroupIds = Set<String>()
        for side in [local, remote] {
            for element in jsonArray(side, "groups") {
                guard let group = element as? [String: Any] else { continue }
                let groupId = jsonString(group, "groupId")
                if !groupId.isEmpty, seenGroupIds.insert(groupId).inserted {
                    mergedGroups.append(group)
                }
            }
        }
        if mergedGroups.isEmpty {
            result.removeValue(forKey: "groups")
        } else {
            result["groups"] = mergedGroups
        }
        if tombstones.isEmpty {
            result.removeValue(forKey: "deletedContactAddresses")
        } else {
            result["deletedContactAddresses"] = tombstones.sorted()
        }

        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}
