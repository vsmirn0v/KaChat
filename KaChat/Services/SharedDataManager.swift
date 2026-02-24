import Foundation

/// Manages shared data between main app and notification extension via App Group
/// Both targets must have the same App Group entitlement configured
final class SharedDataManager {

    // MARK: - Constants

    static let appGroupIdentifier = "group.com.kachat.app"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func sharedDefaultsValue(forKey key: String) -> Any? {
        sharedDefaults?.object(forKey: key)
    }

    // MARK: - Keys

    private enum Keys {
        static let contacts = "shared_contacts"
        static let sharedSecrets = "shared_secrets"
        static let pendingMessages = "pending_messages"
        static let storedMessages = "stored_messages"
        static let outboundShares = "outbound_shares"
        static let privateKeyAvailable = "private_key_available"
        static let walletAddress = "wallet_address"
        static let unreadCount = "shared_unread_count"
        static let incomingNotificationSoundEnabled = "incoming_notification_sound_enabled"
        static let incomingNotificationVibrationEnabled = "incoming_notification_vibration_enabled"
    }

    // MARK: - Contact Sync

    /// Sync contacts from ContactsManager to shared container for notification extension
    @MainActor
    static func syncContactsForExtension() {
        let contacts = ContactsManager.shared.contacts.map { contact in
            SharedContact(
                address: contact.address,
                alias: contact.alias,
                notificationModeOverride: contact.notificationModeOverride
            )
        }

        guard let data = try? JSONEncoder().encode(contacts) else {
            NSLog("[SharedData] Failed to encode contacts")
            return
        }

        sharedDefaults?.set(data, forKey: Keys.contacts)
        NSLog("[SharedData] Synced %d contacts to shared container", contacts.count)
    }

    /// Sync notification defaults used by the notification service extension.
    @MainActor
    static func syncNotificationSettingsForExtension() {
        let settings = AppSettings.load()
        sharedDefaults?.set(settings.incomingNotificationSoundEnabled, forKey: Keys.incomingNotificationSoundEnabled)
        sharedDefaults?.set(settings.incomingNotificationVibrationEnabled, forKey: Keys.incomingNotificationVibrationEnabled)
    }

    /// Sync wallet address for notification extension (used to suppress outgoing pushes)
    @MainActor
    static func syncWalletAddressForExtension() {
        let address = WalletManager.shared.currentWallet?.publicAddress
        sharedDefaults?.set(address, forKey: Keys.walletAddress)
    }

    static func getWalletAddress() -> String? {
        return sharedDefaults?.string(forKey: Keys.walletAddress)
    }

    /// Get contact by address (called from notification extension)
    static func getContact(address: String) -> SharedContact? {
        guard let data = sharedDefaults?.data(forKey: Keys.contacts),
              let contacts = try? JSONDecoder().decode([SharedContact].self, from: data) else {
            return nil
        }
        return contacts.first { $0.address == address }
    }

    /// Get all contacts from shared container
    static func getAllContacts() -> [SharedContact] {
        guard let data = sharedDefaults?.data(forKey: Keys.contacts),
              let contacts = try? JSONDecoder().decode([SharedContact].self, from: data) else {
            return []
        }
        return contacts
    }

    // MARK: - Shared Secrets

    /// Store a shared secret for a contact address (call when handshake is processed)
    static func storeSharedSecret(_ secret: Data, for address: String) {
        var secrets = getSharedSecrets()
        secrets[address] = secret.base64EncodedString()

        guard let data = try? JSONEncoder().encode(secrets) else {
            NSLog("[SharedData] Failed to encode shared secrets")
            return
        }

        sharedDefaults?.set(data, forKey: Keys.sharedSecrets)
        NSLog("[SharedData] Stored shared secret for %@", String(address.suffix(8)))
    }

    /// Get shared secret for a contact address
    static func getSharedSecret(for address: String) -> Data? {
        let secrets = getSharedSecrets()
        guard let base64 = secrets[address],
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        return data
    }

    /// Get all shared secrets
    private static func getSharedSecrets() -> [String: String] {
        guard let data = sharedDefaults?.data(forKey: Keys.sharedSecrets),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return secrets
    }

    /// Remove shared secret for an address (call when contact is deleted)
    static func removeSharedSecret(for address: String) {
        var secrets = getSharedSecrets()
        secrets.removeValue(forKey: address)

        if let data = try? JSONEncoder().encode(secrets) {
            sharedDefaults?.set(data, forKey: Keys.sharedSecrets)
        }
    }

    /// Clear all shared secrets (call on wallet delete)
    static func clearSharedSecrets() {
        sharedDefaults?.removeObject(forKey: Keys.sharedSecrets)
    }

    // MARK: - Pending Messages (txId only, need to fetch payload)

    /// Add a pending message that needs to be fetched when app opens
    static func addPendingMessage(txId: String, sender: String, type: String? = nil) {
        var pending = getPendingMessages()

        // Avoid duplicates
        guard !pending.contains(where: { $0.txId == txId }) else { return }

        pending.append(SharedPendingMessage(
            txId: txId,
            sender: sender,
            type: type,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        ))

        // Keep only last 100 pending messages
        if pending.count > 100 {
            pending = Array(pending.suffix(100))
        }

        if let data = try? JSONEncoder().encode(pending) {
            sharedDefaults?.set(data, forKey: Keys.pendingMessages)
        }
    }

    /// Get all pending messages
    static func getPendingMessages() -> [SharedPendingMessage] {
        guard let data = sharedDefaults?.data(forKey: Keys.pendingMessages) else {
            return []
        }

        // Try JSONDecoder first (app format)
        if let pending = try? JSONDecoder().decode([SharedPendingMessage].self, from: data) {
            return pending
        }

        // Fall back to JSONSerialization (extension format)
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { dict -> SharedPendingMessage? in
            guard let txId = dict["txId"] as? String,
                  let sender = dict["sender"] as? String else {
                return nil
            }
            let type = dict["type"] as? String
            let timestamp = (dict["timestamp"] as? Int64) ?? Int64(Date().timeIntervalSince1970 * 1000)
            return SharedPendingMessage(txId: txId, sender: sender, type: type, timestamp: timestamp)
        }
    }

    /// Clear all pending messages
    static func clearPendingMessages() {
        sharedDefaults?.removeObject(forKey: Keys.pendingMessages)
    }

    /// Replace pending messages list (used for retry persistence)
    static func setPendingMessages(_ pending: [SharedPendingMessage]) {
        if pending.isEmpty {
            clearPendingMessages()
            return
        }
        if let data = try? JSONEncoder().encode(pending) {
            sharedDefaults?.set(data, forKey: Keys.pendingMessages)
        }
    }

    /// Remove a specific pending message by txId
    static func removePendingMessage(txId: String) {
        let pending = getPendingMessages()
        let filtered = pending.filter { $0.txId != txId }
        setPendingMessages(filtered)
    }

    // MARK: - Stored Messages (decrypted by extension, ready to add to chat)

    /// Store a decrypted message from notification extension
    static func storeMessage(txId: String, sender: String, content: String, timestamp: Int64) {
        var messages = getStoredMessagesRaw()

        // Avoid duplicates
        guard !messages.contains(where: { ($0["txId"] as? String) == txId }) else { return }

        messages.append([
            "txId": txId,
            "sender": sender,
            "content": content,
            "timestamp": timestamp
        ] as [String: Any])

        // Keep only last 50 stored messages
        if messages.count > 50 {
            messages = Array(messages.suffix(50))
        }

        if let data = try? JSONSerialization.data(withJSONObject: messages) {
            sharedDefaults?.set(data, forKey: Keys.storedMessages)
        }
    }

    /// Get all stored messages
    static func getStoredMessages() -> [[String: Any]] {
        return getStoredMessagesRaw()
    }

    private static func getStoredMessagesRaw() -> [[String: Any]] {
        guard let data = sharedDefaults?.data(forKey: Keys.storedMessages),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return messages
    }

    /// Clear all stored messages
    static func clearStoredMessages() {
        sharedDefaults?.removeObject(forKey: Keys.storedMessages)
    }

    // MARK: - Outbound Shares (Share Extension -> Main App)

    static func enqueueOutboundShare(contactAddress: String, text: String, autoSend: Bool = true) -> SharedOutboundShare? {
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        var shares = getOutboundShares()
            .filter { nowMs - $0.createdAtMs <= SharedOutboundShare.maxAgeMs }

        let share = SharedOutboundShare(
            id: UUID().uuidString,
            contactAddress: contactAddress,
            text: cleanedText,
            createdAtMs: nowMs,
            autoSend: autoSend
        )
        shares.append(share)

        if shares.count > SharedOutboundShare.maxStoredItems {
            shares = Array(shares.suffix(SharedOutboundShare.maxStoredItems))
        }

        guard let data = try? JSONEncoder().encode(shares) else {
            NSLog("[SharedData] Failed to encode outbound shares")
            return nil
        }

        sharedDefaults?.set(data, forKey: Keys.outboundShares)
        return share
    }

    static func getOutboundShare(id: String) -> SharedOutboundShare? {
        getOutboundShares().first { $0.id == id }
    }

    static func getOutboundShares() -> [SharedOutboundShare] {
        guard let data = sharedDefaults?.data(forKey: Keys.outboundShares),
              let shares = try? JSONDecoder().decode([SharedOutboundShare].self, from: data) else {
            return []
        }
        return shares
    }

    static func removeOutboundShare(id: String) {
        let filtered = getOutboundShares().filter { $0.id != id }
        if filtered.isEmpty {
            sharedDefaults?.removeObject(forKey: Keys.outboundShares)
            return
        }
        if let data = try? JSONEncoder().encode(filtered) {
            sharedDefaults?.set(data, forKey: Keys.outboundShares)
        }
    }

    static func pruneOutboundShares() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let filtered = getOutboundShares().filter { nowMs - $0.createdAtMs <= SharedOutboundShare.maxAgeMs }
        if filtered.isEmpty {
            sharedDefaults?.removeObject(forKey: Keys.outboundShares)
            return
        }
        if let data = try? JSONEncoder().encode(filtered) {
            sharedDefaults?.set(data, forKey: Keys.outboundShares)
        }
    }

    // MARK: - Private Key Availability

    /// Check if private key is available (set by main app)
    static func setPrivateKeyAvailable(_ available: Bool) {
        sharedDefaults?.set(available, forKey: Keys.privateKeyAvailable)
    }

    static func isPrivateKeyAvailable() -> Bool {
        return sharedDefaults?.bool(forKey: Keys.privateKeyAvailable) ?? false
    }

    // MARK: - Cleanup

    /// Clear all shared data (call on wallet delete)
    static func clearAllSharedData() {
        sharedDefaults?.removeObject(forKey: Keys.contacts)
        sharedDefaults?.removeObject(forKey: Keys.sharedSecrets)
        sharedDefaults?.removeObject(forKey: Keys.pendingMessages)
        sharedDefaults?.removeObject(forKey: Keys.storedMessages)
        sharedDefaults?.removeObject(forKey: Keys.privateKeyAvailable)
        sharedDefaults?.removeObject(forKey: Keys.outboundShares)
        sharedDefaults?.removeObject(forKey: Keys.unreadCount)
        sharedDefaults?.removeObject(forKey: Keys.incomingNotificationSoundEnabled)
        sharedDefaults?.removeObject(forKey: Keys.incomingNotificationVibrationEnabled)
        NSLog("[SharedData] Cleared all shared data")
    }

    // MARK: - Unread Count (Badge)

    static func getUnreadCount() -> Int {
        return sharedDefaults?.integer(forKey: Keys.unreadCount) ?? 0
    }

    static func setUnreadCount(_ count: Int) {
        sharedDefaults?.set(max(0, count), forKey: Keys.unreadCount)
    }

    static func incrementUnreadCount() -> Int {
        let newValue = max(0, getUnreadCount() + 1)
        setUnreadCount(newValue)
        return newValue
    }

    static func resetUnreadCount() {
        setUnreadCount(0)
    }
}

// MARK: - Shared Models

/// Contact info shared with notification extension
struct SharedContact: Codable {
    let address: String
    let alias: String
    let notificationModeOverride: ContactNotificationMode?
}

/// Pending message that needs to be fetched
struct SharedPendingMessage: Codable {
    let txId: String
    let sender: String
    let type: String?
    let timestamp: Int64

    init(txId: String, sender: String, type: String? = nil, timestamp: Int64) {
        self.txId = txId
        self.sender = sender
        self.type = type
        self.timestamp = timestamp
    }

    // Handle both old format (without type) and new format (with type)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        txId = try container.decode(String.self, forKey: .txId)
        sender = try container.decode(String.self, forKey: .sender)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
    }
}

/// Outbound share request created by Share Extension.
struct SharedOutboundShare: Codable {
    let id: String
    let contactAddress: String
    let text: String
    let createdAtMs: Int64
    let autoSend: Bool

    static let maxStoredItems = 50
    static let maxAgeMs: Int64 = 7 * 24 * 60 * 60 * 1000

    init(
        id: String,
        contactAddress: String,
        text: String,
        createdAtMs: Int64,
        autoSend: Bool = true
    ) {
        self.id = id
        self.contactAddress = contactAddress
        self.text = text
        self.createdAtMs = createdAtMs
        self.autoSend = autoSend
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        contactAddress = try container.decode(String.self, forKey: .contactAddress)
        text = try container.decode(String.self, forKey: .text)
        createdAtMs = try container.decode(Int64.self, forKey: .createdAtMs)
        autoSend = try container.decodeIfPresent(Bool.self, forKey: .autoSend) ?? true
    }
}
