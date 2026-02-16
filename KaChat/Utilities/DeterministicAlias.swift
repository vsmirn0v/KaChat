import Foundation
import CryptoKit
import P256K

/// Derives deterministic conversation aliases using ECDH + HKDF.
/// Matches the Rust implementation in `external/KaChat/cipher/src/lib.rs:399-440`.
///
/// Algorithm:
/// 1. Extract their x-only pubkey from address
/// 2. Convert to compressed SEC1 (prepend 0x02 for even parity)
/// 3. ECDH via P256K.KeyAgreement → extract 32-byte x-coordinate
/// 4. info = "chat" || sharedSecret || contextPubkey
/// 5. HKDF-SHA256(ikm: sharedSecret, salt: empty, info: info, len: 6)
/// 6. Return 6 bytes as 12-char hex string
struct DeterministicAlias {

    enum AliasDerivationError: LocalizedError {
        case invalidAddress
        case invalidPublicKey
        case invalidPrivateKey
        case ecdhFailed
        case hkdfFailed

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "Invalid Kaspa address"
            case .invalidPublicKey: return "Invalid public key extracted from address"
            case .invalidPrivateKey: return "Invalid private key"
            case .ecdhFailed: return "ECDH key agreement failed"
            case .hkdfFailed: return "HKDF key derivation failed"
            }
        }
    }

    /// Derive my alias (incoming/watch alias) for a conversation.
    /// The peer will send messages to this alias.
    /// Context pubkey = my x-only pubkey (32 bytes).
    static func deriveMyAlias(privateKey: Data, theirAddress: String) throws -> String {
        // My x-only pubkey from my private key
        let myXOnlyPubKey = try deriveXOnlyPublicKey(from: privateKey)
        return try deriveAliasWithContext(privateKey: privateKey, theirAddress: theirAddress, contextPubkey: myXOnlyPubKey)
    }

    /// Derive their alias (outgoing/send alias) for a conversation.
    /// I send messages using this alias.
    /// Context pubkey = their x-only pubkey (32 bytes).
    static func deriveTheirAlias(privateKey: Data, theirAddress: String) throws -> String {
        // Their x-only pubkey from their address
        guard let theirXOnlyPubKey = KaspaAddress.publicKey(from: theirAddress) else {
            throw AliasDerivationError.invalidAddress
        }
        guard theirXOnlyPubKey.count == 32 else {
            throw AliasDerivationError.invalidPublicKey
        }
        return try deriveAliasWithContext(privateKey: privateKey, theirAddress: theirAddress, contextPubkey: theirXOnlyPubKey)
    }

    // MARK: - Internal

    /// Core derivation: ECDH + HKDF with a context pubkey.
    /// Matches Rust `derive_alias_with_context`.
    private static func deriveAliasWithContext(privateKey: Data, theirAddress: String, contextPubkey: Data) throws -> String {
        // 1. Extract their x-only pubkey (32 bytes) from address
        guard let theirXOnly = KaspaAddress.publicKey(from: theirAddress) else {
            throw AliasDerivationError.invalidAddress
        }
        guard theirXOnly.count == 32 else {
            throw AliasDerivationError.invalidPublicKey
        }

        // 2. Convert to compressed SEC1 format (prepend 0x02 for even parity)
        var compressedKey = Data([0x02])
        compressedKey.append(theirXOnly)

        // 3. ECDH via P256K.KeyAgreement
        let privKey: P256K.KeyAgreement.PrivateKey
        do {
            privKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        } catch {
            throw AliasDerivationError.invalidPrivateKey
        }

        let pubKey: P256K.KeyAgreement.PublicKey
        do {
            pubKey = try P256K.KeyAgreement.PublicKey(dataRepresentation: compressedKey, format: .compressed)
        } catch {
            throw AliasDerivationError.invalidPublicKey
        }

        let sharedSecretBytes: ContiguousBytes
        do {
            sharedSecretBytes = try privKey.sharedSecretFromKeyAgreement(with: pubKey, format: .compressed)
        } catch {
            throw AliasDerivationError.ecdhFailed
        }

        // Extract 32-byte x-coordinate from shared secret
        var sharedSecret = Data()
        sharedSecretBytes.withUnsafeBytes { bytes in
            if bytes.count >= 33 {
                // Skip parity prefix byte, take 32 bytes
                sharedSecret = Data(bytes[1..<33])
            } else if bytes.count == 32 {
                sharedSecret = Data(bytes)
            }
        }

        guard sharedSecret.count == 32 else {
            throw AliasDerivationError.ecdhFailed
        }

        // 4. Build info: "chat" || sharedSecret || contextPubkey
        var info = Data("chat".utf8)
        info.append(sharedSecret)
        info.append(contextPubkey)

        // 5. HKDF-SHA256: extract with shared secret, expand with info
        // Rust: Hkdf::<Sha256>::new(None, shared_secret) then expand(&info, &mut [u8; 6])
        // CryptoKit HKDF.deriveKey combines extract+expand
        let inputKey = SymmetricKey(data: sharedSecret)
        let derivedKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data(),
            info: info,
            outputByteCount: 6
        )

        // 6. Convert 6 bytes to 12-char hex string
        let aliasBytes = derivedKey.withUnsafeBytes { bytes in
            Data(Array(bytes))
        }

        // Secure cleanup
        var mutableSecret = sharedSecret
        mutableSecret.zeroOut()

        return aliasBytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Derive x-only public key (32 bytes) from private key using Schnorr.
    /// Matches `WalletManager.deriveSchnorrPublicKey`.
    private static func deriveXOnlyPublicKey(from privateKey: Data) throws -> Data {
        let privKey: P256K.Schnorr.PrivateKey
        do {
            privKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        } catch {
            throw AliasDerivationError.invalidPrivateKey
        }
        return Data(privKey.xonly.bytes)
    }
}
