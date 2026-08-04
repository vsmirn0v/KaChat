import Foundation
import CryptoKit
import P256K

/// Group messaging crypto for KaChat's group chat feature.
///
/// Protocol ported from the Kasia web client's `spike/groupchats` reference implementation
/// (see GROUP_MESSAGING_SPEC.md at github.com/K-Kluster/Kasia, branch `spike/groupchats`).
/// A prior revision of this file also had a KaChat-specific invite-beacon extension (join a
/// group deterministically from a shared code, no prior 1:1 handshake needed) - removed once
/// group chats route through indexers: a publicly-joinable beacon would let anyone discover and
/// join a group's *encrypted* chat, which is exactly the kind of thing that could be used to
/// infer something bad is happening inside it and pressure an indexer operator into censoring.
/// Every member now has to be added directly by the admin, who already knows who they are.
///
/// Trust model: a single admin controls membership and key rotation. All members share a
/// symmetric epoch root key; forward secrecy is at epoch granularity (bumped on membership
/// change), not per-message. Same primitives as 1:1 messaging (`KasiaCipher`): ChaCha20-Poly1305
/// AEAD, HKDF-SHA256, Schnorr/secp256k1 signatures - reused here for consistency, not reinvented.
///
/// This file is pure crypto/codec - no transaction building, no persistence, no network I/O.
/// Wiring this into actual sends/receives (self-stash tx construction, GroupBag storage, UTXO
/// subscription) is a separate layer.
enum GroupCipher {

    // MARK: - Key Derivation

    /// group_id = SHA256("ciph_msg:groupid" || group_seed)
    static func deriveGroupId(groupSeed: Data) -> Data {
        CryptoUtils.sha256(Data("ciph_msg:groupid".utf8) + groupSeed)
    }

    /// group_root_epoch_N = HKDF(group_seed, salt = group_id || epoch_le, info = "kasia:groot")
    static func deriveGroupRootEpoch(groupSeed: Data, groupId: Data, epoch: UInt64) -> Data {
        hkdf(ikm: groupSeed, salt: groupId + leBytes(epoch), info: Data("kasia:groot".utf8))
    }

    /// blinding_key = HKDF(group_seed, salt = group_id, info = "kasia:blinding_key")
    static func deriveBlindingKey(groupSeed: Data, groupId: Data) -> Data {
        hkdf(ikm: groupSeed, salt: groupId, info: Data("kasia:blinding_key".utf8))
    }

    /// blinded_group_id_user = HKDF(blinding_key, salt = member's x-only pubkey, info = "kasia:blinded_gid")
    static func deriveBlindedGroupId(blindingKey: Data, memberXOnlyPubKey: Data) -> Data {
        hkdf(ikm: blindingKey, salt: memberXOnlyPubKey, info: Data("kasia:blinded_gid".utf8))
    }

    /// sender_id = SHA256(sender_address_string_bytes)
    static func deriveSenderId(senderAddress: String) -> Data {
        CryptoUtils.sha256(senderAddress)
    }

    /// sender_key = HKDF(group_root, salt = group_id || epoch_le, info = "kasia:gcomm:key" || sender_id)
    static func deriveSenderKey(groupRootEpoch: Data, groupId: Data, epoch: UInt64, senderId: Data) -> Data {
        hkdf(ikm: groupRootEpoch, salt: groupId + leBytes(epoch), info: Data("kasia:gcomm:key".utf8) + senderId)
    }

    /// sender_nonce_key = HKDF(group_root, salt = group_id || epoch_le, info = "kasia:gcomm:nonce" || sender_id)
    static func deriveSenderNonceKey(groupRootEpoch: Data, groupId: Data, epoch: UInt64, senderId: Data) -> Data {
        hkdf(ikm: groupRootEpoch, salt: groupId + leBytes(epoch), info: Data("kasia:gcomm:nonce".utf8) + senderId)
    }

    /// nonce = HKDF(sender_nonce_key, salt = msg_id, info = "kasia:gcomm:nonce")[0:12]
    static func deriveNonce(senderNonceKey: Data, msgId: Data) -> Data {
        hkdf(ikm: senderNonceKey, salt: msgId, info: Data("kasia:gcomm:nonce".utf8), outputByteCount: 12)
    }

    struct MessageKeys {
        let senderKey: Data
        let nonce: Data
    }

    static func deriveMessageKeys(groupRootEpoch: Data, groupId: Data, epoch: UInt64, senderId: Data, msgId: Data) -> MessageKeys {
        let senderKey = deriveSenderKey(groupRootEpoch: groupRootEpoch, groupId: groupId, epoch: epoch, senderId: senderId)
        let senderNonceKey = deriveSenderNonceKey(groupRootEpoch: groupRootEpoch, groupId: groupId, epoch: epoch, senderId: senderId)
        let nonce = deriveNonce(senderNonceKey: senderNonceKey, msgId: msgId)
        return MessageKeys(senderKey: senderKey, nonce: nonce)
    }

    // MARK: - Message AEAD (gcomm)

    /// AAD = version(1) || "gcomm" || group_id || epoch_le(8) || sender_id || msg_id
    static func buildMessageAAD(groupId: Data, epoch: UInt64, senderId: Data, msgId: Data) -> Data {
        var aad = Data([0x01])
        aad.append(Data("gcomm".utf8))
        aad.append(groupId)
        aad.append(leBytes(epoch))
        aad.append(senderId)
        aad.append(msgId)
        return aad
    }

    /// Encrypts `plaintext` for the group message envelope. Returns ciphertext+tag (no nonce
    /// prefix - the nonce is deterministic from `deriveNonce` and recomputed on decrypt).
    static func encryptMessage(
        plaintext: String,
        groupRootEpoch: Data,
        groupId: Data,
        epoch: UInt64,
        senderId: Data,
        msgId: Data
    ) throws -> Data {
        guard let plaintextData = plaintext.data(using: .utf8) else {
            throw CipherError.invalidPlaintext
        }
        let keys = deriveMessageKeys(groupRootEpoch: groupRootEpoch, groupId: groupId, epoch: epoch, senderId: senderId, msgId: msgId)
        let aad = buildMessageAAD(groupId: groupId, epoch: epoch, senderId: senderId, msgId: msgId)
        let key = SymmetricKey(data: keys.senderKey)
        let nonce = try ChaChaPoly.Nonce(data: keys.nonce)
        let sealedBox = try ChaChaPoly.seal(plaintextData, using: key, nonce: nonce, authenticating: aad)
        var combined = Data(sealedBox.ciphertext)
        combined.append(sealedBox.tag)
        return combined
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
            throw CipherError.invalidEncryptedMessage
        }
        let keys = deriveMessageKeys(groupRootEpoch: groupRootEpoch, groupId: groupId, epoch: epoch, senderId: senderId, msgId: msgId)
        let aad = buildMessageAAD(groupId: groupId, epoch: epoch, senderId: senderId, msgId: msgId)
        let tag = ciphertextWithTag.suffix(16)
        let ciphertext = ciphertextWithTag.dropLast(16)
        let nonce = try ChaChaPoly.Nonce(data: keys.nonce)
        do {
            let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let key = SymmetricKey(data: keys.senderKey)
            let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: aad)
            guard let result = String(data: plaintext, encoding: .utf8) else {
                throw CipherError.invalidPlaintext
            }
            return result
        } catch {
            throw CipherError.decryptionFailed
        }
    }

    // MARK: - Signing (gctl_root / gctl_epoch control messages, and gcomm message authenticity)

    /// Raw Schnorr sign over arbitrary bytes, matching KasiaTransactionBuilder's tx-signing pattern.
    static func sign(_ message: Data, privateKey: Data) throws -> Data {
        let schnorrPrivKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        var messageBytes = [UInt8](message)
        let signature = try schnorrPrivKey.signature(message: &messageBytes, auxiliaryRand: nil)
        for index in messageBytes.indices { messageBytes[index] = 0 }
        return Data(signature.bytes)
    }

    /// Raw Schnorr verify, matching KasiaTransactionBuilder's tx-verification pattern.
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

    /// Signing payload for gcomm: sign(AAD || ciphertext+tag).
    static func buildMessageSigningPayload(aad: Data, ciphertextWithTag: Data) -> Data {
        aad + ciphertextWithTag
    }

    /// Signing payload for gctl_root: v || type || group_id || epoch_le || group_root_epoch || blinding_key || admin_signing_pub
    static func buildRootSigningPayload(
        v: UInt8,
        groupId: Data,
        epoch: UInt64,
        groupRootEpoch: Data,
        blindingKey: Data,
        adminSigningPub: Data
    ) -> Data {
        var payload = Data([v])
        payload.append(Data("gctl_root".utf8))
        payload.append(groupId)
        payload.append(leBytes(epoch))
        payload.append(groupRootEpoch)
        payload.append(blindingKey)
        payload.append(adminSigningPub)
        return payload
    }

    /// Signing payload for gctl_epoch: v || type || group_id || epoch_le || reason
    static func buildEpochSigningPayload(v: UInt8, groupId: Data, epoch: UInt64, reason: String) -> Data {
        var payload = Data([v])
        payload.append(Data("gctl_epoch".utf8))
        payload.append(groupId)
        payload.append(leBytes(epoch))
        payload.append(Data(reason.utf8))
        return payload
    }

    // MARK: - Control payloads (sent over the existing 1:1 encrypted COMM channel, JSON)

    /// Membership/epoch-change reason for `GroupEpochPayload`.
    enum EpochChangeReason: String, Codable {
        case add
        case remove
        case rotate
    }

    /// `gctl_root` - admin distributes the epoch root + blinding key + roster to a member.
    /// Sent as the JSON `content` of a normal 1:1 contextual message (encrypted end-to-end by
    /// the existing KasiaCipher ECIES channel), not on-chain in this shape.
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

    /// `gctl_epoch` - admin announces a membership/epoch change ahead of sending a fresh root.
    struct GroupEpochPayload: Codable {
        var type = "gctl_epoch"
        var v: UInt8 = 1
        var groupId: String
        var epoch: UInt64
        var reason: EpochChangeReason
        var sig: String

        enum CodingKeys: String, CodingKey {
            case type, v
            case groupId = "group_id"
            case epoch, reason, sig
        }
    }

    /// Builds and signs a `gctl_root` payload (admin side). `adminPrivateKey` is the admin's
    /// Schnorr signing key; `adminSigningPub` is its corresponding x-only public key.
    static func buildSignedRootPayload(
        groupId: Data,
        epoch: UInt64,
        groupRootEpoch: Data,
        blindingKey: Data,
        adminSigningPub: Data,
        members: [String],
        name: String,
        adminPrivateKey: Data
    ) throws -> GroupRootPayload {
        let signingPayload = buildRootSigningPayload(
            v: 1, groupId: groupId, epoch: epoch,
            groupRootEpoch: groupRootEpoch, blindingKey: blindingKey, adminSigningPub: adminSigningPub
        )
        let sig = try sign(signingPayload, privateKey: adminPrivateKey)
        return GroupRootPayload(
            groupId: groupId.hexString,
            epoch: epoch,
            groupRootEpoch: groupRootEpoch.hexString,
            blindingKey: blindingKey.hexString,
            adminSigningPub: adminSigningPub.hexString,
            members: members,
            name: name,
            sig: sig.hexString
        )
    }

    /// Verifies a received `gctl_root` payload's signature against the claimed admin key.
    /// Callers are responsible for separately checking `adminSigningPub` is the group's known
    /// trusted admin (this only proves internal consistency of the payload's own signature).
    static func verifyRootPayload(_ payload: GroupRootPayload) -> Bool {
        guard let groupId = Data(hexString: payload.groupId),
              let groupRootEpoch = Data(hexString: payload.groupRootEpoch),
              let blindingKey = Data(hexString: payload.blindingKey),
              let adminSigningPub = Data(hexString: payload.adminSigningPub),
              let sig = Data(hexString: payload.sig) else {
            return false
        }
        let signingPayload = buildRootSigningPayload(
            v: payload.v, groupId: groupId, epoch: payload.epoch,
            groupRootEpoch: groupRootEpoch, blindingKey: blindingKey, adminSigningPub: adminSigningPub
        )
        return verify(sig, message: signingPayload, xOnlyPublicKey: adminSigningPub)
    }

    static func buildSignedEpochPayload(
        groupId: Data,
        epoch: UInt64,
        reason: EpochChangeReason,
        adminPrivateKey: Data
    ) throws -> GroupEpochPayload {
        let signingPayload = buildEpochSigningPayload(v: 1, groupId: groupId, epoch: epoch, reason: reason.rawValue)
        let sig = try sign(signingPayload, privateKey: adminPrivateKey)
        return GroupEpochPayload(groupId: groupId.hexString, epoch: epoch, reason: reason, sig: sig.hexString)
    }

    // MARK: - On-chain payload codecs

    struct ParsedGroupMessage {
        let blindedGroupId: Data
        let epoch: UInt64
        let senderId: Data
        let senderPubKey: Data
        let msgId: Data
        let ciphertext: Data
        let signature: Data
    }

    /// ciph_msg:1:gcomm:{blinded_group_id}:{epoch}:{sender_id}:{sender_pub}:{msg_id}:{ciphertext}:{signature}
    static func buildGroupMessagePayload(
        blindedGroupId: Data,
        epoch: UInt64,
        senderId: Data,
        senderPubKey: Data,
        msgId: Data,
        ciphertext: Data,
        signature: Data
    ) -> String {
        "ciph_msg:1:gcomm:\(blindedGroupId.hexString):\(epoch):\(senderId.hexString):\(senderPubKey.hexString):\(msgId.hexString):\(ciphertext.hexString):\(signature.hexString)"
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

    // MARK: - Random generation

    static func generateGroupSeed() -> Data { randomBytes(32) }
    static func generateDeviceId() -> Data { randomBytes(16) }

    /// msg_id = device_id (16 bytes) || msgCounter_le (u64) -> 24 bytes
    static func buildMsgId(deviceId: Data, counter: UInt64) -> Data {
        deviceId + leBytes(counter)
    }

    // MARK: - Helpers

    private static func leBytes(_ value: UInt64) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: 8)
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
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

    // MARK: - Errors

    enum CipherError: LocalizedError {
        case invalidPlaintext
        case invalidEncryptedMessage
        case encryptionFailed
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .invalidPlaintext: return "Invalid plaintext encoding"
            case .invalidEncryptedMessage: return "Invalid encrypted message format"
            case .encryptionFailed: return "Encryption failed"
            case .decryptionFailed: return "Decryption failed"
            }
        }
    }
}
