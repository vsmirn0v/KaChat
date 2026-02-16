import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

// MARK: - Message decryption, hex utilities, support structures

extension ChatService {
    func decryptHandshakePayload(_ payload: String?, privateKey: Data) async -> DecryptedHandshake? {
        guard let payload = payload else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.decryptHandshakePayloadSync(payload, privateKey: privateKey)
        }.value
    }

    /// Synchronous handshake decryption (runs on background thread)
    /// Handles two payload formats:
    /// - Indexer format: just the encrypted hex (no prefix)
    /// - REST API format: full transaction payload hex = hex("ciph_msg:1:handshake:") + encrypted_hex
    nonisolated static func decryptHandshakePayloadSync(_ payload: String, privateKey: Data) -> DecryptedHandshake? {
        var encryptedHex = payload

        // Strip protocol prefix if present (REST API returns full transaction payload)
        // "ciph_msg:1:handshake:" = 21 bytes = 42 hex chars
        let handshakePrefixHex = "636970685f6d73673a313a68616e647368616b653a"
        let lowered = payload.lowercased()

        // Also handle optional OP_RETURN prefix: "6a" + 1 byte length
        if lowered.hasPrefix("6a") {
            let stripped = String(lowered.dropFirst(4))
            if stripped.hasPrefix(handshakePrefixHex) {
                encryptedHex = String(payload.dropFirst(4 + handshakePrefixHex.count))
            }
        } else if lowered.hasPrefix(handshakePrefixHex) {
            encryptedHex = String(payload.dropFirst(handshakePrefixHex.count))
        }

        // Decrypt the encrypted portion
        if let decrypted = try? KasiaCipher.decryptHex(encryptedHex, privateKey: privateKey) {
            if let data = decrypted.data(using: .utf8),
               let json = try? JSONDecoder().decode(DecryptedHandshake.self, from: data) {
                return json  // alias may be nil for deterministic handshakes
            }
            // Legacy: raw decrypted text is not valid JSON — treat as alias-less handshake
            return DecryptedHandshake(alias: nil, type: "handshake")
        }

        // Fallback: try decrypting the raw payload (indexer format without prefix)
        if encryptedHex != payload {
            if let decrypted = try? KasiaCipher.decryptHex(payload, privateKey: privateKey) {
                if let data = decrypted.data(using: .utf8),
                   let json = try? JSONDecoder().decode(DecryptedHandshake.self, from: data) {
                    return json
                }
                return DecryptedHandshake(alias: nil, type: "handshake")
            }
        }

        return nil
    }

    /// Decrypt contextual message on background thread
    func decryptContextualMessage(_ payload: String?, privateKey: Data) async -> String? {
        guard let payload = payload else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.decryptContextualMessageSync(payload, privateKey: privateKey)
        }.value
    }

    /// Synchronous contextual message decryption (runs on background thread)
    /// Expects format: hex(base64(encrypted)) - as returned by indexer
    nonisolated static func decryptContextualMessageSync(_ payload: String, privateKey: Data) -> String? {
        // Contextual message payload is hex(base64(encrypted))
        // First decode hex to get the base64 string
        guard let base64Data = hexStringToData(payload),
              let base64String = String(data: base64Data, encoding: .utf8) else {
            return nil
        }

        // Then decode base64 to get the encrypted bytes
        guard let encryptedData = Data(base64Encoded: base64String) else {
            return nil
        }

        // Now decrypt
        do {
            guard let encryptedMessage = KasiaCipher.EncryptedMessage(fromBytes: encryptedData) else {
                return nil
            }
            let decrypted = try KasiaCipher.decrypt(encryptedMessage, privateKey: privateKey)
            return decrypted
        } catch {
            return nil
        }
    }

    /// Decrypt contextual message from raw TX payload on background thread
    /// Raw TX payload format: "ciph_msg:1:comm:ALIAS:BASE64_ENCRYPTED" (as returned by REST API)
    func decryptContextualMessageFromRawPayload(_ payload: String?, privateKey: Data) async -> String? {
        guard let payload = payload else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.decryptContextualMessageFromRawPayloadSync(payload, privateKey: privateKey)
        }.value
    }

    /// Synchronous decryption from raw TX payload
    nonisolated static func decryptContextualMessageFromRawPayloadSync(_ payload: String, privateKey: Data) -> String? {
        // Raw payload from REST API is hex-encoded
        guard let payloadData = hexStringToData(payload),
              let payloadString = String(data: payloadData, encoding: .utf8) else {
            NSLog("[ChatService] Raw payload: failed to decode hex to string")
            return nil
        }

        // Check if it's a contextual message: "ciph_msg:1:comm:ALIAS:BASE64_ENCRYPTED"
        guard payloadString.hasPrefix("ciph_msg:1:comm:") else {
            // Not a contextual message - could be handshake or other type
            if payloadString.hasPrefix("ciph_msg:") {
                NSLog("[ChatService] Raw payload: different message type: %@", String(payloadString.prefix(30)))
            }
            return nil
        }

        // Split by ":" and get the last part (encrypted base64)
        let parts = payloadString.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        // parts: ["ciph_msg", "1", "comm", "ALIAS", "BASE64_ENCRYPTED"]
        guard parts.count >= 5 else {
            NSLog("[ChatService] Raw payload: unexpected format, parts=%d", parts.count)
            return nil
        }

        let base64String = String(parts[4])
        guard !base64String.isEmpty else {
            NSLog("[ChatService] Raw payload: empty base64 content")
            return nil
        }

        // Decode base64 to get encrypted bytes
        guard let encryptedData = Data(base64Encoded: base64String) else {
            NSLog("[ChatService] Raw payload: failed to decode base64")
            return nil
        }

        // Decrypt
        do {
            guard let encryptedMessage = KasiaCipher.EncryptedMessage(fromBytes: encryptedData) else {
                NSLog("[ChatService] Raw payload: failed to parse encrypted message structure")
                return nil
            }
            let decrypted = try KasiaCipher.decrypt(encryptedMessage, privateKey: privateKey)
            return decrypted
        } catch {
            NSLog("[ChatService] Raw payload: decryption failed: %@", error.localizedDescription)
            return nil
        }
    }

    nonisolated static func extractContextualAlias(fromRawPayloadString payloadString: String) -> String? {
        guard payloadString.hasPrefix("ciph_msg:1:comm:") else {
            return nil
        }

        let parts = payloadString.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 5 else {
            NSLog("[ChatService] Raw payload: unexpected format, parts=%d", parts.count)
            return nil
        }

        let alias = String(parts[3])
        if alias.isEmpty {
            NSLog("[ChatService] Raw payload: empty alias")
            return nil
        }

        return alias
    }

    func decryptPaymentPayloadFromSealedHex(_ payload: String?, privateKey: Data) async -> PaymentPayload? {
        guard let payload = payload else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.decryptPaymentPayloadFromSealedHexSync(payload, privateKey: privateKey)
        }.value
    }

    nonisolated static func decryptPaymentPayloadFromSealedHexSync(_ payload: String, privateKey: Data) -> PaymentPayload? {
        do {
            let decrypted = try KasiaCipher.decryptHex(payload, privateKey: privateKey)
            if let data = decrypted.data(using: .utf8),
               let json = try? JSONDecoder().decode(PaymentPayload.self, from: data) {
                return json
            }
        } catch {
            return nil
        }
        return nil
    }

    func decryptPaymentPayloadFromRawPayload(_ payload: String?, privateKey: Data) async -> PaymentPayload? {
        guard let payload = payload else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Self.decryptPaymentPayloadFromRawPayloadSync(payload, privateKey: privateKey)
        }.value
    }

    nonisolated static func decryptPaymentPayloadFromRawPayloadSync(_ payload: String, privateKey: Data) -> PaymentPayload? {
        guard let payloadData = hexStringToData(payload) else {
            NSLog("[ChatService] Raw payload: failed to decode hex for payment")
            return nil
        }

        let prefixV1 = Data("ciph_msg:1:pay:".utf8)
        let prefixLegacy = Data("ciph_msg:pay:".utf8)
        let encryptedBytes: Data

        if payloadData.starts(with: prefixV1) {
            encryptedBytes = Data(payloadData.dropFirst(prefixV1.count))
        } else if payloadData.starts(with: prefixLegacy) {
            encryptedBytes = Data(payloadData.dropFirst(prefixLegacy.count))
        } else {
            return nil
        }

        guard let encryptedMessage = KasiaCipher.EncryptedMessage(fromBytes: encryptedBytes) else {
            return nil
        }

        do {
            let decrypted = try KasiaCipher.decrypt(encryptedMessage, privateKey: privateKey)
            if let data = decrypted.data(using: .utf8),
               let json = try? JSONDecoder().decode(PaymentPayload.self, from: data) {
                return json
            }
        } catch {
            return nil
        }

        return nil
    }

    nonisolated static func isPaymentRawPayload(_ payload: String) -> Bool {
        guard let payloadData = hexStringToData(payload) else { return false }
        let prefixV1 = Data("ciph_msg:1:pay:".utf8)
        let prefixLegacy = Data("ciph_msg:pay:".utf8)
        return payloadData.starts(with: prefixV1) || payloadData.starts(with: prefixLegacy)
    }

    /// Decrypt self-stash on background thread
    func decryptSelfStash(_ stashedData: String, privateKey: Data) async -> SavedHandshakeData? {
        return await Task.detached(priority: .userInitiated) {
            Self.decryptSelfStashSync(stashedData, privateKey: privateKey)
        }.value
    }

    /// Synchronous self-stash decryption (runs on background thread)
    nonisolated static func decryptSelfStashSync(_ stashedData: String, privateKey: Data) -> SavedHandshakeData? {
        // Self-stash data is hex-encoded encrypted JSON
        do {
            let decrypted = try KasiaCipher.decryptHex(stashedData, privateKey: privateKey)

            // Parse JSON to extract saved handshake data
            if let data = decrypted.data(using: .utf8) {
                // Try to parse as SavedHandshakeData directly
                if let savedData = try? JSONDecoder().decode(SavedHandshakeData.self, from: data) {
                    return savedData
                }

                // Try to parse as a flexible JSON structure with Kasia's field names
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Extract alias (our alias)
                    let ourAlias = json["alias"] as? String ?? ""

                    // Extract contact address (could be partnerAddress or recipientAddress)
                    let contactAddress = json["partnerAddress"] as? String
                        ?? json["recipientAddress"] as? String
                        ?? json["partner_address"] as? String
                        ?? json["recipient_address"] as? String
                        ?? ""

                    // Extract their alias
                    let theirAlias = json["theirAlias"] as? String
                        ?? json["their_alias"] as? String

                    if !ourAlias.isEmpty && !contactAddress.isEmpty {
                        return SavedHandshakeData(
                            type: json["type"] as? String,
                            alias: ourAlias,
                            timestamp: json["timestamp"] as? UInt64,
                            version: json["version"] as? Int,
                            theirAlias: theirAlias,
                            partnerAddress: contactAddress,
                            recipientAddress: nil,
                            isResponse: json["isResponse"] as? Bool
                        )
                    }
                }
            }

            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - Supporting Types

    struct CachedConversation: Codable {
        let id: UUID
        let contactAddress: String
        let messages: [ChatMessage]
        let unreadCount: Int
    }

    struct ChatHistoryArchive: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let walletAddress: String?
        let conversations: [ChatHistoryArchiveConversation]
    }

    struct ChatHistoryArchiveConversation: Codable {
        let conversationId: UUID?
        let contactAddress: String
        let contactAlias: String?
        let unreadCount: Int
        let messages: [ChatMessage]
    }

/// Result from resolving transaction info from REST API
struct TransactionResolveInfo {
    let sender: String
    let blockTimeMs: UInt64
    let payload: String?
}

struct KaspaTransactionResponse: Codable {
    let outputs: [KaspaTransactionOutput]
}

struct KaspaTransactionOutput: Codable {
    let scriptPublicKeyAddress: String?

    enum CodingKeys: String, CodingKey {
        case scriptPublicKeyAddress = "script_public_key_address"
    }
}

struct DecryptedHandshake: Codable {
    let alias: String?
    let type: String?
    let timestamp: UInt64?
    let version: Int?
    let conversationId: String?
    let recipientAddress: String?
    let sendToRecipient: Bool?
    let isResponse: Bool?

    enum CodingKeys: String, CodingKey {
        case alias
        case type
        case timestamp
        case version
        case conversationId
        case recipientAddress
        case sendToRecipient
        case isResponse
    }

    init(alias: String?, type: String? = nil, timestamp: UInt64? = nil, version: Int? = nil, conversationId: String? = nil, recipientAddress: String? = nil, sendToRecipient: Bool? = nil, isResponse: Bool? = nil) {
        self.alias = alias
        self.type = type
        self.timestamp = timestamp
        self.version = version
        self.conversationId = conversationId
        self.recipientAddress = recipientAddress
        self.sendToRecipient = sendToRecipient
        self.isResponse = isResponse
    }

    /// Dynamic coding key for dual camelCase/snake_case interop
    struct DynKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dyn = try decoder.container(keyedBy: DynKey.self)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.timestamp = try container.decodeIfPresent(UInt64.self, forKey: .timestamp)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version)
        // Dual-key: try camelCase then snake_case
        self.conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
            ?? dyn.decodeIfPresent(String.self, forKey: DynKey(stringValue: "conversation_id"))
        self.recipientAddress = try container.decodeIfPresent(String.self, forKey: .recipientAddress)
            ?? dyn.decodeIfPresent(String.self, forKey: DynKey(stringValue: "recipient_address"))
        self.sendToRecipient = try container.decodeIfPresent(Bool.self, forKey: .sendToRecipient)
            ?? dyn.decodeIfPresent(Bool.self, forKey: DynKey(stringValue: "send_to_recipient"))
        self.isResponse = try container.decodeIfPresent(Bool.self, forKey: .isResponse)
            ?? dyn.decodeIfPresent(Bool.self, forKey: DynKey(stringValue: "is_response"))
    }
}

struct PendingSelfStash: Codable, Identifiable, Equatable {
    let id: UUID
    let partnerAddress: String
    let ourAlias: String
    let theirAlias: String?
    let isResponse: Bool

    init(partnerAddress: String, ourAlias: String, theirAlias: String?, isResponse: Bool) {
        self.id = UUID()
        self.partnerAddress = partnerAddress
        self.ourAlias = ourAlias
        self.theirAlias = theirAlias
        self.isResponse = isResponse
    }
}

// MARK: - Kaspa API Transaction Models (for fetching payments directly)

struct KaspaFullTransactionResponse: Codable {
    let transactionId: String
    let inputs: [KaspaFullTxInput]?
    let outputs: [KaspaFullTxOutput]
    let subnetworkId: String?
    let payload: String?
    let blockTime: UInt64?
    let blockHash: [String]?
    let isAccepted: Bool?
    let acceptingBlockHash: String?
    let acceptingBlockBlueScore: UInt64?
    let acceptingBlockTime: UInt64?
    let mass: String?  // API returns as String
    let hash: String?
    let version: UInt16?
    let lockTime: FlexibleUInt64?
    let gas: FlexibleUInt64?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case inputs
        case outputs
        case subnetworkId = "subnetwork_id"
        case payload
        case blockTime = "block_time"
        case blockHash = "block_hash"
        case isAccepted = "is_accepted"
        case acceptingBlockHash = "accepting_block_hash"
        case acceptingBlockBlueScore = "accepting_block_blue_score"
        case acceptingBlockTime = "accepting_block_time"
        case mass
        case hash
        case version
        case lockTime = "lock_time"
        case gas
    }
}

struct KaspaFullTxInput: Codable {
    // Flat structure - API returns fields directly, not nested
    let transactionId: String?
    let index: Int?
    let previousOutpointHash: String?
    let previousOutpointIndex: String?  // String in API
    let previousOutpointAddress: String? // Resolved address when using resolve_previous_outpoints
    let previousOutpointAmount: UInt64?
    let signatureScript: String?
    let sequence: FlexibleUInt64?
    let sigOpCount: FlexibleUInt8?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case index
        case previousOutpointHash = "previous_outpoint_hash"
        case previousOutpointIndex = "previous_outpoint_index"
        case previousOutpointAddress = "previous_outpoint_address"
        case previousOutpointAmount = "previous_outpoint_amount"
        case signatureScript = "signature_script"
        case sequence
        case sigOpCount = "sig_op_count"
    }
}

/// Flexible decoder that handles both numeric and string representations of UInt64
struct FlexibleUInt64: Codable {
    let value: UInt64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(UInt64.self) {
            value = intVal
        } else if let strVal = try? container.decode(String.self), let parsed = UInt64(strVal) {
            value = parsed
        } else {
            value = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Flexible decoder that handles both numeric and string representations of UInt8
struct FlexibleUInt8: Codable {
    let value: UInt8

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(UInt8.self) {
            value = intVal
        } else if let strVal = try? container.decode(String.self), let parsed = UInt8(strVal) {
            value = parsed
        } else {
            value = 1
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct KaspaFullTxOutput: Codable {
    let transactionId: String?
    let index: Int?
    let amount: UInt64
    let scriptPublicKey: String?  // Simple hex string, not an object
    let scriptPublicKeyAddress: String?
    let scriptPublicKeyType: String?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case index
        case amount
        case scriptPublicKey = "script_public_key"
        case scriptPublicKeyAddress = "script_public_key_address"
        case scriptPublicKeyType = "script_public_key_type"
    }
}

actor InFlightResolveTracker {
    var ids = Set<String>()

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    func insert(_ id: String) {
        ids.insert(id)
    }

    func remove(_ id: String) {
        ids.remove(id)
    }
}
