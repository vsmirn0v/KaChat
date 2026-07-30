import Foundation
import CryptoKit

/// Standard Bitcoin-alphabet Base58 and Base58Check (double-SHA256 checksum), needed for
/// parsing/encoding BIP32 extended public keys (Kaspa's "kpub" format uses this exact
/// encoding, just with a custom 4-byte version prefix — see KaspaExtendedPublicKey).
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base = 58

    static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)

        var zerosCount = 0
        for byte in bytes {
            if byte == 0 { zerosCount += 1 } else { break }
        }

        // Repeatedly divide the big-endian byte string (treated as one large integer) by 58,
        // collecting remainders as base58 digits (least-significant first).
        var digits: [UInt8] = []
        // Only feed the non-leading-zero remainder into the big-number conversion — if every
        // byte is zero, this slice is empty and digits correctly stays empty too, instead of
        // the conversion loop emitting one spurious extra zero-digit on top of the zerosCount
        // leading-'1' prefix that already accounts for every zero byte (caught by a standalone
        // test against an all-zero input before this shipped).
        var input = Array(bytes[zerosCount...])
        while !input.isEmpty {
            var remainder = 0
            var quotient: [UInt8] = []
            for byte in input {
                let acc = remainder * 256 + Int(byte)
                let q = acc / base
                remainder = acc % base
                if !quotient.isEmpty || q != 0 {
                    quotient.append(UInt8(q))
                }
            }
            digits.append(UInt8(remainder))
            input = quotient
        }

        let leading = [Character](repeating: alphabet[0], count: zerosCount)
        let encodedDigits = digits.reversed().map { alphabet[Int($0)] }
        return String(leading + encodedDigits)
    }

    static func decode(_ string: String) -> Data? {
        var indexMap: [Character: Int] = [:]
        for (i, c) in alphabet.enumerated() { indexMap[c] = i }

        var zerosCount = 0
        for char in string {
            if char == "1" { zerosCount += 1 } else { break }
        }

        // Repeatedly multiply the accumulator (little-endian byte array) by 58 and add the
        // next digit, i.e. build the big integer back up from its base58 digits.
        var value: [UInt8] = []
        for char in string {
            guard let digit = indexMap[char] else { return nil }
            var carry = digit
            var result: [UInt8] = []
            for byte in value {
                let acc = Int(byte) * base + carry
                result.append(UInt8(acc & 0xFF))
                carry = acc >> 8
            }
            while carry > 0 {
                result.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
            value = result
        }

        let leading = [UInt8](repeating: 0, count: zerosCount)
        return Data(leading + value.reversed())
    }

    static func encodeChecked(_ payload: Data) -> String {
        let hash1 = SHA256.hash(data: payload)
        let hash2 = SHA256.hash(data: Data(hash1))
        let checksum = Data(hash2.prefix(4))
        return encode(payload + checksum)
    }

    static func decodeChecked(_ string: String) -> Data? {
        guard let full = decode(string), full.count >= 4 else { return nil }
        let payload = full.prefix(full.count - 4)
        let checksum = full.suffix(4)
        let hash1 = SHA256.hash(data: payload)
        let hash2 = SHA256.hash(data: Data(hash1))
        guard Data(hash2.prefix(4)) == checksum else { return nil }
        return Data(payload)
    }
}
