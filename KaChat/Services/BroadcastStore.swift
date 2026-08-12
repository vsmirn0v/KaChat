import Foundation
import CoreData
import CryptoKit

/// Plain, in-memory representation of a joined broadcast channel (mirrors Android's
/// `BroadcastChannelEntity`).
struct BroadcastChannel: Identifiable, Equatable {
    var id: String { channelName }
    let channelName: String
    var alwaysListen: Bool
    var notifyEnabled: Bool
    var retentionMillis: Int64
    var joinedAt: Date?
}

/// Plain, in-memory representation of a broadcast message (mirrors Android's
/// `BroadcastMessageEntity`). `id` is the real Kaspa txId once confirmed, or a
/// synthetic `pending_<uuid>` while the send is in flight.
struct BroadcastMessage: Identifiable, Equatable {
    enum DeliveryStatus: String {
        case sent
        case pending
        case failed
    }

    let id: String
    let channelName: String
    let senderAddress: String
    let content: String
    let blockTime: Int64
    let deliveryStatus: DeliveryStatus
}

/// Local-only, per-wallet store for KaChat 2.0 Broadcast channel data.
/// Unlike `MessageStore`, this is intentionally NOT synced via CloudKit: broadcast
/// channels are public, on-chain, and ephemeral (retention-pruned locally), matching
/// the Android client's local-only Room tables for the same feature.
final class BroadcastStore {
    static let shared = BroadcastStore()

    /// Hard cap on how long any channel's messages are retained locally, regardless
    /// of the per-channel setting - matches Android's `BroadcastRetention.MAX_MILLIS`.
    static let maxRetentionMillis: Int64 = 3 * 24 * 60 * 60 * 1000

    /// Default retention applied when a channel is first joined - a conservative starting point
    /// for a fresh install; users can raise it up to `maxRetentionMillis` via the retention sheet.
    static let defaultRetentionMillis: Int64 = 3 * 60 * 60 * 1000

    private let container: NSPersistentContainer
    private(set) var currentWalletAddress: String?
    private var isLoaded = false

    private init() {
        container = NSPersistentContainer(name: "KaChatBroadcasts", managedObjectModel: Self.makeModel())
        container.persistentStoreDescriptions = []
    }

    private func storeURL(forWallet walletAddress: String) -> URL {
        let hash = SHA256.hash(data: walletAddress.data(using: .utf8) ?? Data())
        let hashPrefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent("KaChatBroadcasts-\(hashPrefix).sqlite")
    }

    /// Switch to a different wallet's broadcast store (own SQLite file per wallet,
    /// following `MessageStore`'s per-wallet file-naming convention).
    func setCurrentWallet(_ walletAddress: String?) {
        guard walletAddress != currentWalletAddress else { return }

        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }

        currentWalletAddress = walletAddress
        isLoaded = false

        guard let walletAddress else { return }

        let description = NSPersistentStoreDescription(url: storeURL(forWallet: walletAddress))
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { [weak self] _, error in
            guard let self else { return }
            if let error {
                AppLog.log("[BroadcastStore] Failed to load store: %@", error.localizedDescription)
                return
            }
            self.isLoaded = true
            self.container.viewContext.automaticallyMergesChangesFromParent = true
            self.container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        }
    }

    private var viewContext: NSManagedObjectContext { container.viewContext }

    // MARK: - Channels

    @discardableResult
    func joinChannel(_ rawName: String) -> Bool {
        let name = BroadcastChannelName.normalize(rawName)
        guard BroadcastChannelName.isValid(name), isLoaded else { return false }
        let context = viewContext
        var joined = false
        context.performAndWait {
            if fetchChannel(name: name, in: context) == nil {
                let channel = CDBroadcastChannel(context: context)
                channel.channelName = name
                channel.alwaysListen = false
                channel.notifyEnabled = false
                channel.retentionMillis = Self.defaultRetentionMillis
                channel.joinedAt = Date()
                save(context)
            }
            joined = true
        }
        return joined
    }

    func leaveChannel(_ name: String) {
        let normalized = BroadcastChannelName.normalize(name)
        let context = viewContext
        context.performAndWait {
            guard let channel = fetchChannel(name: normalized, in: context) else { return }
            context.delete(channel)
            save(context)
        }
    }

    func setAlwaysListen(_ enabled: Bool, forChannel name: String) {
        updateChannel(name) { channel in
            channel.alwaysListen = enabled
            if !enabled { channel.notifyEnabled = false }
        }
    }

    func setNotifyEnabled(_ enabled: Bool, forChannel name: String) {
        updateChannel(name) { channel in
            channel.notifyEnabled = enabled
            if enabled { channel.alwaysListen = true }
        }
    }

    func setRetentionMillis(_ millis: Int64, forChannel name: String) {
        let capped = min(millis, Self.maxRetentionMillis)
        updateChannel(name) { $0.retentionMillis = capped }
    }

    private func updateChannel(_ name: String, _ mutate: (CDBroadcastChannel) -> Void) {
        let normalized = BroadcastChannelName.normalize(name)
        let context = viewContext
        context.performAndWait {
            guard let channel = fetchChannel(name: normalized, in: context) else { return }
            mutate(channel)
            save(context)
        }
    }

    func joinedChannels() -> [BroadcastChannel] {
        guard isLoaded else { return [] }
        var result: [BroadcastChannel] = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDBroadcastChannel>(entityName: CDBroadcastChannel.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "joinedAt", ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            result = rows.map { row in
                BroadcastChannel(
                    channelName: row.channelName,
                    alwaysListen: row.alwaysListen,
                    notifyEnabled: row.notifyEnabled,
                    retentionMillis: row.retentionMillis,
                    joinedAt: row.joinedAt
                )
            }
        }
        return result
    }

    func isJoined(_ name: String) -> Bool {
        let normalized = BroadcastChannelName.normalize(name)
        var found = false
        let context = viewContext
        context.performAndWait {
            found = fetchChannel(name: normalized, in: context) != nil
        }
        return found
    }

    private func fetchChannel(name: String, in context: NSManagedObjectContext) -> CDBroadcastChannel? {
        let request = NSFetchRequest<CDBroadcastChannel>(entityName: CDBroadcastChannel.entityName)
        request.predicate = NSPredicate(format: "channelName == %@", name)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - Messages

    /// Batch insert for indexer-fetched history: ONE async background-context pass for the
    /// whole page instead of a synchronous main-thread performAndWait per row - a resume-time
    /// poll of 200 rows was hard main-thread work exactly while CloudKit import/WAL
    /// checkpointing contend for the store (the app-freeze-after-resume class of bug).
    /// Returns how many rows were actually new.
    func insertMessages(
        _ messages: [(id: String, channel: String, senderAddress: String, content: String, blockTime: Int64)]
    ) async -> Int {
        guard isLoaded, !messages.isEmpty else { return 0 }
        return await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                var inserted = 0
                for message in messages {
                    let normalized = BroadcastChannelName.normalize(message.channel)
                    let request = NSFetchRequest<CDBroadcastMessage>(entityName: CDBroadcastMessage.entityName)
                    request.predicate = NSPredicate(format: "id == %@", message.id)
                    request.fetchLimit = 1
                    guard (try? context.fetch(request))?.first == nil else { continue }
                    let row = CDBroadcastMessage(context: context)
                    row.id = message.id
                    row.channelName = normalized
                    row.senderAddress = message.senderAddress
                    row.content = message.content
                    row.blockTime = message.blockTime
                    row.deliveryStatus = BroadcastMessage.DeliveryStatus.sent.rawValue
                    inserted += 1
                }
                if context.hasChanges {
                    try? context.save()
                }
                continuation.resume(returning: inserted)
            }
        }
    }

    /// Insert a message if its id isn't already present. Returns false if it was a duplicate.
    @discardableResult
    func insertMessage(
        id: String,
        channel: String,
        senderAddress: String,
        content: String,
        blockTime: Int64,
        deliveryStatus: BroadcastMessage.DeliveryStatus
    ) -> Bool {
        guard isLoaded else { return false }
        let normalized = BroadcastChannelName.normalize(channel)
        let context = viewContext
        var inserted = false
        context.performAndWait {
            let request = NSFetchRequest<CDBroadcastMessage>(entityName: CDBroadcastMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard (try? context.fetch(request))?.first == nil else { return }

            let message = CDBroadcastMessage(context: context)
            message.id = id
            message.channelName = normalized
            message.senderAddress = senderAddress
            message.content = content
            message.blockTime = blockTime
            message.deliveryStatus = deliveryStatus.rawValue
            save(context)
            inserted = true
        }
        return inserted
    }

    /// Replace an optimistic `pending_<uuid>` row with the real confirmed txId.
    func resolvePendingMessage(pendingId: String, realId: String, blockTime: Int64) {
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDBroadcastMessage>(entityName: CDBroadcastMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", pendingId)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return }
            message.id = realId
            message.blockTime = blockTime
            message.deliveryStatus = BroadcastMessage.DeliveryStatus.sent.rawValue
            save(context)
        }
    }

    func markMessageFailed(pendingId: String) {
        updateMessageStatus(id: pendingId, status: .failed)
    }

    /// Update an existing message's delivery status in place (e.g. failed -> pending on retry).
    func updateMessageStatus(id: String, status: BroadcastMessage.DeliveryStatus) {
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDBroadcastMessage>(entityName: CDBroadcastMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return }
            message.deliveryStatus = status.rawValue
            save(context)
        }
    }

    /// Messages for a channel, oldest first, with hidden senders already filtered out.
    func messages(forChannel channel: String) -> [BroadcastMessage] {
        guard isLoaded else { return [] }
        let normalized = BroadcastChannelName.normalize(channel)
        let hidden = hiddenSenderAddresses(forChannel: normalized)
        var result: [BroadcastMessage] = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDBroadcastMessage>(entityName: CDBroadcastMessage.entityName)
            request.predicate = NSPredicate(format: "channelName == %@", normalized)
            request.sortDescriptors = [NSSortDescriptor(key: "blockTime", ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            result = rows
                .filter { !hidden.contains($0.senderAddress) }
                .map { row in
                    BroadcastMessage(
                        id: row.id,
                        channelName: row.channelName,
                        senderAddress: row.senderAddress,
                        content: row.content ?? "",
                        blockTime: row.blockTime,
                        deliveryStatus: BroadcastMessage.DeliveryStatus(rawValue: row.deliveryStatus ?? "") ?? .sent
                    )
                }
        }
        return result
    }

    // MARK: - Reactions (CDBroadcastReaction)
    //
    // One row per (targetTxId, reactorAddress), mirroring `GroupStore`'s reaction persistence -
    // with one broadcast-specific twist: a REMOVE is kept as a tombstone row (`emoji == nil`,
    // real `blockTime`) instead of deleting the row outright. The broadcast indexer re-serves
    // the channel's FULL history on every poll, so without a tombstone an already-processed
    // "add" arriving again (after its later "remove" was applied) would silently resurrect the
    // reaction. Newest-blockTime-wins per (target, reactor) makes replaying history idempotent.

    /// Unconditional write for the local user's OWN reaction changes (optimistic apply at send
    /// time + status flips on success/failure) - user intent always wins over whatever's stored.
    /// `emoji == nil` writes a remove-tombstone. Mirrors `GroupStore.upsertGroupReaction`.
    func upsertOwnReaction(
        targetTxId: String,
        channel: String,
        reactorAddress: String,
        emoji: String?,
        reactionTxId: String?,
        blockTime: Int64,
        deliveryStatus: String? = nil,
        failedAction: String? = nil
    ) {
        guard isLoaded else { return }
        let normalized = BroadcastChannelName.normalize(channel)
        let context = viewContext
        context.performAndWait {
            let reaction = fetchReactionRow(targetTxId: targetTxId, reactorAddress: reactorAddress, in: context)
                ?? CDBroadcastReaction(context: context)
            reaction.targetTxId = targetTxId
            reaction.channelName = normalized
            reaction.reactorAddress = reactorAddress
            reaction.emoji = emoji
            reaction.reactionTxId = reactionTxId
            reaction.blockTime = blockTime
            reaction.deliveryStatus = deliveryStatus
            reaction.failedAction = failedAction
            save(context)
        }
    }

    /// Applies a reaction seen on-chain (live block scan or indexer history) with
    /// newest-blockTime-wins semantics - a stale/duplicate replay of already-applied history is
    /// a no-op. `emoji == nil` = the sender removed their reaction (stored as a tombstone).
    /// Returns whether anything actually changed, so callers can skip UI refreshes for no-ops.
    @discardableResult
    func applyIncomingReaction(
        targetTxId: String,
        channel: String,
        reactorAddress: String,
        emoji: String?,
        reactionTxId: String,
        blockTime: Int64
    ) -> Bool {
        guard isLoaded else { return false }
        let normalized = BroadcastChannelName.normalize(channel)
        let context = viewContext
        var changed = false
        context.performAndWait {
            let existing = fetchReactionRow(targetTxId: targetTxId, reactorAddress: reactorAddress, in: context)
            if let existing {
                // Already applied this exact reaction tx, or a newer change supersedes it.
                guard existing.reactionTxId != reactionTxId, existing.blockTime <= blockTime else { return }
            }
            let reaction = existing ?? CDBroadcastReaction(context: context)
            reaction.targetTxId = targetTxId
            reaction.channelName = normalized
            reaction.reactorAddress = reactorAddress
            reaction.emoji = emoji
            reaction.reactionTxId = reactionTxId
            reaction.blockTime = blockTime
            reaction.deliveryStatus = nil
            reaction.failedAction = nil
            save(context)
            changed = true
        }
        return changed
    }

    private func fetchReactionRow(targetTxId: String, reactorAddress: String, in context: NSManagedObjectContext) -> CDBroadcastReaction? {
        let request = NSFetchRequest<CDBroadcastReaction>(entityName: CDBroadcastReaction.entityName)
        request.predicate = NSPredicate(format: "targetTxId == %@ AND reactorAddress == %@", targetTxId, reactorAddress)
        let rows = (try? context.fetch(request)) ?? []
        // One reaction per (message, reactor) - fold any stray duplicates.
        for duplicate in rows.dropFirst() {
            context.delete(duplicate)
        }
        return rows.first
    }

    /// All active (non-tombstone) reactions for `channel`, grouped by the message they target.
    /// Reuses `GroupStore.ReactionSnapshot` - the value shape is identical, and the shared
    /// reaction UI (`ReactionPillView` + retry affordances) already speaks it.
    func fetchReactions(forChannel channel: String) -> [String: [GroupStore.ReactionSnapshot]] {
        guard isLoaded else { return [:] }
        let normalized = BroadcastChannelName.normalize(channel)
        var grouped: [String: [GroupStore.ReactionSnapshot]] = [:]
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDBroadcastReaction>(entityName: CDBroadcastReaction.entityName)
            request.predicate = NSPredicate(format: "channelName == %@", normalized)
            guard let results = try? context.fetch(request) else { return }
            for record in results {
                guard let emoji = record.emoji else { continue } // remove-tombstone
                let status: ChatMessage.DeliveryStatus
                switch record.deliveryStatus {
                case "failed": status = .failed
                case "pending": status = .pending
                default: status = .sent
                }
                let snapshot = GroupStore.ReactionSnapshot(
                    targetTxId: record.targetTxId,
                    reactorAddress: record.reactorAddress,
                    emoji: emoji,
                    deliveryStatus: status,
                    failedAction: record.failedAction,
                    blockTime: record.blockTime
                )
                grouped[record.targetTxId, default: []].append(snapshot)
            }
        }
        return grouped
    }

    // MARK: - Hidden senders (PER ROOM)

    func hideSender(_ address: String, inChannel channel: String) {
        guard isLoaded else { return }
        let normalized = BroadcastChannelName.normalize(channel)
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenBroadcastSender>(entityName: CDHiddenBroadcastSender.entityName)
            request.predicate = NSPredicate(format: "senderAddress == %@ AND channelName == %@", address, normalized)
            request.fetchLimit = 1
            guard (try? context.fetch(request))?.first == nil else { return }
            let entry = CDHiddenBroadcastSender(context: context)
            entry.senderAddress = address
            entry.channelName = normalized
            entry.hiddenAt = Date()
            save(context)
        }
    }

    /// Removes the room-scoped hide. A matching legacy global row ("" channel) is deleted too -
    /// otherwise unhiding from the room's list would appear to do nothing.
    func unhideSender(_ address: String, inChannel channel: String) {
        let normalized = BroadcastChannelName.normalize(channel)
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenBroadcastSender>(entityName: CDHiddenBroadcastSender.entityName)
            request.predicate = NSPredicate(
                format: "senderAddress == %@ AND (channelName == %@ OR channelName == %@)",
                address, normalized, ""
            )
            let rows = (try? context.fetch(request)) ?? []
            guard !rows.isEmpty else { return }
            rows.forEach(context.delete)
            save(context)
        }
    }

    /// Senders hidden in this room: room-scoped rows plus legacy global ("" channel) rows.
    func hiddenSenderAddresses(forChannel channel: String) -> Set<String> {
        guard isLoaded else { return [] }
        let normalized = BroadcastChannelName.normalize(channel)
        var result: Set<String> = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenBroadcastSender>(entityName: CDHiddenBroadcastSender.entityName)
            request.predicate = NSPredicate(format: "channelName == %@ OR channelName == %@", normalized, "")
            let rows = (try? context.fetch(request)) ?? []
            result = Set(rows.map { $0.senderAddress })
        }
        return result
    }

    /// Every hide, grouped for one-pass filtering during block scans and push registration:
    /// `global` = legacy all-room rows, `perChannel` = room-scoped rows.
    func hiddenSendersByChannel() -> (global: Set<String>, perChannel: [String: Set<String>]) {
        guard isLoaded else { return ([], [:]) }
        var global: Set<String> = []
        var perChannel: [String: Set<String>] = [:]
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenBroadcastSender>(entityName: CDHiddenBroadcastSender.entityName)
            let rows = (try? context.fetch(request)) ?? []
            for row in rows {
                if row.channelName.isEmpty {
                    global.insert(row.senderAddress)
                } else {
                    perChannel[row.channelName, default: []].insert(row.senderAddress)
                }
            }
        }
        return (global, perChannel)
    }

    // MARK: - Retention pruning

    /// Prune messages in each joined channel older than that channel's retention window
    /// (capped at `maxRetentionMillis`). Call periodically (e.g. on scan / app-active).
    /// Returns whether anything was actually deleted, so the once-a-second room poll can skip its
    /// follow-up message re-fetch/re-map when nothing expired (see `pruneNowAndRefresh`).
    @discardableResult
    func pruneExpiredMessages() -> Bool {
        guard isLoaded else { return false }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let context = viewContext
        var didDelete = false
        context.performAndWait {
            let channelRequest = NSFetchRequest<CDBroadcastChannel>(entityName: CDBroadcastChannel.entityName)
            let channels = (try? context.fetch(channelRequest)) ?? []
            for channel in channels {
                // Indexer-tracked channels have a FIXED 3-day retention (the gear is hidden
                // for them in the UI; history lives on the indexer, the device keeps 3 days).
                let retention = BroadcastService.featuredChannels.contains(channel.channelName)
                    ? Self.maxRetentionMillis
                    : min(channel.retentionMillis, Self.maxRetentionMillis)
                let cutoff = nowMillis - retention
                // Reactions age out on the same clock as their channel's messages - once the
                // message a reaction targets is pruned there's nothing to render it on, and the
                // tombstones' replay-idempotency job (see the Reactions section) only matters
                // while the indexer still serves the corresponding history window.
                let reactionRequest = NSFetchRequest<NSFetchRequestResult>(entityName: CDBroadcastReaction.entityName)
                reactionRequest.predicate = NSPredicate(format: "channelName == %@ AND blockTime < %lld", channel.channelName, cutoff)
                _ = try? context.execute(NSBatchDeleteRequest(fetchRequest: reactionRequest))
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: CDBroadcastMessage.entityName)
                request.predicate = NSPredicate(format: "channelName == %@ AND blockTime < %lld", channel.channelName, cutoff)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                deleteRequest.resultType = .resultTypeObjectIDs
                guard let result = try? context.execute(deleteRequest) as? NSBatchDeleteResult,
                      let objectIds = result.result as? [NSManagedObjectID],
                      !objectIds.isEmpty else { continue }
                didDelete = true
                // NSBatchDeleteRequest deletes directly in the persistent store, bypassing this
                // context's row cache - without this merge, already-faulted/cached rows for the
                // deleted messages can keep showing up in later fetches on this same context.
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: objectIds],
                    into: [context]
                )
            }
            if didDelete { save(context) }
        }
        return didDelete
    }

    /// Clear all local broadcast data for the current wallet (e.g. on wallet reset).
    func clearAll() {
        guard isLoaded else { return }
        let context = viewContext
        context.performAndWait {
            for entityName in [CDBroadcastMessage.entityName, CDBroadcastChannel.entityName, CDHiddenBroadcastSender.entityName, CDBroadcastReaction.entityName] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                _ = try? context.execute(deleteRequest)
            }
            save(context)
        }
    }

    private func save(_ context: NSManagedObjectContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.log("[BroadcastStore] Save failed: %@", error.localizedDescription)
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let channelEntity = NSEntityDescription()
        channelEntity.name = CDBroadcastChannel.entityName
        channelEntity.managedObjectClassName = NSStringFromClass(CDBroadcastChannel.self)
        channelEntity.properties = [
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "alwaysListen", type: .booleanAttributeType, optional: false, defaultValue: false),
            makeAttribute(name: "notifyEnabled", type: .booleanAttributeType, optional: false, defaultValue: false),
            makeAttribute(name: "retentionMillis", type: .integer64AttributeType, optional: false, defaultValue: BroadcastStore.defaultRetentionMillis),
            makeAttribute(name: "joinedAt", type: .dateAttributeType, optional: true)
        ]

        let messageEntity = NSEntityDescription()
        messageEntity.name = CDBroadcastMessage.entityName
        messageEntity.managedObjectClassName = NSStringFromClass(CDBroadcastMessage.self)
        messageEntity.properties = [
            makeAttribute(name: "id", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "senderAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "content", type: .stringAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true)
        ]

        let hiddenSenderEntity = NSEntityDescription()
        hiddenSenderEntity.name = CDHiddenBroadcastSender.entityName
        hiddenSenderEntity.managedObjectClassName = NSStringFromClass(CDHiddenBroadcastSender.self)
        hiddenSenderEntity.properties = [
            makeAttribute(name: "senderAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            // Room the hide applies to. "" = legacy row from the global-hide era, treated as
            // hidden in EVERY room (lightweight migration fills existing rows with "").
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "hiddenAt", type: .dateAttributeType, optional: true)
        ]

        let reactionEntity = NSEntityDescription()
        reactionEntity.name = CDBroadcastReaction.entityName
        reactionEntity.managedObjectClassName = NSStringFromClass(CDBroadcastReaction.self)
        reactionEntity.properties = [
            makeAttribute(name: "targetTxId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "reactorAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            // nil = remove-tombstone (see the Reactions section's doc comment).
            makeAttribute(name: "emoji", type: .stringAttributeType, optional: true),
            makeAttribute(name: "reactionTxId", type: .stringAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            // Send status for the local user's own reaction, mirroring CDGroupReaction:
            // nil/"sent" = delivered, "failed" = the reaction tx never sent; `failedAction`
            // records "add"/"remove" so Retry knows what to re-attempt.
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true),
            makeAttribute(name: "failedAction", type: .stringAttributeType, optional: true)
        ]

        model.entities = [channelEntity, messageEntity, hiddenSenderEntity, reactionEntity]
        return model
    }

    private static func makeAttribute(name: String, type: NSAttributeType, optional: Bool, defaultValue: Any? = nil) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        if let defaultValue {
            attribute.defaultValue = defaultValue
        }
        return attribute
    }
}

// BroadcastStore only touches Core Data via context.performAndWait on its own contexts;
// treat as Sendable for structured concurrency usage (matches MessageStore's convention).
extension BroadcastStore: @unchecked Sendable {}

@objc(CDBroadcastChannel)
final class CDBroadcastChannel: NSManagedObject {
    static let entityName = "CDBroadcastChannel"

    @NSManaged var channelName: String
    @NSManaged var alwaysListen: Bool
    @NSManaged var notifyEnabled: Bool
    @NSManaged var retentionMillis: Int64
    @NSManaged var joinedAt: Date?
}

@objc(CDBroadcastMessage)
final class CDBroadcastMessage: NSManagedObject {
    static let entityName = "CDBroadcastMessage"

    @NSManaged var id: String
    @NSManaged var channelName: String
    @NSManaged var senderAddress: String
    @NSManaged var content: String?
    @NSManaged var blockTime: Int64
    @NSManaged var deliveryStatus: String?
}

@objc(CDHiddenBroadcastSender)
final class CDHiddenBroadcastSender: NSManagedObject {
    static let entityName = "CDHiddenBroadcastSender"

    @NSManaged var senderAddress: String
    @NSManaged var channelName: String
    @NSManaged var hiddenAt: Date?
}

/// A reaction (tapback) sent or received on a broadcast message - see `MessageReactionContent`.
/// `emoji == nil` is a remove-tombstone (kept, not deleted, so replaying indexer history stays
/// idempotent - see the Reactions section's doc comment above).
@objc(CDBroadcastReaction)
final class CDBroadcastReaction: NSManagedObject {
    static let entityName = "CDBroadcastReaction"

    @NSManaged var targetTxId: String
    @NSManaged var channelName: String
    @NSManaged var reactorAddress: String
    @NSManaged var emoji: String?
    @NSManaged var reactionTxId: String?
    @NSManaged var blockTime: Int64
    @NSManaged var deliveryStatus: String?
    @NSManaged var failedAction: String?
}
