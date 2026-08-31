import Foundation
import SwiftUI

// MARK: - Dynamic Coding Key (for dual camelCase/snake_case decode)

enum SharedFormatting {
    static let chatTime: DateFormatter = {
        let formatter = DateFormatter()
        // 12-hour, not tied to the device's 24-hour system setting - message timestamps should
        // read the same everywhere in the app regardless of the user's locale/region settings.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static let chatDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static let mediumDateShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let iso8601 = ISO8601DateFormatter()
}

enum SharedDetectors {
    static let link = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

// MARK: - Wallet Models

struct Wallet: Codable, Equatable {
    let publicAddress: String
    let publicKey: String
    var alias: String
    let createdAt: Date
    var balanceSompi: UInt64?

    // Spending-chain state (see WalletManager's spending-address derivation). Optional so
    // existing Keychain-stored Wallet JSON without these keys still decodes (synthesized
    // Decodable treats a missing key on an Optional property as nil, not a decode failure).
    var spendingAddressIndex: Int?
    var maxSpendingAddressIndex: Int?

    /// The spending-chain index currently active as the "primary" spending address.
    var effectiveSpendingAddressIndex: Int { spendingAddressIndex ?? 0 }

    /// The highest spending-chain index ever generated/shown in Manage Addresses.
    var effectiveMaxSpendingAddressIndex: Int {
        max(maxSpendingAddressIndex ?? 0, effectiveSpendingAddressIndex)
    }

    var shortAddress: String {
        guard publicAddress.count > 16 else { return publicAddress }
        let prefix = String(publicAddress.prefix(10))
        let suffix = String(publicAddress.suffix(6))
        return "\(prefix)...\(suffix)"
    }
}

/// A single derived spending-chain address as shown in Manage Addresses — always re-derived
/// live from the seed + index rather than persisted, matching Android (only the index bounds
/// are stored, never the address list itself).
struct SpendingAddressEntry: Identifiable, Equatable, Codable {
    let index: Int
    let address: String
    let balanceSompi: UInt64
    let isCurrent: Bool
    /// Whether this address has ever appeared in a transaction (independent of current
    /// balance — swept-to-zero addresses still count as used). Defaults false until the
    /// network history check completes.
    var everUsed: Bool = false
    /// User-assigned display name for this address, if any.
    var label: String?
    /// Whether this address is hidden from the main Manage Addresses list. Enforced
    /// server-side (WalletManager.setSpendingAddressHidden refuses to hide the primary
    /// address or one with a balance) — this flag alone should never be trusted to imply
    /// "safe to hide."
    var hidden: Bool = false

    var id: Int { index }

    var displayLabel: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Address #\(index)" : trimmed
    }

    var shortAddress: String {
        guard address.count > 20 else { return address }
        return "\(address.prefix(14))...\(address.suffix(6))"
    }
}

struct SeedPhrase: Codable {
    let words: [String]

    /// Optional BIP39 passphrase (the "25th word"). Combined with the mnemonic during seed
    /// derivation (`BIP39.mnemonicToSeed`) to unlock a distinct, hidden account. Optional so
    /// wallets stored before this feature still decode (a missing key on an Optional synthesizes
    /// as `nil`, same trick as `Wallet.spendingAddressIndex`). `nil` and `""` are equivalent
    /// (no passphrase). Persisted Secure-Enclave-wrapped and device-only alongside the words
    /// (see `KeychainService.saveSeedPhrase`), so the account auto-unlocks like any other.
    var passphrase: String?

    var phrase: String {
        words.joined(separator: " ")
    }

    init(words: [String], passphrase: String? = nil) {
        self.words = words
        self.passphrase = passphrase
    }

    init?(phrase: String, passphrase: String? = nil) {
        // Split by any whitespace including newlines, tabs, etc.
        let words = phrase.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard words.count == 12 || words.count == 24 else {
            return nil
        }
        self.words = words
        self.passphrase = passphrase
    }
}

// MARK: - Contact Models

enum ContactNotificationMode: String, Codable, CaseIterable {
    case off
    case noSound
    case sound

    var displayName: String {
        switch self {
        case .off: return String(localized: "Off")
        case .noSound: return String(localized: "No Sound")
        case .sound: return String(localized: "Sound")
        }
    }
}

enum PhotoAutoDisplayMode: String, Codable, CaseIterable {
    case automatic
    case alwaysShow
    case alwaysHide

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .alwaysShow: return String(localized: "Always Show")
        case .alwaysHide: return String(localized: "Always Hide")
        }
    }
}

struct Contact: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var address: String
    var alias: String
    var addedAt: Date
    var lastMessageAt: Date?
    var isAutoAdded: Bool
    var notificationModeOverride: ContactNotificationMode?
    var hasSentOutgoingMessage: Bool
    var photoAutoDisplayOverride: PhotoAutoDisplayMode?
    // Local-only enrichment from iOS/macOS system contacts.
    var systemContactId: String?
    /// Avatar source choice for linked system contacts: nil/false = the Contacts-app photo
    /// wins (the default whenever one exists); true = the user chose the KNS avatar in Chat
    /// Info. Optional so contacts stored before this field decode cleanly.
    var preferKNSAvatar: Bool?
    var systemDisplayNameSnapshot: String?
    var systemContactLinkSource: SystemContactLinkSource?
    var systemMatchConfidence: Double?
    var systemLastSyncedAt: Date?
    /// A base64 JPEG photo carried in the cross-platform backup, shown as an avatar
    /// fallback when this device has no system-contact photo or KNS avatar. Lets a photo
    /// set on another device (e.g. desktop) appear here after a restore. Optional so
    /// contacts stored before this field decode cleanly.
    var backupPhoto: String?

    init(
        id: UUID = UUID(),
        address: String,
        alias: String = "",
        addedAt: Date = Date(),
        lastMessageAt: Date? = nil,
        isAutoAdded: Bool = false,
        notificationModeOverride: ContactNotificationMode? = nil,
        hasSentOutgoingMessage: Bool = false,
        photoAutoDisplayOverride: PhotoAutoDisplayMode? = nil,
        systemContactId: String? = nil,
        preferKNSAvatar: Bool? = nil,
        systemDisplayNameSnapshot: String? = nil,
        systemContactLinkSource: SystemContactLinkSource? = nil,
        systemMatchConfidence: Double? = nil,
        systemLastSyncedAt: Date? = nil,
        backupPhoto: String? = nil
    ) {
        self.id = id
        self.address = address
        self.alias = alias.isEmpty ? Contact.generateDefaultAlias(from: address) : alias
        self.addedAt = addedAt
        self.lastMessageAt = lastMessageAt
        self.isAutoAdded = isAutoAdded
        self.notificationModeOverride = notificationModeOverride
        self.hasSentOutgoingMessage = hasSentOutgoingMessage
        self.photoAutoDisplayOverride = photoAutoDisplayOverride
        self.systemContactId = systemContactId
        self.preferKNSAvatar = preferKNSAvatar
        self.systemDisplayNameSnapshot = systemDisplayNameSnapshot
        self.systemContactLinkSource = systemContactLinkSource
        self.systemMatchConfidence = systemMatchConfidence
        self.systemLastSyncedAt = systemLastSyncedAt
        self.backupPhoto = backupPhoto
    }

    enum CodingKeys: String, CodingKey {
        case id
        case address
        case alias
        case addedAt
        case lastMessageAt
        case isAutoAdded
        case notificationModeOverride
        case notificationsMuted // Legacy key migrated into notificationModeOverride
        case hasSentOutgoingMessage
        case photoAutoDisplayOverride
        case systemContactId
        case systemDisplayNameSnapshot
        case systemContactLinkSource
        case systemMatchConfidence
        case systemLastSyncedAt
        case backupPhoto
    }

    // Custom decoding to handle missing fields in existing data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        address = try container.decode(String.self, forKey: .address)
        alias = try container.decode(String.self, forKey: .alias)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        isAutoAdded = try container.decodeIfPresent(Bool.self, forKey: .isAutoAdded) ?? false
        if let storedMode = try container.decodeIfPresent(ContactNotificationMode.self, forKey: .notificationModeOverride) {
            notificationModeOverride = storedMode
        } else {
            let legacyMuted = try container.decodeIfPresent(Bool.self, forKey: .notificationsMuted) ?? false
            notificationModeOverride = legacyMuted ? .off : nil
        }
        hasSentOutgoingMessage = try container.decodeIfPresent(Bool.self, forKey: .hasSentOutgoingMessage) ?? false
        photoAutoDisplayOverride = try container.decodeIfPresent(PhotoAutoDisplayMode.self, forKey: .photoAutoDisplayOverride)
        systemContactId = try container.decodeIfPresent(String.self, forKey: .systemContactId)
        systemDisplayNameSnapshot = try container.decodeIfPresent(String.self, forKey: .systemDisplayNameSnapshot)
        systemContactLinkSource = try container.decodeIfPresent(SystemContactLinkSource.self, forKey: .systemContactLinkSource)
        systemMatchConfidence = try container.decodeIfPresent(Double.self, forKey: .systemMatchConfidence)
        systemLastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .systemLastSyncedAt)
        backupPhoto = try container.decodeIfPresent(String.self, forKey: .backupPhoto)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(address, forKey: .address)
        try container.encode(alias, forKey: .alias)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(lastMessageAt, forKey: .lastMessageAt)
        try container.encode(isAutoAdded, forKey: .isAutoAdded)
        try container.encodeIfPresent(notificationModeOverride, forKey: .notificationModeOverride)
        try container.encode(hasSentOutgoingMessage, forKey: .hasSentOutgoingMessage)
        try container.encodeIfPresent(photoAutoDisplayOverride, forKey: .photoAutoDisplayOverride)
        try container.encodeIfPresent(systemContactId, forKey: .systemContactId)
        try container.encodeIfPresent(systemDisplayNameSnapshot, forKey: .systemDisplayNameSnapshot)
        try container.encodeIfPresent(systemContactLinkSource, forKey: .systemContactLinkSource)
        try container.encodeIfPresent(systemMatchConfidence, forKey: .systemMatchConfidence)
        try container.encodeIfPresent(systemLastSyncedAt, forKey: .systemLastSyncedAt)
        try container.encodeIfPresent(backupPhoto, forKey: .backupPhoto)
    }

    /// Matches Android's `KaspaAddress.shortDisplay`: "prefix:xxxx....xxxx" — shown wherever a
    /// contact has no alias/KNS domain set yet, instead of the old (and much less legible)
    /// last-8-raw-characters fallback.
    static func generateDefaultAlias(from address: String) -> String {
        let parts = address.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return address }
        let prefix = parts[0]
        let body = parts[1]
        guard body.count > 12 else { return "\(prefix):\(body)" }
        return "\(prefix):\(body.prefix(4))....\(body.suffix(4))"
    }
}

enum SystemContactLinkSource: String, Codable, Hashable {
    case matched
    case manual
    case autoCreated
}

struct SystemContactCandidate: Identifiable, Equatable {
    var id: String { "\(contactIdentifier)|\(address)" }
    let contactIdentifier: String
    let displayName: String
    let address: String
    let sourceHint: String?
    let isAutoCreated: Bool
}

struct SystemContactLinkTarget: Identifiable, Equatable {
    var id: String { contactIdentifier }
    let contactIdentifier: String
    let displayName: String
}

// MARK: - Message Models

struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let txId: String
    let senderAddress: String
    let receiverAddress: String
    let content: String
    let timestamp: Date
    let blockTime: UInt64
    let acceptingBlock: String?
    let isOutgoing: Bool
    let messageType: MessageType
    let deliveryStatus: DeliveryStatus

    /// Exact content of the cross-device fill-in slot created when this wallet's own outgoing
    /// message is discovered on-chain by a device that cannot decrypt it (own sends are encrypted
    /// for the recipient). The row keeps the message's place in the store and in backup archives
    /// until CloudKit or an archive restore delivers the real text (see
    /// `ChatService.preferMessage`), but it must NEVER be visible anywhere in the UI - every
    /// display surface filters with `isSentPlaceholder`. Single source of truth for the literal;
    /// do not duplicate the string.
    static let sentViaOtherDevicePlaceholder = "📤 Sent via another device"

    /// True if `content` is exactly the cross-device placeholder above. Use this (or the
    /// instance property) everywhere the placeholder is created, matched, or hidden.
    static func isSentPlaceholder(_ content: String) -> Bool {
        content == sentViaOtherDevicePlaceholder
    }

    /// See `ChatMessage.isSentPlaceholder(_:)`.
    var isSentPlaceholder: Bool {
        Self.isSentPlaceholder(content)
    }

    enum MessageType: String, Codable {
        case handshake
        case contextual
        case payment
        case audio
    }

    enum DeliveryStatus: String, Codable {
        case pending
        case sent
        case failed
        case warning

        var priority: Int {
            switch self {
            case .pending:
                return 0
            case .warning:
                return 1
            case .failed:
                return 2
            case .sent:
                return 3
            }
        }
    }

    init(id: UUID = UUID(), txId: String, senderAddress: String, receiverAddress: String, content: String, timestamp: Date, blockTime: UInt64, acceptingBlock: String? = nil, isOutgoing: Bool, messageType: MessageType = .contextual, deliveryStatus: DeliveryStatus = .sent) {
        self.id = id
        self.txId = txId
        self.senderAddress = senderAddress
        self.receiverAddress = receiverAddress
        self.content = content
        self.timestamp = timestamp
        self.blockTime = blockTime
        self.acceptingBlock = acceptingBlock
        self.isOutgoing = isOutgoing
        self.messageType = messageType
        self.deliveryStatus = deliveryStatus
    }

    enum CodingKeys: String, CodingKey {
        case id
        case txId
        case senderAddress
        case receiverAddress
        case content
        case timestamp
        case blockTime
        case acceptingBlock
        case isOutgoing
        case messageType
        case deliveryStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        txId = try container.decode(String.self, forKey: .txId)
        senderAddress = try container.decode(String.self, forKey: .senderAddress)
        receiverAddress = try container.decode(String.self, forKey: .receiverAddress)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        blockTime = try container.decode(UInt64.self, forKey: .blockTime)
        acceptingBlock = try container.decodeIfPresent(String.self, forKey: .acceptingBlock)
        isOutgoing = try container.decode(Bool.self, forKey: .isOutgoing)
        messageType = try container.decode(MessageType.self, forKey: .messageType)
        if let storedStatus = try container.decodeIfPresent(DeliveryStatus.self, forKey: .deliveryStatus) {
            deliveryStatus = storedStatus
        } else if txId.hasPrefix("pending_") {
            deliveryStatus = .pending
        } else {
            deliveryStatus = .sent
        }
    }
}

struct Conversation: Identifiable, Equatable {
    let id: UUID
    let contact: Contact
    var messages: [ChatMessage]
    var unreadCount: Int

    var lastMessage: ChatMessage? {
        // Cross-device placeholders are hidden everywhere (see ChatMessage.isSentPlaceholder),
        // so the chat-list preview shows the newest REAL message. A conversation whose only
        // messages are placeholders reports nil, exactly like a conversation with no messages,
        // so the row renders its normal empty state instead of leaking the placeholder.
        return messages.filter { !$0.isSentPlaceholder }.max { $0.timestamp < $1.timestamp }
    }

    init(id: UUID = UUID(), contact: Contact, messages: [ChatMessage] = [], unreadCount: Int = 0) {
        self.id = id
        self.contact = contact
        self.messages = messages
        self.unreadCount = unreadCount
    }
}

enum MessageRetention: String, Codable, CaseIterable {
    case forever
    case days30
    case days90
    case year1

    var days: Int? {
        switch self {
        case .forever:
            return nil
        case .days30:
            return 30
        case .days90:
            return 90
        case .year1:
            return 365
        }
    }

    var displayName: String {
        switch self {
        case .forever:
            return String(localized: "Keep forever")
        case .days30:
            return String(localized: "30 days")
        case .days90:
            return String(localized: "90 days")
        case .year1:
            return String(localized: "1 year")
        }
    }
}

// MARK: - API Response Models

struct HandshakeResponse: Codable {
    let txId: String
    let sender: String
    let receiver: String
    let blockTime: UInt64?
    let acceptingBlock: String?
    let acceptingDaaScore: UInt64?
    let messagePayload: String?

    enum CodingKeys: String, CodingKey {
        case txId = "tx_id"
        case sender
        case receiver
        case blockTime = "block_time"
        case acceptingBlock = "accepting_block"
        case acceptingDaaScore = "accepting_daa_score"
        case messagePayload = "message_payload"
    }
}

struct ContextualMessageResponse: Codable {
    let txId: String
    let sender: String
    let alias: String
    let blockTime: UInt64?
    let acceptingBlock: String?
    let acceptingDaaScore: UInt64?
    let messagePayload: String?

    enum CodingKeys: String, CodingKey {
        case txId = "tx_id"
        case sender
        case alias
        case blockTime = "block_time"
        case acceptingBlock = "accepting_block"
        case acceptingDaaScore = "accepting_daa_score"
        case messagePayload = "message_payload"
    }
}

struct PaymentResponse: Codable {
    let txId: String
    let sender: String
    let receiver: String
    let amount: UInt64?
    let message: String?
    let blockTime: UInt64?
    let acceptingBlock: String?
    let acceptingDaaScore: UInt64?
    let messagePayload: String?

    enum CodingKeys: String, CodingKey {
        case txId = "tx_id"
        case sender
        case receiver
        case amount
        case message
        case blockTime = "block_time"
        case acceptingBlock = "accepting_block"
        case acceptingDaaScore = "accepting_daa_score"
        case messagePayload = "message_payload"
    }

    init(txId: String, sender: String, receiver: String, amount: UInt64?, message: String?, blockTime: UInt64?, acceptingBlock: String?, acceptingDaaScore: UInt64?, messagePayload: String?) {
        self.txId = txId
        self.sender = sender
        self.receiver = receiver
        self.amount = amount
        self.message = message
        self.blockTime = blockTime
        self.acceptingBlock = acceptingBlock
        self.acceptingDaaScore = acceptingDaaScore
        self.messagePayload = messagePayload
    }
}

struct IndexerMetrics: Codable {
    let blockHeight: UInt64?
    let lastProcessedBlock: String?
    let pendingTransactions: Int?
    let uptime: UInt64?

    enum CodingKeys: String, CodingKey {
        case blockHeight = "block_height"
        case lastProcessedBlock = "last_processed_block"
        case pendingTransactions = "pending_transactions"
        case uptime
    }
}

struct SelfStashResponse: Codable {
    let txId: String
    let owner: String
    let scope: String
    let blockTime: UInt64?
    let acceptingBlock: String?
    let acceptingDaaScore: UInt64?
    let stashedData: String?

    enum CodingKeys: String, CodingKey {
        case txId = "tx_id"
        case owner
        case scope
        case blockTime = "block_time"
        case acceptingBlock = "accepting_block"
        case acceptingDaaScore = "accepting_daa_score"
        case stashedData = "stashed_data"
    }
}

struct GroupMessageResponse: Codable {
    let txId: String
    let sender: String?
    let blindedGroupId: String
    let blockTime: UInt64
    /// Opaque lossless pagination cursor - `block_time` alone can collide across items, so
    /// catch-up sync should persist and resume from this instead. Optional for source
    /// compatibility with an older indexer that doesn't send it yet. See docs/GROUP_CHAT_API.md.
    let cursor: String?
    let acceptingBlock: String?
    let acceptingDaaScore: UInt64?
    let messagePayload: String

    enum CodingKeys: String, CodingKey {
        case txId = "tx_id"
        case sender
        case blindedGroupId = "blinded_group_id"
        case blockTime = "block_time"
        case cursor
        case acceptingBlock = "accepting_block"
        case acceptingDaaScore = "accepting_daa_score"
        case messagePayload = "message_payload"
    }
}

struct GroupControlResponse: Codable {
    let txId: String
    let sender: String
    /// Present for recipient-addressed controls (`GET /group-control/by-recipient`); nil for
    /// legacy unaddressed ones. See docs/GROUP_CHAT_API.md.
    let recipient: String?
    let blockTime: UInt64
    /// Opaque lossless pagination cursor - see [GroupMessageResponse.cursor].
    let cursor: String?
    let acceptingBlock: String?
    let acceptingDaaScore: UInt64?
    let messagePayload: String

    enum CodingKeys: String, CodingKey {
        case txId = "tx_id"
        case sender
        case recipient
        case blockTime = "block_time"
        case cursor
        case acceptingBlock = "accepting_block"
        case acceptingDaaScore = "accepting_daa_score"
        case messagePayload = "message_payload"
    }
}

/// Decrypted saved handshake data from self-stash
/// Format from Kasia web: { type, alias, timestamp, version, theirAlias, partnerAddress, recipientAddress, isResponse }
struct SavedHandshakeData: Codable {
    let type: String?
    let alias: String?             // Our alias for this conversation
    let timestamp: UInt64?
    let version: Int?
    let theirAlias: String?        // Partner's alias
    let partnerAddress: String?    // Contact address
    let recipientAddress: String?  // Also contact address
    let isResponse: Bool?

    /// Get the contact's address (could be in different fields)
    var contactAddress: String {
        partnerAddress ?? recipientAddress ?? ""
    }

    /// Our alias for sending messages
    var ourAlias: String {
        alias ?? ""
    }
}

// MARK: - Protocol Message Types

struct HandshakePayload: Codable {
    let type: String?
    let alias: String?
    let timestamp: UInt64
    let conversationId: String?
    let version: Int?
    let recipientAddress: String?
    let sendToRecipient: Bool?
    let isResponse: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case alias
        case timestamp
        case conversationId
        case version
        case recipientAddress
        case sendToRecipient
        case isResponse
    }

    init(type: String? = nil, alias: String? = nil, timestamp: UInt64, conversationId: String? = nil, version: Int? = nil, recipientAddress: String? = nil, sendToRecipient: Bool? = nil, isResponse: Bool? = nil) {
        self.type = type
        self.alias = alias
        self.timestamp = timestamp
        self.conversationId = conversationId
        self.version = version
        self.recipientAddress = recipientAddress
        self.sendToRecipient = sendToRecipient
        self.isResponse = isResponse
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.timestamp = try container.decodeIfPresent(UInt64.self, forKey: .timestamp) ?? 0
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.recipientAddress = try container.decodeIfPresent(String.self, forKey: .recipientAddress)
            ?? dynamic.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "recipient_address"))
        self.sendToRecipient = try container.decodeIfPresent(Bool.self, forKey: .sendToRecipient)
            ?? dynamic.decodeIfPresent(Bool.self, forKey: DynamicCodingKey(stringValue: "send_to_recipient"))
        self.isResponse = try container.decodeIfPresent(Bool.self, forKey: .isResponse)
            ?? dynamic.decodeIfPresent(Bool.self, forKey: DynamicCodingKey(stringValue: "is_response"))
        // Dual-key decode: try camelCase then snake_case for cross-platform interop
        if let cid = try container.decodeIfPresent(String.self, forKey: .conversationId) {
            self.conversationId = cid
        } else {
            self.conversationId = try dynamic.decodeIfPresent(String.self, forKey: DynamicCodingKey(stringValue: "conversation_id"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(alias, forKey: .alias)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(recipientAddress, forKey: .recipientAddress)
        try container.encodeIfPresent(sendToRecipient, forKey: .sendToRecipient)
        try container.encodeIfPresent(isResponse, forKey: .isResponse)

        // Compatibility for older clients that still expect snake_case keys.
        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        if let conversationId {
            try dynamic.encode(conversationId, forKey: DynamicCodingKey(stringValue: "conversation_id"))
        }
        if let recipientAddress {
            try dynamic.encode(recipientAddress, forKey: DynamicCodingKey(stringValue: "recipient_address"))
        }
        if let sendToRecipient {
            try dynamic.encode(sendToRecipient, forKey: DynamicCodingKey(stringValue: "send_to_recipient"))
        }
        if let isResponse {
            try dynamic.encode(isResponse, forKey: DynamicCodingKey(stringValue: "is_response"))
        }
    }
}

// MARK: - Deterministic Alias Routing

enum AliasMode: String, Codable {
    case legacyOnly
    case hybrid
    case deterministicOnly
}

struct ConversationRoutingState: Codable {
    let contactAddress: String
    let deterministicMyAlias: String      // incoming/watch alias
    let deterministicTheirAlias: String   // outgoing/send alias
    var legacyIncomingAliases: Set<String>
    var legacyOutgoingAliases: Set<String>
    var mode: AliasMode
    var peerSupportsDeterministic: Bool
    var lastLegacyIncomingAtMs: UInt64?
    var lastDeterministicIncomingAtMs: UInt64?
}

struct MessagePayload: Codable {
    let content: String
}

struct PaymentPayload: Codable {
    let type: String
    let message: String
    let amount: UInt64
    let timestamp: UInt64
    let version: Int
}

/// A message that replies to an earlier one - embedded as JSON directly in the same plaintext
/// content used for plain text (no separate wire type), matching the Android client's
/// `MessageReplyContent` field-for-field so a reply started on one platform renders correctly on
/// the other. `replyToSender` is the original poster's address and `replyToPreview` is captured
/// at reply-creation time (a short snippet, or "🎤 Audio message" for a voice note) so the quote
/// still renders even if the original message has since been pruned or its sender hidden.
struct MessageReplyContent: Codable, Equatable {
    var type: String = "reply"
    let replyToId: String
    let replyToSender: String
    let replyToPreview: String
    let text: String
}

enum MessageReplyCodec {
    static let previewMaxLength = 80

    static func encode(replyToId: String, replyToSender: String, replyToPreview: String, text: String) -> String {
        let content = MessageReplyContent(
            replyToId: replyToId,
            replyToSender: replyToSender,
            replyToPreview: String(replyToPreview.prefix(previewMaxLength)),
            text: text
        )
        guard let data = try? JSONEncoder().encode(content),
              let json = String(data: data, encoding: .utf8) else {
            return text
        }
        return json
    }

    /// Parses `text` as a reply if it looks like one, else returns nil - a plain text message
    /// never accidentally renders as a reply just because it happens to start with `{`, since this
    /// also requires the explicit "reply" type marker.
    ///
    /// This runs on every message row's body evaluation, for every visible/newly-appearing row,
    /// uncached - so it's a hot path when scrolling. A reply envelope is always small (a short
    /// reply-to preview plus the reply text itself), but a photo/file message's envelope is ALSO
    /// valid JSON starting with `{` (see `MediaFile`) - without this size guard, every image
    /// message's multi-KB-to-multi-MB base64 payload got a real `trimmingCharacters` copy,
    /// UTF8 re-encode, and full `JSONDecoder` decode attempt here, just to fail the `type ==
    /// "reply"` check afterward. Scrolling fast through a photo-heavy chat's history - revealing
    /// many such messages at once - made that add up to a real multi-second freeze.
    // Small content-keyed cache: messageRow calls this (directly and via unwrappedText) several
    // times per row per frame, and the swipe-to-reveal-timestamps gesture re-runs the whole
    // body at 60-120 Hz. NSCache is thread-safe and self-evicting under memory pressure.
    private static let parseCache: NSCache<NSString, ReplyBox> = {
        let cache = NSCache<NSString, ReplyBox>(); cache.countLimit = 1024; return cache
    }()
    private final class ReplyBox { let value: MessageReplyContent?; init(_ v: MessageReplyContent?) { value = v } }

    static func parse(_ text: String?) -> MessageReplyContent? {
        guard let text, text.utf8.count < 100_000 else { return nil }
        let key = text as NSString
        if let hit = parseCache.object(forKey: key) { return hit.value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: MessageReplyContent? = {
            guard trimmed.first == "{", let data = trimmed.data(using: .utf8) else { return nil }
            guard let p = try? JSONDecoder().decode(MessageReplyContent.self, from: data),
                  p.type == "reply" else { return nil }
            return p
        }()
        parseCache.setObject(ReplyBox(parsed), forKey: key)
        return parsed
    }

    /// The actual message text for `content` - unwraps one level of reply envelope if present, so
    /// replying to a message that is itself a reply quotes the original reply's own text instead
    /// of embedding its raw JSON envelope as the preview.
    static func unwrappedText(_ content: String) -> String {
        parse(content)?.text ?? content
    }

    /// Human-readable one-line preview for `content` - unwraps a reply envelope first, then
    /// recognizes the inline voice/image JSON envelopes `MediaFile`/`ChatService.sendAudio`/
    /// `sendImage` use and substitutes a placeholder label for those (matching how a photo/voice
    /// message itself renders), instead of showing their raw JSON. Used everywhere a reply's own
    /// preview needs computing: embedding a new reply's quote, the "replying to" composer banner,
    /// and notification bodies.
    static func previewText(for content: String) -> String {
        let unwrapped = unwrappedText(content)
        if let reaction = MessageReactionCodec.parse(unwrapped) {
            // Never surface raw reaction JSON in a preview/notification body - humanized the
            // same way the NSE's `reactionPreviewText` does for push bodies.
            return "Reacted \(reaction.emoji)"
        }
        if VoiceMessageSniff.isVoiceMessage(unwrapped) {
            return "🎤 Audio message"
        }
        if InlineFileSniff.isImage(unwrapped) {
            return "📷 Photo"
        }
        if let chessEnvelope = ChessCodec.parseAny(unwrapped) {
            if case .invite(let invite) = chessEnvelope, let minutes = invite.tcMinutes {
                return "♟️ Chess - \(minutes) | \(invite.tcIncSeconds ?? 0)"
            }
            return "♟️ Chess"
        }
        // Any other {type:"file"} media envelope (video, documents, or one whose mime the
        // head-sniff can't pin down) - never leak raw JSON into a preview.
        if let mime = InlineMediaSniff.mimeType(of: unwrapped) {
            return mime.lowercased().hasPrefix("video/") ? "🎬 Video" : "📎 File"
        }
        if InlineMediaSniff.isFileEnvelope(unwrapped) {
            return "📎 File"
        }
        return unwrapped
    }
}

// MARK: - Reactions

/// A reaction (tapback) to an earlier message - embedded as JSON directly in the same plaintext
/// content used for plain text (no separate wire type), matching the same approach
/// `MessageReplyContent` already uses. `targetTxId` is the reacted-to message's Kaspa transaction
/// id - the only identifier both parties/platforms agree on, since a local row id isn't shared.
/// `action` is "add" or "remove": picking a new emoji on a message you've already reacted to
/// replaces your previous one, and tapping your currently-active reaction again removes it.
/// Field-for-field identical to Android's `MessageReactionContent` so a reaction sent from one
/// platform renders correctly on the other.
struct MessageReactionContent: Codable, Equatable {
    var type: String = "reaction"
    let targetTxId: String
    let emoji: String
    let action: String
}

enum MessageReactionCodec {
    static func encode(targetTxId: String, emoji: String, action: String) -> String {
        let content = MessageReactionContent(targetTxId: targetTxId, emoji: emoji, action: action)
        guard let data = try? JSONEncoder().encode(content),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    /// Same {-prefix + 100_000-byte guard as `MessageReplyCodec.parse`, for the same hot-path
    /// scrolling reason.
    static func parse(_ text: String?) -> MessageReactionContent? {
        guard let text, text.utf8.count < 100_000 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", let data = trimmed.data(using: .utf8) else { return nil }
        guard let parsed = try? JSONDecoder().decode(MessageReactionContent.self, from: data),
              parsed.type == "reaction" else { return nil }
        return parsed
    }
}

// MARK: - Fresh-address payment pools

/// A batch of the SENDER's own fresh receive addresses, shared so the recipient can pay them
/// there instead of at their chatting address - chain observers then can't link payments to the
/// chat identity. Embedded as JSON in the normal encrypted contextual content, exactly like
/// `MessageReactionContent` (no wire-protocol change), and never rendered as a bubble - see the
/// interception in `ChatService.addMessageToConversation`. `replace == true` means "discard my
/// previous pool, this list is authoritative"; false/absent means append (deduped). Wire format
/// documented in MESSAGING.md ("Fresh-Address Payment Pools") - Android/desktop must match
/// field-for-field.
struct AddressPoolContent: Codable, Equatable {
    var type: String = "addr_pool"
    let addresses: [String]
    let replace: Bool?
}

/// "Please send me a fresh pool" - sent when the stored pool for a contact runs low.
struct AddressPoolRequestContent: Codable, Equatable {
    var type: String = "addr_pool_request"
}

/// Sent by the PAYER alongside a pool-address payment: payment detection only watches the
/// chatting address, so a payment to a pool address would otherwise never surface in the
/// recipient's chat. The recipient renders a normal payment bubble from this notice (deduped by
/// `txId`). `amountSompi` is an integer amount in sompi; `address` is the pool address the
/// payment was sent to.
struct PaymentNoticeContent: Codable, Equatable {
    var type: String = "payment_notice"
    let txId: String
    let amountSompi: UInt64
    let address: String
}

/// Any one of the three payment-pool envelope shapes, parsed generically - mirrors
/// `ChessEnvelope`'s type-dispatch approach.
enum PaymentPoolEnvelope {
    case pool(AddressPoolContent)
    case request(AddressPoolRequestContent)
    case notice(PaymentNoticeContent)
}

/// Same conventions as `MessageReactionCodec`: plain JSON embedded directly as encrypted message
/// content, with the `{`-prefix + byte-size guard before attempting a full decode since `parse`
/// runs on every intercepted message's content.
enum PaymentPoolCodec {
    static func encode(_ content: AddressPoolContent) -> String { encodeAny(content) }
    static func encode(_ content: AddressPoolRequestContent) -> String { encodeAny(content) }
    static func encode(_ content: PaymentNoticeContent) -> String { encodeAny(content) }

    private static func encodeAny<T: Encodable>(_ content: T) -> String {
        guard let data = try? JSONEncoder().encode(content),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    static func parse(_ text: String?) -> PaymentPoolEnvelope? {
        guard let text, text.utf8.count < 100_000 else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", let data = trimmed.data(using: .utf8) else { return nil }
        guard let typeOnly = try? JSONDecoder().decode(PoolTypeOnly.self, from: data) else { return nil }
        switch typeOnly.type {
        case "addr_pool":
            guard let content = try? JSONDecoder().decode(AddressPoolContent.self, from: data) else { return nil }
            return .pool(content)
        case "addr_pool_request":
            guard let content = try? JSONDecoder().decode(AddressPoolRequestContent.self, from: data) else { return nil }
            return .request(content)
        case "payment_notice":
            guard let content = try? JSONDecoder().decode(PaymentNoticeContent.self, from: data) else { return nil }
            return .notice(content)
        default:
            return nil
        }
    }

    private struct PoolTypeOnly: Decodable {
        let type: String
    }
}

// MARK: - Chess

/// Which color the inviter chose to play - picked once (a coin flip) when the invite is sent and
/// embedded in the envelope, so both sides agree on colors without a picker UI.
enum ChessInviteColor: String, Codable {
    case white
    case black
}

struct ChessInviteContent: Codable, Equatable {
    var type: String = "chess_invite"
    let gameId: String
    let inviterColor: ChessInviteColor
    /// Optional time control: initial minutes per side + per-move increment seconds (e.g. 3/2).
    /// Both absent = casual untimed game, which is exactly the legacy wire shape - old clients
    /// on both platforms ignore unknown JSON fields, and synthesized Codable omits nil optionals
    /// entirely (encodeIfPresent), so cross-version invites stay compatible in both directions.
    var tcMinutes: Int? = nil
    var tcIncSeconds: Int? = nil
}

struct ChessResponseContent: Codable, Equatable {
    var type: String = "chess_response"
    let gameId: String
    let accepted: Bool
}

struct ChessMoveContent: Codable, Equatable {
    var type: String = "chess_move"
    let gameId: String
    let from: String
    let to: String
    let promotion: String?
    /// Timed games only: the mover's remaining clock in milliseconds AFTER this move, with the
    /// increment already added. Each side's authoritative remaining time is simply the clockMs
    /// of their own most recent move - no separate clock-sync messages needed. Absent on
    /// untimed games and on moves from legacy clients.
    var clockMs: Int64? = nil
}

struct ChessResignContent: Codable, Equatable {
    var type: String = "chess_resign"
    let gameId: String
    /// "timeout" when the sender's clock ran out (they flagged) rather than a manual resign.
    /// Legacy clients ignore this field and render it as a plain resignation.
    var reason: String? = nil
}

/// Any one of the four chess envelope shapes, parsed generically - `ChessGameService` uses this
/// to scan a conversation's messages for everything belonging to a given game without knowing
/// each shape's exact fields up front.
enum ChessEnvelope {
    case invite(ChessInviteContent)
    case response(ChessResponseContent)
    case move(ChessMoveContent)
    case resign(ChessResignContent)

    var gameId: String {
        switch self {
        case .invite(let content): return content.gameId
        case .response(let content): return content.gameId
        case .move(let content): return content.gameId
        case .resign(let content): return content.gameId
        }
    }
}

/// Same conventions as `MessageReplyCodec`: a plain JSON envelope embedded directly as message
/// content (no wire-protocol change), with a `{`-prefix + byte-size guard before attempting a
/// full decode, since this runs on every visible message row alongside reply/image parsing.
enum ChessCodec {
    static func encode(_ content: ChessInviteContent) -> String { encodeAny(content) }
    static func encode(_ content: ChessResponseContent) -> String { encodeAny(content) }
    static func encode(_ content: ChessMoveContent) -> String { encodeAny(content) }
    static func encode(_ content: ChessResignContent) -> String { encodeAny(content) }

    private static func encodeAny<T: Encodable>(_ content: T) -> String {
        guard let data = try? JSONEncoder().encode(content),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    private static let parseAnyCache: NSCache<NSString, ChessBox> = {
        let cache = NSCache<NSString, ChessBox>(); cache.countLimit = 1024; return cache
    }()
    private final class ChessBox { let value: ChessEnvelope?; init(_ v: ChessEnvelope?) { value = v } }

    /// Parses `text` as any of the four chess envelope shapes, or nil if it isn't one.
    static func parseAny(_ text: String?) -> ChessEnvelope? {
        guard let text, text.utf8.count < 100_000 else { return nil }
        let key = text as NSString
        if let hit = parseAnyCache.object(forKey: key) { return hit.value }
        let result = parseAnyUncached(text)
        parseAnyCache.setObject(ChessBox(result), forKey: key)
        return result
    }

    private static func parseAnyUncached(_ text: String) -> ChessEnvelope? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", let data = trimmed.data(using: .utf8) else { return nil }
        guard let typeOnly = try? JSONDecoder().decode(ChessTypeOnly.self, from: data) else { return nil }
        switch typeOnly.type {
        case "chess_invite":
            guard let content = try? JSONDecoder().decode(ChessInviteContent.self, from: data) else { return nil }
            return .invite(content)
        case "chess_response":
            guard let content = try? JSONDecoder().decode(ChessResponseContent.self, from: data) else { return nil }
            return .response(content)
        case "chess_move":
            guard let content = try? JSONDecoder().decode(ChessMoveContent.self, from: data) else { return nil }
            return .move(content)
        case "chess_resign":
            guard let content = try? JSONDecoder().decode(ChessResignContent.self, from: data) else { return nil }
            return .resign(content)
        default:
            return nil
        }
    }

    private struct ChessTypeOnly: Decodable {
        let type: String
    }
}

/// Lightweight sniff for the same inline file-attachment JSON shape `MediaFile` parses in 1:1
/// chats (`ChatService.sendImage`) - mirrors `VoiceMessageSniff`, just checking for an image
/// `mimeType` instead of audio.
enum InlineFileSniff {
    static func isImage(_ text: String) -> Bool {
        InlineMediaSniff.mimeType(of: text)?.lowercased().hasPrefix("image/") == true
    }
}

/// Extracts an inline-media payload's `mimeType` by scanning only the payload HEAD. The previous
/// sniffs trimmed + `JSONSerialization`-parsed the ENTIRE payload - for inline photos/audio that's
/// multi-MB of base64, and the sniffs run inside list-row view bodies (chat-list previews, reply
/// quotes), costing 10-100ms per call. App-generated inline-media JSON always carries `mimeType`
/// near the front; 2KB comfortably covers it.
///
/// Hardened against two real wire variants that used to defeat the sniff and leak raw JSON into
/// previews: (1) senders that built the envelope from a `[String: Any]` dictionary serialize the
/// keys in UNDEFINED order, so `content` can land before `mimeType`, pushing the mime megabytes
/// past this head window - but the `data:` URL itself names the mime right up front; and
/// (2) `JSONSerialization` escapes "/" as "\/", so the extracted value must be unescaped before
/// any `hasPrefix("image/")`-style check can match.
enum InlineMediaSniff {
    static func mimeType(of text: String) -> String? {
        let head = String(text.prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.first == "{" else { return nil }
        if let keyRange = head.range(of: "\"mimeType\"") {
            let afterKey = head[keyRange.upperBound...]
            if let colon = afterKey.firstIndex(of: ":") {
                let afterColon = afterKey[afterKey.index(after: colon)...].drop { $0 == " " }
                if afterColon.first == "\"" {
                    let valueStart = afterColon.index(after: afterColon.startIndex)
                    if let endQuote = afterColon[valueStart...].firstIndex(of: "\"") {
                        return unescaped(String(afterColon[valueStart..<endQuote]))
                    }
                }
            }
        }
        // Fallback: `content` serialized before `mimeType` - read the mime out of the data: URL.
        if let keyRange = head.range(of: "\"content\"") {
            let afterKey = head[keyRange.upperBound...]
            if let colon = afterKey.firstIndex(of: ":") {
                var value = afterKey[afterKey.index(after: colon)...].drop { $0 == " " }
                if value.hasPrefix("\"data:") {
                    value = value.dropFirst("\"data:".count)
                    if let end = value.firstIndex(where: { $0 == ";" || $0 == "\"" || $0 == "," }) {
                        return unescaped(String(value[..<end]))
                    }
                }
            }
        }
        return nil
    }

    /// Whether the head looks like the cross-platform `{"type":"file",...}` media envelope at
    /// all - the last-resort preview catch so raw JSON never shows even when the mime can't be
    /// determined.
    static func isFileEnvelope(_ text: String) -> Bool {
        let head = String(text.prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.first == "{" else { return false }
        return head.range(of: "\"type\"\\s*:\\s*\"file\"", options: .regularExpression) != nil
    }

    private static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\/", with: "/")
    }
}

/// Builds the cross-platform inline-media JSON envelope with a DETERMINISTIC field order:
/// `type, name, size, mimeType, content` - `mimeType` BEFORE the multi-MB `content`, and no
/// "\/" escaping. Senders used to build this from a `[String: Any]` + `JSONSerialization`
/// dictionary, whose undefined key order could push `mimeType` past every client's head-window
/// preview sniff (showing raw JSON in chat lists). Field order now matches Android's
/// `VoiceMessage.encode` and desktop's `buildImageEnvelopeJson` exactly.
enum MediaFileEnvelope {
    static func json(name: String, size: Int, mimeType: String, dataUrlContent: String) -> String {
        "{\"type\":\"file\",\"name\":\"\(escape(name))\",\"size\":\(size),\"mimeType\":\"\(escape(mimeType))\",\"content\":\"\(escape(dataUrlContent))\"}"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Lightweight sniff for the same inline voice-message JSON shape `MediaFile` parses in 1:1 chats
/// (`ChatService.sendAudio`/`MessageBubbleView.MediaFile`) - used where only a yes/no check and a
/// placeholder label are needed (e.g. a broadcast bubble or a reply quote preview), without
/// pulling in the full image/audio-player decoding path.
enum VoiceMessageSniff {
    struct Payload {
        let mimeType: String
        let data: Data
    }

    static func isVoiceMessage(_ text: String) -> Bool {
        // Head-sniff only - decode(text) parses the full multi-MB payload and base64-decodes the
        // audio, which is far too heavy for the yes/no preview checks this backs.
        InlineMediaSniff.mimeType(of: text)?.lowercased().hasPrefix("audio/") == true
    }

    /// Decodes the inline voice-message JSON into its mimeType and raw audio bytes, or nil if
    /// `text` isn't a voice message.
    static func decode(_ text: String) -> Payload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", let jsonData = trimmed.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let mimeType = json["mimeType"] as? String,
              let content = json["content"] as? String,
              mimeType.lowercased().hasPrefix("audio/"),
              content.hasPrefix("data:"),
              let commaIndex = content.firstIndex(of: ",") else { return nil }
        let base64 = String(content[content.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        return Payload(mimeType: mimeType, data: data)
    }
}

// MARK: - Diagnostics Models

struct ConnectionStatus: Equatable {
    var isConnected: Bool
    var pingMs: Int?
    var nodeAddress: String?
    var indexerAddress: String?
    var lastChecked: Date?
    var networkType: NetworkType
    var blockHeight: UInt64?
    var error: String?

    static var disconnected: ConnectionStatus {
        ConnectionStatus(
            isConnected: false,
            pingMs: nil,
            nodeAddress: nil,
            indexerAddress: nil,
            lastChecked: nil,
            networkType: .mainnet,
            blockHeight: nil,
            error: nil
        )
    }
}

enum NetworkType: String, Codable, CaseIterable {
    case mainnet
    case testnet

    var displayName: String {
        switch self {
        case .mainnet: return "Mainnet"
        case .testnet: return "Testnet"
        }
    }
}

/// App-wide appearance override. "System" (the default) just follows the device's own Light/Dark
/// Mode setting like any well-behaved app — Light/Dark force one specific appearance regardless
/// of what the device is currently set to.
enum AppAppearance: String, Codable, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil tells SwiftUI's `.preferredColorScheme` to defer to the device setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// In-app language override, independent of the device's system language. `.system` (the
/// default) means "follow the device setting" - the app never touches `AppleLanguages` in that
/// case, so it behaves exactly as it did before this setting existed. Any other case persists a
/// preferred-language override via the standard `AppleLanguages` UserDefaults key, which iOS only
/// picks up on the next cold launch - there is no in-process Bundle-swizzling here by design (see
/// the Settings row that sets this: it always prompts for a restart after changing this value).
enum AppLanguage: String, Codable, CaseIterable {
    case system
    case ar, arEG = "ar-EG", bn, de, en, es, fa, fr, he, hi, id, it, ja, ko, pt, ru, tr, vi
    case zhHans = "zh-Hans"

    /// Native name, matching how a language picker conventionally presents itself (each language
    /// names itself, not translated into the currently-displayed language).
    var displayName: String {
        switch self {
        case .system: return "System"
        case .ar: return "العربية"
        case .arEG: return "العربية (مصر)"
        case .bn: return "বাংলা"
        case .de: return "Deutsch"
        case .en: return "English"
        case .es: return "Español"
        case .fa: return "فارسی"
        case .fr: return "Français"
        case .he: return "עברית"
        case .hi: return "हिन्दी"
        case .id: return "Bahasa Indonesia"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .tr: return "Türkçe"
        case .vi: return "Tiếng Việt"
        case .zhHans: return "简体中文"
        }
    }

    /// The `AppleLanguages` preferred-language code for this case, or `nil` for `.system` (which
    /// means "remove the override, follow the device setting").
    var appleLanguageCode: String? {
        self == .system ? nil : rawValue
    }

    /// The `Locale` to pass as `.environment(\.locale, ...)` at the app root so every
    /// `Text(LocalizedStringKey)` in the tree re-resolves against this language's `.lproj`
    /// bundle immediately, no relaunch required (see `AppLocalization`'s doc comment for why
    /// this actually works, unlike the `AppleLanguages`/restart approach this replaces). `nil`
    /// for `.system` means "don't override the environment" - follow the device's own locale.
    var locale: Locale? {
        appleLanguageCode.map { Locale(identifier: $0) }
    }
}

/// Fiat currency for Portfolio's live KAS price/value display. Raw value is the lowercase ISO
/// 4217 code, doubling as the literal `vs_currency`/`vs_currencies` value CoinGecko's API expects
/// (see `CoinGeckoService`) - no separate mapping table to keep in sync. Unlike `AppLanguage`,
/// changing this takes effect immediately (no restart) since it only affects a live-fetched price,
/// not `Bundle`/`Locale`-driven UI strings.
enum AppCurrency: String, Codable, CaseIterable {
    case usDollar = "usd"
    case euro = "eur"
    case britishPound = "gbp"
    case japaneseYen = "jpy"
    case chineseYuan = "cny"
    case australianDollar = "aud"
    case canadianDollar = "cad"
    case swissFranc = "chf"
    case hongKongDollar = "hkd"
    case indianRupee = "inr"
    case southKoreanWon = "krw"
    case singaporeDollar = "sgd"
    case indonesianRupiah = "idr"
    case newZealandDollar = "nzd"
    case mexicanPeso = "mxn"
    case brazilianReal = "brl"
    case russianRuble = "rub"
    case turkishLira = "try"
    case southAfricanRand = "zar"
    /// Not ISO 4217 (no fiat currency is) - CoinGecko's `vs_currency` list includes major
    /// cryptocurrencies alongside fiat ones, "btc" among them, so this needs no special handling
    /// anywhere else: same API call, same `NumberFormatter` fallback-to-code behavior as any other
    /// code it doesn't recognize a symbol for (see `PortfolioView.currencySymbol(for:)`).
    case bitcoin = "btc"

    /// Uppercased for display (e.g. "USD") - `Foundation.Currency`/`NumberFormatter` both expect
    /// this casing. Not every case is a real ISO 4217 code (see `.bitcoin`).
    var code: String { rawValue.uppercased() }

    var name: String {
        switch self {
        case .usDollar: return "US Dollar"
        case .euro: return "Euro"
        case .britishPound: return "British Pound"
        case .japaneseYen: return "Japanese Yen"
        case .chineseYuan: return "Chinese Yuan"
        case .australianDollar: return "Australian Dollar"
        case .canadianDollar: return "Canadian Dollar"
        case .swissFranc: return "Swiss Franc"
        case .hongKongDollar: return "Hong Kong Dollar"
        case .indianRupee: return "Indian Rupee"
        case .southKoreanWon: return "South Korean Won"
        case .singaporeDollar: return "Singapore Dollar"
        case .indonesianRupiah: return "Indonesian Rupiah"
        case .newZealandDollar: return "New Zealand Dollar"
        case .mexicanPeso: return "Mexican Peso"
        case .brazilianReal: return "Brazilian Real"
        case .russianRuble: return "Russian Ruble"
        case .turkishLira: return "Turkish Lira"
        case .southAfricanRand: return "South African Rand"
        case .bitcoin: return "Bitcoin"
        }
    }

    var displayName: String { "\(name) (\(code))" }
}

/// Every bottom-tab destination this app can show - drives both MainTabView's actual TabView and
/// the reorderable preview strip on Settings > Customization > Menu. `tag` is a fixed identifier
/// per case (not tied to display position) so the app's existing tag-based navigation (e.g.
/// jumping to Chats on a notification tap) keeps working no matter what order the user picks.
enum AppTab: String, Codable, CaseIterable, Identifiable, Equatable, Hashable {
    case portfolio
    case coldStorage
    case chats
    case swap
    case profile
    case kaposts
    case broadcasts
    case apps
    /// The container the other feature tabs live in when they are not in the dock
    /// themselves - see `ecosystemSections(from:)`.
    case ecosystem
    /// RETIRED (4.0): the "+ More" dock item was removed - Customize Dock is reached via
    /// Settings > Customization instead. The case survives only so saved `tabOrder` /
    /// per-account `DockOverlay` blobs that contain "more" still decode; `isEnabled` hard-codes
    /// it hidden so it can never render in the dock again.
    case more

    var id: String { rawValue }

    var label: String {
        switch self {
        case .portfolio: return "Portfolio"
        case .coldStorage: return "Storage"
        case .chats: return "Chats"
        case .swap: return "Swap"
        case .profile: return "Profile"
        case .kaposts: return "KaPosts"
        case .broadcasts: return "Broadcasts"
        // Short enough for a dock label. `ecosystemTitle` carries the full name, which is what
        // the Ecosystem grid and the screen itself show.
        case .apps: return "Websites"
        case .ecosystem: return "Ecosystem"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .portfolio: return "chart.pie"
        case .coldStorage: return "lock.shield"
        case .chats: return "bubble.left.and.bubble.right"
        case .swap: return "arrow.left.arrow.right"
        case .profile: return "person.crop.circle"
        case .kaposts: return "square.and.pencil"
        case .broadcasts: return "dot.radiowaves.left.and.right"
        case .apps: return "globe"
        case .ecosystem: return "circle.hexagongrid"
        case .more: return "plus.circle"
        }
    }

    /// The name shown inside the Ecosystem grid, at the top of the section it opens, and in
    /// Customize Dock. Differs from `label` only where a dock label has to stay short - the tab
    /// bar truncates hard, so these full names live here rather than in `label`.
    var ecosystemTitle: String {
        switch self {
        case .apps: return "Popular Kaspa Websites"
        // ChangeNOW's own capitalization, matching how the app already names it everywhere else
        // (swap transaction rows, the settings section).
        case .swap: return "ChangeNOW Swap"
        default: return label
        }
    }

    var tag: Int {
        switch self {
        case .chats: return 1
        case .profile: return 2
        case .portfolio: return 3
        case .coldStorage: return 4
        case .swap: return 5
        case .kaposts: return 6
        case .more: return 7
        case .broadcasts: return 8
        case .apps: return 9
        case .ecosystem: return 10
        }
    }

    /// Chats/Profile stay mandatory (a wallet with no way back to its own chat list or profile
    /// isn't useful) - everything else is user-hideable.
    var canHide: Bool {
        switch self {
        case .chats, .profile: return false
        case .portfolio, .coldStorage, .swap, .kaposts, .broadcasts, .apps, .ecosystem, .more: return true
        }
    }

    /// Ecosystem takes the dock slot Swap used to hold, so a default install shows exactly the
    /// five the dock can fit - Portfolio, Storage, Chats, Ecosystem, Profile - with Swap, KaPosts,
    /// Broadcasts and the websites list still ENABLED but living inside Ecosystem rather than
    /// competing for a dock slot.
    static let defaultOrder: [AppTab] = [.portfolio, .coldStorage, .chats, .ecosystem, .profile, .swap, .kaposts, .broadcasts, .apps]

    /// The dock renders at most this many items (the iPhone tab bar's hard limit); anything past
    /// it falls off rather than letting the system TabView spawn its own "More" list. KaPosts and
    /// Broadcasts drop out first (in that order) when over the cap - they stay reachable by
    /// Ecosystem (see `ecosystemSections(from:)`). Anything enabled that doesn't fit simply
    /// tail-drops out of the dock and is reached through Ecosystem instead.
    static let maxDockItems = 5

    /// `settings.tabOrder`, resolved into real cases with any missing/unknown entries (a fresh
    /// install, or a tab added after some users already saved a custom order) appended at the
    /// end in default order, so nothing silently disappears from Menu Visibility or the tab bar.
    static func resolvedOrder(from settings: AppSettings) -> [AppTab] {
        var order = settings.tabOrder.compactMap { AppTab(rawValue: $0) }
        for tab in defaultOrder where !order.contains(tab) {
            order.append(tab)
        }
        return order
    }

    /// True when this tab is enabled (not hidden) in settings, independent of dock capacity.
    ///
    /// Child Mode (Settings > Security) hard-hides Swaps, KaPosts and Broadcasts here - this is
    /// the single choke point every dock consumer flows through (`visible`, `ecosystemSections`),
    /// so while it's on those tabs can't render in the dock NOR appear inside Ecosystem,
    /// regardless of dock settings.
    func isEnabled(in settings: AppSettings) -> Bool {
        if settings.childModeEnabled {
            switch self {
            case .swap, .kaposts, .broadcasts: return false
            default: break
            }
        }
        switch self {
        case .portfolio: return !settings.hidePortfolioTab
        case .coldStorage: return !settings.hideColdStorageTab
        case .swap: return !settings.hideSwapTab
        case .kaposts: return !settings.hideKaPostsTab
        case .broadcasts: return !settings.hideBroadcasts
        case .apps: return !settings.hideAppsTab
        case .ecosystem: return !settings.hideEcosystemTab
        // "+ More" is retired from the dock entirely (Customize Dock lives in Settings now) -
        // hard-hidden regardless of what an old saved blob says.
        case .more: return false
        case .chats, .profile: return true
        }
    }

    /// The resolved order, filtered down to only the tabs the user hasn't hidden and clamped to
    /// the dock capacity - what MainTabView actually renders and what the Menu Visibility preview
    /// strip shows. When over capacity, KaPosts drops out first (it stays reachable via re-tapping
    /// Chats); after that the tail of the order falls off.
    /// The resolved order, filtered to what the user hasn't hidden and clamped to dock capacity.
    ///
    /// Anything enabled that doesn't fit simply isn't in the dock. It is not lost: the four
    /// feature tabs are reachable through Ecosystem (see `ecosystemSections(from:)`). There is no
    /// longer a Chats-tab cycle - re-tapping or holding Chats to reach KaPosts and Broadcasts was
    /// removed once Ecosystem gave them a place of their own.
    static func visible(from settings: AppSettings) -> [AppTab] {
        let tabs = resolvedOrder(from: settings).filter { $0.isEnabled(in: settings) }
        return tabs.count > maxDockItems ? Array(tabs.prefix(maxDockItems)) : tabs
    }

    /// Everything Ecosystem can hold, in the order it lists them.
    static let ecosystemCandidates: [AppTab] = [.kaposts, .broadcasts, .swap, .apps]

    /// What the Ecosystem page actually shows: its candidates, minus anything hidden, minus
    /// anything that already has its own dock slot.
    ///
    /// The dock subtraction is the point - a feature sitting in the dock has no reason to also be
    /// a tile one level deeper, and listing it twice would just make the grid look padded.
    static func ecosystemSections(from settings: AppSettings) -> [AppTab] {
        let inDock = Set(visible(from: settings))
        return ecosystemCandidates.filter { $0.isEnabled(in: settings) && !inDock.contains($0) }
    }
}

/// Block explorer used for "view transaction" links, matching Android's KaspaExplorer enum.
enum KaspaExplorer: String, Codable, CaseIterable {
    case kaspaStream
    case kaspaOrg

    var displayName: String {
        switch self {
        case .kaspaStream: return "kaspa.stream"
        case .kaspaOrg: return "explorer.kaspa.org"
        }
    }

    private var txBaseURL: String {
        switch self {
        case .kaspaStream: return "https://kaspa.stream/transactions/"
        case .kaspaOrg: return "https://explorer.kaspa.org/txs/"
        }
    }

    private var addressBaseURL: String {
        switch self {
        case .kaspaStream: return "https://kaspa.stream/addresses/"
        case .kaspaOrg: return "https://explorer.kaspa.org/addresses/"
        }
    }

    func txURL(for txId: String) -> URL? {
        URL(string: txBaseURL + txId)
    }

    func addressURL(for address: String) -> URL? {
        guard let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: addressBaseURL + encoded)
    }

    static let `default`: KaspaExplorer = .kaspaOrg
}

enum NotificationMode: String, Codable, CaseIterable {
    case disabled
    case remotePush

    static var allCases: [NotificationMode] {
        [.disabled, .remotePush]
    }

    var displayName: String {
        switch self {
        case .disabled: return String(localized: "Disabled")
        case .remotePush: return String(localized: "Remote push")
        }
    }
}

// MARK: - Settings Models

enum ChatPhotoQualityPreset: String, Codable, CaseIterable {
    case dataSaver
    case balanced
    case high
    case best

    static let `default`: ChatPhotoQualityPreset = .balanced

    var displayName: String {
        switch self {
        case .dataSaver: return String(localized: "Data Saver")
        case .balanced: return String(localized: "Balanced")
        case .high: return String(localized: "High")
        case .best: return String(localized: "Best")
        }
    }

    var targetBytes: Int {
        switch self {
        case .dataSaver: return 10_000
        case .balanced: return 15_000
        case .high: return 31_000
        case .best: return 50_000
        }
    }

    var targetSizeText: String {
        "~\(targetBytes / 1_000) KB"
    }

    var summaryText: String {
        "\(displayName) · \(targetSizeText)"
    }

    var sliderValue: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    init(sliderValue: Double) {
        let index = Int(sliderValue.rounded())
        let clamped = min(max(index, 0), Self.allCases.count - 1)
        self = Self.allCases[clamped]
    }
}

struct AppSettings: Codable {
    var storeMessagesInICloud: Bool
    var messageRetention: MessageRetention
    var networkType: NetworkType
    var autoAddContacts: Bool
    var syncSystemContacts: Bool
    var notificationMode: NotificationMode
    var notificationPermissionRequested: Bool
    var incomingNotificationSoundEnabled: Bool
    var incomingNotificationVibrationEnabled: Bool
    /// Settings > Notifications > "Address Activity" (default ON): local notifications when
    /// any of the wallet's own NON-chatting addresses - spending-chain (Manage Addresses) or
    /// watch-only cold storage - receives Kaspa from an external source. Gates both the live
    /// UTXO-subscription path and the foreground catch-up diff (see AddressActivityNotifier).
    /// Deliberately not gated by Child Mode - these are wallet notifications, and Portfolio /
    /// Cold Storage remain available there.
    var addressActivityNotificationsEnabled: Bool
    /// Settings > Notifications > KaPosts: per-event-type gates for KaPosts notification
    /// pings (all default ON). Mapped from the K notifications API's `contentType` /
    /// `voteType` fields via `shouldNotifyKaPostsAction` - a disabled type is silently
    /// skipped, never queued. Orthogonal to Child Mode (which suppresses ALL KaPosts pings).
    var kaPostsNotifyLikes: Bool
    var kaPostsNotifyReposts: Bool
    var kaPostsNotifyFollows: Bool
    var kaPostsNotifyDislikes: Bool
    var kaPostsNotifyComments: Bool
    var messagePollInterval: TimeInterval
    var liveUpdatesEnabled: Bool
    var chatPhotoQualityPreset: ChatPhotoQualityPreset
    var requirePhotoApprovalForNewContacts: Bool
    var showFeeEstimate: Bool
    /// Optional (unlike most fields here) - this struct has no custom `init(from:)`, so a newly
    /// added *required* field would fail this whole struct's decode for anyone with a
    /// pre-existing settings blob saved before it existed, silently resetting every other setting
    /// back to `.default` (see `AppSettings.load()`'s `try?`). Nil/wrong-count means "never
    /// customized" - read via `effectiveQuickReactionEmojis`, never this raw property directly.
    var quickReactionEmojis: [String]?

    // Customization
    var appearance: AppAppearance
    var language: AppLanguage
    var currency: AppCurrency
    var hidePortfolioTab: Bool
    var hideSwapTab: Bool
    var hideColdStorageTab: Bool
    var hideKaPostsTab: Bool
    /// RETIRED (4.0): the "+ More" dock item is gone (`AppTab.isEnabled` hard-hides `.more`).
    /// Kept only so existing saved blobs that contain the key keep decoding/encoding cleanly.
    var hideMoreItem: Bool
    /// Broadcasts isn't a tab (it's an entry row inside the Chats list, see `ChatListView`'s
    /// `chatsTabContent`) but is still user-hideable from Settings > Customization > Menu, so it
    /// gets its own flag here rather than a case in `AppTab`.
    var hideBroadcasts: Bool
    /// Apps (ecosystem link bubbles) as a dock tab. Hidden (default) = the Apps row lives on
    /// the Profile screen instead; toggled on = dock tab, Profile row disappears.
    var hideAppsTab: Bool
    var hideEcosystemTab: Bool
    /// Raw values of `AppTab`, in display order - user-customizable via Settings > Customization
    /// > Menu's drag-to-reorder preview strip.
    var tabOrder: [String]

    // Security
    /// Child Mode (Settings > Security): while on, the app is strictly Chats, Group Chats,
    /// Portfolio and Cold Storage - Swaps, KaPosts and Broadcasts are removed from every access
    /// point (dock, Ecosystem, deep links, notifications, push registration). Turning it
    /// OFF is validated against the salted password hash in the Keychain (see ChildModeService) -
    /// this flag alone is just the fast-path gate the UI reads.
    var childModeEnabled: Bool
    var biometricSeedPhraseEnabled: Bool
    var biometricAccountLoginEnabled: Bool
    /// Gates the "Export" button on a spending address's own screen (Manage Addresses > tap an
    /// address) - separate from `biometricSeedPhraseEnabled` since revealing one address's own
    /// derived key is lower-stakes than the wallet's whole seed phrase, but still sensitive
    /// enough that some users will want it gated independently rather than always tied 1:1 to
    /// the seed-phrase toggle.
    var biometricSpendingKeyEnabled: Bool

    // Swap (ChangeNOW)
    var swapDisclaimerAgreed: Bool

    // Diagnostics
    /// Settings > Diagnostics > "Verbose API Logging" (default OFF): restores the per-request
    /// [KasiaAPI] success log lines (full URL, connection kind, IP, timing breakdown). While
    /// off, the API client only logs failures and slow requests plus a once-a-minute rollup.
    /// The unified logging system rate-limits and eventually quarantines processes that log
    /// too much, which was silencing the log lines that actually matter (see KasiaAPIClient's
    /// APIRequestLogGate).
    var verboseAPILogging: Bool

    // Connection settings
    var indexerURL: String
    /// K social-network indexer powering KaPosts (reusing the already-running public K indexer).
    var kaPostIndexerURL: String
    /// KaChat-owned broadcast indexer (tracks #kaspa and #kachat-bugs history) - served from
    /// the same box/domain as the KaPosts indexer.
    var broadcastIndexerURL: String
    var pushIndexerURL: String
    /// The Kaspa Name Service endpoint. Fixed to the current network's default, never stored and
    /// never user-editable.
    ///
    /// It used to be an editable field with no empty-string fallback (unlike the KaPosts and
    /// broadcast indexer fields, which fall back to their defaults). Saving Connection Settings
    /// with that field blank wrote "" straight through, and an empty base URL builds a
    /// scheme-less URL that URLSession rejects with NSURLErrorUnsupportedURL (-1002) - so every
    /// KNS call failed until it was typed back in by hand.
    ///
    /// Deriving it from `networkType` also means switching networks moves it, instead of leaving
    /// a testnet wallet pointed at the mainnet registry.
    var knsBaseURL: String { Self.defaultKNSURL(for: networkType) }

    var kaspaRestAPIURL: String
    var kaspaExplorer: KaspaExplorer
    /// A user-pinned "host:port" gRPC node - when non-blank, NodePoolService stops discovery
    /// (DNS seeds/peer-gossip/scoring) entirely and only ever connects to this address,
    /// Kaspium-style. Empty string = disabled (normal pool discovery). See
    /// NodeRegistry.setTrustedNode.
    var trustedNodeAddress: String

    /// User-saved node addresses for quick copy/paste into `trustedNodeAddress` above -
    /// purely a convenience list, never itself read by the node pool.
    var savedNodeAddresses: [SavedNodeAddress]

    // gRPC endpoint pool settings
    var grpcEndpointPool: [GrpcEndpoint]
    var discoverNewPeers: Bool           // Enable peer discovery from hot pool nodes
    var grpcPoolNetworkType: NetworkType?
    var lastPoolPersistDate: Date?       // Track when pool was last saved

    // Default URLs per network
    static let defaultIndexerURL = "https://kachat.duckdns.org"
    static let defaultKaPostIndexerURL = "https://kachat.duckdns.org"
    static let defaultBroadcastIndexerURL = defaultKaPostIndexerURL
    /// Retired default - the public K social indexer (`mainnet.kaspatalk.net`). KaPosts now
    /// runs on KaChat's own indexer, which enforces two-way KaChat-only exclusivity server-side
    /// and is a fresh network with no relation to the K social graph. Anyone still on the old
    /// default is migrated in `SettingsViewModel.load()`.
    static let legacyDefaultKaPostIndexerURL = "https://mainnet.kaspatalk.net"
    /// Retired default - `indexer.kasia.fyi` doesn't run the group-chat REST endpoints
    /// (`/group-messages/...`, `/group-control/...`). See `AppSettings.load()`'s one-time migration.
    static let legacyDefaultIndexerURL = "https://indexer.kasia.fyi"
    /// The previous shipped default (the community `indexer.kasia.wtf`), now replaced by KaChat's
    /// own indexer (`kachat.duckdns.org`). Swept in `SettingsViewModel.load()` like kasia.fyi.
    static let legacyDefaultIndexerURLKasiaWtf = "https://indexer.kasia.wtf"
    /// Our own push service (chat/group push + the broadcast/KaPosts extensions - see
    /// PUSH_EXTENSIONS.md). Superseded the community indexer.kasia.wtf once kachat.duckdns.org
    /// went live.
    static let defaultPushIndexerURL = "https://kachat.duckdns.org"
    static let defaultKNSMainnetURL = "https://api.knsdomains.org/mainnet/api/v1"
    static let defaultKNSTestnetURL = "https://api.knsdomains.org/tn10/api/v1"
    static let defaultKaspaMainnetURL = "https://api.kaspa.org"
    static let defaultKaspaTestnetURL = "https://api-tn11.kaspa.org"
    /// KaChat ships pinned to this node out of the box, rather than defaulting to full
    /// seed/DNS/peer-gossip discovery - the "Use Default" button in Connection Settings resets
    /// back to this same address after a user has typed something else. This is Kaspium's own
    /// currently-live default (see their node_settings_notifier.dart's "temporary Toccata node
    /// override" - node.kaspium.io's cert had expired, so Kaspium's app itself now points here
    /// instead) - TLS-secured, hence the `grpcs://` scheme (see Endpoint.secure/Endpoint(url:)).
    static let defaultTrustedNodeAddress = "grpcs://toccata.kaspium.io"

    /// Fixed tapback-style default set - matches Android's `QUICK_REACTION_EMOJIS`'s default.
    static let defaultQuickReactionEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// What the double-tap quick-reaction bar should actually show - falls back to the default
    /// set if never customized, or if a customization somehow ended up with the wrong count
    /// (the settings UI only ever writes exactly 6, but this stays defensive against any other
    /// path that might not).
    var effectiveQuickReactionEmojis: [String] {
        guard let quickReactionEmojis, quickReactionEmojis.count == 6 else {
            return AppSettings.defaultQuickReactionEmojis
        }
        return quickReactionEmojis
    }

    static func defaultKNSURL(for network: NetworkType) -> String {
        network == .mainnet ? defaultKNSMainnetURL : defaultKNSTestnetURL
    }

    static func defaultKaspaRestURL(for network: NetworkType) -> String {
        network == .mainnet ? defaultKaspaMainnetURL : defaultKaspaTestnetURL
    }

    static var `default`: AppSettings {
        AppSettings(
            storeMessagesInICloud: true,
            messageRetention: .forever,
            networkType: .mainnet,
            autoAddContacts: true,
            syncSystemContacts: true,
            notificationMode: .remotePush,
            notificationPermissionRequested: false,
            incomingNotificationSoundEnabled: true,
            incomingNotificationVibrationEnabled: true,
            addressActivityNotificationsEnabled: true,
            kaPostsNotifyLikes: true,
            kaPostsNotifyReposts: true,
            kaPostsNotifyFollows: true,
            kaPostsNotifyDislikes: true,
            kaPostsNotifyComments: true,
            messagePollInterval: 10.0,
            liveUpdatesEnabled: false,
            chatPhotoQualityPreset: .default,
            requirePhotoApprovalForNewContacts: true,
            showFeeEstimate: true,
            quickReactionEmojis: defaultQuickReactionEmojis,
            appearance: .system,
            language: .system,
            currency: .usDollar,
            // Fresh-install dock: EVERYTHING on. The dock renders as many as fit
            // (maxDockItems) - Portfolio, Storage, Chats, Ecosystem, Profile - and Swap,
            // KaPosts, Broadcasts and the websites list are reached through Ecosystem rather
            // than competing for a slot. Existing users are
            // unaffected: their saved settings decode with their own explicit values (or the ??
            // fallbacks in init(from:) for keys that predate them). "+ More" no longer exists
            // as a dock item.
            hidePortfolioTab: false,
            hideSwapTab: false,
            hideColdStorageTab: false,
            hideKaPostsTab: false,
            hideMoreItem: true,
            hideBroadcasts: false,
            hideAppsTab: false,
            hideEcosystemTab: false,
            tabOrder: AppTab.defaultOrder.map { $0.rawValue },
            childModeEnabled: false,
            biometricSeedPhraseEnabled: true,
            // Account-login biometrics are opt-in (off by default) on every platform.
            biometricAccountLoginEnabled: false,
            biometricSpendingKeyEnabled: true,
            swapDisclaimerAgreed: false,
            indexerURL: defaultIndexerURL,
            kaPostIndexerURL: defaultKaPostIndexerURL,
            broadcastIndexerURL: defaultBroadcastIndexerURL,
            pushIndexerURL: defaultPushIndexerURL,
            kaspaRestAPIURL: defaultKaspaMainnetURL,
            kaspaExplorer: .default,
            trustedNodeAddress: defaultTrustedNodeAddress,
            savedNodeAddresses: [],
            grpcEndpointPool: [],
            discoverNewPeers: true,
            grpcPoolNetworkType: nil,
            lastPoolPersistDate: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case storeMessagesInICloud
        case messageRetention
        case networkType
        case autoAddContacts
        case syncSystemContacts
        case notificationMode
        case notificationPermissionRequested
        case incomingNotificationSoundEnabled
        case incomingNotificationVibrationEnabled
        case addressActivityNotificationsEnabled
        case kaPostsNotifyLikes
        case kaPostsNotifyReposts
        case kaPostsNotifyFollows
        case kaPostsNotifyDislikes
        case kaPostsNotifyComments
        case messagePollInterval
        case liveUpdatesEnabled
        case chatPhotoQualityPreset
        case requirePhotoApprovalForNewContacts
        case showFeeEstimate
        case quickReactionEmojis
        case appearance
        case language
        case currency
        case hidePortfolioTab
        case hideSwapTab
        case hideColdStorageTab
        case hideKaPostsTab
        case hideMoreItem
        case hideBroadcasts
        case hideAppsTab
        case hideEcosystemTab
        case tabOrder
        case childModeEnabled
        case biometricSeedPhraseEnabled
        case biometricAccountLoginEnabled
        case biometricSpendingKeyEnabled
        case swapDisclaimerAgreed
        case verboseAPILogging
        case indexerURL
        case kaPostIndexerURL
        case broadcastIndexerURL
        case pushIndexerURL
        case kaspaRestAPIURL
        case kaspaExplorer
        case trustedNodeAddress
        case savedNodeAddresses
        case grpcEndpointPool
        case discoverNewPeers
        case grpcPoolNetworkType
        case lastPoolPersistDate
        // Legacy keys for migration
        case customIndexerURL
        case wrpcEndpointPool  // Legacy, ignored on load
        case autoRefreshWrpcPool  // Legacy, ignored on load
        case autoRefreshGrpcPool  // Legacy, migrate to discoverNewPeers
        case preferGrpc  // Legacy, ignored on load
        case notificationsEnabled  // Legacy, migrate to notificationMode
        case backgroundFetchEnabled  // Legacy, migrate to notificationMode
        case pushNotificationsEnabled  // Legacy, migrate to notificationMode
    }

    init(
        storeMessagesInICloud: Bool,
        messageRetention: MessageRetention,
        networkType: NetworkType,
        autoAddContacts: Bool,
        syncSystemContacts: Bool,
        notificationMode: NotificationMode,
        notificationPermissionRequested: Bool = false,
        incomingNotificationSoundEnabled: Bool = true,
        incomingNotificationVibrationEnabled: Bool = true,
        addressActivityNotificationsEnabled: Bool = true,
        kaPostsNotifyLikes: Bool = true,
        kaPostsNotifyReposts: Bool = true,
        kaPostsNotifyFollows: Bool = true,
        kaPostsNotifyDislikes: Bool = true,
        kaPostsNotifyComments: Bool = true,
        messagePollInterval: TimeInterval,
        liveUpdatesEnabled: Bool,
        chatPhotoQualityPreset: ChatPhotoQualityPreset = .default,
        requirePhotoApprovalForNewContacts: Bool = true,
        showFeeEstimate: Bool = true,
        quickReactionEmojis: [String]? = nil,
        appearance: AppAppearance = .system,
        language: AppLanguage = .system,
        currency: AppCurrency = .usDollar,
        hidePortfolioTab: Bool = false,
        hideSwapTab: Bool = false,
        hideColdStorageTab: Bool = false,
        hideKaPostsTab: Bool = false,
        hideMoreItem: Bool = true,
        hideBroadcasts: Bool = false,
        hideAppsTab: Bool = false,
        hideEcosystemTab: Bool = false,
        tabOrder: [String] = AppTab.defaultOrder.map { $0.rawValue },
        childModeEnabled: Bool = false,
        biometricSeedPhraseEnabled: Bool = true,
        biometricAccountLoginEnabled: Bool = false,
        biometricSpendingKeyEnabled: Bool = true,
        swapDisclaimerAgreed: Bool = false,
        verboseAPILogging: Bool = false,
        indexerURL: String,
        kaPostIndexerURL: String = AppSettings.defaultKaPostIndexerURL,
        broadcastIndexerURL: String = AppSettings.defaultBroadcastIndexerURL,
        pushIndexerURL: String,
        kaspaRestAPIURL: String,
        kaspaExplorer: KaspaExplorer = .default,
        trustedNodeAddress: String = AppSettings.defaultTrustedNodeAddress,
        savedNodeAddresses: [SavedNodeAddress] = [],
        grpcEndpointPool: [GrpcEndpoint] = [],
        discoverNewPeers: Bool = true,
        grpcPoolNetworkType: NetworkType? = nil,
        lastPoolPersistDate: Date? = nil
    ) {
        self.storeMessagesInICloud = storeMessagesInICloud
        self.messageRetention = messageRetention
        self.networkType = networkType
        // Auto-add contacts is always enabled.
        self.autoAddContacts = true
        self.syncSystemContacts = syncSystemContacts
        self.notificationMode = notificationMode
        self.notificationPermissionRequested = notificationPermissionRequested
        self.incomingNotificationSoundEnabled = incomingNotificationSoundEnabled
        self.incomingNotificationVibrationEnabled = incomingNotificationVibrationEnabled
        self.addressActivityNotificationsEnabled = addressActivityNotificationsEnabled
        self.kaPostsNotifyLikes = kaPostsNotifyLikes
        self.kaPostsNotifyReposts = kaPostsNotifyReposts
        self.kaPostsNotifyFollows = kaPostsNotifyFollows
        self.kaPostsNotifyDislikes = kaPostsNotifyDislikes
        self.kaPostsNotifyComments = kaPostsNotifyComments
        self.messagePollInterval = messagePollInterval
        self.liveUpdatesEnabled = liveUpdatesEnabled
        self.chatPhotoQualityPreset = chatPhotoQualityPreset
        self.requirePhotoApprovalForNewContacts = requirePhotoApprovalForNewContacts
        self.showFeeEstimate = showFeeEstimate
        self.quickReactionEmojis = quickReactionEmojis
        self.appearance = appearance
        self.language = language
        self.currency = currency
        self.hidePortfolioTab = hidePortfolioTab
        self.hideSwapTab = hideSwapTab
        self.hideColdStorageTab = hideColdStorageTab
        self.hideKaPostsTab = hideKaPostsTab
        self.hideMoreItem = hideMoreItem
        self.hideBroadcasts = hideBroadcasts
        self.hideAppsTab = hideAppsTab
        self.hideEcosystemTab = hideEcosystemTab
        self.tabOrder = tabOrder
        self.childModeEnabled = childModeEnabled
        self.biometricSeedPhraseEnabled = biometricSeedPhraseEnabled
        self.biometricAccountLoginEnabled = biometricAccountLoginEnabled
        self.biometricSpendingKeyEnabled = biometricSpendingKeyEnabled
        self.swapDisclaimerAgreed = swapDisclaimerAgreed
        self.verboseAPILogging = verboseAPILogging
        self.indexerURL = indexerURL
        self.kaPostIndexerURL = kaPostIndexerURL
        self.broadcastIndexerURL = broadcastIndexerURL
        self.pushIndexerURL = pushIndexerURL
        self.kaspaRestAPIURL = kaspaRestAPIURL
        self.kaspaExplorer = kaspaExplorer
        self.trustedNodeAddress = trustedNodeAddress
        self.savedNodeAddresses = savedNodeAddresses
        self.grpcEndpointPool = grpcEndpointPool
        self.discoverNewPeers = discoverNewPeers
        self.grpcPoolNetworkType = grpcPoolNetworkType
        self.lastPoolPersistDate = lastPoolPersistDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeMessagesInICloud = try container.decodeIfPresent(Bool.self, forKey: .storeMessagesInICloud) ?? false
        messageRetention = try container.decodeIfPresent(MessageRetention.self, forKey: .messageRetention) ?? .forever
        // Testnet is no longer selectable anywhere in the app - always run mainnet. Installs
        // that previously switched to testnet get migrated back (network-scoped URLs that
        // still match the testnet defaults snap back to mainnet defaults below).
        let storedNetworkType = try container.decodeIfPresent(NetworkType.self, forKey: .networkType) ?? .mainnet
        networkType = .mainnet
        // Ignore persisted value and keep this feature always enabled.
        autoAddContacts = true
        syncSystemContacts = try container.decodeIfPresent(Bool.self, forKey: .syncSystemContacts) ?? true
        if let storedModeRaw = try container.decodeIfPresent(String.self, forKey: .notificationMode) {
            switch storedModeRaw {
            case NotificationMode.disabled.rawValue:
                notificationMode = .disabled
            case NotificationMode.remotePush.rawValue, "localBackgroundFetch":
                notificationMode = .remotePush
            default:
                notificationMode = .remotePush
            }
        } else {
            let legacyNotifications = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
            let legacyBackgroundFetch = try container.decodeIfPresent(Bool.self, forKey: .backgroundFetchEnabled) ?? false
            let legacyPush = try container.decodeIfPresent(Bool.self, forKey: .pushNotificationsEnabled) ?? false

            if legacyPush {
                notificationMode = .remotePush
            } else if legacyBackgroundFetch || legacyNotifications {
                notificationMode = .remotePush
            } else {
                notificationMode = .disabled
            }
        }
        notificationPermissionRequested = try container.decodeIfPresent(Bool.self, forKey: .notificationPermissionRequested) ?? false
        incomingNotificationSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .incomingNotificationSoundEnabled) ?? true
        incomingNotificationVibrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .incomingNotificationVibrationEnabled) ?? true
        addressActivityNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .addressActivityNotificationsEnabled) ?? true
        kaPostsNotifyLikes = try container.decodeIfPresent(Bool.self, forKey: .kaPostsNotifyLikes) ?? true
        kaPostsNotifyReposts = try container.decodeIfPresent(Bool.self, forKey: .kaPostsNotifyReposts) ?? true
        kaPostsNotifyFollows = try container.decodeIfPresent(Bool.self, forKey: .kaPostsNotifyFollows) ?? true
        kaPostsNotifyDislikes = try container.decodeIfPresent(Bool.self, forKey: .kaPostsNotifyDislikes) ?? true
        kaPostsNotifyComments = try container.decodeIfPresent(Bool.self, forKey: .kaPostsNotifyComments) ?? true
        messagePollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .messagePollInterval) ?? 10.0
        liveUpdatesEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveUpdatesEnabled) ?? false
        chatPhotoQualityPreset = try container.decodeIfPresent(
            ChatPhotoQualityPreset.self,
            forKey: .chatPhotoQualityPreset
        ) ?? .default
        requirePhotoApprovalForNewContacts = try container.decodeIfPresent(Bool.self, forKey: .requirePhotoApprovalForNewContacts) ?? true
        showFeeEstimate = try container.decodeIfPresent(Bool.self, forKey: .showFeeEstimate) ?? true
        quickReactionEmojis = try container.decodeIfPresent([String].self, forKey: .quickReactionEmojis)
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        currency = try container.decodeIfPresent(AppCurrency.self, forKey: .currency) ?? .usDollar
        hidePortfolioTab = try container.decodeIfPresent(Bool.self, forKey: .hidePortfolioTab) ?? false
        hideSwapTab = try container.decodeIfPresent(Bool.self, forKey: .hideSwapTab) ?? false
        hideColdStorageTab = try container.decodeIfPresent(Bool.self, forKey: .hideColdStorageTab) ?? false
        // Seeding for EXISTING users (blobs saved before these keys existed): KaPosts and
        // Broadcasts land ENABLED. With a full dock they don't get a slot, and are reached
        // through Ecosystem instead - see AppTab.ecosystemSections.
        hideKaPostsTab = try container.decodeIfPresent(Bool.self, forKey: .hideKaPostsTab) ?? false
        hideMoreItem = try container.decodeIfPresent(Bool.self, forKey: .hideMoreItem) ?? false
        hideBroadcasts = try container.decodeIfPresent(Bool.self, forKey: .hideBroadcasts) ?? false
        hideAppsTab = try container.decodeIfPresent(Bool.self, forKey: .hideAppsTab) ?? true
        // Defaults to SHOWN for everyone, new and existing: Ecosystem is where Swap, KaPosts,
        // Broadcasts and the websites list live now, so hiding it by default would strand them.
        hideEcosystemTab = try container.decodeIfPresent(Bool.self, forKey: .hideEcosystemTab) ?? false
        tabOrder = try container.decodeIfPresent([String].self, forKey: .tabOrder) ?? AppTab.defaultOrder.map { $0.rawValue }
        childModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .childModeEnabled) ?? false
        biometricSeedPhraseEnabled = try container.decodeIfPresent(Bool.self, forKey: .biometricSeedPhraseEnabled) ?? true
        biometricAccountLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .biometricAccountLoginEnabled) ?? false
        biometricSpendingKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .biometricSpendingKeyEnabled) ?? true
        swapDisclaimerAgreed = try container.decodeIfPresent(Bool.self, forKey: .swapDisclaimerAgreed) ?? false
        verboseAPILogging = try container.decodeIfPresent(Bool.self, forKey: .verboseAPILogging) ?? false

        // Handle migration from old settings
        if let customIndexer = try container.decodeIfPresent(String.self, forKey: .customIndexerURL), !customIndexer.isEmpty {
            indexerURL = customIndexer
        } else {
            indexerURL = try container.decodeIfPresent(String.self, forKey: .indexerURL) ?? AppSettings.defaultIndexerURL
        }
        // Old-default migration: stored values pointing at superseded default hosts follow the
        // default forward; custom URLs are untouched.
        let storedKaPostIndexer = try container.decodeIfPresent(String.self, forKey: .kaPostIndexerURL) ?? AppSettings.defaultKaPostIndexerURL
        let supersededIndexerDefaults = ["https://kaposts.duckdns.org", "https://mainnet.kaspatalk.net"]
        kaPostIndexerURL = supersededIndexerDefaults.contains(storedKaPostIndexer)
            ? AppSettings.defaultKaPostIndexerURL : storedKaPostIndexer
        let storedBroadcastIndexer = try container.decodeIfPresent(String.self, forKey: .broadcastIndexerURL) ?? ""
        broadcastIndexerURL = storedBroadcastIndexer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || storedBroadcastIndexer == "https://kaposts.duckdns.org"
            ? AppSettings.defaultBroadcastIndexerURL : storedBroadcastIndexer

        if let customPushIndexer = try container.decodeIfPresent(String.self, forKey: .pushIndexerURL),
           !customPushIndexer.isEmpty,
           customPushIndexer != "https://indexer.kasia.wtf" {
            // Stored custom URLs are honored; the superseded kasia.wtf default migrates
            // forward to our own push service.
            pushIndexerURL = customPushIndexer
        } else {
            pushIndexerURL = AppSettings.defaultPushIndexerURL
        }

        // knsBaseURL is computed from networkType now, so any value in an existing blob - including
        // the empty string that broke it - is simply ignored.
        kaspaRestAPIURL = try container.decodeIfPresent(String.self, forKey: .kaspaRestAPIURL) ?? AppSettings.defaultKaspaRestURL(for: networkType)
        if storedNetworkType == .testnet {
            if kaspaRestAPIURL == AppSettings.defaultKaspaRestURL(for: .testnet) {
                kaspaRestAPIURL = AppSettings.defaultKaspaRestURL(for: .mainnet)
            }
        }
        kaspaExplorer = try container.decodeIfPresent(KaspaExplorer.self, forKey: .kaspaExplorer) ?? .default
        trustedNodeAddress = try container.decodeIfPresent(String.self, forKey: .trustedNodeAddress) ?? AppSettings.defaultTrustedNodeAddress
        savedNodeAddresses = try container.decodeIfPresent([SavedNodeAddress].self, forKey: .savedNodeAddresses) ?? []

        // gRPC pool settings
        grpcEndpointPool = try container.decodeIfPresent([GrpcEndpoint].self, forKey: .grpcEndpointPool) ?? []
        grpcPoolNetworkType = try container.decodeIfPresent(NetworkType.self, forKey: .grpcPoolNetworkType)
        lastPoolPersistDate = try container.decodeIfPresent(Date.self, forKey: .lastPoolPersistDate)

        // Migrate from legacy autoRefreshGrpcPool to discoverNewPeers
        if let newValue = try container.decodeIfPresent(Bool.self, forKey: .discoverNewPeers) {
            discoverNewPeers = newValue
        } else if let legacyValue = try container.decodeIfPresent(Bool.self, forKey: .autoRefreshGrpcPool) {
            discoverNewPeers = legacyValue
        } else {
            discoverNewPeers = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storeMessagesInICloud, forKey: .storeMessagesInICloud)
        try container.encode(messageRetention, forKey: .messageRetention)
        try container.encode(networkType, forKey: .networkType)
        // Persist as enabled for forward/backward compatibility.
        try container.encode(true, forKey: .autoAddContacts)
        try container.encode(syncSystemContacts, forKey: .syncSystemContacts)
        try container.encode(notificationMode, forKey: .notificationMode)
        try container.encode(notificationPermissionRequested, forKey: .notificationPermissionRequested)
        try container.encode(incomingNotificationSoundEnabled, forKey: .incomingNotificationSoundEnabled)
        try container.encode(incomingNotificationVibrationEnabled, forKey: .incomingNotificationVibrationEnabled)
        try container.encode(addressActivityNotificationsEnabled, forKey: .addressActivityNotificationsEnabled)
        try container.encode(kaPostsNotifyLikes, forKey: .kaPostsNotifyLikes)
        try container.encode(kaPostsNotifyReposts, forKey: .kaPostsNotifyReposts)
        try container.encode(kaPostsNotifyFollows, forKey: .kaPostsNotifyFollows)
        try container.encode(kaPostsNotifyDislikes, forKey: .kaPostsNotifyDislikes)
        try container.encode(kaPostsNotifyComments, forKey: .kaPostsNotifyComments)
        try container.encode(messagePollInterval, forKey: .messagePollInterval)
        try container.encode(liveUpdatesEnabled, forKey: .liveUpdatesEnabled)
        try container.encode(chatPhotoQualityPreset, forKey: .chatPhotoQualityPreset)
        try container.encode(requirePhotoApprovalForNewContacts, forKey: .requirePhotoApprovalForNewContacts)
        try container.encode(showFeeEstimate, forKey: .showFeeEstimate)
        try container.encodeIfPresent(quickReactionEmojis, forKey: .quickReactionEmojis)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(language, forKey: .language)
        try container.encode(currency, forKey: .currency)
        try container.encode(hidePortfolioTab, forKey: .hidePortfolioTab)
        try container.encode(hideSwapTab, forKey: .hideSwapTab)
        try container.encode(hideColdStorageTab, forKey: .hideColdStorageTab)
        try container.encode(hideKaPostsTab, forKey: .hideKaPostsTab)
        try container.encode(hideMoreItem, forKey: .hideMoreItem)
        try container.encode(hideBroadcasts, forKey: .hideBroadcasts)
        try container.encode(hideAppsTab, forKey: .hideAppsTab)
        try container.encode(hideEcosystemTab, forKey: .hideEcosystemTab)
        try container.encode(tabOrder, forKey: .tabOrder)
        try container.encode(childModeEnabled, forKey: .childModeEnabled)
        try container.encode(biometricSeedPhraseEnabled, forKey: .biometricSeedPhraseEnabled)
        try container.encode(biometricAccountLoginEnabled, forKey: .biometricAccountLoginEnabled)
        try container.encode(biometricSpendingKeyEnabled, forKey: .biometricSpendingKeyEnabled)
        try container.encode(swapDisclaimerAgreed, forKey: .swapDisclaimerAgreed)
        try container.encode(verboseAPILogging, forKey: .verboseAPILogging)
        try container.encode(indexerURL, forKey: .indexerURL)
        try container.encode(kaPostIndexerURL, forKey: .kaPostIndexerURL)
        try container.encode(broadcastIndexerURL, forKey: .broadcastIndexerURL)
        try container.encode(pushIndexerURL, forKey: .pushIndexerURL)
        try container.encode(kaspaRestAPIURL, forKey: .kaspaRestAPIURL)
        try container.encode(kaspaExplorer, forKey: .kaspaExplorer)
        try container.encode(trustedNodeAddress, forKey: .trustedNodeAddress)
        try container.encode(savedNodeAddresses, forKey: .savedNodeAddresses)
        try container.encode(grpcEndpointPool, forKey: .grpcEndpointPool)
        try container.encode(discoverNewPeers, forKey: .discoverNewPeers)
        try container.encodeIfPresent(grpcPoolNetworkType, forKey: .grpcPoolNetworkType)
        try container.encodeIfPresent(lastPoolPersistDate, forKey: .lastPoolPersistDate)
    }

    var defaultIncomingNotificationMode: ContactNotificationMode {
        incomingNotificationSoundEnabled ? .sound : .noSound
    }

    func effectiveIncomingNotificationMode(for contact: Contact?) -> ContactNotificationMode {
        guard notificationMode != .disabled else { return .off }
        return contact?.notificationModeOverride ?? defaultIncomingNotificationMode
    }

    func shouldDeliverIncomingNotification(for contact: Contact?) -> Bool {
        effectiveIncomingNotificationMode(for: contact) != .off
    }

    func shouldPlayIncomingNotificationSound(for contact: Contact?) -> Bool {
        effectiveIncomingNotificationMode(for: contact) == .sound
    }

    var notificationsEnabled: Bool {
        get { notificationMode != .disabled }
        set { notificationMode = newValue ? .remotePush : .disabled }
    }

    /// Per-event-type gate for KaPosts notification pings, keyed off the K notifications
    /// API's fields (see KaPostsAPIClient.KNotification / KaPostsNotificationService.postLocal):
    /// `contentType` is "vote" (with `voteType` "upvote"/"downvote"), "reply", "quote"
    /// (K's repost mechanism - quotes-with-text included), or "follow". Unknown kinds always
    /// notify rather than silently vanishing behind a toggle that doesn't name them.
    func shouldNotifyKaPostsAction(contentType: String?, voteType: String?) -> Bool {
        switch contentType {
        case "vote": return voteType == "downvote" ? kaPostsNotifyDislikes : kaPostsNotifyLikes
        case "reply": return kaPostsNotifyComments
        case "quote": return kaPostsNotifyReposts
        case "follow": return kaPostsNotifyFollows
        // Being @mentioned always pings - deliberate, not the unknown-kind fallback.
        case "mention": return true
        default: return true
        }
    }

    var backgroundFetchEnabled: Bool {
        get { false }
        set { }
    }

    var pushNotificationsEnabled: Bool {
        get { notificationMode == .remotePush }
        set {
            if newValue {
                notificationMode = .remotePush
            } else if notificationMode == .remotePush {
                notificationMode = .disabled
            }
        }
    }
}

// MARK: - Error Types

enum KasiaError: LocalizedError {
    case walletNotFound
    case invalidSeedPhrase
    case seedPhraseParsingFailed(wordCount: Int)
    case mnemonicValidationFailed(reason: String)
    case invalidAddress
    case networkError(String)
    case keychainError(String)
    case encryptionError(String)
    case apiError(String)
    case unknownError

    var errorDescription: String? {
        switch self {
        case .walletNotFound:
            return "Account not found. Please create or import an account."
        case .invalidSeedPhrase:
            return "Invalid seed phrase. Please enter 12 or 24 words."
        case .seedPhraseParsingFailed(let wordCount):
            return "Seed phrase parsing failed. Detected \(wordCount) words (expected 12 or 24)."
        case .mnemonicValidationFailed(let reason):
            return "Mnemonic validation failed: \(reason)"
        case .invalidAddress:
            return "Invalid Kaspa address format."
        case .networkError(let message):
            return "Network error: \(message)"
        case .keychainError(let message):
            return "Keychain error: \(message)"
        case .encryptionError(let message):
            return "Encryption error: \(message)"
        case .apiError(let message):
            return "API error: \(message)"
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}

// MARK: - gRPC Endpoint Pool

/// Pool tier for endpoint classification
enum PoolType: Int, Codable, CaseIterable {
    case hot = 0    // Active endpoints for user requests
    case warm = 1   // Validated candidates ready for promotion
    case cold = 2   // Discovery source, unchecked or failed endpoints

    var displayName: String {
        switch self {
        case .hot: return "Hot"
        case .warm: return "Warm"
        case .cold: return "Cold"
        }
    }
}

/// Origin of endpoint
enum EndpointOrigin: Int, Codable {
    case dynamic = 0        // Discovered via peer discovery
    case userAdded = 1      // Manually added by user
    case preProvisioned = 2 // Bundled with app

    var displayName: String {
        switch self {
        case .dynamic: return "Discovered"
        case .userAdded: return "Manual"
        case .preProvisioned: return "Default"
        }
    }

    /// Whether this endpoint can be deleted by user
    var canDelete: Bool { true }

    /// Maximum cooling time for this origin type
    var maxCoolingMinutes: Int {
        switch self {
        case .preProvisioned: return 5
        default: return 7 * 24 * 60 // 1 week
        }
    }
}

/// A user-saved "host:port" node address, kept purely for quick copy/paste into the
/// trusted-node field in Connection Settings - not itself used for connections.
struct SavedNodeAddress: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var address: String

    init(id: UUID = UUID(), label: String, address: String) {
        self.id = id
        self.label = label
        self.address = address
    }
}

struct GrpcEndpoint: Codable, Identifiable, Equatable {
    var id: String { url }
    let url: String

    // Pool assignment
    var pool: PoolType

    // Health metrics
    var latencyMs: Int?              // Last measured gRPC ping latency
    var errorCount: Int              // Cumulative errors (preserved across transitions)
    var coolingUntil: Date?          // Don't recheck until this time
    var lastDaaScore: UInt64?        // Last observed DAA score

    // Tracking
    var peerSeenDate: Date?          // Last seen in getPeerAddresses response
    var lastSuccessDate: Date?       // Last successful request
    var lastCheckDate: Date?         // Last health check attempt
    var dateAdded: Date              // When endpoint was first added

    // Origin and network
    var origin: EndpointOrigin
    var networkType: NetworkType

    // Legacy compatibility
    var isManual: Bool {
        get { origin == .userAdded }
        set { if newValue { origin = .userAdded } }
    }

    init(url: String, networkType: NetworkType, origin: EndpointOrigin = .dynamic, pool: PoolType = .cold) {
        self.url = url
        self.networkType = networkType
        self.origin = origin
        self.pool = pool
        self.dateAdded = Date()
        self.latencyMs = nil
        self.errorCount = 0
        self.lastSuccessDate = nil
        self.coolingUntil = nil
        self.lastDaaScore = nil
        self.peerSeenDate = nil
        self.lastCheckDate = nil
    }

    // MARK: - Codable with migration support

    enum CodingKeys: String, CodingKey {
        case url, pool, latencyMs, errorCount, coolingUntil, lastDaaScore
        case peerSeenDate, lastSuccessDate, lastCheckDate, dateAdded
        case origin, networkType
        // Legacy keys for migration
        case isManual
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        url = try container.decode(String.self, forKey: .url)
        networkType = try container.decode(NetworkType.self, forKey: .networkType)

        // New fields with defaults for migration
        pool = try container.decodeIfPresent(PoolType.self, forKey: .pool) ?? .cold
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        errorCount = try container.decodeIfPresent(Int.self, forKey: .errorCount) ?? 0
        coolingUntil = try container.decodeIfPresent(Date.self, forKey: .coolingUntil)
        lastDaaScore = try container.decodeIfPresent(UInt64.self, forKey: .lastDaaScore)
        peerSeenDate = try container.decodeIfPresent(Date.self, forKey: .peerSeenDate)
        lastSuccessDate = try container.decodeIfPresent(Date.self, forKey: .lastSuccessDate)
        lastCheckDate = try container.decodeIfPresent(Date.self, forKey: .lastCheckDate)
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()

        // Migrate origin from legacy isManual field
        if let origin = try container.decodeIfPresent(EndpointOrigin.self, forKey: .origin) {
            self.origin = origin
        } else if let isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual), isManual {
            self.origin = .userAdded
        } else {
            self.origin = .dynamic
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(pool, forKey: .pool)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encode(errorCount, forKey: .errorCount)
        try container.encodeIfPresent(coolingUntil, forKey: .coolingUntil)
        try container.encodeIfPresent(lastDaaScore, forKey: .lastDaaScore)
        try container.encodeIfPresent(peerSeenDate, forKey: .peerSeenDate)
        try container.encodeIfPresent(lastSuccessDate, forKey: .lastSuccessDate)
        try container.encodeIfPresent(lastCheckDate, forKey: .lastCheckDate)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(origin, forKey: .origin)
        try container.encode(networkType, forKey: .networkType)
    }

    /// Display-friendly hostname extracted from URL
    var displayName: String {
        guard let urlComponents = URLComponents(string: url),
              let host = urlComponents.host else {
            return url
        }
        return host
    }

    /// Time since endpoint was added, formatted for display
    var addedAgo: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: dateAdded, relativeTo: Date())
    }

    /// Whether endpoint is currently in cooling period
    var isCooling: Bool {
        guard let coolingUntil = coolingUntil else { return false }
        return Date() < coolingUntil
    }

    /// Calculate cooling time based on error count and origin
    mutating func setCoolingTime() {
        let baseMinutes: Double
        let maxMinutes: Double
        let randomRange: Double

        switch origin {
        case .preProvisioned:
            baseMinutes = 1
            maxMinutes = 5
            randomRange = 1
        default:
            baseMinutes = 10
            maxMinutes = Double(7 * 24 * 60) // 1 week
            randomRange = 10
        }

        let coolingMinutes = min(maxMinutes, baseMinutes * pow(2, Double(errorCount)))
        let randomMinutes = Double.random(in: 0...randomRange)
        coolingUntil = Date().addingTimeInterval((coolingMinutes + randomMinutes) * 60)
    }

    /// Set success cooling time (for periodic rechecks)
    mutating func setSuccessCoolingTime() {
        let baseMinutes: Double
        let randomRange: Double

        switch pool {
        case .hot:
            baseMinutes = 10
            randomRange = 10
        case .warm:
            baseMinutes = 30
            randomRange = 30
        case .cold:
            baseMinutes = 60
            randomRange = 60
        }

        coolingUntil = Date().addingTimeInterval((baseMinutes + Double.random(in: 0...randomRange)) * 60)
    }
}

// MARK: - Group Chat Models
//
// Single-admin, epoch-based group messaging - see GroupCipher.swift for the crypto and
// GroupChatService for the orchestration layer. Secret key material (GroupBag) lives in
// Keychain only (never CloudKit-synced); non-secret roster/message metadata lives in
// GroupStore's local-only Core Data store (mirrors BroadcastStore's pattern).

/// A member of a group chat.
struct GroupMember: Codable, Identifiable, Equatable, Hashable {
    var id: String { address }
    let address: String
    /// Hex-encoded 32-byte x-only secp256k1 pubkey, used for gcomm signature verification
    /// and blinded_group_id derivation.
    let xOnlyPubKeyHex: String
    var isAdmin: Bool
    var displayName: String?

    /// SHA256(address) hex - matches the on-chain `sender_id` field, used to attribute
    /// incoming gcomm messages to a roster entry.
    var senderIdHex: String {
        GroupCipher.deriveSenderId(senderAddress: address).hexString
    }
}

/// Local secret+state bag for a group, persisted in Keychain (device-specific, SE-wrapped,
/// never CloudKit-synced) - mirrors the reference implementation's `GroupBag` schema.
struct GroupBag: Codable, Sendable {
    let groupId: String              // hex
    var groupSeed: String?           // hex, admin-only, nil for non-admin members
    var groupRootEpoch: String       // hex, current epoch's root key
    var blindingKey: String          // hex
    var currentEpoch: UInt64
    var deviceId: String             // hex, 16 bytes
    var msgCounter: UInt64           // monotonic per (group_id, epoch, device_id)
    /// Epoch for which this admin has published its self-addressed recovery invite (nil = none
    /// yet). Drives the backfill so pre-existing admin groups become seed-recoverable.
    var selfInviteEpoch: UInt64? = nil
}

/// Non-secret group metadata - the in-memory/view-facing model backed by GroupStore.
struct GroupChat: Identifiable, Equatable, Hashable {
    let id: String                   // groupId, hex
    var name: String
    var adminAddress: String
    var adminXOnlyPubKeyHex: String
    var members: [GroupMember]
    var currentEpoch: UInt64
    var createdAt: Date
    /// True if the local wallet is this group's admin (i.e. this device holds groupSeed).
    var isAdmin: Bool
}

/// A decrypted group chat message (mirrors ChatMessage's shape for reuse in UI/bubble views).
struct GroupMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let groupId: String
    let txId: String
    /// Resolved from senderId against the roster; nil if the sender isn't a known member
    /// (e.g. a stale roster mid-epoch-rotation).
    let senderAddress: String?
    let senderIdHex: String
    let content: String
    let timestamp: Date
    let blockTime: Int64
    let isOutgoing: Bool
    var deliveryStatus: ChatMessage.DeliveryStatus
}
