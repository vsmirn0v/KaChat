import Foundation
import CoreData
import CryptoKit
import OSLog
#if canImport(SQLite3)
import SQLite3
#endif

struct StoredMessage {
    let contactAddress: String
    let message: ChatMessage
}

struct ConversationMeta {
    let contactAddress: String
    let id: UUID
    let unreadCount: Int
    let lastMessageAt: Date?
    // Read status sync fields
    let lastReadTxId: String?
    let lastReadBlockTime: Int64
    let lastReadAt: Date?
}

final class MessageStore {
    static let shared = MessageStore()
    static let dpiCorruptionWarningKey = "messageStoreDpiCorruptionWarning"
    static let dpiCorruptionWarningEndpointKey = "messageStoreDpiCorruptionEndpoint"
    static let dpiCorruptionWarningDateKey = "messageStoreDpiCorruptionDate"

    /// Device-local Core Data. Messages never leave this store on their own: cross-device
    /// history is Nextcloud's job (an encrypted archive the user's own server carries - see
    /// `NextcloudService`), and this used to be an `NSPersistentCloudKitContainer` mirroring
    /// every wallet into its own iCloud zone as well. That path is gone: no container, no
    /// zones, no import/export cycles to wait on, and nothing about the wallet reaches Apple.
    private let container: NSPersistentContainer
    private var isLoaded = false
    private var didLogMissingStore = false
    private let inMemoryMode: Bool
    /// Bumped on every load. A load that finishes after a later one began belongs to a wallet
    /// the store has moved past; its file is detached instead of joining the new one.
    private var loadGeneration = 0

    /// Current wallet address. Each wallet has its own SQLite store.
    /// Call `setCurrentWallet()` to switch wallets - this reloads the persistent store.
    private(set) var currentWalletAddress: String?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kachat.app",
        category: "MessageStore"
    )

    private func logInfo(_ format: String, _ args: CVarArg...) {
        let message: String
        if args.isEmpty {
            message = format
        } else {
            message = String(format: format, arguments: args)
        }
        logger.info("\(message, privacy: .public)")
    }

    func markDpiCorruptionWarning(endpoint: String) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: MessageStore.dpiCorruptionWarningKey)
        defaults.set(endpoint, forKey: MessageStore.dpiCorruptionWarningEndpointKey)
        defaults.set(Date().timeIntervalSince1970, forKey: MessageStore.dpiCorruptionWarningDateKey)
    }

    func clearDpiCorruptionWarning() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: MessageStore.dpiCorruptionWarningKey)
        defaults.removeObject(forKey: MessageStore.dpiCorruptionWarningEndpointKey)
        defaults.removeObject(forKey: MessageStore.dpiCorruptionWarningDateKey)
    }

    func destroyLocalStoreFiles() async {
        resetViewContextBeforeStoreRemoval()
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
            } catch {
                self.logInfo("[MessageStore] Failed to remove store before delete: %@", error.localizedDescription)
            }
        }

        let url = storeURLForWallet(currentWalletAddress)
        let walURL = url.appendingPathExtension("-wal")
        let shmURL = url.appendingPathExtension("-shm")

        for fileURL in [url, walURL, shmURL] {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    self.logInfo("[MessageStore] Deleted store file %@", fileURL.lastPathComponent)
                } catch {
                    self.logInfo("[MessageStore] Failed to delete %@: %@", fileURL.lastPathComponent, error.localizedDescription)
                }
            }
        }

        isLoaded = false
        didLogMissingStore = false
    }

    private func resetViewContextBeforeStoreRemoval() {
        viewContext.performAndWait {
            if viewContext.hasChanges {
                viewContext.rollback()
            }
            viewContext.reset()
        }
    }

    var viewContext: NSManagedObjectContext { container.viewContext }
    var isStoreLoaded: Bool { isLoaded }

    /// Returns the store file URL for a wallet address. The 8-byte hash suffix is the same
    /// scheme every other per-wallet scope in the app keys on (see KeychainService).
    private func storeURLForWallet(_ walletAddress: String?) -> URL {
        guard let walletAddress = walletAddress else {
            // Legacy/default store for when no wallet is set
            return Self.defaultStoreURL()
        }
        let hash = SHA256.hash(data: walletAddress.data(using: .utf8) ?? Data())
        let hashPrefix = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent("KasiaMessages-\(hashPrefix).sqlite")
    }

    init(inMemory: Bool = false) {
        self.inMemoryMode = inMemory
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "KasiaMessages", managedObjectModel: model)

        // Start with no stores - will be loaded when setCurrentWallet is called
        container.persistentStoreDescriptions = []

        // Load a temporary default store for initial state (will be replaced when wallet is set)
        let description = NSPersistentStoreDescription()
        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        } else {
            description.url = Self.defaultStoreURL()
        }

        configureStoreDescription(description)
        container.persistentStoreDescriptions = [description]
        loadPersistentStores(primaryDescription: description, completion: nil)
    }

    // MARK: - Wallet Switching

    /// Switch to a different wallet's message store.
    /// Each wallet has its own SQLite file for complete isolation.
    /// - Parameter walletAddress: The wallet's public address, or nil to use default store
    func setCurrentWallet(_ walletAddress: String?) {
        // Skip if already on this wallet
        guard walletAddress != currentWalletAddress else { return }

        self.logInfo("[MessageStore] Switching wallet store: \(currentWalletAddress ?? "none") → \(walletAddress ?? "none")")

        resetViewContextBeforeStoreRemoval()

        // Remove existing stores
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
            } catch {
                self.logInfo("[MessageStore] Failed to remove store: \(error)")
            }
        }

        // Update current wallet
        currentWalletAddress = walletAddress
        isLoaded = false
        didLogMissingStore = false

        // Create new store description for this wallet
        let storeURL = inMemoryMode ? URL(fileURLWithPath: "/dev/null") : storeURLForWallet(walletAddress)
        let description = NSPersistentStoreDescription(url: storeURL)
        configureStoreDescription(description)

        container.persistentStoreDescriptions = [description]
        loadPersistentStores(primaryDescription: description, completion: nil)

        self.logInfo("[MessageStore] Wallet store loaded: \(storeURL.lastPathComponent)")
    }

    /// Switch wallet store asynchronously with completion callback
    func setCurrentWallet(_ walletAddress: String?, completion: (() -> Void)?) {
        guard walletAddress != currentWalletAddress else {
            completion?()
            return
        }

        self.logInfo("[MessageStore] Switching wallet store async: \(currentWalletAddress ?? "none") → \(walletAddress ?? "none")")

        resetViewContextBeforeStoreRemoval()

        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
            } catch {
                self.logInfo("[MessageStore] Failed to remove store: \(error)")
            }
        }

        currentWalletAddress = walletAddress
        isLoaded = false
        didLogMissingStore = false

        let storeURL = inMemoryMode ? URL(fileURLWithPath: "/dev/null") : storeURLForWallet(walletAddress)
        let description = NSPersistentStoreDescription(url: storeURL)
        configureStoreDescription(description)

        container.persistentStoreDescriptions = [description]
        loadPersistentStores(primaryDescription: description, completion: completion)
    }

    /// Switch wallet store asynchronously. `container.loadPersistentStores` (invoked inside the
    /// completion-based overload below) has no built-in timeout, and a store load that stalls -
    /// a WAL recovery after a jetsam, a migration on a large file - would otherwise block this
    /// `await` (and everything downstream of it, e.g. `WalletManager.importWallet` during
    /// account creation) indefinitely with no visible error. The store keeps loading in the
    /// background regardless of the timeout; this only stops making the caller wait on it past
    /// a point where something is clearly wrong.
    func setCurrentWallet(_ walletAddress: String?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeLock = NSLock()
            var hasResumed = false
            func resumeOnce() {
                resumeLock.lock()
                let alreadyResumed = hasResumed
                hasResumed = true
                resumeLock.unlock()
                guard !alreadyResumed else { return }
                continuation.resume()
            }

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.logInfo("[MessageStore] setCurrentWallet timed out waiting for the persistent store to finish loading - proceeding anyway.")
                resumeOnce()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeoutWorkItem)

            setCurrentWallet(walletAddress) {
                timeoutWorkItem.cancel()
                resumeOnce()
            }
        }
    }

    // Runs on a background context (not `viewContext`) since this can be asked to fetch and
    // AES-decrypt an entire wallet's worth of messages - e.g. every time a handshake's self-stash
    // transaction confirms - and doing that synchronously on `viewContext` (main-queue-confined)
    // used to freeze the UI for as long as the fetch+decrypt took.
    func fetchConversationMeta() async -> [String: ConversationMeta] {
        guard ensureStoreLoaded() else { return [:] }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: ConversationMeta], Never>) in
            container.performBackgroundTask { context in
                var result: [String: ConversationMeta] = [:]
                let request = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
                request.includesPendingChanges = true
                // Filter by wallet address if set
                if let walletAddress = walletAddress {
                    request.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddress)
                }
                do {
                    let conversations = try context.fetch(request)
                    for conversation in conversations {
                        let id = conversation.conversationId ?? UUID()
                        let unread = Int(conversation.unreadCount)
                        let candidate = ConversationMeta(
                            contactAddress: conversation.contactAddress,
                            id: id,
                            unreadCount: unread,
                            lastMessageAt: conversation.lastMessageAt,
                            lastReadTxId: conversation.lastReadTxId,
                            lastReadBlockTime: conversation.lastReadBlockTime,
                            lastReadAt: conversation.lastReadAt
                        )
                        if let existing = result[conversation.contactAddress] {
                            // Merge duplicate rows deterministically:
                            // 1) higher read cursor wins
                            // 2) for equal cursor, prefer lower unread (avoid badge resurrection)
                            // 3) then newest update timestamp
                            let useCandidate: Bool
                            if candidate.lastReadBlockTime != existing.lastReadBlockTime {
                                useCandidate = candidate.lastReadBlockTime > existing.lastReadBlockTime
                            } else if candidate.unreadCount != existing.unreadCount {
                                useCandidate = candidate.unreadCount < existing.unreadCount
                            } else {
                                useCandidate = (candidate.lastReadAt ?? .distantPast) > (existing.lastReadAt ?? .distantPast)
                            }
                            result[conversation.contactAddress] = useCandidate ? candidate : existing
                        } else {
                            result[conversation.contactAddress] = candidate
                        }
                    }
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch conversation meta: \(error)")
                }
                continuation.resume(returning: result)
            }
        }
    }

    func fetchAllMessages(decryptionKey: SymmetricKey) async -> [StoredMessage] {
        guard ensureStoreLoaded() else { return [] }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[StoredMessage], Never>) in
            container.performBackgroundTask { context in
                var results: [StoredMessage] = []
                let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
                request.includesPendingChanges = true
                // Filter by wallet address if set
                if let walletAddress = walletAddress {
                    request.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddress)
                }
                do {
                    let records = try context.fetch(request)
                    results = records.compactMap { record in
                        guard let message = self.decodeMessage(record, key: decryptionKey) else { return nil }
                        return StoredMessage(contactAddress: record.contactAddress, message: message)
                    }
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch messages: \(error)")
                }
                continuation.resume(returning: results)
            }
        }
    }

    /// The messages the conversation list actually keeps in memory, fetched as that set instead
    /// of as everything.
    ///
    /// `_loadMessagesFromStoreIfNeeded` runs after every store write that matters to the list,
    /// and it called `fetchAllMessages` - every row for the wallet,
    /// decrypted, photos and voice notes inline as base64 - only for `buildMergedConversations`
    /// to trim each conversation down to `inMemoryConversationWindowSize` plus its sticky
    /// messages afterwards. A two-year wallet decrypted tens of MB of history to keep 160
    /// messages per chat, repeatedly, while the user was texting.
    ///
    /// This produces the same set directly: per contact the newest `window` rows, plus every
    /// handshake and every message not marked sent - the exact `trimMessagesForMemory`
    /// exemption - so the trim afterwards has nothing left to drop. Order is unspecified; the
    /// caller groups by contact and sorts. The backup and import paths still use
    /// `fetchAllMessages`, because they genuinely need everything.
    func fetchConversationWindows(decryptionKey: SymmetricKey, window: Int) async -> [StoredMessage] {
        guard ensureStoreLoaded() else { return [] }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[StoredMessage], Never>) in
            container.performBackgroundTask { context in
                var results: [StoredMessage] = []
                do {
                    let walletPredicate: NSPredicate? = walletAddress.map {
                        NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", $0)
                    }
                    func scoped(_ predicate: NSPredicate) -> NSPredicate {
                        guard let walletPredicate else { return predicate }
                        return NSCompoundPredicate(andPredicateWithSubpredicates: [walletPredicate, predicate])
                    }

                    // Which conversations exist: one column, distinct.
                    let addressRequest = NSFetchRequest<NSDictionary>(entityName: CDMessage.entityName)
                    addressRequest.resultType = .dictionaryResultType
                    addressRequest.propertiesToFetch = ["contactAddress"]
                    addressRequest.returnsDistinctResults = true
                    if let walletPredicate { addressRequest.predicate = walletPredicate }
                    let addresses = try context.fetch(addressRequest).compactMap { $0["contactAddress"] as? String }

                    // Sticky rows for the whole wallet in one query: handshakes, anything not marked
                    // sent, and pending sends - a nil status decodes as pending when the txId says
                    // so (see `ChatMessage.init(from:)`), so the txId prefix is matched too.
                    var seen = Set<NSManagedObjectID>()
                    let stickyRequest = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                    stickyRequest.predicate = scoped(NSPredicate(
                        format: "messageType == %@ OR (deliveryStatus != nil AND deliveryStatus != %@) OR txId BEGINSWITH %@",
                        ChatMessage.MessageType.handshake.rawValue,
                        ChatMessage.DeliveryStatus.sent.rawValue,
                        "pending_"
                    ))
                    stickyRequest.includesPendingChanges = true
                    for record in try context.fetch(stickyRequest) {
                        seen.insert(record.objectID)
                        if let message = self.decodeMessage(record, key: decryptionKey) {
                            results.append(StoredMessage(contactAddress: record.contactAddress, message: message))
                        }
                    }

                    // The newest `window` rows of each conversation. Duplicate txIds across rows
                    // still come through, as before; the caller's `preferMessage` settles them.
                    for address in addresses {
                        let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                        request.predicate = scoped(NSPredicate(format: "contactAddress == %@", address))
                        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                        request.fetchLimit = window
                        request.includesPendingChanges = true
                        for record in try context.fetch(request) where !seen.contains(record.objectID) {
                            seen.insert(record.objectID)
                            if let message = self.decodeMessage(record, key: decryptionKey) {
                                results.append(StoredMessage(contactAddress: record.contactAddress, message: message))
                            }
                        }
                    }
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch conversation windows: \(error)")
                }
                continuation.resume(returning: results)
            }
        }
    }

    struct MessagePageCursor: Equatable {
        let blockTime: Int64
        let timestamp: Date
        let txId: String
    }

    struct MessagePage {
        let messages: [ChatMessage]
        let oldestCursor: MessagePageCursor?
        let hasMore: Bool
    }

    /// Async/background keyset page fetch.
    func fetchMessagesPageAsync(
        contactAddress: String,
        decryptionKey: SymmetricKey,
        limit: Int,
        olderThan cursor: MessagePageCursor? = nil
    ) async -> MessagePage {
        guard ensureStoreLoaded() else { return MessagePage(messages: [], oldestCursor: nil, hasMore: false) }
        guard limit > 0 else { return MessagePage(messages: [], oldestCursor: nil, hasMore: false) }

        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { continuation in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                request.predicate = self.pagedMessagesPredicate(
                    contactAddress: contactAddress,
                    walletAddress: walletAddress,
                    olderThan: cursor
                )
                request.sortDescriptors = [
                    NSSortDescriptor(key: "blockTime", ascending: false),
                    NSSortDescriptor(key: "timestamp", ascending: false),
                    NSSortDescriptor(key: "txId", ascending: false)
                ]
                request.fetchLimit = limit + 1
                request.includesPendingChanges = false

                do {
                    let records = try context.fetch(request)
                    continuation.resume(returning: self.makePageResult(from: records, key: decryptionKey, limit: limit))
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch messages page async for %@: %@", contactAddress, error.localizedDescription)
                    continuation.resume(returning: MessagePage(messages: [], oldestCursor: nil, hasMore: false))
                }
            }
        }
    }

    private func pagedMessagesPredicate(
        contactAddress: String,
        walletAddress: String?,
        olderThan cursor: MessagePageCursor?
    ) -> NSPredicate {
        let basePredicate: NSPredicate
        if let walletAddress {
            basePredicate = NSPredicate(
                format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)",
                contactAddress,
                walletAddress
            )
        } else {
            basePredicate = NSPredicate(format: "contactAddress == %@", contactAddress)
        }

        guard let cursor else { return basePredicate }

        let olderPredicate = NSPredicate(
            format: "(blockTime < %lld) OR (blockTime == %lld AND timestamp < %@) OR (blockTime == %lld AND timestamp == %@ AND txId < %@)",
            cursor.blockTime,
            cursor.blockTime,
            cursor.timestamp as NSDate,
            cursor.blockTime,
            cursor.timestamp as NSDate,
            cursor.txId
        )
        return NSCompoundPredicate(andPredicateWithSubpredicates: [basePredicate, olderPredicate])
    }

    private func makePageResult(from records: [CDMessage], key: SymmetricKey, limit: Int) -> MessagePage {
        guard !records.isEmpty else {
            return MessagePage(messages: [], oldestCursor: nil, hasMore: false)
        }

        let decoded = records.compactMap { decodeMessage($0, key: key) }
        guard !decoded.isEmpty else {
            return MessagePage(messages: [], oldestCursor: nil, hasMore: false)
        }

        let hasMore = decoded.count > limit
        let pageSlice = hasMore ? Array(decoded.prefix(limit)) : decoded
        let oldest = pageSlice.last
        let cursor = oldest.map {
            MessagePageCursor(
                blockTime: Int64($0.blockTime),
                timestamp: $0.timestamp,
                txId: $0.txId
            )
        }

        // Query order is newest-first. Return oldest-first for prepend merges.
        return MessagePage(messages: Array(pageSlice.reversed()), oldestCursor: cursor, hasMore: hasMore)
    }

    /// Count messages for a single conversation in current wallet scope.
    /// Runs on a background context - see `fetchConversationMeta` for why blocking `viewContext`
    /// here used to be able to freeze the UI (e.g. this is on the read-receipt/notification path).
    func countMessages(contactAddress: String) async -> Int {
        guard ensureStoreLoaded() else { return 0 }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                if let walletAddress {
                    request.predicate = NSPredicate(
                        format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)",
                        contactAddress,
                        walletAddress
                    )
                } else {
                    request.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
                }
                request.includesPendingChanges = false
                do {
                    continuation.resume(returning: try context.count(for: request))
                } catch {
                    self.logInfo("[MessageStore] Failed to count messages for %@: %@", contactAddress, error.localizedDescription)
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    /// Count sent and received messages for a single conversation in current wallet scope.
    /// Runs on a background context - see `fetchConversationMeta` for why blocking `viewContext`
    /// here used to be able to freeze the UI.
    func messageStats(contactAddress: String) async -> (sent: Int, received: Int) {
        guard ensureStoreLoaded() else { return (0, 0) }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<(sent: Int, received: Int), Never>) in
            container.performBackgroundTask { context in
                let basePredicate: String
                let baseArgs: [Any]
                if let walletAddress {
                    basePredicate = "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)"
                    baseArgs = [contactAddress, walletAddress]
                } else {
                    basePredicate = "contactAddress == %@"
                    baseArgs = [contactAddress]
                }

                let sentRequest = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                sentRequest.predicate = NSPredicate(format: "\(basePredicate) AND isOutgoing == YES", argumentArray: baseArgs)
                sentRequest.includesPendingChanges = false

                let receivedRequest = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                receivedRequest.predicate = NSPredicate(format: "\(basePredicate) AND isOutgoing == NO", argumentArray: baseArgs)
                receivedRequest.includesPendingChanges = false

                do {
                    let sent = try context.count(for: sentRequest)
                    let received = try context.count(for: receivedRequest)
                    continuation.resume(returning: (sent, received))
                } catch {
                    self.logInfo("[MessageStore] Failed to count message stats for %@: %@", contactAddress, error.localizedDescription)
                    continuation.resume(returning: (0, 0))
                }
            }
        }
    }

    /// Single indexed-row lookup used from `findLocalMessage`. MUST be `async`: `ChatService` is
    /// `@MainActor`, and the UTXO-notification burst calls this once per incoming UTXO. The old
    /// synchronous `newBackgroundContext().performAndWait { fetch }` blocked the MAIN thread (a
    /// `performAndWait` blocks its *calling* thread no matter which context runs the block), and
    /// each fetch contended the persistent-store coordinator during a large import - N UTXOs -> N serialized main-thread stalls ->
    /// the app froze ~15s into sync. `performBackgroundTask` + a continuation suspends the awaiting
    /// main actor instead of blocking it, so the run loop stays live.
    func fetchMessage(txId: String, decryptionKey: SymmetricKey) async -> ChatMessage? {
        guard ensureStoreLoaded() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<ChatMessage?, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                request.predicate = NSPredicate(format: "txId == %@", txId)
                request.fetchLimit = 1
                var result: ChatMessage?
                do {
                    if let record = try context.fetch(request).first {
                        result = self.decodeMessage(record, key: decryptionKey)
                    }
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch message \(txId): \(error)")
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Check if a message exists with actual content (not placeholder) in the store - i.e.
    /// whether an archive restore has delivered the text of an outgoing message sent from
    /// another device. Runs on a background context - see `fetchConversationMeta` for
    /// why blocking `viewContext` here used to be able to freeze the UI.
    func hasMessageWithContent(txId: String) async -> Bool {
        guard ensureStoreLoaded() else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                request.predicate = NSPredicate(format: "txId == %@ AND contentEncrypted != nil", txId)
                request.fetchLimit = 1
                do {
                    let count = try context.count(for: request)
                    continuation.resume(returning: count > 0)
                } catch {
                    self.logInfo("[MessageStore] Failed to check message content \(txId): \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// True if `txId` is a reaction's own transaction id (`CDReaction.reactionTxId`) rather than a
    /// real message - a reaction never gets a `CDMessage` row on the device that actually decrypts
    /// it (see `MessageReactionCodec.parse` interception in `addMessageToConversation`), so when
    /// this wallet's own outgoing-message catch-up sync later re-discovers that same transaction
    /// from the indexer, it has no local content to find and would otherwise fall back to the
    /// "📤 Sent via another device" placeholder - permanently, since no real `CDMessage` will ever
    /// arrive to replace it. Checking this first lets the caller skip creating that placeholder
    /// entirely for a transaction that was always a reaction, never a message.
    /// `async` for the same reason as `fetchMessage` above: it's on the per-UTXO / push catch-up
    /// path off `@MainActor` code, and a synchronous `performAndWait` here blocked the main thread
    /// while contending the store coordinator.
    func isReactionTransaction(txId: String) async -> Bool {
        guard ensureStoreLoaded() else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDReaction>(entityName: CDReaction.entityName)
                request.predicate = NSPredicate(format: "reactionTxId == %@", txId)
                request.fetchLimit = 1
                let count = (try? context.count(for: request)) ?? 0
                continuation.resume(returning: count > 0)
            }
        }
    }

    /// One-time cleanup for placeholder messages already stuck from this bug before the fix:
    /// deletes any `CDMessage` whose txId is actually a reaction's own transaction id (per
    /// `isReactionTransaction`) - these can never resolve to real content since a reaction was
    /// never meant to be a message in the first place. Safe to call unconditionally on every
    /// launch; it's a no-op once a wallet's stuck placeholders (if any) have been cleared.
    /// Returns the txIds of whatever it deleted, so the caller can also drop them from any
    /// in-memory conversation state it's already loaded (this only touches Core Data).
    /// `async`: called on the main actor at every launch, and the old synchronous `performAndWait`
    /// scanned the whole reaction + message tables and blocked the main thread while contending the
    /// store coordinator - the same freeze class as the per-UTXO fetch. Now suspends
    /// via `performBackgroundTask` + continuation instead of blocking.
    @discardableResult
    func deleteStuckReactionPlaceholderMessages() async -> [String] {
        guard ensureStoreLoaded() else { return [] }
        let walletAddr = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            container.performBackgroundTask { context in
                var deletedTxIds: [String] = []
                let reactionRequest = NSFetchRequest<CDReaction>(entityName: CDReaction.entityName)
                guard let reactionTxIds = try? context.fetch(reactionRequest).compactMap({ $0.reactionTxId }),
                      !reactionTxIds.isEmpty else { continuation.resume(returning: deletedTxIds); return }

                let messageRequest = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                if let walletAddr {
                    messageRequest.predicate = NSPredicate(format: "txId IN %@ AND (walletAddress == %@ OR walletAddress == nil)", reactionTxIds, walletAddr)
                } else {
                    messageRequest.predicate = NSPredicate(format: "txId IN %@", reactionTxIds)
                }
                guard let stuckMessages = try? context.fetch(messageRequest), !stuckMessages.isEmpty else { continuation.resume(returning: deletedTxIds); return }
                for message in stuckMessages {
                    deletedTxIds.append(message.txId)
                    context.delete(message)
                }
                do {
                    try context.save()
                    self.logInfo("[MessageStore] Cleaned up %d stuck reaction-placeholder messages", stuckMessages.count)
                } catch {
                    self.logInfo("[MessageStore] Failed to clean up stuck reaction placeholders: \(error)")
                }
                continuation.resume(returning: deletedTxIds)
            }
        }
    }

    /// `onConversationProgress` (optional) fires after each conversation's records are staged
    /// in the background context, as `(done, total)`. Invoked on the Core Data background
    /// queue, so callers must hop to the main actor themselves. Drives the restore progress
    /// modal's determinate bar during archive imports.
    @discardableResult
    func syncFromConversations(
        _ conversations: [Conversation],
        encryptionKey: SymmetricKey,
        retention: MessageRetention,
        performMaintenance: Bool = true,
        onConversationProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Bool {
        guard ensureStoreLoaded() else { return false }
        let walletAddr = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            container.performBackgroundTask { context in
                var didWrite = false
                defer { continuation.resume(returning: didWrite) }
                context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy

                // Performance optimizations for batch writes
                context.automaticallyMergesChangesFromParent = false
                context.undoManager = nil
                context.shouldDeleteInaccessibleFaults = true
                context.stalenessInterval = 0.0

                let startTime = Date()
                var currentTxIds = Set<String>()
                var updatedCount = 0
                var skippedCount = 0

                // OPTIMIZATION: Batch fetch all existing messages at once (1 query vs N queries)
                let allTxIds = conversations.flatMap { $0.messages.map { $0.txId } }
                let batchStart = Date()
                let existingMessages = self.batchFetchMessages(txIds: allTxIds, walletAddress: walletAddr, in: context)
                let batchTime = Date().timeIntervalSince(batchStart) * 1000
                self.logInfo("[MessageStore] Batch fetch took %.0fms for %d messages", batchTime, allTxIds.count)

                let totalConversations = conversations.count
                for (conversationIndex, conversation) in conversations.enumerated() {
                    let conv = self.fetchOrCreateConversation(contactAddress: conversation.contact.address, walletAddress: walletAddr, in: context)

                    // Only update conversation if values differ
                    var convChanged = false
                    if conv.conversationId != conversation.id {
                        conv.conversationId = conversation.id
                        convChanged = true
                    }
                    let newUnread = Int64(conversation.unreadCount)
                    if conv.unreadCount != newUnread {
                        conv.unreadCount = newUnread
                        convChanged = true
                    }
                    let newLastMsg = conversation.lastMessage?.timestamp
                    if let newLastMsg = newLastMsg, conv.lastMessageAt != newLastMsg {
                        conv.lastMessageAt = newLastMsg
                        convChanged = true
                    }
                    if let walletAddr = walletAddr, conv.walletAddress != walletAddr {
                        conv.walletAddress = walletAddr
                        convChanged = true
                    }
                    if convChanged {
                        conv.updatedAt = Date()
                    }

                    for message in conversation.messages {
                        // Use cached lookup instead of individual fetch
                        let record = existingMessages[message.txId] ?? CDMessage(context: context)
                        let isNewRecord = record.messageId == nil

                        // Check if this record needs updating (diff-only writes)
                        var needsUpdate = isNewRecord

                        if !isNewRecord {
                            // Compare key fields to see if anything changed
                            needsUpdate = needsUpdate ||
                                record.deliveryStatus != message.deliveryStatus.rawValue ||
                                record.acceptingBlock != message.acceptingBlock
                        }

                        let isPlaceholder = message.isSentPlaceholder
                        let existingHasContent = record.contentEncrypted != nil
                        let shouldForceOutgoingContent = message.isOutgoing && !isPlaceholder

                        // If this is outgoing content with actual text, force an update so imports
                        // and cross-device restores can replace placeholder entries.
                        if shouldForceOutgoingContent {
                            needsUpdate = true
                        }

                        // If we have real content and the store doesn't, force an update.
                        if !isPlaceholder && !existingHasContent {
                            needsUpdate = true
                        }

                        if needsUpdate || isNewRecord {
                            record.messageId = message.id
                            record.txId = message.txId
                            record.contactAddress = conversation.contact.address
                            record.senderAddress = message.senderAddress
                            record.receiverAddress = message.receiverAddress
                            record.timestamp = message.timestamp
                            record.blockTime = Int64(message.blockTime)
                            record.acceptingBlock = message.acceptingBlock
                            record.isOutgoing = message.isOutgoing
                            record.messageType = message.messageType.rawValue
                            record.deliveryStatus = message.deliveryStatus.rawValue
                            record.updatedAt = Date()

                            if let walletAddr = walletAddr {
                                record.walletAddress = walletAddr
                            }

                            // Content update rules:
                            // - If new content is placeholder ("📤 Sent via another device"), NEVER overwrite
                            // - If existing record has content (e.g. from an archive restore), preserve it unless
                            //   new content is meaningfully different (not a placeholder)
                            // Only update content if:
                            // 1. New content is NOT a placeholder, AND
                            // 2. Either: existing record has no content, OR this is a new record, OR
                            // 3. This is an outgoing message with real content (force overwrite placeholders)
                            let shouldUpdateContent = !isPlaceholder && (shouldForceOutgoingContent || !existingHasContent || isNewRecord)

                            if shouldUpdateContent, let encrypted = self.encryptContent(message.content, key: encryptionKey) {
                                record.contentEncrypted = encrypted
                            } else if isPlaceholder && existingHasContent {
                                // Log when we preserve stored content over a placeholder
                                self.logInfo("[MessageStore] Preserving stored content for %@", message.txId)
                            }

                            updatedCount += 1
                        } else {
                            skippedCount += 1
                        }

                        currentTxIds.insert(message.txId)
                    }

                    onConversationProgress?(conversationIndex + 1, totalConversations)
                }

                // Only save if there are actual changes
                if context.hasChanges {
                    let saveStart = Date()
                    do {
                        try context.save()
                        didWrite = true
                        let saveTime = Date().timeIntervalSince(saveStart) * 1000
                        let totalTime = Date().timeIntervalSince(startTime) * 1000
                        self.logInfo("[MessageStore] Sync saved: %d updated, %d unchanged (skipped) | save: %.0fms, total: %.0fms",
                              updatedCount, skippedCount, saveTime, totalTime)
                    } catch {
                        self.logInfo("[MessageStore] Failed to save messages: \(error)")
                    }
                } else {
                    let totalTime = Date().timeIntervalSince(startTime) * 1000
                    self.logInfo("[MessageStore] Sync: no changes to save (%d records checked) | total: %.0fms",
                          updatedCount + skippedCount, totalTime)
                }

                if performMaintenance {
                    let didPrune = self.pruneStalePendingMessages(keeping: currentTxIds, in: context)
                    let didRetain = self.applyRetention(retention, in: context)
                    let didDedupe = self.dedupeMessagesIfNeeded(in: context, walletAddr: walletAddr)
                    if didPrune || didRetain || didDedupe {
                        didWrite = true
                    }
                }
            }
        }
    }

    func updateConversationUnread(contactAddress: String, unreadCount: Int) {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        context.perform {
            let newUnread = Int64(unreadCount)
            let request = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
            if let walletAddr = walletAddr {
                request.predicate = NSPredicate(
                    format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)",
                    contactAddress,
                    walletAddr
                )
            } else {
                request.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
            }
            do {
                var conversations = try context.fetch(request)
                if conversations.isEmpty {
                    conversations = [self.fetchOrCreateConversation(contactAddress: contactAddress, walletAddress: walletAddr, in: context)]
                }

                var didChange = false
                for conv in conversations {
                    if conv.unreadCount != newUnread {
                        conv.unreadCount = newUnread
                        conv.updatedAt = Date()
                        if let walletAddr = walletAddr {
                            conv.walletAddress = walletAddr
                        }
                        didChange = true
                    }
                }
                guard didChange else { return }
                try context.save()
            } catch {
                self.logInfo("[MessageStore] Failed to update conversation unread: \(error)")
            }
        }
    }

    /// Permanently deletes every message and the conversation row for a single contact - the
    /// per-contact counterpart to `clearAll()`, used by `ContactsManager.deleteContact` so a
    /// deleted chat's history doesn't linger even though its `Contact` is gone.
    ///
    /// Deletes via plain `context.delete(...)` + `save()` rather than `NSBatchDeleteRequest`:
    /// a batch delete executes directly against the SQLite store and bypasses the managed object
    /// context's save cycle, so the view context never learns of it and the "deleted" chat
    /// lingers on screen until the next full reload. A normal delete+save merges into the view
    /// context at once (same pattern already used by `dedupeMessagesIfNeeded`).
    func deleteConversation(contactAddress: String) async {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        // `perform`, not `performAndWait`: the only caller is `ContactsManager.deleteContact` on
        // the main actor, and `performAndWait` blocks the CALLING thread for the whole delete -
        // an unbounded fetch of every message for the contact, deleted one by one so the view
        // context sees each deletion. A chat with 20k messages froze the UI for the duration. The
        // sibling paths in this file already had this fixed; this one was missed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          context.perform {
            defer { continuation.resume() }
            guard !self.container.persistentStoreCoordinator.persistentStores.isEmpty else { return }

            let messageFetch = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
            // Rows are only being deleted, so their (possibly multi-MB, base64 media) content
            // never needs faulting in.
            messageFetch.includesPropertyValues = false
            let conversationFetch = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
            if let walletAddr = walletAddr {
                messageFetch.predicate = NSPredicate(
                    format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)",
                    contactAddress, walletAddr
                )
                conversationFetch.predicate = NSPredicate(
                    format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)",
                    contactAddress, walletAddr
                )
            } else {
                messageFetch.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
                conversationFetch.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
            }

            do {
                let messages = try context.fetch(messageFetch)
                for message in messages {
                    context.delete(message)
                }
                let conversations = try context.fetch(conversationFetch)
                for conversation in conversations {
                    context.delete(conversation)
                }
                if context.hasChanges {
                    try context.save()
                }
                self.logInfo("[MessageStore] Deleted conversation for %@: %d messages", contactAddress, messages.count)
            } catch {
                self.logInfo("[MessageStore] Failed to delete conversation for \(contactAddress): \(error)")
            }
          }
        }
    }

    // MARK: - Read Status Sync

    /// Read status info for a conversation
    struct ReadStatus {
        let contactAddress: String
        let lastReadTxId: String?
        let lastReadBlockTime: Int64
        let lastReadAt: Date?
    }

    /// Update read status for a conversation.
    /// Updates when:
    /// - new blockTime is greater than existing, or
    /// - forceUpdate is true, or
    /// - blockTime is equal but unreadCount is still non-zero / txId changed (stale local state repair).
    /// This implements "last-read-wins" conflict resolution.
    /// - Parameters:
    ///   - contactAddress: The contact's address
    ///   - lastReadTxId: txId of the last read message
    ///   - lastReadBlockTime: blockTime of the last read message
    ///   - lastReadAt: When the message was read
    ///   - forceUpdate: If true, skip the blockTime comparison (an archive restore is authoritative)
    /// Fire-and-forget wrapper, kept for callers that don't need the write durably committed
    /// before continuing - see `updateReadStatusAndWait` for callers that do (e.g.
    /// `ChatService.markConversationAsRead`, where a force-quit racing this write used to be
    /// able to revert the read cursor to its old value on next launch).
    func updateReadStatus(contactAddress: String, lastReadTxId: String?, lastReadBlockTime: Int64, lastReadAt: Date? = nil, forceUpdate: Bool = false) {
        Task {
            await updateReadStatusAndWait(
                contactAddress: contactAddress,
                lastReadTxId: lastReadTxId,
                lastReadBlockTime: lastReadBlockTime,
                lastReadAt: lastReadAt,
                forceUpdate: forceUpdate
            )
        }
    }

    /// Awaitable version of `updateReadStatus` - resumes only once the Core Data save has
    /// actually completed, so a caller can be sure the read cursor is durably on disk (and safe
    /// from being lost to a force-quit) before it returns.
    func updateReadStatusAndWait(contactAddress: String, lastReadTxId: String?, lastReadBlockTime: Int64, lastReadAt: Date? = nil, forceUpdate: Bool = false) async {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let context = container.newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
            context.perform {
                defer { continuation.resume() }
                let request = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
                if let walletAddr = walletAddr {
                    request.predicate = NSPredicate(
                        format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)",
                        contactAddress,
                        walletAddr
                    )
                } else {
                    request.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
                }

                do {
                    var conversations = try context.fetch(request)
                    if conversations.isEmpty {
                        conversations = [self.fetchOrCreateConversation(contactAddress: contactAddress, walletAddress: walletAddr, in: context)]
                    }

                    var didChange = false
                    var skippedExistingBlockTime: Int64?
                    for conv in conversations {
                        // Usually we only advance when blockTime increases, but allow equal-blockTime
                        // updates to repair stale unread counters after store merges/reloads.
                        let existingBlockTime = conv.lastReadBlockTime
                        let hasSameBlockTimeUpdate = lastReadBlockTime == existingBlockTime &&
                            (conv.unreadCount > 0 || conv.lastReadTxId != lastReadTxId)
                        guard forceUpdate || lastReadBlockTime > existingBlockTime || hasSameBlockTimeUpdate else {
                            skippedExistingBlockTime = existingBlockTime
                            continue
                        }

                        conv.lastReadTxId = lastReadTxId
                        conv.lastReadBlockTime = lastReadBlockTime
                        conv.lastReadAt = lastReadAt ?? Date()
                        conv.updatedAt = Date()

                        // Also update unreadCount to 0 since we've read up to this point
                        conv.unreadCount = 0

                        if let walletAddr = walletAddr {
                            conv.walletAddress = walletAddr
                        }
                        didChange = true
                    }

                    guard didChange else {
                        self.logInfo("[MessageStore] Skipping read status update for %@ (existing: %lld, new: %lld)",
                              String(contactAddress.suffix(8)), skippedExistingBlockTime ?? 0, lastReadBlockTime)
                        return
                    }
                    try context.save()
                    self.logInfo("[MessageStore] Updated read status for %@: blockTime=%lld",
                          String(contactAddress.suffix(8)), lastReadBlockTime)
                } catch {
                    self.logInfo("[MessageStore] Failed to update read status: \(error)")
                }
            }
        }
    }

    /// Fetch read status for a specific conversation. Runs on a background context - see
    /// `fetchConversationMeta` for why blocking `viewContext` here used to be able to freeze the UI.
    func fetchReadStatus(contactAddress: String) async -> ReadStatus? {
        guard ensureStoreLoaded() else { return nil }
        let walletAddr = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<ReadStatus?, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
                if let walletAddr {
                    request.predicate = NSPredicate(format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)", contactAddress, walletAddr)
                } else {
                    request.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
                }
                request.fetchLimit = 1
                do {
                    guard let conv = try context.fetch(request).first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: ReadStatus(
                        contactAddress: conv.contactAddress,
                        lastReadTxId: conv.lastReadTxId,
                        lastReadBlockTime: conv.lastReadBlockTime,
                        lastReadAt: conv.lastReadAt
                    ))
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch read status: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Fetch the latest incoming message cursor for a conversation.
    /// Uses persistent store data so read cursor updates do not depend on in-memory pagination
    /// window. Runs on a background context - see `fetchConversationMeta` for why blocking
    /// `viewContext` here used to be able to freeze the UI (this runs every time a chat is opened,
    /// via `markConversationAsRead`).
    func fetchLatestIncomingCursor(contactAddress: String) async -> (txId: String?, blockTime: Int64)? {
        guard ensureStoreLoaded() else { return nil }
        let walletAddr = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<(txId: String?, blockTime: Int64)?, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                if let walletAddr {
                    request.predicate = NSPredicate(
                        format: "contactAddress == %@ AND isOutgoing == NO AND (walletAddress == %@ OR walletAddress == nil)",
                        contactAddress,
                        walletAddr
                    )
                } else {
                    request.predicate = NSPredicate(
                        format: "contactAddress == %@ AND isOutgoing == NO",
                        contactAddress
                    )
                }
                request.sortDescriptors = [NSSortDescriptor(key: "blockTime", ascending: false)]
                request.fetchLimit = 1
                do {
                    guard let msg = try context.fetch(request).first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (txId: msg.txId, blockTime: msg.blockTime))
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch latest incoming cursor: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Fetch all read statuses. Runs on a background context - see
    /// `fetchConversationMeta` for why blocking `viewContext` here used to be able to freeze the UI.
    func fetchAllReadStatuses() async -> [ReadStatus] {
        guard ensureStoreLoaded() else { return [] }
        let walletAddr = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[ReadStatus], Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
                if let walletAddr {
                    request.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
                }
                do {
                    let conversations = try context.fetch(request)
                    continuation.resume(returning: conversations.map { conv in
                        ReadStatus(
                            contactAddress: conv.contactAddress,
                            lastReadTxId: conv.lastReadTxId,
                            lastReadBlockTime: conv.lastReadBlockTime,
                            lastReadAt: conv.lastReadAt
                        )
                    })
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch all read statuses: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }

    // MARK: - Per-Device Read Markers (CDReadMarker)

    /// Upsert a read marker for the current device. Only updates if blockTime advances (monotonic).
    /// - Parameters:
    ///   - conversationId: Contact address identifying the conversation
    ///   - deviceId: Device identifier from KeychainService
    ///   - lastReadTxId: txId of the last read message (optional)
    ///   - lastReadBlockTime: blockTime of the last read message
    func upsertReadMarker(conversationId: String, deviceId: String, lastReadTxId: String?, lastReadBlockTime: Int64) {
        guard ensureStoreLoaded() else { return }
        guard let walletAddress = currentWalletAddress else {
            self.logInfo("[MessageStore] upsertReadMarker: No wallet set")
            return
        }

        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        context.perform {
            let request = NSFetchRequest<CDReadMarker>(entityName: CDReadMarker.entityName)
            request.predicate = NSPredicate(
                format: "walletAddress == %@ AND conversationId == %@ AND deviceId == %@",
                walletAddress, conversationId, deviceId
            )
            request.fetchLimit = 1

            do {
                let existing = try context.fetch(request).first
                let marker: CDReadMarker

                if let existing = existing {
                    // Monotonic update with equal-blockTime tie repair:
                    // allow updating txId/timestamp when blockTime is equal.
                    let shouldAdvance = lastReadBlockTime > existing.lastReadBlockTime
                    let shouldRepairEqual = lastReadBlockTime == existing.lastReadBlockTime &&
                        existing.lastReadTxId != lastReadTxId &&
                        lastReadTxId != nil
                    guard shouldAdvance || shouldRepairEqual else {
                        self.logInfo("[MessageStore] Skipping read marker update for %@ (existing: %lld, new: %lld)",
                              String(conversationId.suffix(8)), existing.lastReadBlockTime, lastReadBlockTime)
                        return
                    }
                    marker = existing
                } else {
                    marker = CDReadMarker(context: context)
                    marker.walletAddress = walletAddress
                    marker.conversationId = conversationId
                    marker.deviceId = deviceId
                }

                marker.lastReadTxId = lastReadTxId
                marker.lastReadBlockTime = lastReadBlockTime
                marker.updatedAt = Date()

                try context.save()
                self.logInfo("[MessageStore] Upserted read marker for %@ device=%@ blockTime=%lld",
                      String(conversationId.suffix(8)), String(deviceId.prefix(8)), lastReadBlockTime)
            } catch {
                self.logInfo("[MessageStore] Failed to upsert read marker: \(error)")
            }
        }
    }

    /// Effective read status computed from all device markers for a conversation
    struct EffectiveReadStatus {
        let conversationId: String
        let lastReadBlockTime: Int64
        let lastReadTxId: String?
        let deviceCount: Int
    }

    /// Recompute effective read status by taking max(blockTime) across all device markers
    /// - Parameter conversationId: Contact address identifying the conversation
    /// - Returns: Effective read status or nil if no markers exist
    /// Runs on a background context - see `fetchConversationMeta` for why blocking `viewContext`
    /// here used to be able to freeze the UI.
    func recomputeEffectiveReadStatus(conversationId: String) async -> EffectiveReadStatus? {
        guard ensureStoreLoaded() else { return nil }
        guard let walletAddress = currentWalletAddress else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<EffectiveReadStatus?, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDReadMarker>(entityName: CDReadMarker.entityName)
                request.predicate = NSPredicate(
                    format: "walletAddress == %@ AND conversationId == %@",
                    walletAddress, conversationId
                )

                do {
                    let markers = try context.fetch(request)
                    guard !markers.isEmpty else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // Pick marker with highest blockTime; break ties with updatedAt.
                    let best = markers.max { lhs, rhs in
                        if lhs.lastReadBlockTime != rhs.lastReadBlockTime {
                            return lhs.lastReadBlockTime < rhs.lastReadBlockTime
                        }
                        return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
                    }!
                    continuation.resume(returning: EffectiveReadStatus(
                        conversationId: conversationId,
                        lastReadBlockTime: best.lastReadBlockTime,
                        lastReadTxId: best.lastReadTxId,
                        deviceCount: markers.count
                    ))
                } catch {
                    self.logInfo("[MessageStore] Failed to recompute effective read status: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Compute unread count for a conversation based on effective read status
    /// - Parameters:
    ///   - contactAddress: Contact address identifying the conversation
    ///   - lastReadBlockTime: Effective last read blockTime from recomputeEffectiveReadStatus()
    /// - Returns: Number of unread incoming messages
    ///
    /// Runs on a background context - see `fetchConversationMeta` for why blocking `viewContext`
    /// here used to be able to freeze the UI.
    func computeUnreadCount(contactAddress: String, lastReadBlockTime: Int64) async -> Int {
        guard ensureStoreLoaded() else { return 0 }
        guard let walletAddress = currentWalletAddress else { return 0 }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
                // Count incoming messages with blockTime > lastReadBlockTime
                request.predicate = NSPredicate(
                    format: "contactAddress == %@ AND isOutgoing == NO AND blockTime > %lld AND (walletAddress == %@ OR walletAddress == nil)",
                    contactAddress, lastReadBlockTime, walletAddress
                )

                do {
                    continuation.resume(returning: try context.count(for: request))
                } catch {
                    self.logInfo("[MessageStore] Failed to compute unread count: \(error)")
                    continuation.resume(returning: 0)
                }
            }
        }
    }

    /// Fetch all read markers for the current wallet (for debugging/diagnostics). Runs on a
    /// background context - see `fetchConversationMeta` for why blocking `viewContext` here used
    /// to be able to freeze the UI.
    func fetchAllReadMarkers() async -> [(conversationId: String, deviceId: String, blockTime: Int64, updatedAt: Date?)] {
        guard ensureStoreLoaded() else { return [] }
        guard let walletAddress = currentWalletAddress else { return [] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[(conversationId: String, deviceId: String, blockTime: Int64, updatedAt: Date?)], Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDReadMarker>(entityName: CDReadMarker.entityName)
                request.predicate = NSPredicate(format: "walletAddress == %@", walletAddress)
                request.sortDescriptors = [
                    NSSortDescriptor(key: "conversationId", ascending: true),
                    NSSortDescriptor(key: "deviceId", ascending: true)
                ]

                do {
                    let markers = try context.fetch(request)
                    continuation.resume(returning: markers.map { ($0.conversationId, $0.deviceId, $0.lastReadBlockTime, $0.updatedAt) })
                } catch {
                    self.logInfo("[MessageStore] Failed to fetch all read markers: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Prune read markers older than specified days (for stale device cleanup)
    /// - Parameter days: Age threshold in days (default 90)
    func pruneStaleReadMarkers(olderThan days: Int = 90) {
        guard ensureStoreLoaded() else { return }
        guard let walletAddress = currentWalletAddress else { return }

        let cutoffDate = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        let context = container.newBackgroundContext()

        context.perform {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: CDReadMarker.entityName)
            request.predicate = NSPredicate(
                format: "walletAddress == %@ AND updatedAt < %@",
                walletAddress, cutoffDate as NSDate
            )

            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            deleteRequest.resultType = .resultTypeCount

            do {
                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0
                if deletedCount > 0 {
                    self.logInfo("[MessageStore] Pruned %d stale read markers (older than %d days)", deletedCount, days)
                }
            } catch {
                self.logInfo("[MessageStore] Failed to prune stale read markers: \(error)")
            }
        }
    }

    /// Purge persistent history older than specified days
    /// - Parameter days: Age threshold in days (default 7)
    func purgeOldHistory(olderThan days: Int = 7) {
        guard ensureStoreLoaded() else { return }

        let cutoffDate = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        let context = container.newBackgroundContext()

        context.perform {
            let purgeRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoffDate)
            do {
                try context.execute(purgeRequest)
                self.logInfo("[MessageStore] Purged history older than %d days", days)
            } catch {
                self.logInfo("[MessageStore] Failed to purge old history: \(error)")
            }
        }
    }

    // MARK: - Read Marker Migration

    private static let readMarkerMigrationKey = "MessageStore.didMigrateToReadMarkers"

    /// Migrate existing CDConversation.lastReadBlockTime to CDReadMarker for this device.
    /// One-time migration on first launch after upgrade.
    /// - Parameter deviceId: Current device identifier from KeychainService
    func migrateToReadMarkersIfNeeded(deviceId: String) {
        // Check if already migrated
        guard !UserDefaults.standard.bool(forKey: Self.readMarkerMigrationKey) else { return }
        guard ensureStoreLoaded() else { return }
        guard let walletAddress = currentWalletAddress else { return }

        self.logInfo("[MessageStore] Starting read marker migration for device %@", String(deviceId.prefix(8)))

        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy

        context.performAndWait {
            // Fetch all conversations with read status
            let request = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
            request.predicate = NSPredicate(
                format: "(walletAddress == %@ OR walletAddress == nil) AND lastReadBlockTime > 0",
                walletAddress
            )

            do {
                let conversations = try context.fetch(request)

                guard !conversations.isEmpty else {
                    self.logInfo("[MessageStore] No conversations to migrate")
                    UserDefaults.standard.set(true, forKey: Self.readMarkerMigrationKey)
                    return
                }

                // Create a CDReadMarker for each conversation with read status
                for conversation in conversations {
                    let marker = CDReadMarker(context: context)
                    marker.walletAddress = walletAddress
                    marker.conversationId = conversation.contactAddress
                    marker.deviceId = deviceId
                    marker.lastReadTxId = conversation.lastReadTxId
                    marker.lastReadBlockTime = conversation.lastReadBlockTime
                    marker.updatedAt = conversation.lastReadAt ?? Date()
                }

                try context.save()
                self.logInfo("[MessageStore] Migrated %d conversations to read markers", conversations.count)

                // Mark migration complete
                UserDefaults.standard.set(true, forKey: Self.readMarkerMigrationKey)
            } catch {
                self.logInfo("[MessageStore] Read marker migration failed: \(error)")
            }
        }
    }

    func upsertMessage(_ message: ChatMessage, contactAddress: String, encryptionKey: SymmetricKey) {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        context.perform {
            let record = self.fetchOrCreateMessage(txId: message.txId, walletAddress: walletAddr, in: context)
            let isNewRecord = record.messageId == nil

            // Check if record needs updating (diff-only for existing records)
            let isPlaceholder = message.isSentPlaceholder
            let existingHasContent = record.contentEncrypted != nil
            let shouldForceOutgoingContent = message.isOutgoing && !isPlaceholder
            let needsUpdate = isNewRecord ||
                record.deliveryStatus != message.deliveryStatus.rawValue ||
                record.acceptingBlock != message.acceptingBlock ||
                shouldForceOutgoingContent ||
                (!isPlaceholder && !existingHasContent)

            guard needsUpdate else { return } // Skip if no changes

            record.messageId = message.id
            record.txId = message.txId
            record.contactAddress = contactAddress
            record.senderAddress = message.senderAddress
            record.receiverAddress = message.receiverAddress
            record.timestamp = message.timestamp
            record.blockTime = Int64(message.blockTime)
            record.acceptingBlock = message.acceptingBlock
            record.isOutgoing = message.isOutgoing
            record.messageType = message.messageType.rawValue
            record.deliveryStatus = message.deliveryStatus.rawValue
            record.updatedAt = Date()

            if let walletAddr = walletAddr {
                record.walletAddress = walletAddr
            }

            // Content update rules:
            // - If new content is placeholder, NEVER overwrite existing content
            // - Preserve existing content unless we are explicitly importing
            //   outgoing content that should replace placeholders.
            let shouldUpdateContent = !isPlaceholder && (shouldForceOutgoingContent || !existingHasContent || isNewRecord)

            if shouldUpdateContent, let encrypted = self.encryptContent(message.content, key: encryptionKey) {
                record.contentEncrypted = encrypted
            }

            do {
                try context.save()
            } catch {
                self.logInfo("[MessageStore] Failed to upsert message: \(error)")
            }
        }
    }

    /// Deletes a specific message by txId for the CURRENT wallet only.
    func deleteMessage(txId: String) {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        context.perform {
            let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            if let walletAddr = walletAddr {
                fetch.predicate = NSPredicate(format: "txId == %@ AND (walletAddress == %@ OR walletAddress == nil)", txId, walletAddr)
            } else {
                fetch.predicate = NSPredicate(format: "txId == %@", txId)
            }
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetch)
            deleteRequest.resultType = .resultTypeObjectIDs
            do {
                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                let objectIds = result?.result as? [NSManagedObjectID] ?? []
                if !objectIds.isEmpty {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: objectIds], into: [self.viewContext])
                }
            } catch {
                self.logInfo("[MessageStore] Failed to delete message \(txId): \(error)")
            }
        }
    }

    /// Clears all messages and conversations for the CURRENT wallet only.
    /// Each wallet has its own SQLite store, so this only affects the current store.
    /// IMPORTANT: This is synchronous - it blocks until deletion completes to prevent
    /// race conditions where the store is removed before deletion finishes.
    func clearAll() {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        self.logInfo("[MessageStore] clearAll() called for wallet: \(walletAddr ?? "default")")

        let context = container.newBackgroundContext()
        context.performAndWait {
            // Double-check store is still valid (may have been removed by another thread)
            guard !self.container.persistentStoreCoordinator.persistentStores.isEmpty else {
                self.logInfo("[MessageStore] clearAll: Store removed before execution, skipping")
                return
            }

            // Filter by wallet address for safety (even though each wallet has its own store)
            let messageFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            if let walletAddr = walletAddr {
                messageFetch.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
            }
            let messageDelete = NSBatchDeleteRequest(fetchRequest: messageFetch)
            messageDelete.resultType = .resultTypeObjectIDs

            let conversationFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDConversation.entityName)
            if let walletAddr = walletAddr {
                conversationFetch.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
            }
            let conversationDelete = NSBatchDeleteRequest(fetchRequest: conversationFetch)
            conversationDelete.resultType = .resultTypeObjectIDs

            do {
                let messageResult = try context.execute(messageDelete) as? NSBatchDeleteResult
                let conversationResult = try context.execute(conversationDelete) as? NSBatchDeleteResult
                let messageIds = messageResult?.result as? [NSManagedObjectID] ?? []
                let conversationIds = conversationResult?.result as? [NSManagedObjectID] ?? []
                let changes: [String: Any] = [
                    NSDeletedObjectsKey: messageIds + conversationIds
                ]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [self.viewContext])
                self.logInfo("[MessageStore] Cleared %d messages, %d conversations", messageIds.count, conversationIds.count)
            } catch {
                self.logInfo("[MessageStore] Failed to clear store: \(error)")
            }
        }
    }

    /// Clears incoming messages for the CURRENT wallet only.
    func clearIncomingMessages() {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        context.perform {
            let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            if let walletAddr = walletAddr {
                fetch.predicate = NSPredicate(format: "isOutgoing == NO AND (walletAddress == %@ OR walletAddress == nil)", walletAddr)
            } else {
                fetch.predicate = NSPredicate(format: "isOutgoing == NO")
            }
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetch)
            deleteRequest.resultType = .resultTypeObjectIDs
            do {
                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                let objectIds = result?.result as? [NSManagedObjectID] ?? []
                if !objectIds.isEmpty {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: objectIds], into: [self.viewContext])
                }
            } catch {
                self.logInfo("[MessageStore] Failed to clear incoming messages: \(error)")
            }
        }
    }

    /// Awaitable incoming-message wipe for the CURRENT wallet, optionally limited to the given
    /// conversations (matched by `CDMessage.contactAddress`). Used by the Danger Zone
    /// wipe-and-resync flow, which must not start re-fetching until the delete has actually
    /// landed in the store (the fire-and-forget `clearIncomingMessages()` above could otherwise
    /// race the re-sync's own writes).
    func clearIncomingMessagesAndWait(forContacts contactAddresses: [String]? = nil) async {
        guard ensureStoreLoaded() else { return }
        if let contactAddresses, contactAddresses.isEmpty { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            context.perform {
                let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
                var clauses = ["isOutgoing == NO"]
                var arguments: [Any] = []
                if let contactAddresses {
                    clauses.append("contactAddress IN %@")
                    arguments.append(contactAddresses)
                }
                if let walletAddr {
                    clauses.append("(walletAddress == %@ OR walletAddress == nil)")
                    arguments.append(walletAddr)
                }
                fetch.predicate = NSPredicate(format: clauses.joined(separator: " AND "), argumentArray: arguments)
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetch)
                deleteRequest.resultType = .resultTypeObjectIDs
                do {
                    let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                    let objectIds = result?.result as? [NSManagedObjectID] ?? []
                    if !objectIds.isEmpty {
                        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: objectIds], into: [self.viewContext])
                    }
                    self.logInfo("[MessageStore] Cleared %d incoming messages (%@)", objectIds.count, contactAddresses == nil ? "all chats" : "\(contactAddresses?.count ?? 0) chats")
                } catch {
                    self.logInfo("[MessageStore] Failed to clear incoming messages: \(error)")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Retention

    /// Off-main wrapper for `applyRetention`. The synchronous version uses `performAndWait`, which
    /// blocks its caller - and retention is applied on the main actor at launch and on every
    /// settings change. Running it inside `performBackgroundTask` keeps the batch delete + merge on
    /// a private queue so the awaiting main actor only suspends. (The internal caller at the
    /// message-store-sync path already passes its own background `context:` and stays sync.)
    func applyRetentionInBackground(_ retention: MessageRetention) async {
        guard ensureStoreLoaded(), retention.days != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            container.performBackgroundTask { context in
                _ = self.applyRetention(retention, in: context)
                continuation.resume()
            }
        }
    }

    /// Applies message retention policy for the CURRENT wallet only.
    @discardableResult
    func applyRetention(_ retention: MessageRetention, in context: NSManagedObjectContext? = nil) -> Bool {
        guard ensureStoreLoaded() else { return false }
        guard let days = retention.days else { return false }
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86_400))
        let walletAddr = currentWalletAddress
        let context = context ?? container.newBackgroundContext()
        var didDelete = false
        context.performAndWait {
            let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            if let walletAddr = walletAddr {
                fetch.predicate = NSPredicate(
                    format: "timestamp < %@ AND messageType != %@ AND (walletAddress == %@ OR walletAddress == nil)",
                    cutoff as NSDate,
                    ChatMessage.MessageType.handshake.rawValue,
                    walletAddr
                )
            } else {
                fetch.predicate = NSPredicate(format: "timestamp < %@ AND messageType != %@", cutoff as NSDate, ChatMessage.MessageType.handshake.rawValue)
            }
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetch)
            deleteRequest.resultType = .resultTypeObjectIDs

            do {
                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                let objectIds = result?.result as? [NSManagedObjectID] ?? []
                didDelete = !objectIds.isEmpty
                if !objectIds.isEmpty {
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: objectIds], into: [self.viewContext])
                }
            } catch {
                self.logInfo("[MessageStore] Failed to apply retention: \(error)")
            }
        }
        return didDelete
    }

    // MARK: - Helpers

    private func configureStoreDescription(_ description: NSPersistentStoreDescription) {
        // Persistent history tracking stays ON. Every existing store on every device was
        // created with it (the CloudKit mirror required it), and Core Data refuses to open a
        // store whose history tracking was enabled and is later turned off. Nothing reads the
        // history any more, so `purgeOldHistory` trims it on every load instead of letting it
        // grow for the life of the store as it silently did before.
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        // SQLite WAL optimizations to prevent checkpoint contention during batch writes
        let pragmas = [
            "journal_mode": "WAL",           // Enable WAL mode (already default for Core Data)
            "synchronous": "NORMAL",         // Faster commits while maintaining safety with WAL
            "wal_autocheckpoint": "1000",    // ~1000 pages before checkpoint (approx a few MB)
            "cache_size": "-20000"           // 20MB cache (negative = KB, positive = pages)
        ]
        description.setOption(pragmas as NSDictionary, forKey: NSSQLitePragmasOption)

        // Store configuration for reliability. The add itself runs off the main thread - see
        // `CoreDataStoreLoader`.
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
    }

    /// Indexes for the columns every read filters and sorts on. See `CoreDataIndexBuilder` for
    /// why these are created in SQLite rather than declared in the model.
    private static let sqliteIndexSpecs: [CoreDataIndexBuilder.Spec] = [
        .init(entityName: CDMessage.entityName, attributes: ["walletAddress", "contactAddress", "blockTime"]),
        .init(entityName: CDMessage.entityName, attributes: ["txId"]),
        .init(entityName: CDConversation.entityName, attributes: ["walletAddress", "contactAddress"]),
        .init(entityName: CDReadMarker.entityName, attributes: ["walletAddress", "conversationId"]),
        .init(entityName: CDReaction.entityName, attributes: ["walletAddress", "targetTxId"]),
        .init(entityName: CDReaction.entityName, attributes: ["walletAddress", "contactAddress"]),
        .init(entityName: CDMessageEdit.entityName, attributes: ["walletAddress", "contactAddress"]),
    ]

    private func loadPersistentStores(primaryDescription: NSPersistentStoreDescription, completion: (() -> Void)? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        CoreDataStoreLoader.load(container: container, description: primaryDescription, indexSpecs: Self.sqliteIndexSpecs) { [weak self] error in
            // `completion` backs `setCurrentWallet(_:) async`'s `withCheckedContinuation` - every
            // exit path below MUST call it, even on failure, or that continuation hangs forever
            // with no timeout and no way to recover (previously the two failure branches here
            // returned without calling it, permanently wedging wallet load on any store-load
            // error, e.g. a WAL/SHM issue from a cold launch after the process was jetsammed).
            guard let self else {
                completion?()
                return
            }
            guard generation == self.loadGeneration else {
                // A later switch overtook this load: its file must not sit beside the new one.
                CoreDataStoreLoader.detachStore(at: primaryDescription.url, from: self.container)
                completion?()
                return
            }
            if let error {
                // Never rebuilt here: this is the user's history, not a cache.
                CoreDataStoreLoader.reportFailure(store: "MessageStore", error: error)
                completion?()
                return
            }
            self.finishStoreLoad()
            completion?()
        }
    }

    private func finishStoreLoad() {
        let hasStore = !container.persistentStoreCoordinator.persistentStores.isEmpty
        if !hasStore {
            self.logInfo("[MessageStore] Persistent stores list is empty after load; deferring operations.")
        }
        isLoaded = hasStore

        // Configure view context for optimal performance
        container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.undoManager = nil

        // Disable unnecessary features for performance
        container.viewContext.shouldDeleteInaccessibleFaults = true

        // Batch processing hint for large saves
        container.viewContext.stalenessInterval = 0.0  // Always use latest data

        // History rows are dead weight now (see configureStoreDescription); keep the file lean.
        purgeOldHistory()
    }

    private func ensureStoreLoaded() -> Bool {
        guard isLoaded else {
            if !didLogMissingStore {
                didLogMissingStore = true
                self.logInfo("[MessageStore] Store not loaded yet; skipping operation.")
            }
            return false
        }
        if container.persistentStoreCoordinator.persistentStores.isEmpty {
            if !didLogMissingStore {
                didLogMissingStore = true
                self.logInfo("[MessageStore] Store loaded flag set but no persistent stores attached; skipping operation.")
            }
            return false
        }
        return true
    }

    /// Batch fetch messages by txIds for O(1) lookup (replaces N individual fetches)
    private func batchFetchMessages(txIds: [String], walletAddress: String?, in context: NSManagedObjectContext) -> [String: CDMessage] {
        guard !txIds.isEmpty else { return [:] }

        let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
        if let walletAddress = walletAddress {
            request.predicate = NSPredicate(format: "txId IN %@ AND (walletAddress == %@ OR walletAddress == nil)", txIds, walletAddress)
        } else {
            request.predicate = NSPredicate(format: "txId IN %@", txIds)
        }

        var result: [String: CDMessage] = [:]
        do {
            let messages = try context.fetch(request)
            for message in messages {
                result[message.txId] = message
            }
            self.logInfo("[MessageStore] Batch fetched %d existing messages (from %d txIds)", result.count, txIds.count)
        } catch {
            self.logInfo("[MessageStore] Batch fetch failed: \(error)")
        }
        return result
    }

    private func fetchOrCreateMessage(txId: String, walletAddress: String? = nil, in context: NSManagedObjectContext) -> CDMessage {
        let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
        // Include wallet address in lookup if provided
        if let walletAddress = walletAddress {
            request.predicate = NSPredicate(format: "txId == %@ AND (walletAddress == %@ OR walletAddress == nil)", txId, walletAddress)
        } else {
            request.predicate = NSPredicate(format: "txId == %@", txId)
        }
        request.fetchLimit = 10
        if let results = try? context.fetch(request), !results.isEmpty {
            if results.count > 1 {
                let sorted = results.sorted { lhs, rhs in
                    switch (lhs.contentEncrypted != nil, rhs.contentEncrypted != nil) {
                    case (true, false):
                        return true
                    case (false, true):
                        return false
                    default:
                        return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
                    }
                }
                let keeper = sorted.first!
                for duplicate in sorted.dropFirst() {
                    context.delete(duplicate)
                }
                return keeper
            }
            return results[0]
        }
        let record = CDMessage(context: context)
        record.txId = txId
        return record
    }

    private func fetchOrCreateConversation(contactAddress: String, walletAddress: String? = nil, in context: NSManagedObjectContext) -> CDConversation {
        let request = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
        // Include wallet address in lookup if provided
        if let walletAddress = walletAddress {
            request.predicate = NSPredicate(format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)", contactAddress, walletAddress)
        } else {
            request.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
        }
        request.fetchLimit = 1
        if let existing = try? context.fetch(request).first {
            return existing
        }
        let record = CDConversation(context: context)
        record.contactAddress = contactAddress
        record.conversationId = UUID()
        record.unreadCount = 0
        return record
    }

    private func encryptContent(_ content: String, key: SymmetricKey) -> Data? {
        guard let data = content.data(using: .utf8) else { return nil }
        return try? CryptoUtils.encrypt(data, using: key)
    }

    private func decryptContent(_ data: Data, key: SymmetricKey) -> String? {
        guard let decrypted = try? CryptoUtils.decrypt(data, using: key) else { return nil }
        return String(data: decrypted, encoding: .utf8)
    }

    private func decodeMessage(_ record: CDMessage, key: SymmetricKey) -> ChatMessage? {
        let txId = record.txId
        let contactAddress = record.contactAddress
        guard !txId.isEmpty, !contactAddress.isEmpty else { return nil }

        let content: String
        if let contentData = record.contentEncrypted {
            if let decrypted = decryptContent(contentData, key: key) {
                content = decrypted
            } else {
                content = "[Encrypted message]"
            }
        } else {
            content = ChatMessage.sentViaOtherDevicePlaceholder
        }
        let messageType = ChatMessage.MessageType(rawValue: record.messageType ?? "contextual") ?? .contextual
        let deliveryStatus = ChatMessage.DeliveryStatus(rawValue: record.deliveryStatus ?? "sent") ?? .sent
        return ChatMessage(
            id: record.messageId ?? UUID(),
            txId: txId,
            senderAddress: record.senderAddress ?? "",
            receiverAddress: record.receiverAddress ?? "",
            content: content,
            timestamp: record.timestamp ?? Date(),
            blockTime: UInt64(record.blockTime),
            acceptingBlock: record.acceptingBlock,
            isOutgoing: record.isOutgoing,
            messageType: messageType,
            deliveryStatus: deliveryStatus
        )
    }

    // MARK: - Reactions (CDReaction)

    /// One reaction on a message, decrypted and safe to pass across contexts/threads.
    struct ReactionSnapshot: Identifiable, Equatable {
        var id: String { "\(targetTxId)-\(reactorAddress)" }
        let targetTxId: String
        let reactorAddress: String
        let emoji: String
        /// Send state of the local user's own reaction (`.sent` for everyone else's / delivered).
        /// `.failed` drives the error icon on the pill and the Retry affordance under the message.
        var deliveryStatus: ChatMessage.DeliveryStatus = .sent
        /// When `.failed`, whether the failed change was an "add" or "remove" — so Retry re-attempts
        /// the correct action.
        var failedAction: String? = nil
        /// Reaction creation time (ms since epoch). Used to drop the green "sent" checkmark after a
        /// short window (the checkmark is a recent-confirmation, not a permanent badge).
        var blockTime: Int64 = 0
    }

    /// Replaces any existing reaction `reactorAddress` left on `targetTxId` with `emoji` - one
    /// reaction per (message, reactor). No uniqueness constraint at the Core Data level (same
    /// as `CDReadMarker`) - any duplicate found during the
    /// fetch-then-upsert is folded into the first result and the rest deleted.
    func upsertReaction(targetTxId: String, reactorAddress: String, contactAddress: String, emoji: String, reactionTxId: String?, blockTime: Int64, encryptionKey: SymmetricKey, deliveryStatus: String? = nil, failedAction: String? = nil) {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        context.perform {
            let request = NSFetchRequest<CDReaction>(entityName: CDReaction.entityName)
            if let walletAddr {
                request.predicate = NSPredicate(format: "targetTxId == %@ AND reactorAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)", targetTxId, reactorAddress, walletAddr)
            } else {
                request.predicate = NSPredicate(format: "targetTxId == %@ AND reactorAddress == %@", targetTxId, reactorAddress)
            }
            let existing = (try? context.fetch(request)) ?? []
            let reaction = existing.first ?? CDReaction(context: context)
            for duplicate in existing.dropFirst() {
                context.delete(duplicate)
            }
            reaction.targetTxId = targetTxId
            reaction.reactorAddress = reactorAddress
            reaction.contactAddress = contactAddress
            reaction.reactionTxId = reactionTxId
            reaction.blockTime = blockTime
            reaction.deliveryStatus = deliveryStatus
            reaction.failedAction = failedAction
            reaction.updatedAt = Date()
            if let walletAddr {
                reaction.walletAddress = walletAddr
            }
            if let encrypted = self.encryptContent(emoji, key: encryptionKey) {
                reaction.emojiEncrypted = encrypted
            }
            do {
                try context.save()
            } catch {
                self.logInfo("[MessageStore] Failed to upsert reaction: \(error)")
            }
        }
    }

    // MARK: - Edits (CDMessageEdit)

    /// Records the newest edit of `targetTxId`. Newest by block time wins - an older edit
    /// replayed from history never overwrites a newer one - except that the local user's own
    /// in-flight edit (pending/failed) is always replaced by its own outcome.
    func upsertEdit(targetTxId: String, contactAddress: String, text: String, editTxId: String?, blockTime: Int64, encryptionKey: SymmetricKey, deliveryStatus: String? = nil) {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        context.perform {
            let request = NSFetchRequest<CDMessageEdit>(entityName: CDMessageEdit.entityName)
            if let walletAddr {
                request.predicate = NSPredicate(format: "targetTxId == %@ AND (walletAddress == %@ OR walletAddress == nil)", targetTxId, walletAddr)
            } else {
                request.predicate = NSPredicate(format: "targetTxId == %@", targetTxId)
            }
            let existing = (try? context.fetch(request)) ?? []
            if let current = existing.first, current.deliveryStatus == nil || current.deliveryStatus == "sent",
               current.blockTime > blockTime, current.editTxId != editTxId {
                return
            }
            let edit = existing.first ?? CDMessageEdit(context: context)
            for duplicate in existing.dropFirst() {
                context.delete(duplicate)
            }
            edit.targetTxId = targetTxId
            edit.contactAddress = contactAddress
            edit.editTxId = editTxId
            edit.blockTime = blockTime
            edit.deliveryStatus = deliveryStatus
            edit.updatedAt = Date()
            if let walletAddr {
                edit.walletAddress = walletAddr
            }
            if let encrypted = self.encryptContent(text, key: encryptionKey) {
                edit.textEncrypted = encrypted
            }
            do {
                try context.save()
            } catch {
                self.logInfo("[MessageStore] Failed to upsert edit: \(error)")
            }
        }
    }

    /// One conversation's edits, keyed by the message they change.
    func fetchEdits(contactAddress: String, decryptionKey: SymmetricKey) async -> [String: MessageEditSnapshot] {
        guard ensureStoreLoaded() else { return [:] }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: MessageEditSnapshot], Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDMessageEdit>(entityName: CDMessageEdit.entityName)
                if let walletAddress {
                    request.predicate = NSPredicate(format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)", contactAddress, walletAddress)
                } else {
                    request.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
                }
                var edits: [String: MessageEditSnapshot] = [:]
                if let results = try? context.fetch(request) {
                    for record in results {
                        guard let data = record.textEncrypted, let text = self.decryptContent(data, key: decryptionKey) else { continue }
                        let status: ChatMessage.DeliveryStatus
                        switch record.deliveryStatus {
                        case "failed": status = .failed
                        case "pending": status = .pending
                        default: status = .sent
                        }
                        edits[record.targetTxId] = MessageEditSnapshot(targetTxId: record.targetTxId, text: text, editTxId: record.editTxId, blockTime: record.blockTime, deliveryStatus: status)
                    }
                }
                continuation.resume(returning: edits)
            }
        }
    }

    /// Deletes `reactorAddress`'s reaction on `targetTxId`, if any.
    func removeReaction(targetTxId: String, reactorAddress: String) {
        guard ensureStoreLoaded() else { return }
        let walletAddr = currentWalletAddress
        let context = container.newBackgroundContext()
        context.perform {
            let request = NSFetchRequest<CDReaction>(entityName: CDReaction.entityName)
            if let walletAddr {
                request.predicate = NSPredicate(format: "targetTxId == %@ AND reactorAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)", targetTxId, reactorAddress, walletAddr)
            } else {
                request.predicate = NSPredicate(format: "targetTxId == %@ AND reactorAddress == %@", targetTxId, reactorAddress)
            }
            do {
                let existing = try context.fetch(request)
                for record in existing {
                    context.delete(record)
                }
                try context.save()
            } catch {
                self.logInfo("[MessageStore] Failed to remove reaction: \(error)")
            }
        }
    }

    /// All reactions for `contactAddress`, decrypted and grouped by the message they target -
    /// loaded once when a conversation opens; kept live afterward by the caller applying the same
    /// upsert/remove calls to its own in-memory copy, the same way `ChatService` already keeps its
    /// published conversation state in sync without a Core Data change-notification round trip for
    /// every update.
    func fetchReactions(contactAddress: String, decryptionKey: SymmetricKey) async -> [String: [ReactionSnapshot]] {
        guard ensureStoreLoaded() else { return [:] }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: [ReactionSnapshot]], Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDReaction>(entityName: CDReaction.entityName)
                if let walletAddress {
                    request.predicate = NSPredicate(format: "contactAddress == %@ AND (walletAddress == %@ OR walletAddress == nil)", contactAddress, walletAddress)
                } else {
                    request.predicate = NSPredicate(format: "contactAddress == %@", contactAddress)
                }
                var grouped: [String: [ReactionSnapshot]] = [:]
                if let results = try? context.fetch(request) {
                    for record in results {
                        guard let emojiData = record.emojiEncrypted,
                              let emoji = self.decryptContent(emojiData, key: decryptionKey) else { continue }
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
                continuation.resume(returning: grouped)
            }
        }
    }

    /// One conversation's most recent reaction across all its messages, with enough context to
    /// render a chat-list preview ("Reacted to your message" etc.) without a second round trip.
    struct LatestReactionPreview {
        let emoji: String
        let reactorAddress: String
        let blockTime: Int64
        /// Whether the message *being reacted to* (not the reaction itself) was sent by this
        /// wallet - nil if the target message couldn't be found (e.g. pruned by message
        /// retention settings while the reaction itself was kept).
        let targetMessageIsOutgoing: Bool?
    }

    /// The single newest reaction per contact, across every message in that conversation - not
    /// scoped to one already-open conversation like `fetchReactions` (which needs a live
    /// conversation's `reactionsByTxId` to already be populated). Used to show reaction activity
    /// in the chat list preview when it's more recent than the last real message, which otherwise
    /// has no visibility into reactions at all (they're applied as a pill, never inserted as a
    /// message). `decryptionKey` is the same wallet-wide at-rest key `messageEncryptionKey()`
    /// returns for every conversation (not a per-contact shared secret), so this can scan across
    /// all contacts in one pass.
    func fetchLatestReactionPerContact(decryptionKey: SymmetricKey) async -> [String: LatestReactionPreview] {
        guard ensureStoreLoaded() else { return [:] }
        let walletAddress = currentWalletAddress
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: LatestReactionPreview], Never>) in
            container.performBackgroundTask { context in
                let request = NSFetchRequest<CDReaction>(entityName: CDReaction.entityName)
                if let walletAddress {
                    request.predicate = NSPredicate(format: "(walletAddress == %@ OR walletAddress == nil)", walletAddress)
                }
                guard let allReactions = try? context.fetch(request), !allReactions.isEmpty else {
                    continuation.resume(returning: [:])
                    return
                }

                // Newest reaction per contact, by blockTime.
                var latestByContact: [String: CDReaction] = [:]
                for reaction in allReactions {
                    if let existing = latestByContact[reaction.contactAddress], existing.blockTime >= reaction.blockTime {
                        continue
                    }
                    latestByContact[reaction.contactAddress] = reaction
                }

                let targetMessagesByTxId = self.batchFetchMessages(
                    txIds: latestByContact.values.map { $0.targetTxId },
                    walletAddress: walletAddress,
                    in: context
                )

                var result: [String: LatestReactionPreview] = [:]
                for (contactAddress, reaction) in latestByContact {
                    guard let emojiData = reaction.emojiEncrypted,
                          let emoji = self.decryptContent(emojiData, key: decryptionKey) else { continue }
                    result[contactAddress] = LatestReactionPreview(
                        emoji: emoji,
                        reactorAddress: reaction.reactorAddress,
                        blockTime: reaction.blockTime,
                        targetMessageIsOutgoing: targetMessagesByTxId[reaction.targetTxId]?.isOutgoing
                    )
                }
                continuation.resume(returning: result)
            }
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let messageEntity = NSEntityDescription()
        messageEntity.name = CDMessage.entityName
        messageEntity.managedObjectClassName = NSStringFromClass(CDMessage.self)

        let conversationEntity = NSEntityDescription()
        conversationEntity.name = CDConversation.entityName
        conversationEntity.managedObjectClassName = NSStringFromClass(CDConversation.self)

        let readMarkerEntity = NSEntityDescription()
        readMarkerEntity.name = CDReadMarker.entityName
        readMarkerEntity.managedObjectClassName = NSStringFromClass(CDReadMarker.self)

        // CDSyncMarker was the row the CloudKit mirror touched to force an export. Nothing writes
        // it any more; the entity stays in the model because dropping it would migrate every
        // existing store for no gain.
        let syncMarkerEntity = NSEntityDescription()
        syncMarkerEntity.name = CDSyncMarker.entityName
        syncMarkerEntity.managedObjectClassName = NSStringFromClass(CDSyncMarker.self)

        let reactionEntity = NSEntityDescription()
        reactionEntity.name = CDReaction.entityName
        reactionEntity.managedObjectClassName = NSStringFromClass(CDReaction.self)

        messageEntity.properties = [
            makeAttribute(name: "messageId", type: .UUIDAttributeType, optional: true),
            makeAttribute(name: "txId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "contactAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "senderAddress", type: .stringAttributeType, optional: true),
            makeAttribute(name: "receiverAddress", type: .stringAttributeType, optional: true),
            makeAttribute(name: "contentEncrypted", type: .binaryDataAttributeType, optional: true),
            makeAttribute(name: "timestamp", type: .dateAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "acceptingBlock", type: .stringAttributeType, optional: true),
            makeAttribute(name: "isOutgoing", type: .booleanAttributeType, optional: false, defaultValue: false),
            makeAttribute(name: "messageType", type: .stringAttributeType, optional: true),
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true),
            makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true),
            // Multi-account support: wallet address for partitioning
            makeAttribute(name: "walletAddress", type: .stringAttributeType, optional: true)
        ]

        conversationEntity.properties = [
            makeAttribute(name: "contactAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "conversationId", type: .UUIDAttributeType, optional: true),
            makeAttribute(name: "unreadCount", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "lastMessageAt", type: .dateAttributeType, optional: true),
            makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true),
            // Multi-account support: wallet address for partitioning
            makeAttribute(name: "walletAddress", type: .stringAttributeType, optional: true),
            // Read status fields
            makeAttribute(name: "lastReadTxId", type: .stringAttributeType, optional: true),
            makeAttribute(name: "lastReadBlockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "lastReadAt", type: .dateAttributeType, optional: true),
            // Archived state
            makeAttribute(name: "isArchived", type: .booleanAttributeType, optional: false, defaultValue: false)
        ]

        // CDReadMarker: per-device read markers, a schema born for cross-device merging and
        // kept as-is (a model change would migrate every store). No uniqueness constraint;
        // deduplication is handled manually in upsertReadMarker() by fetching before insert
        readMarkerEntity.properties = [
            makeAttribute(name: "walletAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "conversationId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "deviceId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "lastReadTxId", type: .stringAttributeType, optional: true),
            makeAttribute(name: "lastReadBlockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true)
        ]

        syncMarkerEntity.properties = [
            makeAttribute(name: "walletAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true)
        ]

        // CDReaction: one row per (targetTxId, reactorAddress, walletAddress) - picking a new
        // emoji replaces the row's emojiEncrypted rather than adding a second row; removing a
        // reaction deletes the row outright. No uniqueness constraint (same as CDReadMarker
        // above) - dedup is handled manually before insert.
        reactionEntity.properties = [
            makeAttribute(name: "targetTxId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "reactorAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "contactAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "emojiEncrypted", type: .binaryDataAttributeType, optional: true),
            makeAttribute(name: "reactionTxId", type: .stringAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true),
            makeAttribute(name: "walletAddress", type: .stringAttributeType, optional: true),
            // Send status for the local user's own reaction: nil/"sent" = delivered, "failed" =
            // the reaction tx never sent. `failedAction` records whether the failed change was an
            // "add" or "remove" so Retry knows what to re-attempt. Optional → lightweight migration.
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true),
            makeAttribute(name: "failedAction", type: .stringAttributeType, optional: true)
        ]

        // Fetch indexes for the columns every read actually filters and sorts on. Without them
        // each of these was a full table scan of the whole message history, and the app does one
        // per chat-list row, one per chat open, and one per incoming message (the txId dedup
        // check) - which is most of the general sluggishness.
        //
        // NOTE: Core Data's version hash does NOT cover indexes, so an EXISTING store is judged
        // compatible and keeps running without them; only a store created from scratch gets
        // them. Forcing the migration with a versionHashModifier was tried and reverted - it
        // wedged the app on a store this size. Building these on an existing store needs to happen off
        // the main thread with the UI told to wait, which is its own piece of work.
        messageEntity.indexes = [
            makeIndex(name: "byWalletContactTime", on: messageEntity, attributes: ["walletAddress", "contactAddress", "blockTime"]),
            makeIndex(name: "byTxId", on: messageEntity, attributes: ["txId"])
        ]
        conversationEntity.indexes = [
            makeIndex(name: "byWalletContact", on: conversationEntity, attributes: ["walletAddress", "contactAddress"])
        ]
        readMarkerEntity.indexes = [
            makeIndex(name: "byWalletConversation", on: readMarkerEntity, attributes: ["walletAddress", "conversationId"])
        ]
        reactionEntity.indexes = [
            makeIndex(name: "byWalletTarget", on: reactionEntity, attributes: ["walletAddress", "targetTxId"]),
            makeIndex(name: "byWalletContact", on: reactionEntity, attributes: ["walletAddress", "contactAddress"])
        ]

        // CDMessageEdit: the newest edit per (targetTxId, walletAddress) - a later edit replaces
        // the row's text. New entity → lightweight migration, like CDReaction before it.
        let editEntity = NSEntityDescription()
        editEntity.name = CDMessageEdit.entityName
        editEntity.managedObjectClassName = NSStringFromClass(CDMessageEdit.self)
        editEntity.properties = [
            makeAttribute(name: "targetTxId", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "contactAddress", type: .stringAttributeType, optional: false, defaultValue: ""),
            makeAttribute(name: "textEncrypted", type: .binaryDataAttributeType, optional: true),
            makeAttribute(name: "editTxId", type: .stringAttributeType, optional: true),
            makeAttribute(name: "blockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
            makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true),
            makeAttribute(name: "walletAddress", type: .stringAttributeType, optional: true),
            makeAttribute(name: "deliveryStatus", type: .stringAttributeType, optional: true)
        ]
        editEntity.indexes = [
            makeIndex(name: "byWalletContact", on: editEntity, attributes: ["walletAddress", "contactAddress"])
        ]

        model.entities = [messageEntity, conversationEntity, readMarkerEntity, syncMarkerEntity, reactionEntity, editEntity]
        return model
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

    private static func defaultStoreURL() -> URL {
        NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("KasiaMessages.sqlite")
    }

    @discardableResult
    private func pruneStalePendingMessages(keeping currentTxIds: Set<String>, in context: NSManagedObjectContext) -> Bool {
        guard !currentTxIds.isEmpty else { return false }
        let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
        // Filter by current wallet for safety
        if let walletAddr = currentWalletAddress {
            fetch.predicate = NSPredicate(
                format: "txId BEGINSWITH %@ AND NOT (txId IN %@) AND (walletAddress == %@ OR walletAddress == nil)",
                "pending_",
                currentTxIds,
                walletAddr
            )
        } else {
            fetch.predicate = NSPredicate(format: "txId BEGINSWITH %@ AND NOT (txId IN %@)", "pending_", currentTxIds)
        }
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetch)
        deleteRequest.resultType = .resultTypeObjectIDs
        do {
            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            let objectIds = result?.result as? [NSManagedObjectID] ?? []
            let didDelete = !objectIds.isEmpty
            if !objectIds.isEmpty {
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: objectIds], into: [self.viewContext])
            }
            return didDelete
        } catch {
            self.logInfo("[MessageStore] Failed to prune pending messages: \(error)")
            return false
        }
    }

    func currentStoreSizeBytes() -> Int64 {
        let storeUrl = container.persistentStoreCoordinator.persistentStores.first?.url ?? Self.defaultStoreURL()
        return Self.sizeOfStoreFiles(at: storeUrl)
    }

    private var lastDedupeAt: Date?
    private let dedupeMinInterval: TimeInterval = 10 * 60
    private let dedupeThresholdRatio: Double = 1.2
    private let dedupeMinTotalMessages = 1000
    private let dedupeBatchLimit = 2000

    struct StoreDiagnostics {
        let totalMessages: Int
        let distinctTxIds: Int
        let placeholderCount: Int
        let outgoingCount: Int
        let incomingCount: Int
    }

    /// Counts over the whole store; asynchronous so the diagnostics export never blocks the
    /// thread that asked (it ran a synchronous performAndWait from the main actor).
    func currentStoreDiagnostics() async -> StoreDiagnostics {
        guard ensureStoreLoaded() else {
            return StoreDiagnostics(totalMessages: 0, distinctTxIds: 0, placeholderCount: 0, outgoingCount: 0, incomingCount: 0)
        }
        let context = container.newBackgroundContext()
        var result = StoreDiagnostics(totalMessages: 0, distinctTxIds: 0, placeholderCount: 0, outgoingCount: 0, incomingCount: 0)
        return await withCheckedContinuation { continuation in
        context.perform {
            let totalFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            totalFetch.resultType = .countResultType
            if let walletAddr = currentWalletAddress {
                totalFetch.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
            }
            if let countResult = try? context.count(for: totalFetch) {
                result = StoreDiagnostics(totalMessages: countResult, distinctTxIds: result.distinctTxIds, placeholderCount: result.placeholderCount, outgoingCount: result.outgoingCount, incomingCount: result.incomingCount)
            }

            let distinctFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            distinctFetch.resultType = .dictionaryResultType
            distinctFetch.propertiesToFetch = ["txId"]
            distinctFetch.returnsDistinctResults = true
            if let walletAddr = currentWalletAddress {
                distinctFetch.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
            }
            let distinctCount = (try? context.fetch(distinctFetch).count) ?? 0
            result = StoreDiagnostics(totalMessages: result.totalMessages, distinctTxIds: distinctCount, placeholderCount: result.placeholderCount, outgoingCount: result.outgoingCount, incomingCount: result.incomingCount)

            let placeholderFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            placeholderFetch.resultType = .countResultType
            if let walletAddr = currentWalletAddress {
                placeholderFetch.predicate = NSPredicate(format: "contentEncrypted == nil AND (walletAddress == %@ OR walletAddress == nil)", walletAddr)
            } else {
                placeholderFetch.predicate = NSPredicate(format: "contentEncrypted == nil")
            }
            let placeholderCount = (try? context.count(for: placeholderFetch)) ?? 0
            result = StoreDiagnostics(totalMessages: result.totalMessages, distinctTxIds: result.distinctTxIds, placeholderCount: placeholderCount, outgoingCount: result.outgoingCount, incomingCount: result.incomingCount)

            let outgoingFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            outgoingFetch.resultType = .countResultType
            if let walletAddr = currentWalletAddress {
                outgoingFetch.predicate = NSPredicate(format: "isOutgoing == YES AND (walletAddress == %@ OR walletAddress == nil)", walletAddr)
            } else {
                outgoingFetch.predicate = NSPredicate(format: "isOutgoing == YES")
            }
            let outgoingCount = (try? context.count(for: outgoingFetch)) ?? 0

            let incomingFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
            incomingFetch.resultType = .countResultType
            if let walletAddr = currentWalletAddress {
                incomingFetch.predicate = NSPredicate(format: "isOutgoing == NO AND (walletAddress == %@ OR walletAddress == nil)", walletAddr)
            } else {
                incomingFetch.predicate = NSPredicate(format: "isOutgoing == NO")
            }
            let incomingCount = (try? context.count(for: incomingFetch)) ?? 0

            result = StoreDiagnostics(
                totalMessages: result.totalMessages,
                distinctTxIds: result.distinctTxIds,
                placeholderCount: result.placeholderCount,
                outgoingCount: outgoingCount,
                incomingCount: incomingCount
            )
            continuation.resume(returning: result)
        }
        }
    }

    private func fetchMessageCounts(in context: NSManagedObjectContext, walletAddr: String?) -> (total: Int, distinct: Int) {
        let totalFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
        totalFetch.resultType = .countResultType
        if let walletAddr = walletAddr {
            totalFetch.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
        }
        let total = (try? context.count(for: totalFetch)) ?? 0

        let distinctFetch = NSFetchRequest<NSFetchRequestResult>(entityName: CDMessage.entityName)
        distinctFetch.resultType = .dictionaryResultType
        distinctFetch.propertiesToFetch = ["txId"]
        distinctFetch.returnsDistinctResults = true
        if let walletAddr = walletAddr {
            distinctFetch.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
        }
        let distinct = (try? context.fetch(distinctFetch).count) ?? 0
        return (total, distinct)
    }

    private func shouldRunDedupe(total: Int, distinct: Int) -> Bool {
        guard total >= dedupeMinTotalMessages else { return false }
        guard distinct > 0 else { return false }
        let ratio = Double(total) / Double(max(distinct, 1))
        return ratio >= dedupeThresholdRatio
    }

    private func dedupeMessagesIfNeeded(in context: NSManagedObjectContext, walletAddr: String?) -> Bool {
        let now = Date()
        if let last = lastDedupeAt, now.timeIntervalSince(last) < dedupeMinInterval {
            return false
        }

        let counts = fetchMessageCounts(in: context, walletAddr: walletAddr)
        guard shouldRunDedupe(total: counts.total, distinct: counts.distinct) else { return false }
        lastDedupeAt = now

        let fetch = NSFetchRequest<NSDictionary>(entityName: CDMessage.entityName)
        fetch.resultType = .dictionaryResultType
        let countExpression = NSExpressionDescription()
        countExpression.name = "count"
        countExpression.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "txId")])
        countExpression.expressionResultType = .integer64AttributeType
        fetch.propertiesToFetch = ["txId", countExpression]
        fetch.propertiesToGroupBy = ["txId"]
        if let walletAddr = walletAddr {
            fetch.predicate = NSPredicate(format: "walletAddress == %@ OR walletAddress == nil", walletAddr)
        }
        fetch.fetchLimit = dedupeBatchLimit

        guard let groups = try? context.fetch(fetch) else { return false }
        let duplicateTxIds = groups.compactMap { dict -> String? in
            guard let count = dict["count"] as? Int, count > 1 else { return nil }
            return dict["txId"] as? String
        }
        guard !duplicateTxIds.isEmpty else { return false }

        var deletedCount = 0
        for txId in duplicateTxIds {
            let dupFetch = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
            if let walletAddr = walletAddr {
                dupFetch.predicate = NSPredicate(format: "txId == %@ AND (walletAddress == %@ OR walletAddress == nil)", txId, walletAddr)
            } else {
                dupFetch.predicate = NSPredicate(format: "txId == %@", txId)
            }
            guard let matches = try? context.fetch(dupFetch), matches.count > 1 else { continue }

            let sorted = matches.sorted { lhs, rhs in
                let lhsHasContent = lhs.contentEncrypted != nil
                let rhsHasContent = rhs.contentEncrypted != nil
                if lhsHasContent != rhsHasContent {
                    return lhsHasContent && !rhsHasContent
                }
                let lhsUpdated = lhs.updatedAt ?? lhs.timestamp ?? Date.distantPast
                let rhsUpdated = rhs.updatedAt ?? rhs.timestamp ?? Date.distantPast
                return lhsUpdated > rhsUpdated
            }
            guard let keep = sorted.first else { continue }
            for record in sorted where record.objectID != keep.objectID {
                context.delete(record)
                deletedCount += 1
            }
        }

        guard deletedCount > 0 else { return false }
        do {
            try context.save()
            self.logInfo("[MessageStore] Deduped %d records (total=%d, distinct=%d)", deletedCount, counts.total, counts.distinct)
            return true
        } catch {
            self.logInfo("[MessageStore] Failed to dedupe messages: %@", error.localizedDescription)
            return false
        }
    }

    /// Manually checkpoint the WAL file to reduce file size
    /// Call this when the app is idle (backgrounded, after a large import, etc.)
    /// This triggers Core Data's PostSaveMaintenance which will checkpoint if needed
    func checkpointWAL() {
        guard ensureStoreLoaded() else { return }

        let context = container.newBackgroundContext()
        // ASYNC perform, never performAndWait: this is fired from the scene-phase handler when
        // the app backgrounds (tapping a link -> Safari), exactly when a background save may
        // be using the store. performAndWait blocked the MAIN thread on the SQLite lock, iOS
        // suspended the process mid-wait, and the app resumed still frozen inside that wait
        // (~1min hang + "unsafeForcedSync called from Swift Concurrent context"). Every caller
        // is fire-and-forget; a checkpoint is pure maintenance nobody needs to wait for.
        context.perform {
            do {
                let startTime = Date()

                // Trigger Core Data's PostSaveMaintenance by saving
                // This will checkpoint the WAL if the file size exceeds the threshold
                // Since we're calling this when idle (no active transactions),
                // it won't get "Database busy" errors
                if context.hasChanges {
                    try context.save()
                } else {
                    // No changes, but still trigger a save to force checkpoint
                    // Core Data will optimize this to a no-op if nothing changed
                    try context.save()
                }

                let duration = Date().timeIntervalSince(startTime) * 1000
                self.logInfo("[MessageStore] Manual WAL checkpoint triggered in %.0fms", duration)
            } catch {
                self.logInfo("[MessageStore] Manual checkpoint failed: %@", error.localizedDescription)
            }
        }
    }

    private static func sizeOfStoreFiles(at url: URL) -> Int64 {
        let basePath = url.path
        let candidates = [basePath, basePath + "-wal", basePath + "-shm"]
        let fileManager = FileManager.default
        var total: Int64 = 0
        for path in candidates {
            if let attributes = try? fileManager.attributesOfItem(atPath: path),
               let size = attributes[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
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

// MessageStore coordinates Core Data work on its own queues.
// Treat as sendable for structured concurrency usage.
extension MessageStore: @unchecked Sendable {}

@objc(CDMessage)
final class CDMessage: NSManagedObject {
    static let entityName = "CDMessage"

    @NSManaged var messageId: UUID?
    @NSManaged var txId: String
    @NSManaged var contactAddress: String
    @NSManaged var senderAddress: String?
    @NSManaged var receiverAddress: String?
    @NSManaged var contentEncrypted: Data?
    @NSManaged var timestamp: Date?
    @NSManaged var blockTime: Int64
    @NSManaged var acceptingBlock: String?
    @NSManaged var isOutgoing: Bool
    @NSManaged var messageType: String?
    @NSManaged var deliveryStatus: String?
    @NSManaged var updatedAt: Date?
    /// Wallet address for multi-account partitioning (nil = legacy/any wallet)
    @NSManaged var walletAddress: String?
}

@objc(CDConversation)
final class CDConversation: NSManagedObject {
    static let entityName = "CDConversation"

    @NSManaged var contactAddress: String
    @NSManaged var conversationId: UUID?
    @NSManaged var unreadCount: Int64
    @NSManaged var lastMessageAt: Date?
    @NSManaged var updatedAt: Date?
    /// Wallet address for multi-account partitioning (nil = legacy/any wallet)
    @NSManaged var walletAddress: String?

    // Read status fields
    /// txId of the last message the user has read
    @NSManaged var lastReadTxId: String?
    /// blockTime of the last read message (for ordering comparisons)
    @NSManaged var lastReadBlockTime: Int64
    /// When the user marked messages as read locally
    @NSManaged var lastReadAt: Date?

    // Archived state
    @NSManaged var isArchived: Bool
}

/// Per-device read marker (one row per device that read the conversation).
/// Each device writes its own marker (walletAddress + conversationId + deviceId).
/// This eliminates write conflicts between devices.
@objc(CDReadMarker)
final class CDReadMarker: NSManagedObject {
    static let entityName = "CDReadMarker"

    /// Wallet address the marker belongs to (required - every query filters on it)
    @NSManaged var walletAddress: String
    /// Contact address identifying the conversation
    @NSManaged var conversationId: String
    /// Device identifier from KeychainService.deviceIdentifier()
    @NSManaged var deviceId: String
    /// txId of the last read message (optional)
    @NSManaged var lastReadTxId: String?
    /// blockTime of the last read message (for ordering)
    @NSManaged var lastReadBlockTime: Int64
    /// When this marker was last updated (for stale cleanup)
    @NSManaged var updatedAt: Date?
}

/// A reaction (tapback) sent or received on a 1:1 message - see `MessageReactionContent`. One row
/// per (targetTxId, reactorAddress, walletAddress); `reactionTxId` is the reaction message's own
/// transaction id, kept for reference (not used for dedup - the fetch-then-upsert in
/// `MessageStore.upsertReaction` already prevents duplicates).
@objc(CDReaction)
final class CDReaction: NSManagedObject {
    static let entityName = "CDReaction"

    @NSManaged var targetTxId: String
    @NSManaged var reactorAddress: String
    @NSManaged var contactAddress: String
    @NSManaged var emojiEncrypted: Data?
    @NSManaged var reactionTxId: String?
    @NSManaged var blockTime: Int64
    @NSManaged var updatedAt: Date?
    @NSManaged var walletAddress: String?
    @NSManaged var deliveryStatus: String?
    @NSManaged var failedAction: String?
}

@objc(CDMessageEdit)
final class CDMessageEdit: NSManagedObject {
    static let entityName = "CDMessageEdit"

    @NSManaged var targetTxId: String
    @NSManaged var contactAddress: String
    @NSManaged var textEncrypted: Data?
    @NSManaged var editTxId: String?
    @NSManaged var blockTime: Int64
    @NSManaged var updatedAt: Date?
    @NSManaged var walletAddress: String?
    @NSManaged var deliveryStatus: String?
}

@objc(CDSyncMarker)
final class CDSyncMarker: NSManagedObject {
    static let entityName = "CDSyncMarker"

    @NSManaged var walletAddress: String
    @NSManaged var updatedAt: Date?
}
