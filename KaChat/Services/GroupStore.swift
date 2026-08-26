import Foundation
import CoreData
import CryptoKit

/// Local-only, per-wallet store for group chat metadata and messages.
/// Like `BroadcastStore`, this is intentionally NOT synced via CloudKit - group secrets
/// (GroupBag) live in Keychain only, and message content here is stored as raw gcomm
/// ciphertext (not plaintext), decrypted on read using the Keychain-held keys. Compromising
/// this database alone does not reveal message content, matching MessageStore's posture for
/// 1:1 messages.
final class GroupStore {
    static let shared = GroupStore()

    private let container: NSPersistentContainer
    private(set) var currentWalletAddress: String?
    private var isLoaded = false

    private init() {
        container = NSPersistentContainer(name: "KaChatGroups", managedObjectModel: Self.makeModel())
        container.persistentStoreDescriptions = []
    }

    private func storeURL(forWallet walletAddress: String) -> URL {
        let hash = SHA256.hash(data: walletAddress.data(using: .utf8) ?? Data())
        let hashPrefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent("KaChatGroups-\(hashPrefix).sqlite")
    }

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
                AppLog.log("[GroupStore] Failed to load store: %@", error.localizedDescription)
                return
            }
            self.isLoaded = true
            self.container.viewContext.automaticallyMergesChangesFromParent = true
            self.container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        }
    }

    private var viewContext: NSManagedObjectContext { container.viewContext }

    // MARK: - Groups

    @discardableResult
    func upsertGroup(_ group: GroupChat) -> Bool {
        guard isLoaded else { return false }
        let context = viewContext
        var ok = false
        context.performAndWait {
            let row = fetchGroup(id: group.id, in: context) ?? CDGroup(context: context)
            row.groupId = group.id
            row.name = group.name
            row.adminAddress = group.adminAddress
            row.adminXOnlyPubKeyHex = group.adminXOnlyPubKeyHex
            row.currentEpoch = Int64(group.currentEpoch)
            row.createdAt = group.createdAt
            row.isAdmin = group.isAdmin
            row.membersJSON = (try? JSONEncoder().encode(group.members)) ?? Data()
            save(context)
            ok = true
        }
        return ok
    }

    func deleteGroup(id: String) {
        let context = viewContext
        context.performAndWait {
            guard let row = fetchGroup(id: id, in: context) else { return }
            context.delete(row)
            let messageRequest = NSFetchRequest<NSFetchRequestResult>(entityName: CDGroupMessage.entityName)
            messageRequest.predicate = NSPredicate(format: "groupId == %@", id)
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: messageRequest)
            _ = try? context.execute(deleteRequest)
            let reactionRequest = NSFetchRequest<NSFetchRequestResult>(entityName: CDGroupReaction.entityName)
            reactionRequest.predicate = NSPredicate(format: "groupId == %@", id)
            _ = try? context.execute(NSBatchDeleteRequest(fetchRequest: reactionRequest))
            save(context)
        }
    }

    func group(id: String) -> GroupChat? {
        guard isLoaded else { return nil }
        var result: GroupChat?
        let context = viewContext
        context.performAndWait {
            guard let row = fetchGroup(id: id, in: context) else { return }
            result = Self.makeGroup(from: row)
        }
        return result
    }

    func allGroups() -> [GroupChat] {
        guard isLoaded else { return [] }
        var result: [GroupChat] = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroup>(entityName: CDGroup.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            result = rows.map(Self.makeGroup)
        }
        return result
    }

    private func fetchGroup(id: String, in context: NSManagedObjectContext) -> CDGroup? {
        let request = NSFetchRequest<CDGroup>(entityName: CDGroup.entityName)
        request.predicate = NSPredicate(format: "groupId == %@", id)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    private static func makeGroup(from row: CDGroup) -> GroupChat {
        let members = (try? JSONDecoder().decode([GroupMember].self, from: row.membersJSON ?? Data())) ?? []
        return GroupChat(
            id: row.groupId,
            name: row.name,
            adminAddress: row.adminAddress,
            adminXOnlyPubKeyHex: row.adminXOnlyPubKeyHex,
            members: members,
            currentEpoch: UInt64(row.currentEpoch),
            createdAt: row.createdAt ?? Date(),
            isAdmin: row.isAdmin
        )
    }

    // MARK: - Messages
    //
    // `contentEncrypted` stores the raw gcomm ciphertext+tag (not plaintext) - matches
    // MessageStore's CDMessage.contentEncrypted posture. Callers decrypt via GroupCipher using
    // the epoch/senderId/msgId columns plus the Keychain-held GroupBag root key.

    /// Insert a message if its txId isn't already present. Returns false if it was a duplicate.
    @discardableResult
    func insertMessage(
        txId: String,
        groupId: String,
        senderAddress: String?,
        senderIdHex: String,
        epoch: UInt64,
        msgIdHex: String,
        contentEncrypted: Data,
        blockTime: Int64,
        isOutgoing: Bool,
        deliveryStatus: ChatMessage.DeliveryStatus
    ) -> Bool {
        guard isLoaded else { return false }
        let context = viewContext
        var inserted = false
        context.performAndWait {
            let request = NSFetchRequest<CDGroupMessage>(entityName: CDGroupMessage.entityName)
            request.predicate = NSPredicate(format: "txId == %@", txId)
            request.fetchLimit = 1
            guard (try? context.fetch(request))?.first == nil else { return }

            let message = CDGroupMessage(context: context)
            message.txId = txId
            message.groupId = groupId
            message.senderAddress = senderAddress
            message.senderIdHex = senderIdHex
            message.epoch = Int64(epoch)
            message.msgIdHex = msgIdHex
            message.contentEncrypted = contentEncrypted
            message.blockTime = blockTime
            message.isOutgoing = isOutgoing
            message.deliveryStatus = deliveryStatus.rawValue
            save(context)
            inserted = true
        }
        return inserted
    }

    /// Insert a decrypted plaintext message restored from a backup archive, keyed on the negative
    /// epoch sentinel (-1) so `messageRows`/`decryptGroupRows` return it verbatim without a group
    /// key. `content` is stored as UTF-8 bytes in `contentEncrypted`. No-op on a duplicate txId.
    @discardableResult
    func insertImportedPlaintextMessage(
        txId: String, groupId: String, senderAddress: String?, senderIdHex: String,
        msgIdHex: String, content: String, blockTime: Int64, isOutgoing: Bool
    ) -> Bool {
        guard isLoaded else { return false }
        let context = viewContext
        var inserted = false
        context.performAndWait {
            let request = NSFetchRequest<CDGroupMessage>(entityName: CDGroupMessage.entityName)
            request.predicate = NSPredicate(format: "txId == %@", txId)
            request.fetchLimit = 1
            guard (try? context.fetch(request))?.first == nil else { return }
            let message = CDGroupMessage(context: context)
            message.txId = txId
            message.groupId = groupId
            message.senderAddress = senderAddress
            message.senderIdHex = senderIdHex
            message.epoch = -1
            message.msgIdHex = msgIdHex
            message.contentEncrypted = Data(content.utf8)
            message.blockTime = blockTime
            message.isOutgoing = isOutgoing
            message.deliveryStatus = ChatMessage.DeliveryStatus.sent.rawValue
            save(context)
            inserted = true
        }
        return inserted
    }

    /// Replace an optimistic `pending_<uuid>` row with the real confirmed txId.
    func resolvePendingMessage(pendingId: String, realId: String, blockTime: Int64) {
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroupMessage>(entityName: CDGroupMessage.entityName)
            request.predicate = NSPredicate(format: "txId == %@", pendingId)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return }
            message.txId = realId
            message.blockTime = blockTime
            message.deliveryStatus = ChatMessage.DeliveryStatus.sent.rawValue
            save(context)
        }
    }

    /// Deletes a specific message by txId, local-only - mirrors `MessageStore.deleteMessage(txId:)`.
    func deleteMessage(txId: String) {
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroupMessage>(entityName: CDGroupMessage.entityName)
            request.predicate = NSPredicate(format: "txId == %@", txId)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return }
            context.delete(message)
            save(context)
        }
    }

    func markMessageFailed(pendingId: String) {
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroupMessage>(entityName: CDGroupMessage.entityName)
            request.predicate = NSPredicate(format: "txId == %@", pendingId)
            request.fetchLimit = 1
            guard let message = (try? context.fetch(request))?.first else { return }
            message.deliveryStatus = ChatMessage.DeliveryStatus.failed.rawValue
            save(context)
        }
    }

    /// Raw rows for a group, oldest first - callers decrypt via GroupCipher using the group's
    /// per-epoch root key(s) held in Keychain.
    func messageRows(forGroup groupId: String) -> [CDGroupMessageSnapshot] {
        guard isLoaded else { return [] }
        var result: [CDGroupMessageSnapshot] = []
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroupMessage>(entityName: CDGroupMessage.entityName)
            request.predicate = NSPredicate(format: "groupId == %@", groupId)
            request.sortDescriptors = [NSSortDescriptor(key: "blockTime", ascending: true)]
            let rows = (try? context.fetch(request)) ?? []
            result = rows.map { row in
                CDGroupMessageSnapshot(
                    txId: row.txId,
                    groupId: row.groupId,
                    senderAddress: row.senderAddress,
                    senderIdHex: row.senderIdHex,
                    epoch: row.epoch < 0 ? 0 : UInt64(row.epoch),
                    msgIdHex: row.msgIdHex,
                    contentEncrypted: row.contentEncrypted ?? Data(),
                    blockTime: row.blockTime,
                    isOutgoing: row.isOutgoing,
                    deliveryStatus: ChatMessage.DeliveryStatus(rawValue: row.deliveryStatus ?? "") ?? .sent,
                    isImportedPlaintext: row.epoch < 0
                )
            }
        }
        return result
    }

    // MARK: - Reactions (CDGroupReaction)

    /// Plain snapshot of a `CDGroupReaction` row, safe to pass across contexts/actors.
    struct ReactionSnapshot: Identifiable, Equatable {
        var id: String { "\(targetTxId)-\(reactorAddress)" }
        let targetTxId: String
        let reactorAddress: String
        let emoji: String
        /// Send state of the local user's own reaction (`.sent` for everyone else's / delivered).
        /// `.failed` drives the error icon on the pill and the Retry under the message.
        var deliveryStatus: ChatMessage.DeliveryStatus = .sent
        /// When `.failed`, whether the failed change was an "add" or "remove" — so Retry re-attempts
        /// the correct action.
        var failedAction: String? = nil
        /// Reaction creation time (ms since epoch). Used to drop the green "sent" checkmark after a
        /// short window (the checkmark is a recent-confirmation, not a permanent badge).
        var blockTime: Int64 = 0
    }

    /// Replaces any existing reaction `reactorAddress` left on `targetTxId` with `emoji` - one
    /// reaction per (message, reactor), mirroring `MessageStore.upsertReaction`'s 1:1 shape.
    func upsertGroupReaction(targetTxId: String, groupId: String, reactorAddress: String, emoji: String, reactionTxId: String?, blockTime: Int64, deliveryStatus: String? = nil, failedAction: String? = nil) {
        guard isLoaded else { return }
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroupReaction>(entityName: CDGroupReaction.entityName)
            request.predicate = NSPredicate(format: "targetTxId == %@ AND reactorAddress == %@", targetTxId, reactorAddress)
            let existing = (try? context.fetch(request)) ?? []
            let reaction = existing.first ?? CDGroupReaction(context: context)
            for duplicate in existing.dropFirst() {
                context.delete(duplicate)
            }
            reaction.targetTxId = targetTxId
            reaction.groupId = groupId
            reaction.reactorAddress = reactorAddress
            reaction.emoji = emoji
            reaction.reactionTxId = reactionTxId
            reaction.blockTime = blockTime
            reaction.deliveryStatus = deliveryStatus
            reaction.failedAction = failedAction
            save(context)
        }
    }

    /// Deletes `reactorAddress`'s reaction on `targetTxId`, if any.
    func removeGroupReaction(targetTxId: String, reactorAddress: String) {
        guard isLoaded else { return }
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroupReaction>(entityName: CDGroupReaction.entityName)
            request.predicate = NSPredicate(format: "targetTxId == %@ AND reactorAddress == %@", targetTxId, reactorAddress)
            let existing = (try? context.fetch(request)) ?? []
            for record in existing {
                context.delete(record)
            }
            save(context)
        }
    }

    /// All reactions for `groupId`, grouped by the message they target.
    func fetchGroupReactions(groupId: String) -> [String: [ReactionSnapshot]] {
        guard isLoaded else { return [:] }
        var grouped: [String: [ReactionSnapshot]] = [:]
        let context = viewContext
        context.performAndWait {
            let request = NSFetchRequest<CDGroupReaction>(entityName: CDGroupReaction.entityName)
            request.predicate = NSPredicate(format: "groupId == %@", groupId)
            guard let results = try? context.fetch(request) else { return }
            for record in results {
                guard let emoji = record.emoji else { continue }
                let status: ChatMessage.DeliveryStatus
                switch record.deliveryStatus {
                case "failed": status = .failed
                case "pending": status = .pending
                default: status = .sent
                }
                let snapshot = ReactionSnapshot(targetTxId: record.targetTxId, reactorAddress: record.reactorAddress, emoji: emoji, deliveryStatus: status, failedAction: record.failedAction, blockTime: record.blockTime)
                grouped[record.targetTxId, default: []].append(snapshot)
            }
        }
        return grouped
    }

    /// Clear all local group data for the current wallet (e.g. on wallet reset/logout).
    /// Does NOT touch Keychain-held GroupBags - callers must separately delete those per group.
    func clearAll() {
        guard isLoaded else { return }
        let context = viewContext
        context.performAndWait {
            for entityName in [CDGroupMessage.entityName, CDGroup.entityName, CDGroupReaction.entityName] {
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
            AppLog.log("[GroupStore] Save failed: %@", error.localizedDescription)
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let groupEntity = NSEntityDescription()
        groupEntity.name = CDGroup.entityName
        groupEntity.managedObjectClassName = NSStringFromClass(CDGroup.self)
        groupEntity.properties = [
            makeAttribute(name: "groupId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "name", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "adminAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "adminXOnlyPubKeyHex", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "currentEpoch", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "createdAt", type: .dateAttributeType, optional: true),
            makeAttribute(name: "isAdmin", type: .booleanAttributeType, optional: false, defaultValue: false),
            makeAttribute(name: "membersJSON", type: .binaryDataAttributeType, optional: true)
        ]

        let messageEntity = NSEntityDescription()
        messageEntity.name = CDGroupMessage.entityName
        messageEntity.managedObjectClassName = NSStringFromClass(CDGroupMessage.self)
        messageEntity.properties = [
            makeAttribute(name: "txId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "groupId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "senderAddress", type: .stringAttributeType, optional: true),
            makeAttribute(name: "senderIdHex", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "epoch", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "msgIdHex", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "contentEncrypted", type: .binaryDataAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "isOutgoing", type: .booleanAttributeType, optional: false, defaultValue: false),
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true)
        ]

        let reactionEntity = NSEntityDescription()
        reactionEntity.name = CDGroupReaction.entityName
        reactionEntity.managedObjectClassName = NSStringFromClass(CDGroupReaction.self)
        reactionEntity.properties = [
            makeAttribute(name: "targetTxId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "groupId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "reactorAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "emoji", type: .stringAttributeType, optional: true),
            makeAttribute(name: "reactionTxId", type: .stringAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            // Send status for the local user's own reaction: nil/"sent" = delivered, "failed" = the
            // reaction tx never sent. `failedAction` records "add"/"remove" so Retry knows what to
            // re-attempt. Optional → lightweight migration on the existing store.
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true),
            makeAttribute(name: "failedAction", type: .stringAttributeType, optional: true)
        ]

        model.entities = [groupEntity, messageEntity, reactionEntity]
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

/// Plain snapshot of a `CDGroupMessage` row, safe to pass across contexts/actors.
struct CDGroupMessageSnapshot: Sendable {
    let txId: String
    let groupId: String
    let senderAddress: String?
    let senderIdHex: String
    let epoch: UInt64
    let msgIdHex: String
    let contentEncrypted: Data
    let blockTime: Int64
    let isOutgoing: Bool
    let deliveryStatus: ChatMessage.DeliveryStatus
    // Imported-from-backup rows carry decrypted plaintext under a negative-epoch sentinel;
    // `contentEncrypted` is then the UTF-8 bytes of the message, not ciphertext.
    var isImportedPlaintext: Bool = false
}

// GroupStore only touches Core Data via context.performAndWait on its own contexts;
// treat as Sendable for structured concurrency usage (matches BroadcastStore's convention).
extension GroupStore: @unchecked Sendable {}

@objc(CDGroup)
final class CDGroup: NSManagedObject {
    static let entityName = "CDGroup"

    @NSManaged var groupId: String
    @NSManaged var name: String
    @NSManaged var adminAddress: String
    @NSManaged var adminXOnlyPubKeyHex: String
    @NSManaged var currentEpoch: Int64
    @NSManaged var createdAt: Date?
    @NSManaged var isAdmin: Bool
    @NSManaged var membersJSON: Data?
}

@objc(CDGroupMessage)
final class CDGroupMessage: NSManagedObject {
    static let entityName = "CDGroupMessage"

    @NSManaged var txId: String
    @NSManaged var groupId: String
    @NSManaged var senderAddress: String?
    @NSManaged var senderIdHex: String
    @NSManaged var epoch: Int64
    @NSManaged var msgIdHex: String
    @NSManaged var contentEncrypted: Data?
    @NSManaged var blockTime: Int64
    @NSManaged var isOutgoing: Bool
    @NSManaged var deliveryStatus: String?
}

/// A reaction (tapback) sent or received on a group message - see `MessageReactionContent`.
/// `emoji` is stored as plain text, unlike `CDGroupMessage.contentEncrypted` above - a reaction
/// carries no independent at-rest encryption key here (this store has none of its own; group
/// message content is protected by `GroupCipher`'s own crypto in transit and only ever decrypted
/// to plaintext for display, never re-encrypted just for local storage).
@objc(CDGroupReaction)
final class CDGroupReaction: NSManagedObject {
    static let entityName = "CDGroupReaction"

    @NSManaged var targetTxId: String
    @NSManaged var groupId: String
    @NSManaged var reactorAddress: String
    @NSManaged var emoji: String?
    @NSManaged var reactionTxId: String?
    @NSManaged var blockTime: Int64
    @NSManaged var deliveryStatus: String?
    @NSManaged var failedAction: String?
}
