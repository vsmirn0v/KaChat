import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

// MARK: - Data persistence, UI helpers, aliases, CloudKit, badges

extension ChatService {
    nonisolated static func hexStringToData(_ hex: String) -> Data? {
        var data = Data()
        var temp = ""

        for char in hex {
            temp += String(char)
            if temp.count == 2 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                } else {
                    return nil
                }
                temp = ""
            }
        }

        return data
    }

    func migrateLegacyMessagesIfNeeded() {
        guard let data = userDefaults.data(forKey: messagesKey),
              let cachedConversations = try? JSONDecoder().decode([CachedConversation].self, from: data) else {
            return
        }
        guard let key = messageEncryptionKey() else { return }
        guard messageStore.isStoreLoaded else {
            if !legacyMigrationScheduled {
                legacyMigrationScheduled = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self?.legacyMigrationScheduled = false
                    self?.migrateLegacyMessagesIfNeeded()
                }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let conversations = await MainActor.run { () -> [Conversation] in
                cachedConversations.compactMap { cached in
                    guard let contact = self.contactsManager.getContact(byAddress: cached.contactAddress) else { return nil }
                    return Conversation(id: cached.id, contact: contact, messages: cached.messages, unreadCount: cached.unreadCount)
                }
            }
            let didWrite = await self.messageStore.syncFromConversations(
                conversations,
                encryptionKey: key,
                retention: SettingsViewModel.loadSettings().messageRetention
            )
            if didWrite {
                await MainActor.run {
                    self.recordLocalSave()
                }
            }
        }
        userDefaults.removeObject(forKey: messagesKey)
    }

    /// Public method to reload messages from the message store.
    /// Call this after CloudKit sync to pick up messages from other devices.
    /// - Parameter forceReload: If true, reloads even if conversations are not empty
    func loadMessagesFromStoreIfNeeded(onlyIfEmpty: Bool = true) {
        if onlyIfEmpty {
            _loadMessagesFromStoreIfNeeded(onlyIfEmpty: true)
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastMessageStoreReloadAt)
        if elapsed < messageStoreReloadMinInterval {
            guard !messageStoreReloadPending else { return }
            messageStoreReloadPending = true
            let delay = messageStoreReloadMinInterval - elapsed
            messageStoreReloadTask?.cancel()
            messageStoreReloadTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                guard let self else { return }
                self.messageStoreReloadPending = false
                self.lastMessageStoreReloadAt = Date()
                self._loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
            }
            return
        }

        lastMessageStoreReloadAt = now
        _loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
    }

    func _loadMessagesFromStoreIfNeeded(onlyIfEmpty: Bool) {
        if onlyIfEmpty && !conversations.isEmpty {
            return
        }
        guard let key = messageEncryptionKey() else { return }
        let messages = messageStore.fetchAllMessages(decryptionKey: key)
        let meta = messageStore.fetchConversationMeta()
        guard !messages.isEmpty || !meta.isEmpty else { return }

        // Debug: count messages with/without content
        let withContent = messages.filter { $0.message.content != "📤 Sent via another device" }.count
        let placeholder = messages.count - withContent
        NSLog("[ChatService] loadMessagesFromStore: %d messages (%d with content, %d placeholder)",
              messages.count, withContent, placeholder)

        var grouped: [String: [String: ChatMessage]] = [:]
        for stored in messages {
            let contactAddress = stored.contactAddress
            let txId = stored.message.txId
            guard !txId.isEmpty else {
                continue
            }
            var bucket = grouped[contactAddress, default: [:]]
            if let existing = bucket[txId] {
                bucket[txId] = preferMessage(existing, stored.message)
            } else {
                bucket[txId] = stored.message
            }
            grouped[contactAddress] = bucket
        }

        var loaded: [Conversation] = []
        let allContactAddresses = Set(grouped.keys).union(meta.keys)
        for contactAddress in allContactAddresses {
            let byTxId = grouped[contactAddress] ?? [:]
            let contact = contactsManager.getOrCreateContact(address: contactAddress)
            let conversationId = meta[contactAddress]?.id ?? UUID()
            let sorted = byTxId.values.sorted(by: isMessageOrderedBefore)
            let dedupedFull = dedupeMessages(sorted)
            let dedupedWindow = trimMessagesForMemory(dedupedFull)

            // Compute unread count from lastReadBlockTime if available (CloudKit-synced)
            // This ensures read status from other devices is honored
            let convMeta = meta[contactAddress]
            let lastReadBlockTime = convMeta?.lastReadBlockTime ?? 0
            let unreadCount: Int
            if lastReadBlockTime > 0 {
                // Compute unread as messages with blockTime > lastReadBlockTime (incoming only)
                unreadCount = dedupedFull.filter { msg in
                    !msg.isOutgoing && Int64(msg.blockTime) > lastReadBlockTime
                }.count
            } else {
                // Fallback to stored unreadCount (backward compatibility)
                unreadCount = convMeta?.unreadCount ?? 0
            }

            // Sync archived state between CloudKit (Core Data) and local Contact (UserDefaults)
            if let convMeta = convMeta {
                if convMeta.isArchived != contact.isArchived {
                    // CloudKit state differs from local — adopt CloudKit value
                    // setContactArchived write-through to Core Data is idempotent (no-op if already matching)
                    contactsManager.setContactArchived(address: contactAddress, isArchived: convMeta.isArchived)
                }
            } else if contact.isArchived {
                // One-time migration: Contact archived in UserDefaults but no CDConversation yet
                // Write local state to Core Data so CloudKit picks it up
                messageStore.setConversationArchived(contactAddress: contactAddress, isArchived: true)
            }

            loaded.append(Conversation(id: conversationId, contact: contact, messages: dedupedWindow, unreadCount: unreadCount))
        }

        if !loaded.isEmpty {
            resetOlderHistoryPaginationState(for: allContactAddresses)
            if conversations.isEmpty {
                conversations = loaded.sorted { ($0.lastMessage?.timestamp ?? .distantPast) < ($1.lastMessage?.timestamp ?? .distantPast) }
                rebuildPendingOutgoingQueue()
                return
            }

            var existingByAddress: [String: Conversation] = [:]
            for conversation in conversations {
                existingByAddress[conversation.contact.address] = conversation
            }

            var merged: [Conversation] = []
            var seenAddresses: Set<String> = []

            for loadedConv in loaded {
                let address = loadedConv.contact.address
                seenAddresses.insert(address)
                if var existing = existingByAddress[address] {
                    let mergedMessages = dedupeMessages(existing.messages + loadedConv.messages)
                    let shouldTrim = address != activeConversationAddress
                    let combinedMessages = shouldTrim
                        ? trimMessagesForMemory(mergedMessages)
                        : mergedMessages

                    // Determine unread count:
                    // - If CloudKit has a read status (lastReadBlockTime > 0), use computed count from loaded
                    // - Otherwise prefer in-memory value to prevent race conditions
                    let convMeta = meta[address]
                    let cloudKitLastReadBlockTime = convMeta?.lastReadBlockTime ?? 0
                    let unreadCount: Int
                    if cloudKitLastReadBlockTime > 0 {
                        // CloudKit has read status - recompute unread from combined messages
                        unreadCount = combinedMessages.filter { msg in
                            !msg.isOutgoing && Int64(msg.blockTime) > cloudKitLastReadBlockTime
                        }.count
                    } else {
                        // No CloudKit read status - prefer in-memory value
                        unreadCount = existing.unreadCount
                    }

                    existing = Conversation(
                        id: existing.id,
                        contact: existing.contact,
                        messages: combinedMessages,
                        unreadCount: unreadCount
                    )
                    merged.append(existing)
                } else {
                    merged.append(loadedConv)
                }
            }

            for conversation in conversations where !seenAddresses.contains(conversation.contact.address) {
                merged.append(conversation)
            }

            conversations = merged.sorted { ($0.lastMessage?.timestamp ?? .distantPast) < ($1.lastMessage?.timestamp ?? .distantPast) }
            rebuildPendingOutgoingQueue()
        }
    }

    func isMessageOrderedBefore(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.blockTime != rhs.blockTime {
            return lhs.blockTime < rhs.blockTime
        }
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.id != rhs.id {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.txId < rhs.txId
    }

    func preferMessage(_ existing: ChatMessage, _ candidate: ChatMessage) -> ChatMessage {
        let existingPlaceholder = isPlaceholderContent(existing.content)
        let candidatePlaceholder = isPlaceholderContent(candidate.content)

        if existingPlaceholder != candidatePlaceholder {
            return candidatePlaceholder ? existing : candidate
        }

        if existing.deliveryStatus != candidate.deliveryStatus {
            if candidate.deliveryStatus.priority != existing.deliveryStatus.priority {
                return candidate.deliveryStatus.priority > existing.deliveryStatus.priority ? candidate : existing
            }
        }

        return isMessageOrderedBefore(existing, candidate) ? candidate : existing
    }

    func isPlaceholderContent(_ content: String) -> Bool {
        content == "📤 Sent via another device" || content == "[Encrypted message]"
    }

    func dedupeMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var byId: [UUID: ChatMessage] = [:]
        for message in messages {
            if let existing = byId[message.id] {
                byId[message.id] = preferMessage(existing, message)
            } else {
                byId[message.id] = message
            }
        }

        var byTxId: [String: ChatMessage] = [:]
        for message in byId.values {
            let key = message.txId.isEmpty ? message.id.uuidString : message.txId
            if let existing = byTxId[key] {
                byTxId[key] = preferMessage(existing, message)
            } else {
                byTxId[key] = message
            }
        }
        return Array(byTxId.values).sorted(by: isMessageOrderedBefore)
    }

    /// Reduce in-memory history while preserving protocol-critical/system-critical messages.
    /// Keeps all handshakes and unsent messages, plus a rolling window of recent regular messages.
    func trimMessagesForMemory(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard messages.count > inMemoryConversationWindowSize else { return messages }

        let sticky = messages.filter { message in
            message.messageType == .handshake || message.deliveryStatus != .sent
        }
        let stickyIds = Set(sticky.map(\.id))
        let recent = messages
            .filter { !stickyIds.contains($0.id) }
            .suffix(inMemoryConversationWindowSize)

        return Array((sticky + recent).sorted(by: isMessageOrderedBefore))
    }

    func rebuildPendingOutgoingQueue() {
        pendingOutgoingQueue.removeAll()
        for conversation in conversations {
            let pending = conversation.messages
                .filter { $0.isOutgoing && $0.deliveryStatus != .sent }
                .sorted(by: isMessageOrderedBefore)
            guard !pending.isEmpty else { continue }
            let contactAddress = conversation.contact.address
            pendingOutgoingQueue[contactAddress] = pending.map {
                PendingOutgoingRef(txId: $0.txId, messageType: $0.messageType, timestamp: $0.timestamp)
            }
        }
    }

    func resetOlderHistoryPaginationState<S: Sequence>(for contactAddresses: S) where S.Element == String {
        for address in contactAddresses {
            olderHistoryExhaustedContacts.remove(address)
            olderHistoryPageTasks[address]?.cancel()
            olderHistoryPageTasks[address] = nil
        }
    }

    func observeRemoteStoreChanges() {
        remoteChangeObserver = messageStore.observeRemoteChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleCloudKitImport()
            }
        }
    }

    /// Record when we do a local save to avoid triggering import right after
    func recordLocalSave() {
        lastLocalSaveAt = Date()
    }

    func scheduleCloudKitImport() {
        // Ignore remote-change notifications while app is inactive to avoid
        // background import churn and CoreData CloudKit background task pressure.
        guard UIApplication.shared.applicationState == .active else { return }

        // Skip if this notification is likely from our own recent save
        if let lastSave = lastLocalSaveAt,
           Date().timeIntervalSince(lastSave) < 15.0 {
            return  // Likely our own save, skip
        }

        // Cancel any pending timer
        cloudKitImportTimer?.invalidate()

        // If already have a timer pending, this is a burst - import now
        if cloudKitImportTimer != nil {
            cloudKitImportTimer = nil
            performCloudKitImport()
            return
        }

        // First notification - wait 500ms for more to arrive
        cloudKitImportTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cloudKitImportTimer = nil
                self.performCloudKitImport()
            }
        }
    }

    func performCloudKitImport() {
        // Avoid competing with initial CloudKit setup/import. Let MessageStore
        // complete initial sync first, then remote-change imports can run.
        switch messageStore.cloudKitSyncStatus {
        case .syncing, .notStarted, .disabled, .failed:
            return
        default:
            break
        }

        // Remote-change notifications mean Core Data already has new transactions.
        // Do not force a new CloudKit import cycle here; just refresh and reload.
        if UIApplication.shared.applicationState != .active {
            return
        }

        // Check minimum interval
        if let lastImport = lastCloudKitImportAt,
           Date().timeIntervalSince(lastImport) < cloudKitImportMinInterval {
            return  // Too soon
        }

        lastCloudKitImportAt = Date()
        NSLog("[ChatService] Processing remote store change")

        Task {
            messageStore.refreshFromCloudKit()
            messageStore.processRemoteChanges()
            await MainActor.run {
                self.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
            }
        }
    }

    func observeContacts() {
        contactsCancellable = contactsManager.$contacts
            .receive(on: RunLoop.main)
            .sink { [weak self] contacts in
                self?.syncConversationContacts(with: contacts)
            }
    }

    func observeSettings() {
        settingsCancellable = NotificationCenter.default.publisher(for: .settingsDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let settings = notification.object as? AppSettings else { return }
                self?.cachedSettings = settings
                self?.messageStore.applyRetention(settings.messageRetention)
                self?.saveMessages()
                self?.refreshPushReliabilityPrerequisites()
            }
    }

    func loadPushReliabilityState() {
        if let raw = userDefaults.string(forKey: pushReliabilityStateKey),
           let parsed = PushReliabilityState(rawValue: raw) {
            pushReliabilityState = parsed
        } else {
            pushReliabilityState = .disabled
        }
        pushConsecutiveMisses = max(0, userDefaults.integer(forKey: pushConsecutiveMissesKey))

        if let ts = userDefaults.object(forKey: pushLastCatchUpSyncAtKey) as? Double {
            lastCatchUpSyncAt = Date(timeIntervalSince1970: ts)
        } else {
            lastCatchUpSyncAt = nil
        }

        if let ts = userDefaults.object(forKey: pushLastReregisterAtKey) as? Double {
            lastPushReregisterAt = Date(timeIntervalSince1970: ts)
        } else {
            lastPushReregisterAt = nil
        }

        // Deferred: refreshPushReliabilityPrerequisites() accesses PushNotificationManager.shared,
        // which in turn accesses ChatService.shared.$conversations during its init.
        // Running synchronously here would cause a circular static-init crash.
        Task { @MainActor [weak self] in
            self?.refreshPushReliabilityPrerequisites()
        }
    }

    func persistPushReliabilityState() {
        userDefaults.set(pushReliabilityState.rawValue, forKey: pushReliabilityStateKey)
        userDefaults.set(pushConsecutiveMisses, forKey: pushConsecutiveMissesKey)
        if let lastCatchUpSyncAt {
            userDefaults.set(lastCatchUpSyncAt.timeIntervalSince1970, forKey: pushLastCatchUpSyncAtKey)
        } else {
            userDefaults.removeObject(forKey: pushLastCatchUpSyncAtKey)
        }
        if let lastPushReregisterAt {
            userDefaults.set(lastPushReregisterAt.timeIntervalSince1970, forKey: pushLastReregisterAtKey)
        } else {
            userDefaults.removeObject(forKey: pushLastReregisterAtKey)
        }
    }

    func isPushChannelOperational() -> Bool {
        let settings = currentSettings
        guard settings.notificationMode == .remotePush else { return false }

        let pushManager = PushNotificationManager.shared
        let status = pushManager.permissionStatus
        guard status == .authorized || status == .provisional else { return false }
        guard pushManager.isRegistered else { return false }

        return true
    }

    func refreshPushReliabilityPrerequisites() {
        if !isPushChannelOperational() {
            if pushReliabilityState != .disabled {
                NSLog("[ChatService] Push reliability disabled (push mode not operational)")
            }
            pushReliabilityState = .disabled
            pushConsecutiveMisses = 0
            for task in pushObservationTasks.values {
                task.cancel()
            }
            pushObservationTasks.removeAll()
            pendingPushObservations.removeAll()
            persistPushReliabilityState()
            return
        }

        if pushReliabilityState == .disabled {
            pushReliabilityState = .unknown
            pushConsecutiveMisses = 0
            NSLog("[ChatService] Push reliability moved to unknown (operational)")
            persistPushReliabilityState()
        }
    }

    func prunePushReliabilityCaches(now: Date) {
        let cutoff = now.addingTimeInterval(-pushObservationRetention)
        pushSeenByTxId = pushSeenByTxId.filter { $0.value >= cutoff }

        let staleObservations = pendingPushObservations.values
            .filter { $0.observedAt < cutoff }
            .map(\.txId)
        for txId in staleObservations {
            pendingPushObservations.removeValue(forKey: txId)
            if let task = pushObservationTasks.removeValue(forKey: txId) {
                task.cancel()
            }
        }
    }

    func shouldTrackPushReliability(for senderAddress: String) -> Bool {
        let normalized = senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let settings = currentSettings
        guard settings.notificationMode == .remotePush else { return false }

        let eligible = Set(pushEligibleConversationAddresses(settings: settings))
        guard eligible.contains(normalized) else { return false }

        let contact = contactsManager.getContact(byAddress: normalized)
        return settings.shouldDeliverIncomingNotification(for: contact)
    }

    func trackIncomingUtxoForPushReliability(txId: String, senderAddress: String) {
        refreshPushReliabilityPrerequisites()
        guard pushReliabilityState != .disabled else { return }
        guard shouldTrackPushReliability(for: senderAddress) else { return }

        let normalizedTxId = txId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTxId.isEmpty else { return }

        let now = Date()
        prunePushReliabilityCaches(now: now)

        if let pushSeenAt = pushSeenByTxId[normalizedTxId],
           pushSeenAt.timeIntervalSince(now) >= -pushLeadMatchTolerance {
            applyPushObservationOutcome(
                txId: normalizedTxId,
                senderAddress: senderAddress,
                didReceivePush: true
            )
            return
        }

        if pendingPushObservations[normalizedTxId] != nil {
            return
        }

        pendingPushObservations[normalizedTxId] = PendingPushObservation(
            txId: normalizedTxId,
            senderAddress: senderAddress,
            observedAt: now
        )
        schedulePushObservationEvaluation(for: normalizedTxId)
    }

    func schedulePushObservationEvaluation(for txId: String) {
        if let task = pushObservationTasks.removeValue(forKey: txId) {
            task.cancel()
        }
        let delayNs = UInt64(pushObservationGraceInterval * 1_000_000_000)
        pushObservationTasks[txId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            self?.evaluatePendingPushObservation(txId: txId)
        }
    }

    func evaluatePendingPushObservation(txId: String) {
        refreshPushReliabilityPrerequisites()
        guard pushReliabilityState != .disabled else { return }

        guard let observation = pendingPushObservations.removeValue(forKey: txId) else {
            pushObservationTasks.removeValue(forKey: txId)
            return
        }

        if let task = pushObservationTasks.removeValue(forKey: txId) {
            task.cancel()
        }

        guard shouldTrackPushReliability(for: observation.senderAddress) else {
            return
        }

        let didReceivePush: Bool
        if let pushSeenAt = pushSeenByTxId[txId] {
            didReceivePush = pushSeenAt.timeIntervalSince(observation.observedAt) >= -pushLeadMatchTolerance
        } else {
            didReceivePush = false
        }

        applyPushObservationOutcome(
            txId: txId,
            senderAddress: observation.senderAddress,
            didReceivePush: didReceivePush
        )
    }

    func applyPushObservationOutcome(
        txId: String,
        senderAddress: String,
        didReceivePush: Bool
    ) {
        refreshPushReliabilityPrerequisites()
        guard pushReliabilityState != .disabled else { return }

        if didReceivePush {
            pushConsecutiveMisses = 0
            if pushReliabilityState != .reliable {
                transitionPushReliabilityState(
                    to: .reliable,
                    reason: "push matched tx \(String(txId.prefix(12))) from \(String(senderAddress.suffix(10)))"
                )
            } else {
                persistPushReliabilityState()
            }
            return
        }

        pushConsecutiveMisses += 1
        NSLog("[ChatService] Push miss for tx=%@ sender=%@ misses=%d",
              String(txId.prefix(12)),
              String(senderAddress.suffix(10)),
              pushConsecutiveMisses)
        if pushConsecutiveMisses >= 3 {
            transitionPushReliabilityState(
                to: .unreliable,
                reason: "3 consecutive push misses"
            )
        } else {
            persistPushReliabilityState()
        }
    }

    func transitionPushReliabilityState(to newState: PushReliabilityState, reason: String) {
        guard pushReliabilityState != newState else { return }
        let oldState = pushReliabilityState
        pushReliabilityState = newState
        if newState == .reliable || newState == .disabled {
            pushConsecutiveMisses = 0
        }
        persistPushReliabilityState()

        NSLog("[ChatService] Push reliability state %@ -> %@ (%@)",
              oldState.rawValue,
              newState.rawValue,
              reason)

        if newState == .unreliable {
            Task { [weak self] in
                await self?.handlePushMarkedUnreliable(reason: reason)
            }
        }
    }

    func handlePushMarkedUnreliable(reason: String) async {
        await maybeRunCatchUpSync(trigger: .pushMarkedUnreliable, force: true)

        let now = Date()
        if let lastPushReregisterAt,
           now.timeIntervalSince(lastPushReregisterAt) < pushReregisterCooldown {
            NSLog("[ChatService] Skipping push re-register - cooldown active")
            return
        }

        lastPushReregisterAt = now
        persistPushReliabilityState()
        await PushNotificationManager.shared.forceReregister(reason: reason)
    }

    func handleCloudKitImportResult(txId: String, didImport: Bool) async {
        guard messageStore.hasMessageWithContent(txId: txId) == false else {
            cloudKitImportFirstAttemptAt.removeValue(forKey: txId)
            cloudKitImportLastObservedAt.removeValue(forKey: txId)
            cloudKitImportRetryTokenByTxId.removeValue(forKey: txId)
            return
        }

        let firstAttempt = cloudKitImportFirstAttemptAt[txId] ?? Date()
        cloudKitImportFirstAttemptAt[txId] = firstAttempt
        let elapsed = Date().timeIntervalSince(firstAttempt)
        if elapsed >= cloudKitImportMaxWaitSeconds {
            NSLog("[ChatService] CloudKit import wait exhausted for %@ after %.0fs",
                  String(txId.prefix(12)), elapsed)
            cloudKitImportFirstAttemptAt.removeValue(forKey: txId)
            cloudKitImportLastObservedAt.removeValue(forKey: txId)
            cloudKitImportRetryTokenByTxId.removeValue(forKey: txId)
            return
        }

        var delaySeconds: TimeInterval = didImport ? 6.0 : 2.0
        var retryAfterDate = cloudKitImportLastObservedAt[txId] ?? firstAttempt
        var retryReason = didImport ? "observed but content missing" : "timed out"

        if didImport, let latestImport = messageStore.latestCloudKitImportEndDate {
            if let previousImport = cloudKitImportLastObservedAt[txId], latestImport <= previousImport {
                // We only saw the same import watermark again; wait a bit longer and
                // require a newer import cycle on retry.
                delaySeconds = 8.0
                retryAfterDate = previousImport
                retryReason = "observed stale import"
            } else {
                cloudKitImportLastObservedAt[txId] = latestImport
                retryAfterDate = latestImport
            }
        }

        NSLog("[ChatService] CloudKit import %@ for %@ - retrying in %.1fs (elapsed %.0fs, after=%@)",
              retryReason,
              String(txId.prefix(12)),
              delaySeconds,
              elapsed,
              retryAfterDate.description)

        let retryToken = UUID()
        cloudKitImportRetryTokenByTxId[txId] = retryToken

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self else { return }
            guard self.cloudKitImportRetryTokenByTxId[txId] == retryToken else { return }
            let didRetryImport = await MessageStore.shared.fetchCloudKitChanges(
                reason: "self-stash-retry-\(String(txId.prefix(12)))",
                after: retryAfterDate,
                timeout: 12.0
            )
            guard self.cloudKitImportRetryTokenByTxId[txId] == retryToken else { return }
            self.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
            await self.handleCloudKitImportResult(txId: txId, didImport: didRetryImport)
        }
    }

    func syncConversationContacts(with contacts: [Contact]) {
        var byId: [UUID: Contact] = [:]
        byId.reserveCapacity(contacts.count)
        var byAddress: [String: Contact] = [:]
        byAddress.reserveCapacity(contacts.count)
        for contact in contacts {
            byId[contact.id] = contact
            byAddress[contact.address.lowercased()] = contact
        }

        let updated = conversations.map { conversation -> Conversation in
            let refreshed = byId[conversation.contact.id] ??
                byAddress[conversation.contact.address.lowercased()]
            guard let refreshed else {
                return conversation
            }
            if refreshed == conversation.contact {
                return conversation
            }
            return Conversation(
                id: conversation.id,
                contact: refreshed,
                messages: conversation.messages,
                unreadCount: conversation.unreadCount
            )
        }
        if updated != conversations {
            conversations = updated
        }
    }

    func currentTimeMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    func handshakeSyncObjectKey(direction: String, address: String) -> String {
        "hs|\(direction)|\(address.lowercased())"
    }

    func contextualSyncObjectKey(
        direction: String,
        queryAddress: String,
        alias: String,
        contactAddress: String? = nil
    ) -> String {
        var key = "ctx|\(direction)|\(queryAddress.lowercased())|\(alias)"
        if let contactAddress, !contactAddress.isEmpty {
            key += "|\(contactAddress.lowercased())"
        }
        return key
    }

    func syncStartBlockTime(for objectKey: String, fallbackBlockTime: UInt64, nowMs: UInt64) -> UInt64 {
        guard let cursor = syncObjectCursors[objectKey], cursor.lastFetchedBlockTime > 0 else {
            return fallbackBlockTime
        }

        let lastFetchedBlockTime = cursor.lastFetchedBlockTime
        if nowMs > lastFetchedBlockTime, nowMs - lastFetchedBlockTime > syncReorgBufferMs {
            return lastFetchedBlockTime == UInt64.max ? UInt64.max : lastFetchedBlockTime + 1
        }

        return lastFetchedBlockTime > syncReorgBufferMs ? lastFetchedBlockTime - syncReorgBufferMs : 0
    }

    func advanceSyncCursor(for objectKey: String, maxBlockTime: UInt64?) {
        guard let maxBlockTime, maxBlockTime > 0 else { return }
        let previous = syncObjectCursors[objectKey]?.lastFetchedBlockTime ?? 0
        guard maxBlockTime > previous else { return }
        syncObjectCursors[objectKey] = SyncObjectCursor(lastFetchedBlockTime: maxBlockTime)
        syncObjectCursorsDirty = true
        if !isSyncInProgress {
            saveSyncObjectCursorsIfNeeded()
        }
    }

    func clearSyncObjectCursors() {
        syncObjectCursors = [:]
        syncObjectCursorsDirty = false
        userDefaults.removeObject(forKey: syncCursorsKey)
    }

    func loadSyncObjectCursors() {
        guard let data = userDefaults.data(forKey: syncCursorsKey),
              let decoded = try? JSONDecoder().decode([String: SyncObjectCursor].self, from: data) else {
            return
        }
        syncObjectCursors = decoded
    }

    func saveSyncObjectCursorsIfNeeded() {
        guard syncObjectCursorsDirty else { return }
        guard let data = try? JSONEncoder().encode(syncObjectCursors) else { return }
        userDefaults.set(data, forKey: syncCursorsKey)
        syncObjectCursorsDirty = false
    }

    func updateLastPollTime(_ blockTime: UInt64) {
        if isSyncInProgress {
            if let current = syncMaxBlockTime {
                syncMaxBlockTime = max(current, blockTime)
            } else {
                syncMaxBlockTime = blockTime
            }
            return
        }
        lastPollTime = blockTime
        userDefaults.set(Int(blockTime), forKey: lastPollTimeKey)
    }

    func scheduleBadgeUpdate() {
        badgeUpdateTask?.cancel()
        badgeUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            updateAppBadge()
        }
    }

    func updateAppBadge() {
        let totalUnread = conversations.reduce(0) { $0 + max(0, $1.unreadCount) }
        SharedDataManager.setUnreadCount(totalUnread)
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(totalUnread)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = totalUnread
        }
    }

    func beginSyncBlockTime() {
        isSyncInProgress = true
        syncMaxBlockTime = lastPollTime
    }

    func endSyncBlockTime(success: Bool) {
        defer {
            isSyncInProgress = false
            syncMaxBlockTime = nil
        }

        if success, let candidate = syncMaxBlockTime, candidate > lastPollTime {
            lastPollTime = candidate
            userDefaults.set(Int(candidate), forKey: lastPollTimeKey)
        }
        if needsMessageStoreSyncAfterBatch {
            needsMessageStoreSyncAfterBatch = false
            saveMessages()
        }
        saveSyncObjectCursorsIfNeeded()
        flushPendingLastMessageUpdates()
    }

    func messageEncryptionKey() -> SymmetricKey? {
        guard var privateKey = WalletManager.shared.getPrivateKey() else { return nil }
        var keyData = CryptoUtils.sha256(privateKey)
        privateKey.zeroOut()
        let key = SymmetricKey(data: keyData)
        keyData.zeroOut()
        return key
    }

    func scheduleMessageStoreSync(triggerExport: Bool = false) {
        if triggerExport {
            pendingCloudKitExport = true
        }
        if let lastScheduled = lastMessageStoreSyncScheduledAt,
           !isSyncInProgress,
           Date().timeIntervalSince(lastScheduled) < messageStoreSyncMinInterval,
           !pendingCloudKitExport {
            return
        }
        messageSyncTask?.cancel()
        lastMessageStoreSyncScheduledAt = Date()
        messageSyncTask = Task { [weak self] in
            // Reduced delay from 600ms to 150ms to minimize race condition window
            // where in-memory changes (e.g., marking as read) get overwritten by
            // stale Core Data reloads before save completes
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            guard let key = self.messageEncryptionKey() else { return }
            let shouldExport = self.pendingCloudKitExport
            let conversationsSnapshot = await MainActor.run { self.conversations }
            let dirtyAddresses = await MainActor.run { () -> Set<String> in
                let snapshot = self.dirtyConversationAddresses
                self.dirtyConversationAddresses.removeAll()
                return snapshot
            }
            let now = Date()
            let shouldRunMaintenance = now.timeIntervalSince(self.lastFullStoreMaintenanceAt) >= self.fullStoreMaintenanceInterval
            let conversationsToSync: [Conversation]
            let performMaintenance: Bool
            if shouldRunMaintenance {
                conversationsToSync = conversationsSnapshot
                performMaintenance = true
            } else if !dirtyAddresses.isEmpty {
                conversationsToSync = conversationsSnapshot.filter { dirtyAddresses.contains($0.contact.address) }
                performMaintenance = false
            } else {
                conversationsToSync = []
                performMaintenance = false
            }

            if conversationsToSync.isEmpty {
                if shouldExport {
                    await MainActor.run {
                        self.messageStore.triggerCloudKitExport()
                        self.pendingCloudKitExport = false
                    }
                } else {
                    await MainActor.run {
                        self.pendingCloudKitExport = false
                    }
                }
                return
            }

            let didWrite = await self.messageStore.syncFromConversations(
                conversationsToSync,
                encryptionKey: key,
                retention: SettingsViewModel.loadSettings().messageRetention,
                performMaintenance: performMaintenance
            )
            if performMaintenance {
                await MainActor.run {
                    self.lastFullStoreMaintenanceAt = now
                }
            }

            if didWrite {
                // Record that we just did a local save (to avoid triggering import from our own changes)
                await MainActor.run {
                    self.recordLocalSave()
                }
            }

            // Trigger CloudKit export for outgoing content (debounced)
            if shouldExport && didWrite {
                await MainActor.run {
                    NSLog("[ChatService] Triggering CloudKit export after message store sync")
                    NSLog("[ChatService] Requesting CloudKit export after message store sync")
                    self.messageStore.triggerCloudKitExport()
                    self.pendingCloudKitExport = false
                }
            } else if shouldExport {
                await MainActor.run {
                    self.pendingCloudKitExport = false
                }
            }
        }
    }

    func saveMessages(triggerExport: Bool = false) {
        scheduleMessageStoreSync(triggerExport: triggerExport)
    }

    func markConversationDirty(_ contactAddress: String) {
        dirtyConversationAddresses.insert(contactAddress)
    }

    func enqueuePendingOutgoing(contactAddress: String, pendingTxId: String, messageType: ChatMessage.MessageType, timestamp: Date) {
        var queue = pendingOutgoingQueue[contactAddress, default: []]
        if !queue.contains(where: { $0.txId == pendingTxId }) {
            queue.append(PendingOutgoingRef(txId: pendingTxId, messageType: messageType, timestamp: timestamp))
            queue.sort { $0.timestamp < $1.timestamp }
            pendingOutgoingQueue[contactAddress] = queue
        }
    }

    func removePendingOutgoing(contactAddress: String, pendingTxId: String) {
        guard var queue = pendingOutgoingQueue[contactAddress] else { return }
        queue.removeAll { $0.txId == pendingTxId }
        if queue.isEmpty {
            pendingOutgoingQueue.removeValue(forKey: contactAddress)
        } else {
            pendingOutgoingQueue[contactAddress] = queue
        }
    }

    func removePendingOutgoingGlobally(_ pendingTxId: String) {
        for (contactAddress, queue) in pendingOutgoingQueue {
            let filtered = queue.filter { $0.txId != pendingTxId }
            if filtered.isEmpty {
                pendingOutgoingQueue.removeValue(forKey: contactAddress)
            } else {
                pendingOutgoingQueue[contactAddress] = filtered
            }
        }
    }

    func popPendingOutgoing(contactAddress: String, messageType: ChatMessage.MessageType) -> String? {
        guard var queue = pendingOutgoingQueue[contactAddress] else { return nil }
        if let index = queue.firstIndex(where: { $0.messageType == messageType }) {
            let ref = queue.remove(at: index)
            if queue.isEmpty {
                pendingOutgoingQueue.removeValue(forKey: contactAddress)
            } else {
                pendingOutgoingQueue[contactAddress] = queue
            }
            return ref.txId
        }
        return nil
    }

    func updatePendingFromQueue(contactAddress: String, newTxId: String, messageType: ChatMessage.MessageType) -> Bool {
        guard let queue = pendingOutgoingQueue[contactAddress], !queue.isEmpty else {
            return false
        }
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else {
            return false
        }
        let pendingSet = Set(conversations[convIndex].messages.map { $0.txId })
        for ref in queue where ref.messageType == messageType {
            if pendingSet.contains(ref.txId) {
                if updatePendingMessage(ref.txId, withRealTxId: newTxId, contactAddress: contactAddress) {
                    return true
                }
            }
        }
        return false
    }

    func queueLastMessageUpdate(contactId: UUID, date: Date) {
        if let existing = pendingLastMessageUpdates[contactId], existing >= date {
            return
        }
        pendingLastMessageUpdates[contactId] = date
        pendingLastMessageUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingLastMessageUpdates()
        }
        pendingLastMessageUpdateWorkItem = workItem
        let delay = isSyncInProgress ? max(lastMessageBatchDelay, 1.5) : lastMessageBatchDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func flushPendingLastMessageUpdates() {
        guard !pendingLastMessageUpdates.isEmpty else { return }
        let updates = pendingLastMessageUpdates
        pendingLastMessageUpdates.removeAll()
        for (contactId, date) in updates {
            contactsManager.updateContactLastMessage(contactId, at: date)
        }
    }

    // MARK: - Draft Storage

    func loadMessageDrafts() {
        guard let data = userDefaults.data(forKey: draftsKey),
              let drafts = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        messageDrafts = drafts
    }

    func saveMessageDrafts() {
        guard let data = try? JSONEncoder().encode(messageDrafts) else { return }
        userDefaults.set(data, forKey: draftsKey)
    }

    func draft(for contactAddress: String) -> String {
        messageDrafts[contactAddress] ?? ""
    }

    func setDraft(_ text: String, for contactAddress: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            messageDrafts.removeValue(forKey: contactAddress)
        } else {
            messageDrafts[contactAddress] = text
        }
        saveMessageDrafts()
    }

    func clearDraft(for contactAddress: String) {
        if messageDrafts.removeValue(forKey: contactAddress) != nil {
            saveMessageDrafts()
        }
    }

    // MARK: - Alias Storage

    func loadConversationAliases() {
        guard let data = userDefaults.data(forKey: aliasesKey) else {
            return
        }
        if let decoded = decodeAliasSetMap(from: data) {
            conversationAliases = decoded
        } else if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            conversationAliases = legacy.mapValues { [$0] }.mapValues { Set($0) }
            conversationPrimaryAliases = legacy
        }
        if let primaryData = userDefaults.data(forKey: conversationPrimaryAliasesKey),
           let primary = try? JSONDecoder().decode([String: String].self, from: primaryData) {
            conversationPrimaryAliases = primary
        }
        if let updatedData = userDefaults.data(forKey: conversationAliasUpdatedAtKey),
           let updated = try? JSONDecoder().decode([String: UInt64].self, from: updatedData) {
            conversationAliasUpdatedAt = updated
        }
        rebuildPrimaryAliasesIfNeeded()
        print("[ChatService] Loaded \(conversationAliases.count) conversation aliases")
    }

    func saveConversationAliases() {
        guard let data = try? JSONEncoder().encode(encodeAliasSetMap(conversationAliases)) else { return }
        userDefaults.set(data, forKey: aliasesKey)
        if let primaryData = try? JSONEncoder().encode(conversationPrimaryAliases) {
            userDefaults.set(primaryData, forKey: conversationPrimaryAliasesKey)
        }
        if let updatedData = try? JSONEncoder().encode(conversationAliasUpdatedAt) {
            userDefaults.set(updatedData, forKey: conversationAliasUpdatedAtKey)
        }
        Task {
            await PushNotificationManager.shared.updateWatchedAddresses()
        }
    }

    func knownIncomingAliases() -> [String] {
        let addresses = Set(conversationPrimaryAliases.keys).union(conversationAliases.keys).union(routingStates.keys)
        return knownIncomingAliases(forAddresses: addresses)
    }

    func knownIncomingAliases(forAddresses addresses: Set<String>) -> [String] {
        let normalizedAddresses = Set(addresses.map { $0.lowercased() })
        guard !normalizedAddresses.isEmpty else { return [] }

        var aliasSet = Set<String>()
        for (address, alias) in conversationPrimaryAliases where normalizedAddresses.contains(address.lowercased()) {
            aliasSet.insert(alias)
        }
        for (address, set) in conversationAliases where normalizedAddresses.contains(address.lowercased()) {
            if let selected = set.sorted().first {
                aliasSet.insert(selected)
            }
        }
        // Include deterministic incoming aliases from routing states
        for (address, state) in routingStates where normalizedAddresses.contains(address.lowercased()) {
            aliasSet.insert(state.deterministicMyAlias)
        }
        return Array(aliasSet)
    }

    func loadOurAliases() {
        guard let data = userDefaults.data(forKey: ourAliasesKey) else {
            return
        }
        if let decoded = decodeAliasSetMap(from: data) {
            ourAliases = decoded
        } else if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            ourAliases = legacy.mapValues { [$0] }.mapValues { Set($0) }
            ourPrimaryAliases = legacy
        }
        if let primaryData = userDefaults.data(forKey: ourPrimaryAliasesKey),
           let primary = try? JSONDecoder().decode([String: String].self, from: primaryData) {
            ourPrimaryAliases = primary
        }
        if let updatedData = userDefaults.data(forKey: ourAliasUpdatedAtKey),
           let updated = try? JSONDecoder().decode([String: UInt64].self, from: updatedData) {
            ourAliasUpdatedAt = updated
        }
        rebuildPrimaryAliasesIfNeeded()
        print("[ChatService] Loaded \(ourAliases.count) of our aliases")
    }

    func loadConversationIds() {
        guard let data = userDefaults.data(forKey: conversationIdsKey),
              let ids = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        conversationIds = ids
        print("[ChatService] Loaded \(ids.count) conversation ids")
    }

    func saveOurAliases() {
        guard let data = try? JSONEncoder().encode(encodeAliasSetMap(ourAliases)) else { return }
        userDefaults.set(data, forKey: ourAliasesKey)
        if let primaryData = try? JSONEncoder().encode(ourPrimaryAliases) {
            userDefaults.set(primaryData, forKey: ourPrimaryAliasesKey)
        }
        if let updatedData = try? JSONEncoder().encode(ourAliasUpdatedAt) {
            userDefaults.set(updatedData, forKey: ourAliasUpdatedAtKey)
        }
    }

    func saveConversationIds() {
        guard let data = try? JSONEncoder().encode(conversationIds) else { return }
        userDefaults.set(data, forKey: conversationIdsKey)
    }

    // MARK: - Routing State Persistence

    func loadRoutingStates() {
        guard let data = userDefaults.data(forKey: routingStatesKey) else { return }
        if let decoded = try? JSONDecoder().decode([String: ConversationRoutingState].self, from: data) {
            routingStates = decoded
            print("[ChatService] Loaded \(routingStates.count) routing states")
        }
    }

    func saveRoutingStates() {
        guard let data = try? JSONEncoder().encode(routingStates) else { return }
        userDefaults.set(data, forKey: routingStatesKey)
    }

    /// Migrate legacy aliases to deterministic routing states.
    /// Called once after self-stash recovery completes (requires private key).
    func migrateToDeterministicAliases(privateKey: Data) {
        guard !userDefaults.bool(forKey: deterministicMigrationDoneKey) else { return }

        let allContactAddresses = Set(conversationAliases.keys).union(ourAliases.keys).union(
            contactsManager.activeContacts.map { $0.address }
        )

        var migrated = 0
        for address in allContactAddresses {
            if routingStates[address] != nil { continue }  // already has routing state

            let hasLegacyIncoming = !(conversationAliases[address]?.isEmpty ?? true)
            let hasLegacyOutgoing = !(ourAliases[address]?.isEmpty ?? true)
            let hasLegacy = hasLegacyIncoming || hasLegacyOutgoing

            // Derive deterministic pair
            guard let myAlias = try? DeterministicAlias.deriveMyAlias(privateKey: privateKey, theirAddress: address),
                  let theirAlias = try? DeterministicAlias.deriveTheirAlias(privateKey: privateKey, theirAddress: address) else {
                NSLog("[ChatService] Failed to derive deterministic aliases for %@", String(address.suffix(10)))
                continue
            }

            let state = ConversationRoutingState(
                contactAddress: address,
                deterministicMyAlias: myAlias,
                deterministicTheirAlias: theirAlias,
                legacyIncomingAliases: conversationAliases[address] ?? [],
                legacyOutgoingAliases: ourAliases[address] ?? [],
                mode: hasLegacy ? .hybrid : .deterministicOnly,
                peerSupportsDeterministic: false,
                lastLegacyIncomingAtMs: nil,
                lastDeterministicIncomingAtMs: nil
            )
            routingStates[address] = state
            migrated += 1
        }

        if migrated > 0 {
            saveRoutingStates()
            NSLog("[ChatService] Migrated %d contacts to deterministic routing states", migrated)
        }
        userDefaults.set(true, forKey: deterministicMigrationDoneKey)
    }

    /// Ensure a routing state exists for a contact. Creates one on-demand if needed.
    func ensureRoutingState(for address: String, privateKey: Data?) {
        guard routingStates[address] == nil, let privKey = privateKey else { return }
        guard let myAlias = try? DeterministicAlias.deriveMyAlias(privateKey: privKey, theirAddress: address),
              let theirAlias = try? DeterministicAlias.deriveTheirAlias(privateKey: privKey, theirAddress: address) else {
            return
        }

        let hasLegacyIncoming = !(conversationAliases[address]?.isEmpty ?? true)
        let hasLegacyOutgoing = !(ourAliases[address]?.isEmpty ?? true)

        routingStates[address] = ConversationRoutingState(
            contactAddress: address,
            deterministicMyAlias: myAlias,
            deterministicTheirAlias: theirAlias,
            legacyIncomingAliases: conversationAliases[address] ?? [],
            legacyOutgoingAliases: ourAliases[address] ?? [],
            mode: (hasLegacyIncoming || hasLegacyOutgoing) ? .hybrid : .deterministicOnly,
            peerSupportsDeterministic: false,
            lastLegacyIncomingAtMs: nil,
            lastDeterministicIncomingAtMs: nil
        )
        saveRoutingStates()
    }

    /// Get all incoming aliases (deterministic + legacy) for a contact
    func incomingAliases(for address: String) -> Set<String> {
        guard let state = routingStates[address] else {
            return conversationAliases[address] ?? []
        }
        var aliases: Set<String> = [state.deterministicMyAlias]
        if state.mode != .deterministicOnly {
            aliases.formUnion(state.legacyIncomingAliases)
        }
        return aliases
    }

    /// Get all outgoing fetch aliases (deterministic + legacy) for syncing our sent messages
    func outgoingFetchAliases(for address: String) -> Set<String> {
        guard let state = routingStates[address] else {
            return ourAliases[address] ?? []
        }
        var aliases: Set<String> = [state.deterministicTheirAlias]
        if state.mode != .deterministicOnly {
            aliases.formUnion(state.legacyOutgoingAliases)
        }
        return aliases
    }

    /// Get the outgoing alias to use when sending a new message
    func outgoingAlias(for address: String) -> String {
        guard let state = routingStates[address] else {
            // Fallback to legacy if no routing state
            return primaryOurAlias(for: address) ?? generateAlias()
        }
        switch state.mode {
        case .deterministicOnly:
            return state.deterministicTheirAlias
        case .hybrid:
            return state.peerSupportsDeterministic
                ? state.deterministicTheirAlias
                : state.legacyOutgoingAliases.sorted().first ?? state.deterministicTheirAlias
        case .legacyOnly:
            return state.legacyOutgoingAliases.sorted().first ?? state.deterministicTheirAlias
        }
    }

    /// Check if a routing state exists for a contact
    func hasRoutingState(for address: String) -> Bool {
        routingStates[address] != nil
    }

    func decodeAliasSetMap(from data: Data) -> [String: Set<String>]? {
        if let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return decoded.mapValues { Set($0) }
        }
        return nil
    }

    func encodeAliasSetMap(_ map: [String: Set<String>]) -> [String: [String]] {
        map.mapValues { Array($0) }
    }

    func rebuildPrimaryAliasesIfNeeded() {
        for (address, aliases) in conversationAliases {
            if let primary = conversationPrimaryAliases[address] {
                if !aliases.contains(primary) {
                    var updated = aliases
                    updated.insert(primary)
                    conversationAliases[address] = updated
                }
                continue
            }
            if let selected = aliases.sorted().first {
                conversationPrimaryAliases[address] = selected
            }
        }
        for (address, aliases) in ourAliases {
            if let primary = ourPrimaryAliases[address] {
                if !aliases.contains(primary) {
                    var updated = aliases
                    updated.insert(primary)
                    ourAliases[address] = updated
                }
                continue
            }
            if let selected = aliases.sorted().first {
                ourPrimaryAliases[address] = selected
            }
        }
    }

    func loadPendingSelfStash() {
        guard let data = userDefaults.data(forKey: pendingSelfStashKey),
              let jobs = try? JSONDecoder().decode([PendingSelfStash].self, from: data) else {
            pendingSelfStash = []
            return
        }
        pendingSelfStash = jobs
    }

    func savePendingSelfStash() {
        guard let data = try? JSONEncoder().encode(pendingSelfStash) else { return }
        userDefaults.set(data, forKey: pendingSelfStashKey)
    }

    func loadDeclinedContacts() {
        guard let data = userDefaults.data(forKey: declinedContactsKey),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            declinedContacts = []
            return
        }
        declinedContacts = Set(list)
    }

    func saveDeclinedContacts() {
        let list = Array(declinedContacts)
        guard let data = try? JSONEncoder().encode(list) else { return }
        userDefaults.set(data, forKey: declinedContactsKey)
    }

    func declineContact(_ address: String) {
        declinedContacts.insert(address)
        saveDeclinedContacts()
    }

    func clearDeclined(_ address: String) {
        if declinedContacts.remove(address) != nil {
            saveDeclinedContacts()
        }
    }

    // MARK: - Decryption (nonisolated to run off main thread)

    /// Decrypt handshake payload on background thread
}
