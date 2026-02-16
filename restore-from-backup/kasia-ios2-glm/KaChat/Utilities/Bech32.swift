import Foundation

/// Bech32 encoding for Kaspa addresses
/// Kaspa uses a variant of bech32 with charset: qpzry9x8gf2tvdw0s3jn54khce6mua7l
struct Bech32 {
    // Kaspa bech32 charset (32 characters, no 'b', 'i', 'o', '1')
    static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    static let charsetArray = Array(charset)

    // Generator polynomial for checksum (40-bit values for Kaspa bech32)
    private static let generator: [UInt64] = [0x98f2bc8e61, 0x79b76d99e2, 0xf33e5fb3c4, 0xae2eabe2a8, 0x1e4f43e470]

    // MARK: - Public Methods

    /// Encode data to Kaspa bech32 address
    static func encode(hrp: String, version: UInt8, data: Data) -> String? {
        // Kaspa format: version byte is prepended to data BEFORE 8→5 bit conversion
        var dataWithVersion = [UInt8]()
        dataWithVersion.append(version)
        dataWithVersion.append(contentsOf: data)

        // Convert combined (version + data) from 8-bit to 5-bit groups
        guard let values = convertBits(data: dataWithVersion, fromBits: 8, toBits: 5, pad: true) else {
            return nil
        }

        // Calculate checksum
        let checksum = createChecksum(hrp: hrp, values: values)
        var allValues = values
        allValues.append(contentsOf: checksum)

        // Encode to charset
        var result = hrp + ":"
        for value in allValues {
            guard value < 32 else { return nil }
            result.append(charsetArray[Int(value)])
        }

        return result
    }

    /// Decode Kaspa bech32 address
    static func decode(_ address: String) -> (hrp: String, version: UInt8, data: Data)? {
        // Split by ":"
        let parts = address.lowercased().split(separator: ":")
        guard parts.count == 2 else { return nil }

        let hrp = String(parts[0])
        let dataString = String(parts[1])

        // Decode from charset
        var values = [UInt8]()
        for char in dataString {
            guard let index = charset.firstIndex(of: char) else { return nil }
            values.append(UInt8(charset.distance(from: charset.startIndex, to: index)))
        }

        // Verify checksum (last 8 characters)
        guard values.count >= 8 else { return nil }
        guard verifyChecksum(hrp: hrp, values: values) else { return nil }

        // Remove checksum
        values = Array(values.dropLast(8))

        guard !values.isEmpty else { return nil }

        // Convert ALL 5-bit values back to 8-bit data (including version)
        guard let dataWithVersion = convertBits(data: values, fromBits: 5, toBits: 8, pad: false) else {
            return nil
        }

        guard !dataWithVersion.isEmpty else { return nil }

        // First byte is version/type, rest is payload
        let version = dataWithVersion[0]
        let data = Array(dataWithVersion.dropFirst())

        return (hrp, version, Data(data))
    }

    // MARK: - Private Methods

    private static func polymod(_ values: [UInt8]) -> UInt64 {
        var chk: UInt64 = 1
        for value in values {
            let top = chk >> 35
            chk = ((chk & 0x07ffffffff) << 5) ^ UInt64(value)
            for i in 0..<5 {
                if ((top >> i) & 1) == 1 {
                    chk ^= UInt64(generator[i])
                }
            }
        }
        return chk
    }

    /// Kaspa-specific prefix expansion: lowercase mask (lower 5 bits only) + null separator
    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        // Kaspa uses only the lower 5 bits of each prefix character (lowercase mask)
        for char in hrp.lowercased() {
            result.append(UInt8(char.asciiValue! & 0x1f))
        }
        // Null byte separator
        result.append(0)
        return result
    }

    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        var enc = hrpExpand(hrp)
        enc.append(contentsOf: values)
        enc.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        let polymodValue = polymod(enc) ^ 1
        var result = [UInt8]()
        for i in 0..<8 {
            result.append(UInt8((polymodValue >> (5 * (7 - i))) & 31))
        }
        return result
    }

    private static func verifyChecksum(hrp: String, values: [UInt8]) -> Bool {
        var enc = hrpExpand(hrp)
        enc.append(contentsOf: values)
        return polymod(enc) == 1
    }

    private static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) -> [UInt8]? {
        var acc: UInt32 = 0
        var bits: Int = 0
        var result = [UInt8]()
        let maxv: UInt32 = (1 << toBits) - 1

        for value in data {
            if (value >> fromBits) != 0 {
                return nil
            }
            acc = (acc << fromBits) | UInt32(value)
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (toBits - bits)) & maxv))
            }
        } else if bits >= fromBits {
            return nil
        } else if ((acc << (toBits - bits)) & maxv) != 0 {
            return nil
        }

        return result
    }
}

// MARK: - Kaspa Address Types

enum KaspaAddressType: UInt8 {
    case pubKey = 0        // P2PK - Pay to Public Key (prefix: q)
    case pubKeyECDSA = 1   // P2PK ECDSA (prefix: q)
    case scriptHash = 8    // P2SH - Pay to Script Hash (prefix: p)

    var prefix: Character {
        switch self {
        case .pubKey, .pubKeyECDSA:
            return "q"
        case .scriptHash:
            return "p"
        }
    }
}

// MARK: - Kaspa Address

struct KaspaAddress {
    let hrp: String  // "kaspa" for mainnet, "kaspatest" for testnet
    let type: KaspaAddressType
    let payload: Data  // Public key hash or script hash

    var address: String {
        // Encode with bech32
        // The version byte encodes the address type
        guard let encoded = Bech32.encode(hrp: hrp, version: type.rawValue, data: payload) else {
            return ""
        }
        return encoded
    }

    init?(address: String) {
        guard let decoded = Bech32.decode(address) else {
            return nil
        }

        self.hrp = decoded.hrp
        self.payload = decoded.data

        // Determine type from version
        switch decoded.version {
        case 0, 1:
            self.type = decoded.version == 0 ? .pubKey : .pubKeyECDSA
        case 8:
            self.type = .scriptHash
        default:
            return nil
        }
    }

    init(hrp: String, type: KaspaAddressType, payload: Data) {
        self.hrp = hrp
        self.type = type
        self.payload = payload
    }

    /// Create address from public key
    static func fromPublicKey(_ publicKey: Data, network: NetworkType = .mainnet) -> KaspaAddress {
        let hrp = network == .mainnet ? "kaspa" : "kaspatest"

        // For Schnorr (32-byte key), use pubKey type
        // For ECDSA (33-byte compressed key), use pubKeyECDSA type
        let type: KaspaAddressType = publicKey.count == 32 ? .pubKey : .pubKeyECDSA

        return KaspaAddress(hrp: hrp, type: type, payload: publicKey)
    }

    /// Validate a Kaspa address string
    static func isValid(_ address: String) -> Bool {
        guard let decoded = Bech32.decode(address) else {
            return false
        }

        // Check HRP
        guard decoded.hrp == "kaspa" || decoded.hrp == "kaspatest" else {
            return false
        }

        // Check version is valid
        guard decoded.version == 0 || decoded.version == 1 || decoded.version == 8 else {
            return false
        }

        // Check payload length (32 bytes for pubkey, 32 bytes for script hash)
        guard decoded.data.count == 32 else {
            return false
        }

        return true
    }

    /// Get the public key from an address (only for P2PK addresses)
    static func publicKey(from address: String) -> Data? {
        guard let kaspaAddr = KaspaAddress(address: address) else {
            return nil
        }

        // Only P2PK addresses contain the public key directly
        guard kaspaAddr.type == .pubKey || kaspaAddr.type == .pubKeyECDSA else {
            return nil
        }

        return kaspaAddr.payload
    }

    /// Generate the script public key for an address
    /// This creates the locking script that funds are sent to
    static func scriptPublicKey(from address: String) -> Data? {
        guard let kaspaAddr = KaspaAddress(address: address) else {
            return nil
        }

        var script = Data()

        switch kaspaAddr.type {
        case .pubKey, .pubKeyECDSA:
            // P2PK: <pubkey_length> <pubkey> OP_CHECKSIG
            let pubKey = kaspaAddr.payload
            script.append(UInt8(pubKey.count))
            script.append(pubKey)
            script.append(0xAC) // OP_CHECKSIG

        case .scriptHash:
            // P2SH: OP_BLAKE2B <script_hash_length> <script_hash> OP_EQUAL
            let scriptHash = kaspaAddr.payload
            script.append(0xAA) // OP_BLAKE2B
            script.append(UInt8(scriptHash.count))
            script.append(scriptHash)
            script.append(0x87) // OP_EQUAL
        }

        return script
    }
}
