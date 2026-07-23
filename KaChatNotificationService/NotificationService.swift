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

        // Group pushes have no reliable on-chain sender/receiver address to key the usual
        // contact-lookup/self-suppression/thread-grouping logic off (see PushEventKind's doc
        // comments on the indexer side), so they're handled by a dedicated path that builds its
        // own content from scratch rather than falling through the per-contact pipeline below.
        if messageType == "group_message" || messageType == "group_control" {
            handleGroupPush(messageType: messageType, content: content, userInfo: userInfo, txId: txId)
            return
        }

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
                content.body = unwrapReplyText(decrypted)
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

    // MARK: - Group Push Handling

    private func handleGroupPush(
        messageType: String,
        content: UNMutableNotificationContent,
        userInfo: [AnyHashable: Any],
        txId: String
    ) {
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        let defaultSoundEnabled = (defaults?.object(forKey: incomingNotificationSoundEnabledKey) as? Bool) ?? true
        let shouldIncrementUnread = defaults.map { !hasStoredTxId(txId: txId, defaults: $0) } ?? false

        content.threadIdentifier = "group"

        if messageType == "group_message" {
            guard let blindedGroupIdHex = userInfo["blinded_group_id"] as? String,
                  let payloadHex = userInfo["payload"] as? String,
                  let match = decryptGroupMessage(blindedGroupIdHex: blindedGroupIdHex, payloadHex: payloadHex) else {
                // Can't identify/decrypt this one locally (e.g. just added to the group and the
                // roster hasn't synced to the App Group yet) - suppress rather than show a
                // content-free notification, the main app's catch-up sync will pick it up.
                suppressGroupNotification(content)
                return
            }
            let displayBody = unwrapReplyText(match.plaintext)
            // "Only Notify if I'm Mentioned" - a reply to one of MY messages counts the same as
            // an explicit @mention (checked against the raw, still-wrapped plaintext, since
            // `displayBody` already dropped the reply envelope down to just its own text). Still
            // stored/decryptable/visible once the app is opened either way (this only suppresses
            // the push banner itself), matching how muting a member (enforced earlier, at
            // push-registration time on the main app side) still lets their messages show up.
            if isMentionsOnlyEnabled(groupId: match.groupId),
               !mentionsMe(displayBody), !isReplyToMe(match.plaintext) {
                suppressGroupNotification(content)
                addPendingMessage(txId: txId, sender: "group", type: messageType)
                return
            }
            content.title = match.groupName
            content.body = displayBody
            content.threadIdentifier = "group:\(match.groupId)"
            content.sound = defaultSoundEnabled ? .default : nil
        } else {
            guard let payloadHex = userInfo["payload"] as? String,
                  let groupName = decryptGroupControlForName(payloadHex: payloadHex) else {
                suppressGroupNotification(content)
                return
            }
            content.title = ""
            let format = NSLocalizedString("You were added to \"%@\"", comment: "Push body for being added to a group")
            content.body = String(format: format, groupName)
            content.sound = defaultSoundEnabled ? .default : nil
        }

        if shouldIncrementUnread, let badge = incrementUnreadCountIfNeeded() {
            content.badge = NSNumber(value: badge)
        }
        addPendingMessage(txId: txId, sender: "group", type: messageType)
        contentHandler?(content)
    }

    private func suppressGroupNotification(_ content: UNMutableNotificationContent) {
        content.title = ""
        content.body = ""
        content.sound = nil
        content.badge = nil
        content.interruptionLevel = .passive
        contentHandler?(content)
    }

    private struct GroupMessageMatch {
        let groupId: String
        let groupName: String
        let plaintext: String
    }

    private func decryptGroupMessage(blindedGroupIdHex: String, payloadHex: String) -> GroupMessageMatch? {
        guard let targetBlindedId = Data(hexString: blindedGroupIdHex) else { return nil }
        let payloadString = "ciph_msg:1:gcomm:" + payloadHex
        guard let parsed = NotificationGroupCipher.parseGroupMessagePayload(payloadString),
              parsed.blindedGroupId == targetBlindedId else { return nil }

        for group in getSharedGroups() {
            guard let bag = loadGroupBag(groupId: group.groupId),
                  let blindingKey = Data(hexString: bag.blindingKey),
                  let groupIdData = Data(hexString: group.groupId) else { continue }

            for member in group.members {
                guard let memberPubKey = Data(hexString: member.xOnlyPubKeyHex),
                      memberPubKey == parsed.senderPubKey else { continue }
                let candidate = NotificationGroupCipher.deriveBlindedGroupId(blindingKey: blindingKey, memberXOnlyPubKey: memberPubKey)
                guard candidate == parsed.blindedGroupId else { continue }
                guard NotificationGroupCipher.deriveSenderId(senderAddress: member.address) == parsed.senderId else { continue }

                let aad = NotificationGroupCipher.buildMessageAAD(
                    groupId: groupIdData, epoch: parsed.epoch, senderId: parsed.senderId, msgId: parsed.msgId
                )
                guard NotificationGroupCipher.verify(
                    parsed.signature, message: aad + parsed.ciphertext, xOnlyPublicKey: parsed.senderPubKey
                ) else { return nil }

                guard let root = groupRootEpoch(epoch: parsed.epoch, bag: bag, groupId: groupIdData),
                      let plaintext = try? NotificationGroupCipher.decryptMessage(
                        ciphertextWithTag: parsed.ciphertext, groupRootEpoch: root, groupId: groupIdData,
                        epoch: parsed.epoch, senderId: parsed.senderId, msgId: parsed.msgId
                      ) else { return nil }

                return GroupMessageMatch(groupId: group.groupId, groupName: group.name, plaintext: plaintext)
            }
        }
        return nil
    }

    /// Attempts an ECIES decrypt of a `gctl_root` control payload with the wallet's own private
    /// key (only the intended recipient's key succeeds - every other device's attempt fails
    /// silently, exactly like the main app's `handleIncomingControlMessage`). Deliberately does
    /// NOT persist the resulting group/roster locally (this target has no Core Data access) -
    /// the main app's catch-up sync re-fetches and applies the same `gctl_root` next time it
    /// runs, so this only needs to recover the group name for the notification body.
    private func decryptGroupControlForName(payloadHex: String) -> String? {
        guard let privateKey = loadPrivateKey() else { return nil }
        guard let plaintext = try? NotificationCipher.decryptHex(payloadHex, privateKey: privateKey),
              let jsonData = plaintext.data(using: .utf8) else { return nil }
        guard let rootPayload = try? JSONDecoder().decode(NotificationGroupCipher.GroupRootPayload.self, from: jsonData),
              rootPayload.type == "gctl_root",
              NotificationGroupCipher.verifyRootPayload(rootPayload) else { return nil }
        return rootPayload.name
    }

    /// Mirrors `GroupChatService.groupRootEpoch` - admins can derive any past epoch's root on
    /// demand (they hold groupSeed); non-admins only retain the current epoch's root.
    private func groupRootEpoch(epoch: UInt64, bag: SharedGroupBag, groupId: Data) -> Data? {
        if epoch == bag.currentEpoch, let root = Data(hexString: bag.groupRootEpoch) {
            return root
        }
        if let seedHex = bag.groupSeed, let seed = Data(hexString: seedHex) {
            return NotificationGroupCipher.deriveGroupRootEpoch(groupSeed: seed, groupId: groupId, epoch: epoch)
        }
        return nil
    }

    private func getSharedGroups() -> [SharedGroup] {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: "shared_groups"),
              let groups = try? JSONDecoder().decode([SharedGroup].self, from: data) else {
            return []
        }
        return groups
    }

    /// Loads a `GroupBag` from the Keychain access group shared with the main app, mirroring
    /// `KeychainService.loadGroupBag`'s exact storage scheme (device-scoped key name, optional
    /// Secure Enclave wrapping) so this target can read it independently.
    private func loadGroupBag(groupId: String) -> SharedGroupBag? {
        guard let deviceId = deviceIdentifier() else { return nil }
        let keyName = "kachat_group_bag.\(deviceId).\(groupId)"
        guard let data = loadPrivateKeyWithAccount(account: keyName) else { return nil }
        return try? JSONDecoder().decode(SharedGroupBag.self, from: data)
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

    /// Mirrors `SharedDataManager.syncGroupsForExtension`'s `groupMentionsOnlyNotifications` sync.
    private func isMentionsOnlyEnabled(groupId: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: "shared_group_mentions_only"),
              let groupIds = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return false
        }
        return groupIds.contains(groupId)
    }

    /// A mention is embedded as `@{fullKaspaAddress}` in the plaintext - see the main app's
    /// `GroupMentionCodec` doc comment for why (this target can't do the friendly-name lookup
    /// `decodeForDisplay` does, but doesn't need to - it only needs to know if it's ME).
    private func mentionsMe(_ text: String) -> Bool {
        guard let myAddress = getWalletAddress() else { return true }
        return text.contains("@\(myAddress)")
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

    /// Minimal local mirror of the main app's `MessageReplyContent`/`MessageReplyCodec` (this
    /// extension target doesn't compile Models.swift) - unwraps a reply envelope to its own
    /// `text` for display, so the lock-screen notification shows the reply's actual message
    /// instead of the raw `{"type":"reply",...}` JSON. The stored/decrypted content handed to the
    /// main app is left untouched so its own reply-aware rendering still works.
    private struct PushReplyEnvelope: Decodable {
        let type: String
        let text: String
        let replyToSender: String?
    }

    private func unwrapReplyText(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", let data = trimmed.data(using: .utf8) else { return content }
        guard let parsed = try? JSONDecoder().decode(PushReplyEnvelope.self, from: data),
              parsed.type == "reply" else { return content }
        return inlineAttachmentPreview(for: parsed.text)
    }

    /// True when `content` is a reply envelope (see `PushReplyEnvelope`) whose `replyToSender` is
    /// the wallet's own address - i.e. someone replied to one of MY messages. Counts the same as
    /// an explicit `@mention` for "Only Notify if I'm Mentioned" (see `isMentionsOnlyEnabled`),
    /// since getting replied to and not hearing about it would be a worse surprise than the
    /// setting's name literally promising.
    private func isReplyToMe(_ content: String) -> Bool {
        guard let myAddress = getWalletAddress() else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", let data = trimmed.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(PushReplyEnvelope.self, from: data),
              parsed.type == "reply" else { return false }
        return parsed.replyToSender == myAddress
    }

    /// Mirrors the main app's `MessageReplyCodec.previewText`'s voice/image detection - the
    /// reply's own text can itself be the inline file-attachment JSON `MediaFile`/`sendAudio`/
    /// `sendImage` use (e.g. replying to a photo), which without this shows as raw JSON in the
    /// notification instead of a placeholder label.
    private func inlineAttachmentPreview(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{", let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mimeType = (json["mimeType"] as? String)?.lowercased() else {
            return text
        }
        if mimeType.hasPrefix("audio/") { return "🎤 Audio message" }
        if mimeType.hasPrefix("image/") { return "📷 Photo" }
        return text
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

// MARK: - Group Chat Models (Notification Extension)

/// Mirrors `SharedGroup`/`SharedGroupMember` in the main app's `SharedDataManager.swift` - this
/// target doesn't compile that file, so the shape is duplicated (same JSON keys, since both
/// sides use default `Codable` synthesis with no custom `CodingKeys`).
private struct SharedGroup: Codable {
    let groupId: String
    let name: String
    let adminAddress: String
    let members: [SharedGroupMember]
}

private struct SharedGroupMember: Codable {
    let address: String
    let xOnlyPubKeyHex: String
}

/// Mirrors `GroupBag` in the main app's `Models.swift` - same JSON keys (default `Codable`
/// synthesis, no custom `CodingKeys`), read from the same shared Keychain access group.
private struct SharedGroupBag: Codable {
    let groupId: String
    let groupSeed: String?
    let groupRootEpoch: String
    let blindingKey: String
    let currentEpoch: UInt64
    let deviceId: String
    let msgCounter: UInt64
}

// MARK: - Group Chat Cipher (Notification Extension)

/// Minimal duplicated port of the main app's `GroupCipher.swift` - just enough to verify and
/// decrypt an incoming `gcomm` message and verify/parse a `gctl_root` control payload. Same
/// duplication rationale as `NotificationCipher` above (this target doesn't compile the main
/// app's sources). Keep in sync with `GroupCipher.swift` if the protocol ever changes.
private struct NotificationGroupCipher {
    struct ParsedGroupMessage {
        let blindedGroupId: Data
        let epoch: UInt64
        let senderId: Data
        let senderPubKey: Data
        let msgId: Data
        let ciphertext: Data
        let signature: Data
    }

    static func parseGroupMessagePayload(_ payloadString: String) -> ParsedGroupMessage? {
        let prefix = "ciph_msg:1:gcomm:"
        guard payloadString.hasPrefix(prefix) else { return nil }
        let rest = payloadString.dropFirst(prefix.count)
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 7 else { return nil }
        guard let blindedGroupId = Data(hexString: String(parts[0])),
              let epoch = UInt64(parts[1]),
              let senderId = Data(hexString: String(parts[2])),
              let senderPubKey = Data(hexString: String(parts[3])),
              let msgId = Data(hexString: String(parts[4])),
              let ciphertext = Data(hexString: String(parts[5])),
              let signature = Data(hexString: String(parts[6])) else {
            return nil
        }
        return ParsedGroupMessage(
            blindedGroupId: blindedGroupId, epoch: epoch, senderId: senderId,
            senderPubKey: senderPubKey, msgId: msgId, ciphertext: ciphertext, signature: signature
        )
    }

    struct GroupRootPayload: Codable {
        var type = "gctl_root"
        var v: UInt8 = 1
        var groupId: String
        var epoch: UInt64
        var groupRootEpoch: String
        var blindingKey: String
        var adminSigningPub: String
        var members: [String]
        var name: String
        var sig: String

        enum CodingKeys: String, CodingKey {
            case type, v
            case groupId = "group_id"
            case epoch
            case groupRootEpoch = "group_root_epoch"
            case blindingKey = "blinding_key"
            case adminSigningPub = "admin_signing_pub"
            case members, name, sig
        }
    }

    static func verifyRootPayload(_ payload: GroupRootPayload) -> Bool {
        guard let groupId = Data(hexString: payload.groupId),
              let groupRootEpoch = Data(hexString: payload.groupRootEpoch),
              let blindingKey = Data(hexString: payload.blindingKey),
              let adminSigningPub = Data(hexString: payload.adminSigningPub),
              let sig = Data(hexString: payload.sig) else {
            return false
        }
        var signingPayload = Data([payload.v])
        signingPayload.append(Data("gctl_root".utf8))
        signingPayload.append(groupId)
        signingPayload.append(leBytes(payload.epoch))
        signingPayload.append(groupRootEpoch)
        signingPayload.append(blindingKey)
        signingPayload.append(adminSigningPub)
        return verify(sig, message: signingPayload, xOnlyPublicKey: adminSigningPub)
    }

    static func deriveBlindedGroupId(blindingKey: Data, memberXOnlyPubKey: Data) -> Data {
        hkdf(ikm: blindingKey, salt: memberXOnlyPubKey, info: Data("kasia:blinded_gid".utf8))
    }

    static func deriveSenderId(senderAddress: String) -> Data {
        Data(CryptoKit.SHA256.hash(data: Data(senderAddress.utf8)))
    }

    static func deriveGroupRootEpoch(groupSeed: Data, groupId: Data, epoch: UInt64) -> Data {
        hkdf(ikm: groupSeed, salt: groupId + leBytes(epoch), info: Data("kasia:groot".utf8))
    }

    static func deriveSenderKey(groupRootEpoch: Data, groupId: Data, epoch: UInt64, senderId: Data) -> Data {
        hkdf(ikm: groupRootEpoch, salt: groupId + leBytes(epoch), info: Data("kasia:gcomm:key".utf8) + senderId)
    }

    static func deriveSenderNonceKey(groupRootEpoch: Data, groupId: Data, epoch: UInt64, senderId: Data) -> Data {
        hkdf(ikm: groupRootEpoch, salt: groupId + leBytes(epoch), info: Data("kasia:gcomm:nonce".utf8) + senderId)
    }

    static func deriveNonce(senderNonceKey: Data, msgId: Data) -> Data {
        hkdf(ikm: senderNonceKey, salt: msgId, info: Data("kasia:gcomm:nonce".utf8), outputByteCount: 12)
    }

    static func buildMessageAAD(groupId: Data, epoch: UInt64, senderId: Data, msgId: Data) -> Data {
        var aad = Data([0x01])
        aad.append(Data("gcomm".utf8))
        aad.append(groupId)
        aad.append(leBytes(epoch))
        aad.append(senderId)
        aad.append(msgId)
        return aad
    }

    static func decryptMessage(
        ciphertextWithTag: Data,
        groupRootEpoch: Data,
        groupId: Data,
        epoch: UInt64,
        senderId: Data,
        msgId: Data
    ) throws -> String {
        guard ciphertextWithTag.count >= 16 else {
            throw NotificationCipher.CipherError.invalidEncryptedMessage
        }
        let senderKey = deriveSenderKey(groupRootEpoch: groupRootEpoch, groupId: groupId, epoch: epoch, senderId: senderId)
        let senderNonceKey = deriveSenderNonceKey(groupRootEpoch: groupRootEpoch, groupId: groupId, epoch: epoch, senderId: senderId)
        let nonceBytes = deriveNonce(senderNonceKey: senderNonceKey, msgId: msgId)
        let aad = buildMessageAAD(groupId: groupId, epoch: epoch, senderId: senderId, msgId: msgId)
        let tag = ciphertextWithTag.suffix(16)
        let ciphertext = ciphertextWithTag.dropLast(16)
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let key = SymmetricKey(data: senderKey)
        let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw NotificationCipher.CipherError.invalidPlaintext
        }
        return result
    }

    static func verify(_ signature: Data, message: Data, xOnlyPublicKey: Data) -> Bool {
        guard let schnorrSig = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else {
            return false
        }
        let xonlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: xOnlyPublicKey)
        var messageBytes = [UInt8](message)
        let isValid = xonlyKey.isValid(schnorrSig, for: &messageBytes)
        for index in messageBytes.indices { messageBytes[index] = 0 }
        return isValid
    }

    private static func leBytes(_ value: UInt64) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 8)
    }

    private static func hkdf(ikm: Data, salt: Data, info: Data, outputByteCount: Int = 32) -> Data {
        let inputKey = SymmetricKey(data: ikm)
        let derived = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Data(Array($0)) }
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
