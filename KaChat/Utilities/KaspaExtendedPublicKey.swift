import Foundation
import CryptoKit
import P256K

/// Parses Kaspa "kpub" extended public keys (BIP32 account-level xpub with Kaspa's
/// custom version bytes) and derives descendant public keys/addresses using
/// public-key-only child derivation (CKDpub) — no private key material is ever
/// involved, matching the KasSigner firmware's `wallet::xpub` module which this
/// mirrors byte-for-byte (see bootloader/src/wallet/xpub.rs in the KasSigner repo).
///
/// CKDpub correctness was verified against the app's proven CKDpriv derivation
/// (WalletManager.deriveChildKey) via a standalone script before this shipped:
/// CKDpriv-then-derive-pubkey produced identical results to CKDpub-directly at
/// both first and second derivation levels, across multiple seeds.
struct KaspaExtendedPublicKey {
    /// Kaspa account-level xpub version bytes -> base58check "kpub..." prefix.
    private static let versionBytes: [UInt8] = [0x03, 0x8f, 0x33, 0x2e]
    private static let payloadLength = 78

    let pubkey: Data       // 33 bytes, compressed (0x02/0x03 prefix + X coordinate)
    let chainCode: Data    // 32 bytes
    let depth: UInt8

    init?(kpubString: String) {
        guard let payload = Base58.decodeChecked(kpubString), payload.count == Self.payloadLength else {
            return nil
        }
        guard Array(payload.prefix(4)) == Self.versionBytes else {
            return nil
        }

        self.depth = payload[payload.startIndex + 4]
        self.chainCode = Data(payload[(payload.startIndex + 13)..<(payload.startIndex + 45)])
        self.pubkey = Data(payload[(payload.startIndex + 45)..<(payload.startIndex + 78)])
    }

    private init(pubkey: Data, chainCode: Data, depth: UInt8) {
        self.pubkey = pubkey
        self.chainCode = chainCode
        self.depth = depth
    }

    /// x-only 32-byte pubkey (Kaspa/BIP340 Schnorr form used for addresses).
    var xOnlyPubKey: Data {
        pubkey.suffix(32)
    }

    func address(network: NetworkType) -> String {
        KaspaAddress.fromPublicKey(Data(xOnlyPubKey), network: network).address
    }

    /// Public-key-only BIP32 child derivation (CKDpub). Only non-hardened indices
    /// are derivable from a public key alone.
    func deriveChild(index: UInt32) throws -> KaspaExtendedPublicKey {
        guard index < 0x80000000 else {
            throw KasiaError.encryptionError("Cannot derive a hardened child from a public key")
        }

        var data = Data(pubkey)
        var idx = index.bigEndian
        data.append(Data(bytes: &idx, count: 4))

        let hmacKey = SymmetricKey(data: chainCode)
        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: hmacKey)
        let hmacData = Data(hmac)
        let il = Array(hmacData.prefix(32))
        let childChainCode = Data(hmacData.suffix(32))

        let parentKey = try P256K.Signing.PublicKey(dataRepresentation: [UInt8](pubkey), format: .compressed)
        let childKey = try parentKey.add(il, format: .compressed)

        return KaspaExtendedPublicKey(
            pubkey: Data(childKey.dataRepresentation),
            chainCode: childChainCode,
            depth: depth + 1
        )
    }

    /// Derives the address at the standard receive chain (external, index 0) and
    /// the given address index: kpub -> change(0) -> address(index).
    func receiveAddress(at index: UInt32, network: NetworkType) throws -> String {
        let changeKey = try deriveChild(index: 0)
        let addressKey = try changeKey.deriveChild(index: index)
        return addressKey.address(network: network)
    }
}
