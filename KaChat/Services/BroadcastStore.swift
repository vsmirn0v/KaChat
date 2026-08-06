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
        let hidden = hiddenSenderAddresses()
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

    // MARK: - Hidden senders

    func hideSender(_ address: String) {
        guard isLoaded else { return }
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenBroadcastSender>(entityName: CDHiddenBroadcastSender.entityName)
            request.predicate = NSPredicate(format: "senderAddress == %@", address)
            request.fetchLimit = 1
            guard (try? context.fetch(request))?.first == nil else { return }
            let entry = CDHiddenBroadcastSender(context: context)
            entry.senderAddress = address
            entry.hiddenAt = Date()
            save(context)
        }
    }

    func unhideSender(_ address: String) {
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenBroadcastSender>(entityName: CDHiddenBroadcastSender.entityName)
            request.predicate = NSPredicate(format: "senderAddress == %@", address)
            if let entry = (try? context.fetch(request))?.first {
                context.delete(entry)
                save(context)
            }
        }
    }

    func hiddenSenderAddresses() -> Set<String> {
        guard isLoaded else { return [] }
        var result: Set<String> = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDHiddenBroadcastSender>(entityName: CDHiddenBroadcastSender.entityName)
            let rows = (try? context.fetch(request)) ?? []
            result = Set(rows.map { $0.senderAddress })
        }
        return result
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
            for entityName in [CDBroadcastMessage.entityName, CDBroadcastChannel.entityName, CDHiddenBroadcastSender.entityName] {
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
            makeAttribute(name: "hiddenAt", type: .dateAttributeType, optional: true)
        ]

        model.entities = [channelEntity, messageEntity, hiddenSenderEntity]
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
    @NSManaged var hiddenAt: Date?
}
