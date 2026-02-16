import Foundation

// MARK: - Dynamic Coding Key (for dual camelCase/snake_case decode)

enum SharedFormatting {
    static let chatTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
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

// MARK: - Noisy Contact Warning

/// Warning shown when a contact produces excessive transaction traffic
struct NoisyContactWarning: Identifiable, Equatable {
    let id = UUID()
    let contactAddress: String
    let contactAlias: String
    let txCount: Int
}

// MARK: - Wallet Models

struct Wallet: Codable, Equatable {
    let publicAddress: String
    let publicKey: String
    var alias: String
    let createdAt: Date
    var balanceSompi: UInt64?

    var shortAddress: String {
        guard publicAddress.count > 16 else { return publicAddress }
        let prefix = String(publicAddress.prefix(10))
        let suffix = String(publicAddress.suffix(6))
        return "\(prefix)...\(suffix)"
    }
}

struct SeedPhrase: Codable {
    let words: [String]

    var phrase: String {
        words.joined(separator: " ")
    }

    init(words: [String]) {
        self.words = words
    }

    init?(phrase: String) {
        // Split by any whitespace including newlines, tabs, etc.
        let words = phrase.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard words.count == 12 || words.count == 24 else {
            return nil
        }
        self.words = words
    }
}

// MARK: - Contact Models

enum ContactNotificationMode: String, Codable, CaseIterable {
    case off
    case noSound
    case sound

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .noSound: return "No Sound"
        case .sound: return "Sound"
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
    var realtimeUpdatesDisabled: Bool
    var isArchived: Bool
    // Local-only enrichment from iOS/macOS system contacts.
    var systemContactId: String?
    var systemDisplayNameSnapshot: String?
    var systemContactLinkSource: SystemContactLinkSource?
    var systemMatchConfidence: Double?
    var systemLastSyncedAt: Date?

    init(
        id: UUID = UUID(),
        address: String,
        alias: String = "",
        addedAt: Date = Date(),
        lastMessageAt: Date? = nil,
        isAutoAdded: Bool = false,
        notificationModeOverride: ContactNotificationMode? = nil,
        realtimeUpdatesDisabled: Bool = false,
        isArchived: Bool = false,
        systemContactId: String? = nil,
        systemDisplayNameSnapshot: String? = nil,
        systemContactLinkSource: SystemContactLinkSource? = nil,
        systemMatchConfidence: Double? = nil,
        systemLastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.address = address
        self.alias = alias.isEmpty ? Contact.generateDefaultAlias(from: address) : alias
        self.addedAt = addedAt
        self.lastMessageAt = lastMessageAt
        self.isAutoAdded = isAutoAdded
        self.notificationModeOverride = notificationModeOverride
        self.realtimeUpdatesDisabled = realtimeUpdatesDisabled
        self.isArchived = isArchived
        self.systemContactId = systemContactId
        self.systemDisplayNameSnapshot = systemDisplayNameSnapshot
        self.systemContactLinkSource = systemContactLinkSource
        self.systemMatchConfidence = systemMatchConfidence
        self.systemLastSyncedAt = systemLastSyncedAt
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
        case realtimeUpdatesDisabled
        case isArchived
        case systemContactId
        case systemDisplayNameSnapshot
        case systemContactLinkSource
        case systemMatchConfidence
        case systemLastSyncedAt
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
        realtimeUpdatesDisabled = try container.decodeIfPresent(Bool.self, forKey: .realtimeUpdatesDisabled) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        systemContactId = try container.decodeIfPresent(String.self, forKey: .systemContactId)
        systemDisplayNameSnapshot = try container.decodeIfPresent(String.self, forKey: .systemDisplayNameSnapshot)
        systemContactLinkSource = try container.decodeIfPresent(SystemContactLinkSource.self, forKey: .systemContactLinkSource)
        systemMatchConfidence = try container.decodeIfPresent(Double.self, forKey: .systemMatchConfidence)
        systemLastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .systemLastSyncedAt)
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
        try container.encode(realtimeUpdatesDisabled, forKey: .realtimeUpdatesDisabled)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(systemContactId, forKey: .systemContactId)
        try container.encodeIfPresent(systemDisplayNameSnapshot, forKey: .systemDisplayNameSnapshot)
        try container.encodeIfPresent(systemContactLinkSource, forKey: .systemContactLinkSource)
        try container.encodeIfPresent(systemMatchConfidence, forKey: .systemMatchConfidence)
        try container.encodeIfPresent(systemLastSyncedAt, forKey: .systemLastSyncedAt)
    }

    static func generateDefaultAlias(from address: String) -> String {
        guard address.count > 8 else { return address }
        return String(address.suffix(8))
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
        messages.max { $0.timestamp < $1.timestamp }
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
            return "Keep forever"
        case .days30:
            return "30 days"
        case .days90:
            return "90 days"
        case .year1:
            return "1 year"
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
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.timestamp = try container.decodeIfPresent(UInt64.self, forKey: .timestamp) ?? 0
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        self.recipientAddress = try container.decodeIfPresent(String.self, forKey: .recipientAddress)
        self.sendToRecipient = try container.decodeIfPresent(Bool.self, forKey: .sendToRecipient)
        self.isResponse = try container.decodeIfPresent(Bool.self, forKey: .isResponse)
        // Dual-key decode: try camelCase then snake_case for cross-platform interop
        if let cid = try container.decodeIfPresent(String.self, forKey: .conversationId) {
            self.conversationId = cid
        } else {
            // Try snake_case key via dynamic key
            let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
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

struct ContextualMessagePayload: Codable {
    let alias: String
    let content: String
}

struct PaymentPayload: Codable {
    let type: String
    let message: String
    let amount: UInt64
    let timestamp: UInt64
    let version: Int
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

enum NotificationMode: String, Codable, CaseIterable {
    case disabled
    case remotePush

    static var allCases: [NotificationMode] {
        [.disabled, .remotePush]
    }

    var displayName: String {
        switch self {
        case .disabled: return "Disabled"
        case .remotePush: return "Remote push"
        }
    }
}

// MARK: - Settings Models

struct AppSettings: Codable {
    var storeMessagesInICloud: Bool
    var messageRetention: MessageRetention
    var networkType: NetworkType
    var autoAddContacts: Bool
    var syncSystemContacts: Bool
    var autoCreateSystemContacts: Bool
    var notificationMode: NotificationMode
    var notificationPermissionRequested: Bool
    var incomingNotificationSoundEnabled: Bool
    var incomingNotificationVibrationEnabled: Bool
    var messagePollInterval: TimeInterval
    var liveUpdatesEnabled: Bool
    var feeEstimationEnabled: Bool
    var hideAutoCreatedPaymentChats: Bool

    // Connection settings
    var indexerURL: String
    var pushIndexerURL: String
    var knsBaseURL: String
    var kaspaRestAPIURL: String

    // gRPC endpoint pool settings
    var grpcEndpointPool: [GrpcEndpoint]
    var discoverNewPeers: Bool           // Enable peer discovery from hot pool nodes
    var grpcPoolNetworkType: NetworkType?
    var lastPoolPersistDate: Date?       // Track when pool was last saved

    // Default URLs per network
    static let defaultIndexerURL = "https://indexer.kasia.fyi"
    static let defaultPushIndexerURL = "https://indexer.kasia.wtf"
    static let defaultKNSMainnetURL = "https://api.knsdomains.org/mainnet/api/v1"
    static let defaultKNSTestnetURL = "https://api.knsdomains.org/tn10/api/v1"
    static let defaultKaspaMainnetURL = "https://api.kaspa.org"
    static let defaultKaspaTestnetURL = "https://api-tn11.kaspa.org"

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
            autoCreateSystemContacts: true,
            notificationMode: .remotePush,
            notificationPermissionRequested: false,
            incomingNotificationSoundEnabled: true,
            incomingNotificationVibrationEnabled: true,
            messagePollInterval: 10.0,
            liveUpdatesEnabled: false,
            feeEstimationEnabled: false,
            hideAutoCreatedPaymentChats: false,
            indexerURL: defaultIndexerURL,
            pushIndexerURL: defaultPushIndexerURL,
            knsBaseURL: defaultKNSMainnetURL,
            kaspaRestAPIURL: defaultKaspaMainnetURL,
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
        case autoCreateSystemContacts
        case notificationMode
        case notificationPermissionRequested
        case incomingNotificationSoundEnabled
        case incomingNotificationVibrationEnabled
        case messagePollInterval
        case liveUpdatesEnabled
        case feeEstimationEnabled
        case hideAutoCreatedPaymentChats
        case indexerURL
        case pushIndexerURL
        case knsBaseURL
        case kaspaRestAPIURL
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
        autoCreateSystemContacts: Bool,
        notificationMode: NotificationMode,
        notificationPermissionRequested: Bool = false,
        incomingNotificationSoundEnabled: Bool = true,
        incomingNotificationVibrationEnabled: Bool = true,
        messagePollInterval: TimeInterval,
        liveUpdatesEnabled: Bool,
        feeEstimationEnabled: Bool = false,
        hideAutoCreatedPaymentChats: Bool = false,
        indexerURL: String,
        pushIndexerURL: String,
        knsBaseURL: String,
        kaspaRestAPIURL: String,
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
        self.autoCreateSystemContacts = autoCreateSystemContacts
        self.notificationMode = notificationMode
        self.notificationPermissionRequested = notificationPermissionRequested
        self.incomingNotificationSoundEnabled = incomingNotificationSoundEnabled
        self.incomingNotificationVibrationEnabled = incomingNotificationVibrationEnabled
        self.messagePollInterval = messagePollInterval
        self.liveUpdatesEnabled = liveUpdatesEnabled
        self.feeEstimationEnabled = feeEstimationEnabled
        self.hideAutoCreatedPaymentChats = hideAutoCreatedPaymentChats
        self.indexerURL = indexerURL
        self.pushIndexerURL = pushIndexerURL
        self.knsBaseURL = knsBaseURL
        self.kaspaRestAPIURL = kaspaRestAPIURL
        self.grpcEndpointPool = grpcEndpointPool
        self.discoverNewPeers = discoverNewPeers
        self.grpcPoolNetworkType = grpcPoolNetworkType
        self.lastPoolPersistDate = lastPoolPersistDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeMessagesInICloud = try container.decodeIfPresent(Bool.self, forKey: .storeMessagesInICloud) ?? false
        messageRetention = try container.decodeIfPresent(MessageRetention.self, forKey: .messageRetention) ?? .forever
        networkType = try container.decodeIfPresent(NetworkType.self, forKey: .networkType) ?? .mainnet
        // Ignore persisted value and keep this feature always enabled.
        autoAddContacts = true
        syncSystemContacts = try container.decodeIfPresent(Bool.self, forKey: .syncSystemContacts) ?? true
        autoCreateSystemContacts = try container.decodeIfPresent(Bool.self, forKey: .autoCreateSystemContacts) ?? true
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
        messagePollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .messagePollInterval) ?? 10.0
        liveUpdatesEnabled = try container.decodeIfPresent(Bool.self, forKey: .liveUpdatesEnabled) ?? false
        feeEstimationEnabled = try container.decodeIfPresent(Bool.self, forKey: .feeEstimationEnabled) ?? false
        hideAutoCreatedPaymentChats = try container.decodeIfPresent(Bool.self, forKey: .hideAutoCreatedPaymentChats) ?? false

        // Handle migration from old settings
        if let customIndexer = try container.decodeIfPresent(String.self, forKey: .customIndexerURL), !customIndexer.isEmpty {
            indexerURL = customIndexer
        } else {
            indexerURL = try container.decodeIfPresent(String.self, forKey: .indexerURL) ?? AppSettings.defaultIndexerURL
        }

        if let customPushIndexer = try container.decodeIfPresent(String.self, forKey: .pushIndexerURL),
           !customPushIndexer.isEmpty {
            pushIndexerURL = customPushIndexer
        } else {
            pushIndexerURL = AppSettings.defaultPushIndexerURL
        }

        knsBaseURL = try container.decodeIfPresent(String.self, forKey: .knsBaseURL) ?? AppSettings.defaultKNSURL(for: networkType)
        kaspaRestAPIURL = try container.decodeIfPresent(String.self, forKey: .kaspaRestAPIURL) ?? AppSettings.defaultKaspaRestURL(for: networkType)

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
        try container.encode(autoCreateSystemContacts, forKey: .autoCreateSystemContacts)
        try container.encode(notificationMode, forKey: .notificationMode)
        try container.encode(notificationPermissionRequested, forKey: .notificationPermissionRequested)
        try container.encode(incomingNotificationSoundEnabled, forKey: .incomingNotificationSoundEnabled)
        try container.encode(incomingNotificationVibrationEnabled, forKey: .incomingNotificationVibrationEnabled)
        try container.encode(messagePollInterval, forKey: .messagePollInterval)
        try container.encode(liveUpdatesEnabled, forKey: .liveUpdatesEnabled)
        try container.encode(feeEstimationEnabled, forKey: .feeEstimationEnabled)
        try container.encode(hideAutoCreatedPaymentChats, forKey: .hideAutoCreatedPaymentChats)
        try container.encode(indexerURL, forKey: .indexerURL)
        try container.encode(pushIndexerURL, forKey: .pushIndexerURL)
        try container.encode(knsBaseURL, forKey: .knsBaseURL)
        try container.encode(kaspaRestAPIURL, forKey: .kaspaRestAPIURL)
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

// MARK: - Discovery Models

struct DiscoveredEndpoint: Codable, Equatable {
    let indexerURL: String
    let nodeURL: String?
    let networkType: NetworkType
    let isHealthy: Bool
    let latencyMs: Int?
    let discoveredAt: Date
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
