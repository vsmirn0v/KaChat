import Foundation

/// Blake2b hash function implementation for Kaspa transaction signing
/// Based on RFC 7693: https://tools.ietf.org/html/rfc7693
struct Blake2b {

    // Blake2b-256 initialization vector
    private static let IV: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ]

    // Sigma permutation for rounds
    private static let SIGMA: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    private var h: [UInt64]
    private var t: [UInt64] = [0, 0]  // Counter
    private var buffer = Data()
    private let digestLength: Int

    /// Initialize Blake2b with optional key (for keyed hashing / domain separation)
    /// - Parameters:
    ///   - digestLength: Output hash length in bytes (1-64, default 32)
    ///   - key: Optional key for keyed hashing (max 64 bytes) - used for domain separation in Kaspa
    init(digestLength: Int = 32, key: Data? = nil) {
        self.digestLength = min(64, max(1, digestLength))
        let keyLen = min(64, key?.count ?? 0)

        // Initialize state
        h = Blake2b.IV

        // Parameter block:
        // h[0] ^= 0x01010000 ^ (keyLen << 8) ^ digestLength
        h[0] ^= UInt64(0x01010000) ^ (UInt64(keyLen) << 8) ^ UInt64(self.digestLength)

        // If keyed, pad key to 128 bytes and process as first block
        if let key = key, !key.isEmpty {
            var paddedKey = Data(count: 128)
            paddedKey.replaceSubrange(0..<min(key.count, 64), with: key.prefix(64))
            buffer.append(paddedKey)
        }
    }

    /// Update hash with data
    mutating func update(_ data: Data) {
        buffer.append(data)

        // Process complete 128-byte blocks
        while buffer.count > 128 {
            let block = Data(buffer.prefix(128))
            buffer = Data(buffer.dropFirst(128))
            t[0] = t[0] &+ 128
            if t[0] < 128 { t[1] = t[1] &+ 1 }
            compress(block: block, isFinal: false)
        }
    }

    /// Finalize and return the hash
    mutating func finalize() -> Data {
        // Update counter with remaining bytes
        t[0] = t[0] &+ UInt64(buffer.count)
        if t[0] < UInt64(buffer.count) { t[1] = t[1] &+ 1 }

        // Pad buffer to 128 bytes
        let remaining = buffer
        buffer = remaining + Data(count: 128 - remaining.count)

        compress(block: buffer, isFinal: true)

        // Extract digest
        var result = Data(count: digestLength)
        for i in 0..<(digestLength / 8) {
            var word = h[i].littleEndian
            result.replaceSubrange(i*8..<(i+1)*8, with: Data(bytes: &word, count: 8))
        }
        if digestLength % 8 != 0 {
            let lastIndex = digestLength / 8
            var word = h[lastIndex].littleEndian
            let bytes = Data(bytes: &word, count: 8)
            result.replaceSubrange(lastIndex*8..<digestLength, with: bytes.prefix(digestLength % 8))
        }

        return result
    }

    private mutating func compress(block: Data, isFinal: Bool) {
        var v = [UInt64](repeating: 0, count: 16)
        var m = [UInt64](repeating: 0, count: 16)

        // Initialize working vector
        for i in 0..<8 {
            v[i] = h[i]
            v[i + 8] = Blake2b.IV[i]
        }

        v[12] ^= t[0]
        v[13] ^= t[1]
        if isFinal {
            v[14] = ~v[14]
        }

        // Load message block as little-endian u64s
        for i in 0..<16 {
            let offset = i * 8
            var word: UInt64 = 0
            for j in 0..<8 {
                word |= UInt64(block[offset + j]) << (j * 8)
            }
            m[i] = word
        }

        // 12 rounds of mixing
        for round in 0..<12 {
            let s = Blake2b.SIGMA[round % 10]

            mix(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])

            mix(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }

        // Finalize state
        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    private func mix(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = (v[d] ^ v[a]).rotateRight(32)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotateRight(24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = (v[d] ^ v[a]).rotateRight(16)
        v[c] = v[c] &+ v[d]
        v[b] = (v[b] ^ v[c]).rotateRight(63)
    }

    /// Compute Blake2b-256 hash with optional key (for domain separation)
    static func hash(_ data: Data, digestLength: Int = 32, key: String? = nil) -> Data {
        let keyData = key?.data(using: .utf8)
        var hasher = Blake2b(digestLength: digestLength, key: keyData)
        hasher.update(data)
        return hasher.finalize()
    }
}

// Helper extension for bit rotation
private extension UInt64 {
    func rotateRight(_ n: Int) -> UInt64 {
        return (self >> n) | (self << (64 - n))
    }
}
