import Foundation
import CryptoKit

struct CryptoUtils {
    // MARK: - Hex Encoding/Decoding

    static func dataToHex(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var temp = ""

        let cleanHex = hex.lowercased().replacingOccurrences(of: " ", with: "")

        for char in cleanHex {
            temp += String(char)
            if temp.count == 2 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                } else {
                    return nil
                }
                temp = ""
            }
        }

        return data
    }

    // MARK: - Hashing

    static func sha256(_ data: Data) -> Data {
        let hash = SHA256.hash(data: data)
        return Data(hash)
    }

    static func sha256(_ string: String) -> Data {
        let data = string.data(using: .utf8) ?? Data()
        return sha256(data)
    }

    static func doubleSha256(_ data: Data) -> Data {
        return sha256(sha256(data))
    }

    // MARK: - Key Derivation

    static func deriveKey(from password: String, salt: Data, iterations: Int = 100_000) -> SymmetricKey {
        let passwordData = password.data(using: .utf8) ?? Data()
        var key = passwordData + salt

        for _ in 0..<iterations {
            key = sha256(key)
        }

        return SymmetricKey(data: key.prefix(32))
    }

    // MARK: - Encryption/Decryption

    static func encrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed
        }
        return combined
    }

    static func decrypt(_ data: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Address Generation

    static func generateAddress(from publicKey: Data, network: NetworkType = .mainnet) -> String {
        // Hash the public key
        let hash = sha256(publicKey)

        // Take first 20 bytes for address
        let addressBytes = hash.prefix(20)

        // Encode as hex
        let addressHex = dataToHex(addressBytes)

        // Format as Kaspa address
        let prefix = network == .mainnet ? "kaspa" : "kaspatest"
        return "\(prefix):qr\(addressHex)"
    }

    // MARK: - Validation

    static func isValidKaspaAddress(_ address: String) -> Bool {
        // Check prefix
        guard address.hasPrefix("kaspa:") || address.hasPrefix("kaspatest:") else {
            return false
        }

        // Extract the address part
        let parts = address.split(separator: ":")
        guard parts.count == 2 else { return false }

        let addressPart = String(parts[1])

        // Check type prefix (qr, qp, qz)
        guard addressPart.hasPrefix("qr") || addressPart.hasPrefix("qp") || addressPart.hasPrefix("qz") else {
            return false
        }

        // Check length (2 char prefix + 40 char hex = 42)
        guard addressPart.count >= 42 else {
            return false
        }

        return true
    }
}

// MARK: - Secure Memory Zeroing

extension Data {
    /// Zero out the contents of this Data buffer using memset_s (guaranteed not to be optimized away).
    /// Note: Swift Data is a value type with copy-on-write. This zeros the primary storage location
    /// but cannot guarantee all transient copies are erased.
    mutating func zeroOut() {
        guard !isEmpty else { return }
        withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }
}

enum CryptoError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidKey
    case invalidData

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .decryptionFailed:
            return "Failed to decrypt data"
        case .invalidKey:
            return "Invalid encryption key"
        case .invalidData:
            return "Invalid data format"
        }
    }
}
