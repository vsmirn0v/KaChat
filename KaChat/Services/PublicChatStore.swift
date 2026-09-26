import Foundation
import CoreData
import CryptoKit

/// Plain, in-memory representation of a joined public chat channel (mirrors Android's
/// `PublicChatChannelEntity`).
struct PublicChatChannel: Identifiable, Equatable {
    var id: String { channelName }
    let channelName: String
    var alwaysListen: Bool
    var notifyEnabled: Bool
    var retentionMillis: Int64
    var joinedAt: Date?
}

/// Plain, in-memory representation of a public chat message (mirrors Android's
/// `PublicChatMessageEntity`). `id` is the real Kaspa txId once confirmed, or a
/// synthetic `pending_<uuid>` while the send is in flight.
struct PublicChatMessage: Identifiable, Equatable {
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

    /// The same row with `content` replaced - how an edit is shown without touching the row.
    func replacingContent(_ newContent: String) -> PublicChatMessage {
        PublicChatMessage(id: id, channelName: channelName, senderAddress: senderAddress, content: newContent, blockTime: blockTime, deliveryStatus: deliveryStatus)
    }
}

/// Local-only, per-wallet store for KaChat 2.0 Public Chat channel data.
/// Never part of the Nextcloud archive either: public chat channels are public, on-chain,
/// and ephemeral (retention-pruned locally), matching the Android client's local-only Room
/// tables for the same feature.
final class PublicChatStore {
    static let shared = PublicChatStore()

    /// Hard cap on how long any channel's messages are retained locally, regardless
    /// of the per-channel setting - matches Android's `PublicChatRetention.MAX_MILLIS`.
    static let maxRetentionMillis: Int64 = 3 * 24 * 60 * 60 * 1000

    /// Retention for the FEATURED, indexer-tracked rooms (#kaspa / #kachat-bugs): the KaChat
    /// indexer holds 30 days of history for them, and the room should always show everything
    /// the indexer holds — the old 3-day cap silently pruned days 4-30 locally even though the
    /// backfill had fetched them.
    static let indexerRetentionMillis: Int64 = 30 * 24 * 60 * 60 * 1000

    /// Default retention applied when a channel is first joined - a conservative starting point
    /// for a fresh install; users can raise it up to `maxRetentionMillis` via the retention sheet.
    static let defaultRetentionMillis: Int64 = 3 * 60 * 60 * 1000

    private let container: NSPersistentContainer
    private(set) var currentWalletAddress: String?
    private var isLoaded = false
    /// See `MessageStore.loadGeneration`.
    private var loadGeneration = 0

    private static let indexSpecs: [CoreDataIndexBuilder.Spec] = [
        .init(entityName: CDPublicChatMessage.entityName, attributes: ["channelName", "blockTime"]),
        .init(entityName: CDPublicChatMessage.entityName, attributes: ["id"]),
        .init(entityName: CDPublicChatReaction.entityName, attributes: ["channelName"]),
        .init(entityName: CDPublicChatReaction.entityName, attributes: ["targetTxId"]),
    ]

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

    /// Switch to a different wallet's public chat store (own SQLite file per wallet,
    /// following `MessageStore`'s per-wallet file-naming convention). The store opens off the
    /// main thread; `completion` runs on the main thread once it is usable (or has failed),
    /// which is when the caller may read from it.
    func setCurrentWallet(_ walletAddress: String?, completion: (() -> Void)? = nil) {
        guard walletAddress != currentWalletAddress else {
            completion?()
            return
        }

        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }

        currentWalletAddress = walletAddress
        isLoaded = false
        loadGeneration += 1

        guard let walletAddress else {
            completion?()
            return
        }

        load(NSPersistentStoreDescription(url: storeURL(forWallet: walletAddress)), generation: loadGeneration, isRetry: false, completion: completion)
    }

    private func load(_ description: NSPersistentStoreDescription, generation: Int, isRetry: Bool, completion: (() -> Void)?) {
        CoreDataStoreLoader.load(container: container, description: description, indexSpecs: Self.indexSpecs) { [weak self] error in
            guard let self else {
                completion?()
                return
            }
            guard generation == self.loadGeneration else {
                CoreDataStoreLoader.detachStore(at: description.url, from: self.container)
                completion?()
                return
            }
            if let error {
                // This store is a cache of on-chain rows the indexer and the block scan refill.
                // A file the model cannot open is rebuilt once rather than left dead.
                if !isRetry, CoreDataStoreLoader.isUnusableStore(error), let url = description.url {
                    AppLog.log("%@", "[PublicChatStore] Store unusable (\(error.localizedDescription)); rebuilding the cache")
                    CoreDataStoreLoader.destroyStore(at: url, in: self.container)
                    self.load(NSPersistentStoreDescription(url: url), generation: generation, isRetry: true, completion: completion)
                    return
                }
                CoreDataStoreLoader.reportFailure(store: "PublicChatStore", error: error)
                completion?()
                return
            }
            self.isLoaded = true
            self.container.viewContext.automaticallyMergesChangesFromParent = true
            self.container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
            completion?()
        }
    }

    private var viewContext: NSManagedObjectContext { container.viewContext }

    // MARK: - Channels

    @discardableResult
    func joinChannel(_ rawName: String) -> Bool {
        let name = PublicChatChannelName.normalize(rawName)
        guard PublicChatChannelName.isValid(name), isLoaded else { return false }
        let context = viewContext
        var joined = false
        context.performAndWait {
            if fetchChannel(name: name, in: context) == nil {
                let channel = CDPublicChatChannel(context: context)
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
        let normalized = PublicChatChannelName.normalize(name)
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

    private func updateChannel(_ name: String, _ mutate: (CDPublicChatChannel) -> Void) {
        let normalized = PublicChatChannelName.normalize(name)
        let context = viewContext
        context.performAndWait {
            guard let channel = fetchChannel(name: normalized, in: context) else { return }
            mutate(channel)
            save(context)
        }
    }

    func joinedChannels() -> [PublicChatChannel] {
        guard isLoaded else { return [] }
        var result: [PublicChatChannel] = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatChannel>(entityName: CDPublicChatChannel.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "joinedAt", ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            result = rows.map { row in
                PublicChatChannel(
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
        let normalized = PublicChatChannelName.normalize(name)
        var found = false
        let context = viewContext
        context.performAndWait {
            found = fetchChannel(name: normalized, in: context) != nil
        }
        return found
    }

    private func fetchChannel(name: String, in context: NSManagedObjectContext) -> CDPublicChatChannel? {
        let request = NSFetchRequest<CDPublicChatChannel>(entityName: CDPublicChatChannel.entityName)
        request.predicate = NSPredicate(format: "channelName == %@", name)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    // MARK: - Messages

    /// Batch insert for indexer-fetched history: ONE async background-context pass for the
    /// whole page instead of a synchronous main-thread performAndWait per row - a resume-time
    /// poll of 200 rows was hard main-thread work exactly while WAL checkpointing
    /// contends for the store (the app-freeze-after-resume class of bug).
    /// Returns the ids that were actually new.
    func insertMessages(
        _ messages: [(id: String, channel: String, senderAddress: String, content: String, blockTime: Int64)]
    ) async -> Set<String> {
        guard isLoaded, !messages.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                var inserted = Set<String>()
                for message in messages {
                    let normalized = PublicChatChannelName.normalize(message.channel)
                    let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
                    request.predicate = NSPredicate(format: "id == %@", message.id)
                    request.fetchLimit = 1
                    guard (try? context.fetch(request))?.first == nil else { continue }
                    let row = CDPublicChatMessage(context: context)
                    row.id = message.id
                    row.channelName = normalized
                    row.senderAddress = message.senderAddress
                    row.content = message.content
                    row.blockTime = message.blockTime
                    row.deliveryStatus = PublicChatMessage.DeliveryStatus.sent.rawValue
                    inserted.insert(message.id)
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
        deliveryStatus: PublicChatMessage.DeliveryStatus
    ) -> Bool {
        guard isLoaded else { return false }
        let normalized = PublicChatChannelName.normalize(channel)
        let context = viewContext
        var inserted = false
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard (try? context.fetch(request))?.first == nil else { return }

            let message = CDPublicChatMessage(context: context)
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
            let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", pendingId)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return }
            message.id = realId
            message.blockTime = blockTime
            message.deliveryStatus = PublicChatMessage.DeliveryStatus.sent.rawValue
            save(context)
        }
    }

    func markMessageFailed(pendingId: String) {
        updateMessageStatus(id: pendingId, status: .failed)
    }

    /// Update an existing message's delivery status in place (e.g. failed -> pending on retry).
    /// Sets a row's block time to the chain's, once the transaction is seen in a block. A row
    /// this device sent was stamped with its own clock at submit time; the chess arena orders
    /// seats and runs the clocks by block time, so every phone must hold the same value.
    /// Returns true when the row existed and the time changed.
    @discardableResult
    func updateBlockTime(id: String, blockTime: Int64) -> Bool {
        guard isLoaded else { return false }
        let context = viewContext
        var changed = false
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first, message.blockTime != blockTime else { return }
            message.blockTime = blockTime
            message.deliveryStatus = PublicChatMessage.DeliveryStatus.sent.rawValue
            save(context)
            changed = true
        }
        return changed
    }

    func updateMessageStatus(id: String, status: PublicChatMessage.DeliveryStatus) {
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return }
            message.deliveryStatus = status.rawValue
            save(context)
        }
    }

    /// Messages for a channel, oldest first, hidden senders filtered out, read on a background
    /// context. `newestLimit` cuts the window to the newest N (nil = everything, which the
    /// chess arena needs: its reducer replays the whole room); `olderThan` shifts the window
    /// back for "load earlier". Reading a 30-day room in full on the main thread, which is
    /// what every refresh used to do, was thousands of rows deserialized per tick.
    func messages(forChannel channel: String, newestLimit: Int?, olderThan: Int64? = nil) async -> [PublicChatMessage] {
        guard isLoaded else { return [] }
        let normalized = PublicChatChannelName.normalize(channel)
        let hidden = hiddenSenderAddresses(forChannel: normalized)
        return await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
                if let olderThan {
                    request.predicate = NSPredicate(format: "channelName == %@ AND blockTime < %lld", normalized, olderThan)
                } else {
                    request.predicate = NSPredicate(format: "channelName == %@", normalized)
                }
                // Newest first so the limit keeps the newest; flipped back to oldest-first below.
                request.sortDescriptors = [NSSortDescriptor(key: "blockTime", ascending: false)]
                if let newestLimit { request.fetchLimit = newestLimit }
                let rows = (try? context.fetch(request)) ?? []
                let result = rows
                    .filter { !hidden.contains($0.senderAddress) }
                    .map { row in
                        PublicChatMessage(
                            id: row.id,
                            channelName: row.channelName,
                            senderAddress: row.senderAddress,
                            content: row.content ?? "",
                            blockTime: row.blockTime,
                            deliveryStatus: PublicChatMessage.DeliveryStatus(rawValue: row.deliveryStatus ?? "") ?? .sent
                        )
                    }
                    .reversed()
                continuation.resume(returning: Array(result))
            }
        }
    }

    /// Just the ids a channel holds, for "which of these rows are new" checks - the sweep
    /// used to read every full row of the room for this, every 20 seconds, on the main thread.
    func messageIds(forChannel channel: String) async -> Set<String> {
        guard isLoaded else { return [] }
        let normalized = PublicChatChannelName.normalize(channel)
        return await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<NSDictionary>(entityName: CDPublicChatMessage.entityName)
                request.predicate = NSPredicate(format: "channelName == %@", normalized)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["id"]
                let rows = (try? context.fetch(request)) ?? []
                continuation.resume(returning: Set(rows.compactMap { $0["id"] as? String }))
            }
        }
    }

    /// One row's delivery status, for the send-retry check.
    func deliveryStatus(ofMessage id: String) -> PublicChatMessage.DeliveryStatus? {
        guard isLoaded else { return nil }
        let context = viewContext
        var status: PublicChatMessage.DeliveryStatus?
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            if let row = (try? context.fetch(request))?.first {
                status = PublicChatMessage.DeliveryStatus(rawValue: row.deliveryStatus ?? "")
            }
        }
        return status
    }

    // MARK: - Reactions (CDPublicChatReaction)
    //
    // One row per (targetTxId, reactorAddress), mirroring `GroupStore`'s reaction persistence -
    // with one public chat-specific twist: a REMOVE is kept as a tombstone row (`emoji == nil`,
    // real `blockTime`) instead of deleting the row outright. The public chat indexer re-serves
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
        let normalized = PublicChatChannelName.normalize(channel)
        let context = viewContext
        context.performAndWait {
            let reaction = fetchReactionRow(targetTxId: targetTxId, reactorAddress: reactorAddress, in: context)
                ?? CDPublicChatReaction(context: context)
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
        let normalized = PublicChatChannelName.normalize(channel)
        let context = viewContext
        var changed = false
        context.performAndWait {
            let existing = fetchReactionRow(targetTxId: targetTxId, reactorAddress: reactorAddress, in: context)
            if let existing {
                // Already applied this exact reaction tx, or a newer change supersedes it.
                guard existing.reactionTxId != reactionTxId, existing.blockTime <= blockTime else { return }
            }
            let reaction = existing ?? CDPublicChatReaction(context: context)
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

    // MARK: - Edits (CDPublicChatEdit)

    /// The sender of `txId` in `channel`, if the row is here - an edit counts only when its
    /// sender sent the message it names.
    func sender(ofMessage txId: String) -> (senderAddress: String, content: String)? {
        guard isLoaded else { return nil }
        let context = viewContext
        var found: (String, String)?
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatMessage>(entityName: CDPublicChatMessage.entityName)
            request.predicate = NSPredicate(format: "id == %@", txId)
            request.fetchLimit = 1
            if let row = (try? context.fetch(request))?.first {
                found = (row.senderAddress, row.content ?? "")
            }
        }
        return found
    }

    /// Records the newest edit of `targetTxId` - newest by block time wins (a replay of older
    /// history is a no-op), except that the local user's own in-flight edit is replaced by
    /// its own outcome. Returns whether anything changed.
    @discardableResult
    func upsertEdit(targetTxId: String, channel: String, text: String, editTxId: String?, blockTime: Int64, deliveryStatus: String? = nil) -> Bool {
        guard isLoaded else { return false }
        let normalized = PublicChatChannelName.normalize(channel)
        let context = viewContext
        var changed = false
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatEdit>(entityName: CDPublicChatEdit.entityName)
            request.predicate = NSPredicate(format: "targetTxId == %@", targetTxId)
            let existing = (try? context.fetch(request)) ?? []
            if let current = existing.first, current.deliveryStatus == nil || current.deliveryStatus == "sent" {
                if current.editTxId == editTxId, current.text == text { return }
                if current.blockTime > blockTime, current.editTxId != editTxId { return }
            }
            let edit = existing.first ?? CDPublicChatEdit(context: context)
            for duplicate in existing.dropFirst() {
                context.delete(duplicate)
            }
            edit.targetTxId = targetTxId
            edit.channelName = normalized
            edit.text = text
            edit.editTxId = editTxId
            edit.blockTime = blockTime
            edit.deliveryStatus = deliveryStatus
            save(context)
            changed = true
        }
        return changed
    }

    /// All edits in `channel`, keyed by the message they change.
    func fetchEdits(forChannel channel: String) -> [String: MessageEditSnapshot] {
        guard isLoaded else { return [:] }
        let normalized = PublicChatChannelName.normalize(channel)
        var edits: [String: MessageEditSnapshot] = [:]
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatEdit>(entityName: CDPublicChatEdit.entityName)
            request.predicate = NSPredicate(format: "channelName == %@", normalized)
            guard let results = try? context.fetch(request) else { return }
            for record in results {
                guard let text = record.text else { continue }
                let status: ChatMessage.DeliveryStatus
                switch record.deliveryStatus {
                case "failed": status = .failed
                case "pending": status = .pending
                default: status = .sent
                }
                edits[record.targetTxId] = MessageEditSnapshot(targetTxId: record.targetTxId, text: text, editTxId: record.editTxId, blockTime: record.blockTime, deliveryStatus: status)
            }
        }
        return edits
    }

    private func fetchReactionRow(targetTxId: String, reactorAddress: String, in context: NSManagedObjectContext) -> CDPublicChatReaction? {
        let request = NSFetchRequest<CDPublicChatReaction>(entityName: CDPublicChatReaction.entityName)
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
        let normalized = PublicChatChannelName.normalize(channel)
        var grouped: [String: [GroupStore.ReactionSnapshot]] = [:]
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDPublicChatReaction>(entityName: CDPublicChatReaction.entityName)
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
        let normalized = PublicChatChannelName.normalize(channel)
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenPublicChatSender>(entityName: CDHiddenPublicChatSender.entityName)
            request.predicate = NSPredicate(format: "senderAddress == %@ AND channelName == %@", address, normalized)
            request.fetchLimit = 1
            guard (try? context.fetch(request))?.first == nil else { return }
            let entry = CDHiddenPublicChatSender(context: context)
            entry.senderAddress = address
            entry.channelName = normalized
            entry.hiddenAt = Date()
            save(context)
        }
    }

    /// Removes the room-scoped hide. A matching legacy global row ("" channel) is deleted too -
    /// otherwise unhiding from the room's list would appear to do nothing.
    func unhideSender(_ address: String, inChannel channel: String) {
        let normalized = PublicChatChannelName.normalize(channel)
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenPublicChatSender>(entityName: CDHiddenPublicChatSender.entityName)
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
        let normalized = PublicChatChannelName.normalize(channel)
        var result: Set<String> = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenPublicChatSender>(entityName: CDHiddenPublicChatSender.entityName)
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
            let request = NSFetchRequest<CDHiddenPublicChatSender>(entityName: CDHiddenPublicChatSender.entityName)
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
    func pruneExpiredMessages() async -> Bool {
        guard isLoaded else { return false }
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        // Read on the caller's side: these are the service's main-actor sets.
        let fullWindowChannels = Set(PublicChatService.indexedChannels).union(PublicChatService.serviceChannels)
        let viewContext = self.viewContext
        // Off the main thread: two batch deletes per channel every prune, and it used to run
        // every 30 s while a room was open and after every merge, all on main.
        return await withCheckedContinuation { continuation in
          container.performBackgroundTask { context in
            var didDelete = false
            let channelRequest = NSFetchRequest<CDPublicChatChannel>(entityName: CDPublicChatChannel.entityName)
            let channels = (try? context.fetch(channelRequest)) ?? []
            for channel in channels {
                // Indexer-tracked channels keep the indexer's FULL 30-day window (the gear is
                // hidden for them in the UI; the indexer serves 30 days and the room should
                // always show all of it). Other channels keep the user setting, 3-day cap.
                // The chess arena too: every phone must hold the same rooms, and the rooms are
                // whatever the indexer's 30-day window holds. With the short default here, a
                // phone forgot yesterday's rooms overnight and offered a room number the
                // others had moved past.
                let retention = fullWindowChannels.contains(channel.channelName)
                    ? Self.indexerRetentionMillis
                    : min(channel.retentionMillis, Self.maxRetentionMillis)
                let cutoff = nowMillis - retention
                // Reactions age out on the same clock as their channel's messages - once the
                // message a reaction targets is pruned there's nothing to render it on, and the
                // tombstones' replay-idempotency job (see the Reactions section) only matters
                // while the indexer still serves the corresponding history window.
                let reactionRequest = NSFetchRequest<NSFetchRequestResult>(entityName: CDPublicChatReaction.entityName)
                reactionRequest.predicate = NSPredicate(format: "channelName == %@ AND blockTime < %lld", channel.channelName, cutoff)
                _ = try? context.execute(NSBatchDeleteRequest(fetchRequest: reactionRequest))
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: CDPublicChatMessage.entityName)
                request.predicate = NSPredicate(format: "channelName == %@ AND blockTime < %lld", channel.channelName, cutoff)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                deleteRequest.resultType = .resultTypeObjectIDs
                guard let result = try? context.execute(deleteRequest) as? NSBatchDeleteResult,
                      let objectIds = result.result as? [NSManagedObjectID],
                      !objectIds.isEmpty else { continue }
                didDelete = true
                // NSBatchDeleteRequest deletes directly in the persistent store, bypassing the
                // contexts' row caches - without this merge, already-faulted/cached rows for the
                // deleted messages can keep showing up in later fetches.
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: objectIds],
                    into: [context, viewContext]
                )
            }
            if didDelete, context.hasChanges { try? context.save() }
            continuation.resume(returning: didDelete)
          }
        }
    }

    /// Clear all local public chat data for the current wallet (e.g. on wallet reset).
    func clearAll() {
        guard isLoaded else { return }
        let context = viewContext
        context.performAndWait {
            for entityName in [CDPublicChatMessage.entityName, CDPublicChatChannel.entityName, CDHiddenPublicChatSender.entityName, CDPublicChatReaction.entityName] {
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
            AppLog.log("[PublicChatStore] Save failed: %@", error.localizedDescription)
        }
    }

    /// Builds a fetch index over `attributes` in order, which Core Data turns into a real SQLite
    /// index on the backing store.
    private static func makeIndex(
        name: String,
        on entity: NSEntityDescription,
        attributes: [String]
    ) -> NSFetchIndexDescription {
        let elements = attributes.compactMap { attributeName -> NSFetchIndexElementDescription? in
            guard let property = entity.properties.first(where: { $0.name == attributeName }) else { return nil }
            return NSFetchIndexElementDescription(property: property, collationType: .binary)
        }
        return NSFetchIndexDescription(name: name, elements: elements)
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let channelEntity = NSEntityDescription()
        channelEntity.name = CDPublicChatChannel.entityName
        channelEntity.managedObjectClassName = NSStringFromClass(CDPublicChatChannel.self)
        channelEntity.properties = [
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "alwaysListen", type: .booleanAttributeType, optional: false, defaultValue: false),
            makeAttribute(name: "notifyEnabled", type: .booleanAttributeType, optional: false, defaultValue: false),
            makeAttribute(name: "retentionMillis", type: .integer64AttributeType, optional: false, defaultValue: PublicChatStore.defaultRetentionMillis),
            makeAttribute(name: "joinedAt", type: .dateAttributeType, optional: true)
        ]

        let messageEntity = NSEntityDescription()
        messageEntity.name = CDPublicChatMessage.entityName
        messageEntity.managedObjectClassName = NSStringFromClass(CDPublicChatMessage.self)
        messageEntity.properties = [
            makeAttribute(name: "id", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "senderAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "content", type: .stringAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true)
        ]

        let hiddenSenderEntity = NSEntityDescription()
        hiddenSenderEntity.name = CDHiddenPublicChatSender.entityName
        hiddenSenderEntity.managedObjectClassName = NSStringFromClass(CDHiddenPublicChatSender.self)
        hiddenSenderEntity.properties = [
            makeAttribute(name: "senderAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            // Room the hide applies to. "" = legacy row from the global-hide era, treated as
            // hidden in EVERY room (lightweight migration fills existing rows with "").
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "hiddenAt", type: .dateAttributeType, optional: true)
        ]

        let reactionEntity = NSEntityDescription()
        reactionEntity.name = CDPublicChatReaction.entityName
        reactionEntity.managedObjectClassName = NSStringFromClass(CDPublicChatReaction.self)
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

        // Rooms are always read one at a time, oldest-first, and reactions by their target -
        // none of which the store could serve without a scan.
        messageEntity.indexes = [
            makeIndex(name: "byChannelAndTime", on: messageEntity, attributes: ["channelName", "blockTime"]),
            makeIndex(name: "byId", on: messageEntity, attributes: ["id"])
        ]
        reactionEntity.indexes = [
            makeIndex(name: "byChannel", on: reactionEntity, attributes: ["channelName"]),
            makeIndex(name: "byTarget", on: reactionEntity, attributes: ["targetTxId"])
        ]
        hiddenSenderEntity.indexes = [
            makeIndex(name: "byChannel", on: hiddenSenderEntity, attributes: ["channelName"])
        ]

        // CDPublicChatEdit: the newest edit per target message in a room (plaintext, like the
        // rows themselves). New entity → lightweight migration, like CDPublicChatReaction.
        let editEntity = NSEntityDescription()
        editEntity.name = CDPublicChatEdit.entityName
        editEntity.managedObjectClassName = NSStringFromClass(CDPublicChatEdit.self)
        editEntity.properties = [
            makeAttribute(name: "targetTxId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "channelName", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "text", type: .stringAttributeType, optional: true),
            makeAttribute(name: "editTxId", type: .stringAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true)
        ]
        editEntity.indexes = [
            makeIndex(name: "byChannel", on: editEntity, attributes: ["channelName"])
        ]

        model.entities = [channelEntity, messageEntity, hiddenSenderEntity, reactionEntity, editEntity]
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

// PublicChatStore only touches Core Data via context.performAndWait on its own contexts;
// treat as Sendable for structured concurrency usage (matches MessageStore's convention).
extension PublicChatStore: @unchecked Sendable {}

// The Objective-C names and `entityName`s stay `CDBroadcast*`: they are what every existing
// store was written with. Only the Swift names say public chat.
@objc(CDBroadcastChannel)
final class CDPublicChatChannel: NSManagedObject {
    static let entityName = "CDBroadcastChannel"

    @NSManaged var channelName: String
    @NSManaged var alwaysListen: Bool
    @NSManaged var notifyEnabled: Bool
    @NSManaged var retentionMillis: Int64
    @NSManaged var joinedAt: Date?
}

@objc(CDBroadcastMessage)
final class CDPublicChatMessage: NSManagedObject {
    static let entityName = "CDBroadcastMessage"

    @NSManaged var id: String
    @NSManaged var channelName: String
    @NSManaged var senderAddress: String
    @NSManaged var content: String?
    @NSManaged var blockTime: Int64
    @NSManaged var deliveryStatus: String?
}

@objc(CDHiddenBroadcastSender)
final class CDHiddenPublicChatSender: NSManagedObject {
    static let entityName = "CDHiddenBroadcastSender"

    @NSManaged var senderAddress: String
    @NSManaged var channelName: String
    @NSManaged var hiddenAt: Date?
}

/// A reaction (tapback) sent or received on a public chat message - see `MessageReactionContent`.
/// `emoji == nil` is a remove-tombstone (kept, not deleted, so replaying indexer history stays
/// idempotent - see the Reactions section's doc comment above).
@objc(CDBroadcastEdit)
final class CDPublicChatEdit: NSManagedObject {
    static let entityName = "CDBroadcastEdit"

    @NSManaged var targetTxId: String
    @NSManaged var channelName: String
    @NSManaged var text: String?
    @NSManaged var editTxId: String?
    @NSManaged var blockTime: Int64
    @NSManaged var deliveryStatus: String?
}

@objc(CDBroadcastReaction)
final class CDPublicChatReaction: NSManagedObject {
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
