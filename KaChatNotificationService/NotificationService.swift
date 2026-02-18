//
//  NotificationService.swift
//  KaChatNotificationService
//
//  Notification Service Extension for processing KaChat push notifications.
//  Shows contact names and stores messages for main app to decrypt.
//

import CryptoKit
import Foundation
import OSLog
import P256K
import Security
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    private let logger = Logger(subsystem: "com.kachat.app", category: "NotificationService")

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    // App Group identifier for shared data
    private let appGroupIdentifier = "group.com.kachat.app"
    private let keychainServiceName = "com.kachat.app"
    private let keychainAccessGroup: String? = {
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
           !prefix.isEmpty {
            return prefix + "com.kachat.app"
        }
        return nil
    }()
    private let keychainPrivateKeyAccount = "kachat_private_key"
    private let secureEnclaveTag = "com.kachat.app.secure-enclave-key"
    private let secureEnclaveHeader = Data([0x4B, 0x53, 0x45, 0x31]) // "KSE1"
    private let unreadCountKey = "shared_unread_count"
    private let incomingNotificationSoundEnabledKey = "incoming_notification_sound_enabled"

    private enum EffectiveNotificationMode: String {
        case off
        case noSound
        case sound
    }

    private struct SharedContact: Codable {
        let address: String
        let alias: String
        let notificationModeOverride: String?
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Extract push data from userInfo
        let userInfo = request.content.userInfo

        guard let txId = userInfo["tx_id"] as? String,
              let senderAddress = userInfo["sender"] as? String,
              let messageType = userInfo["type"] as? String else {
            // Not a KaChat message, pass through
            contentHandler(content)
            return
        }

        NSLog("[NotificationService] Processing push: type=%@, sender=%@", messageType, senderAddress)

        // Get sender display name from shared contacts
        if let walletAddress = getWalletAddress(), walletAddress == senderAddress {
            content.title = ""
            content.body = ""
            content.sound = nil
            content.badge = nil
            content.interruptionLevel = .passive
            contentHandler(content)
            return
        }

        let sharedContact = getSharedContact(address: senderAddress)
        let senderName = sharedContact?.alias ?? formatAddress(senderAddress)
        content.title = senderName

        // Set thread identifier for grouping
        content.threadIdentifier = senderAddress

        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        let defaultSoundEnabled = (defaults?.object(forKey: incomingNotificationSoundEnabledKey) as? Bool) ?? true
        let effectiveMode = effectiveNotificationMode(for: sharedContact, defaultSoundEnabled: defaultSoundEnabled)
        if effectiveMode == .off {
            content.title = ""
            content.body = ""
            content.sound = nil
            content.badge = nil
            content.interruptionLevel = .passive
            contentHandler(content)
            return
        }
        content.sound = (effectiveMode == .sound) ? .default : nil

        let payloadHex = userInfo["payload"] as? String
        if let payloadHex {
            let prefix = payloadHex.prefix(200)
            logger.info("payload len=\(payloadHex.count, privacy: .public) prefix=\(prefix, privacy: .public)")
            storeLastPushDebug(
                payload: payloadHex,
                messageType: messageType,
                sender: senderAddress,
                txId: txId
            )
        } else {
            logger.info("payload=nil")
            storeLastPushDebug(
                payload: nil,
                messageType: messageType,
                sender: senderAddress,
                txId: txId
            )
        }

        let shouldIncrementUnread = defaults.map { !hasStoredTxId(txId: txId, defaults: $0) } ?? false

        // Set body based on message type
        switch messageType {
        case "contextual":
            if let payloadHex,
               let decrypted = decryptContextualMessage(payloadHex: payloadHex) {
                content.body = decrypted
                storeDecryptedMessage(
                    txId: txId,
                    sender: senderAddress,
                    content: decrypted,
                    timestamp: extractTimestamp(userInfo: userInfo)
                )
            } else {
                content.body = NSLocalizedString("New message", comment: "Fallback body for contextual push notification")
            }
        case "payment":
            handlePayment(content: content, userInfo: userInfo)
        case "handshake":
            content.body = NSLocalizedString("Started a conversation", comment: "Push body for handshake notification")
        case "audio":
            content.body = NSLocalizedString("Voice message", comment: "Push body for audio notification")
        default:
            content.body = NSLocalizedString("New message", comment: "Generic push body")
        }

        if content.body == NSLocalizedString("New message", comment: "Generic push body") || messageType != "contextual" {
            addPendingMessage(txId: txId, sender: senderAddress, type: messageType)
        }

        if shouldIncrementUnread, let badge = incrementUnreadCountIfNeeded() {
            content.badge = NSNumber(value: badge)
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Message Handlers

    private func handlePayment(content: UNMutableNotificationContent, userInfo: [AnyHashable: Any]) {
        // Try to extract amount from userInfo
        if let amountSompi = userInfo["amount"] as? UInt64 {
            let kas = Double(amountSompi) / 100_000_000.0
            let format = NSLocalizedString("Received %.8f KAS", comment: "Push body for incoming payment with amount")
            content.body = String(format: format, kas)
        } else if let amountStr = userInfo["amount"] as? String,
                  let amountSompi = UInt64(amountStr) {
            let kas = Double(amountSompi) / 100_000_000.0
            let format = NSLocalizedString("Received %.8f KAS", comment: "Push body for incoming payment with amount")
            content.body = String(format: format, kas)
        } else if let amountNum = userInfo["amount"] as? NSNumber {
            let kas = amountNum.doubleValue / 100_000_000.0
            let format = NSLocalizedString("Received %.8f KAS", comment: "Push body for incoming payment with amount")
            content.body = String(format: format, kas)
        } else {
            content.body = NSLocalizedString("Received payment", comment: "Push body for incoming payment")
        }
    }

    // MARK: - Shared Data Access

    private func getSharedContact(address: String) -> SharedContact? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: "shared_contacts") else {
            return nil
        }

        guard let contacts = try? JSONDecoder().decode([SharedContact].self, from: data) else {
            return nil
        }

        return contacts.first { $0.address == address }
    }

    private func effectiveNotificationMode(
        for contact: SharedContact?,
        defaultSoundEnabled: Bool
    ) -> EffectiveNotificationMode {
        if let raw = contact?.notificationModeOverride,
           let mode = EffectiveNotificationMode(rawValue: raw) {
            return mode
        }
        return defaultSoundEnabled ? .sound : .noSound
    }

    private func getWalletAddress() -> String? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            return nil
        }
        return defaults.string(forKey: "wallet_address")
    }

    private func addPendingMessage(txId: String, sender: String, type: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }

        // Load existing pending messages
        var pending: [[String: Any]] = []
        if let data = defaults.data(forKey: "pending_messages"),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pending = existing
        }

        // Check for duplicates
        guard !pending.contains(where: { ($0["txId"] as? String) == txId }) else { return }

        // Add new message
        pending.append([
            "txId": txId,
            "sender": sender,
            "type": type,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ])

        // Keep only last 100 pending messages
        if pending.count > 100 {
            pending = Array(pending.suffix(100))
        }

        // Save back
        if let data = try? JSONSerialization.data(withJSONObject: pending) {
            defaults.set(data, forKey: "pending_messages")
        }
    }

    private func incrementUnreadCountIfNeeded() -> Int? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return nil }
        let current = defaults.integer(forKey: unreadCountKey)
        let updated = max(0, current + 1)
        defaults.set(updated, forKey: unreadCountKey)
        return updated
    }

    private func hasStoredTxId(txId: String, defaults: UserDefaults) -> Bool {
        if let data = defaults.data(forKey: "stored_messages"),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           existing.contains(where: { ($0["txId"] as? String) == txId }) {
            return true
        }
        if let data = defaults.data(forKey: "pending_messages"),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           existing.contains(where: { ($0["txId"] as? String) == txId }) {
            return true
        }
        return false
    }

    private func formatAddress(_ address: String) -> String {
        guard address.count > 8 else { return address }
        return String(address.suffix(8))
    }

    private func storeDecryptedMessage(txId: String, sender: String, content: String, timestamp: Int64) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }

        var messages: [[String: Any]] = []
        if let data = defaults.data(forKey: "stored_messages"),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            messages = existing
        }

        guard !messages.contains(where: { ($0["txId"] as? String) == txId }) else { return }

        messages.append([
            "txId": txId,
            "sender": sender,
            "content": content,
            "timestamp": timestamp
        ])

        if messages.count > 50 {
            messages = Array(messages.suffix(50))
        }

        if let data = try? JSONSerialization.data(withJSONObject: messages) {
            defaults.set(data, forKey: "stored_messages")
        }
    }

    private func extractTimestamp(userInfo: [AnyHashable: Any]) -> Int64 {
        if let timestamp = userInfo["timestamp"] as? Int64 {
            return timestamp
        }
        if let timestamp = userInfo["timestamp"] as? NSNumber {
            return timestamp.int64Value
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func decryptContextualMessage(payloadHex: String) -> String? {
        guard let privateKey = loadPrivateKey() else {
            NSLog("[NotificationService] decrypt: private key missing")
            storeLastPushDecryptStatus("missing_private_key")
            return nil
        }
        NSLog("[NotificationService] decrypt: private key len=%d", privateKey.count)
        let (message, error) = NotificationCipher.decryptContextualPayloadDebug(
            payloadHex,
            privateKey: privateKey
        )
        if let error {
            NSLog("[NotificationService] decrypt: failed status=%@", error)
            storeLastPushDecryptStatus(error)
        } else {
            NSLog("[NotificationService] decrypt: ok")
            storeLastPushDecryptStatus("ok")
        }
        return message
    }

    private func loadPrivateKey() -> Data? {
        // Try device-specific storage first (new format)
        if let deviceId = deviceIdentifier(),
           let data = loadPrivateKeyWithAccount(account: "\(keychainPrivateKeyAccount).\(deviceId)") {
            return data
        }

        // Fallback to legacy storage (old format without device ID)
        return loadPrivateKeyWithAccount(account: keychainPrivateKeyAccount)
    }

    private func loadPrivateKeyWithAccount(account: String) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let accessGroup = keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecSuccess {
                NSLog("[NotificationService] keychain read failed for account=%@: %d", account, status)
            }
            return nil
        }

        if data.starts(with: secureEnclaveHeader) {
            if let unwrapped = unwrapPrivateKey(data) {
                return unwrapped
            }
            NSLog("[NotificationService] failed to unwrap secure enclave private key")
            return nil
        }

        return data
    }

    /// Returns a stable device identifier derived from the Secure Enclave public key hash
    private func deviceIdentifier() -> String? {
        guard let seKey = secureEnclavePrivateKey() else {
            return nil
        }

        guard let publicKey = SecKeyCopyPublicKey(seKey) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        // Hash the public key to create a stable, short identifier (same as main app)
        let hash = SHA256.hash(data: publicKeyData)
        let deviceId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return deviceId
    }

    private enum SecureEnclaveAlgorithm: UInt8 {
        case eciesCofactorSha256AesGcm = 1
        case eciesStandardSha256AesGcm = 2

        var secKeyAlgorithm: SecKeyAlgorithm {
            switch self {
            case .eciesCofactorSha256AesGcm:
                return .eciesEncryptionCofactorX963SHA256AESGCM
            case .eciesStandardSha256AesGcm:
                return .eciesEncryptionStandardX963SHA256AESGCM
            }
        }
    }

    private func unwrapPrivateKey(_ wrapped: Data) -> Data? {
        guard wrapped.count > secureEnclaveHeader.count + 1 else {
            return nil
        }

        let algorithmId = wrapped[secureEnclaveHeader.count]
        let encrypted = wrapped.dropFirst(secureEnclaveHeader.count + 1)

        guard let algorithm = SecureEnclaveAlgorithm(rawValue: algorithmId)?.secKeyAlgorithm else {
            return nil
        }

        guard let securePrivateKey = secureEnclavePrivateKey() else {
            return nil
        }

        guard SecKeyIsAlgorithmSupported(securePrivateKey, .decrypt, algorithm) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(
            securePrivateKey,
            algorithm,
            encrypted as CFData,
            &error
        ) as Data? else {
            return nil
        }

        return decrypted
    }

    private func secureEnclavePrivateKey() -> SecKey? {
        let tagData = secureEnclaveTag.data(using: .utf8) ?? Data()
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        if let accessGroup = keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let keyRef = result else {
            return nil
        }
        guard CFGetTypeID(keyRef) == SecKeyGetTypeID() else {
            return nil
        }
        return unsafeBitCast(keyRef, to: SecKey.self)
    }

    private func storeLastPushDebug(payload: String?, messageType: String, sender: String, txId: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(payload, forKey: "last_push_payload")
        defaults.set(payload?.count ?? 0, forKey: "last_push_payload_len")
        defaults.set(messageType, forKey: "last_push_type")
        defaults.set(sender, forKey: "last_push_sender")
        defaults.set(txId, forKey: "last_push_tx_id")
        defaults.set(Int64(Date().timeIntervalSince1970 * 1000), forKey: "last_push_ts")
    }

    private func storeLastPushDecryptStatus(_ status: String) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return }
        defaults.set(status, forKey: "last_push_decrypt_status")
    }
}

// MARK: - KaChat Cipher (Notification Extension)

private struct NotificationCipher {
    struct EncryptedMessage {
        let nonce: Data
        let ephemeralPublicKey: Data
        let ciphertext: Data

        init?(fromBytes bytes: Data) {
            guard bytes.count > 45 else { return nil }
            let nonce = bytes.prefix(12)
            let keyStart = 12
            let isSec1Compressed = bytes[keyStart] == 0x02 || bytes[keyStart] == 0x03
            let keySize = isSec1Compressed ? 33 : 32
            let keyEnd = keyStart + keySize
            guard bytes.count >= keyEnd else { return nil }

            let ephemeralPublicKey = bytes[keyStart..<keyEnd]
            let ciphertext = bytes[keyEnd...]

            self.nonce = Data(nonce)
            self.ephemeralPublicKey = Data(ephemeralPublicKey)
            self.ciphertext = Data(ciphertext)
        }

        init?(fromHex hex: String) {
            guard let bytes = Data(hexString: hex) else { return nil }
            self.init(fromBytes: bytes)
        }
    }

    static func decryptHex(_ hexMessage: String, privateKey: Data) throws -> String {
        guard let encrypted = EncryptedMessage(fromHex: hexMessage) else {
            throw CipherError.invalidEncryptedMessage
        }
        return try decrypt(encrypted, privateKey: privateKey)
    }

    static func decryptContextualPayloadDebug(_ payloadHex: String, privateKey: Data) -> (String?, String?) {
        var firstError: String?

        if let payloadString = decodePayloadString(from: payloadHex),
           payloadString.hasPrefix("ciph_msg:1:comm:") {
            let (message, error) = decryptContextualProtocolPayload(payloadString, privateKey: privateKey)
            if let message {
                return (message, nil)
            }
            firstError = error ?? "payload_protocol_decode_failed"
        }

        if let encryptedData = Data(base64Encoded: payloadHex) {
            let (message, error) = decryptEncryptedBytes(encryptedData, privateKey: privateKey)
            if let message {
                return (message, nil)
            }
            if firstError == nil {
                firstError = error
            }

            if let utf8 = String(data: encryptedData, encoding: .utf8) {
                if let nestedHex = Data(hexString: utf8) {
                    let (nestedMessage, nestedError) = decryptEncryptedBytes(nestedHex, privateKey: privateKey)
                    if let nestedMessage {
                        return (nestedMessage, nil)
                    }
                    if firstError == nil {
                        firstError = nestedError
                    }
                }

                if let nestedPayloadString = decodePayloadString(from: utf8),
                   nestedPayloadString.hasPrefix("ciph_msg:1:comm:") {
                    let (nestedMessage, nestedError) = decryptContextualProtocolPayload(
                        nestedPayloadString,
                        privateKey: privateKey
                    )
                    if let nestedMessage {
                        return (nestedMessage, nil)
                    }
                    if firstError == nil {
                        firstError = nestedError
                    }
                }
            }
        }

        if let encryptedData = Data(hexString: payloadHex) {
            let (message, error) = decryptEncryptedBytes(encryptedData, privateKey: privateKey)
            if let message {
                return (message, nil)
            }
            if firstError == nil {
                firstError = error
            }
        }

        return (nil, firstError ?? "payload_decode_failed")
    }

    private static func decryptContextualProtocolPayload(
        _ payloadString: String,
        privateKey: Data
    ) -> (String?, String?) {
        let parts = payloadString.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return (nil, "payload_parts_invalid") }

        let base64String = String(parts[4])
        guard !base64String.isEmpty else { return (nil, "payload_base64_empty") }
        guard let encryptedData = Data(base64Encoded: base64String) else {
            return (nil, "payload_base64_decode_failed")
        }
        return decryptEncryptedBytes(encryptedData, privateKey: privateKey)
    }

    private static func decodePayloadString(from payloadHex: String) -> String? {
        if let payloadData = Data(hexString: payloadHex),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            return payloadString
        }

        if payloadHex.hasPrefix("ciph_msg:") {
            return payloadHex
        }

        return nil
    }

    private static func decryptEncryptedBytes(_ encryptedData: Data, privateKey: Data) -> (String?, String?) {
        guard let encrypted = EncryptedMessage(fromBytes: encryptedData) else {
            return (nil, "payload_encrypted_parse_failed_len_\(encryptedData.count)")
        }

        do {
            let message = try decrypt(encrypted, privateKey: privateKey)
            return (message, nil)
        } catch {
            return (nil, "payload_decrypt_failed_len_\(encryptedData.count)")
        }
    }

    private static func decrypt(_ encryptedMessage: EncryptedMessage, privateKey: Data) throws -> String {
        guard encryptedMessage.ephemeralPublicKey.count == 33 else {
            throw CipherError.invalidPublicKey
        }

        let sharedSecret = try performECDH(
            privateKey: privateKey,
            ephemeralPublicKey: encryptedMessage.ephemeralPublicKey
        )

        let derivedKey = deriveKey(sharedSecret: sharedSecret)

        guard encryptedMessage.ciphertext.count >= 16 else {
            throw CipherError.invalidEncryptedMessage
        }

        let tagLength = 16
        let actualCiphertext = encryptedMessage.ciphertext.dropLast(tagLength)
        let tag = encryptedMessage.ciphertext.suffix(tagLength)

        let nonce = try ChaChaPoly.Nonce(data: encryptedMessage.nonce)
        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: actualCiphertext,
            tag: tag
        )

        let symmetricKey = SymmetricKey(data: derivedKey)
        let plaintext = try ChaChaPoly.open(sealedBox, using: symmetricKey)
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw CipherError.invalidPlaintext
        }
        return result
    }

    private static func performECDH(privateKey: Data, ephemeralPublicKey: Data) throws -> Data {
        let privKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        let pubKey = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: ephemeralPublicKey,
            format: .compressed
        )

        let sharedSecretBytes = try privKey.sharedSecretFromKeyAgreement(
            with: pubKey,
            format: .compressed
        )

        var xCoordinate = Data()
        sharedSecretBytes.withUnsafeBytes { bytes in
            if bytes.count >= 33 {
                xCoordinate = Data(bytes[1..<33])
            } else if bytes.count == 32 {
                xCoordinate = Data(bytes)
            }
        }

        guard xCoordinate.count == 32 else {
            throw CipherError.decryptionFailed
        }

        return xCoordinate
    }

    private static func deriveKey(sharedSecret: Data) -> Data {
        let inputKey = SymmetricKey(data: sharedSecret)
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(),
            info: Data(),
            outputByteCount: 32
        )

        return derivedKey.withUnsafeBytes { bytes in
            Data(Array(bytes))
        }
    }

    enum CipherError: LocalizedError {
        case invalidEncryptedMessage
        case invalidPublicKey
        case invalidPrivateKey
        case decryptionFailed
        case invalidPlaintext
    }
}

private extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex

        for _ in 0..<len {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
