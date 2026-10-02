import Foundation

/// BLAKE3 in pure Swift: the default hash and the keyed hash, 32-byte output, any input length,
/// one-shot or incremental. A straight port of the BLAKE3 reference implementation
/// (`reference_impl.rs` in github.com/BLAKE3-team/BLAKE3): chunks of 1024 bytes, a stack of
/// chaining values merged as the tree grows, ROOT on the last compression.
///
/// Used by the `.kachat` name core: `key = blake3(name)`, the commit hash, contract template
/// hashes, and rusty-kaspa's keyed BLAKE3 hashers (`PayloadDigest`, `TransactionRest`,
/// `TransactionV1Id`, keyed with their domain string zero-padded to 32 bytes) for v1 tx ids.
/// Checked against the official BLAKE3 test vectors and against Rust `blake3::hash`.
struct Blake3 {
    static let outLength = 32

    private static let iv: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19
    ]
    private static let msgPermutation: [Int] = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

    private static let chunkStart: UInt32 = 1 << 0
    private static let chunkEnd: UInt32 = 1 << 1
    private static let parent: UInt32 = 1 << 2
    private static let root: UInt32 = 1 << 3
    private static let keyedHash: UInt32 = 1 << 4

    private static let blockLen = 64
    private static let chunkLen = 1024

    // MARK: - Compression

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }

    @inline(__always)
    private static func g(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ mx: UInt32, _ my: UInt32) {
        s[a] = s[a] &+ s[b] &+ mx
        s[d] = rotr(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]
        s[b] = rotr(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b] &+ my
        s[d] = rotr(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]
        s[b] = rotr(s[b] ^ s[c], 7)
    }

    private static func round(_ s: inout [UInt32], _ m: [UInt32]) {
        g(&s, 0, 4, 8, 12, m[0], m[1])
        g(&s, 1, 5, 9, 13, m[2], m[3])
        g(&s, 2, 6, 10, 14, m[4], m[5])
        g(&s, 3, 7, 11, 15, m[6], m[7])
        g(&s, 0, 5, 10, 15, m[8], m[9])
        g(&s, 1, 6, 11, 12, m[10], m[11])
        g(&s, 2, 7, 8, 13, m[12], m[13])
        g(&s, 3, 4, 9, 14, m[14], m[15])
    }

    /// The full 16-word output of one compression.
    private static func compress(
        _ cv: [UInt32], _ blockWords: [UInt32], _ counter: UInt64, _ blockLen: UInt32, _ flags: UInt32
    ) -> [UInt32] {
        var s: [UInt32] = [
            cv[0], cv[1], cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
            iv[0], iv[1], iv[2], iv[3],
            UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32), blockLen, flags
        ]
        var m = blockWords
        for r in 0..<7 {
            round(&s, m)
            if r < 6 {
                m = msgPermutation.map { m[$0] }
            }
        }
        for i in 0..<8 {
            s[i] ^= s[i + 8]
            s[i + 8] ^= cv[i]
        }
        return s
    }

    private static func words(_ bytes: ArraySlice<UInt8>) -> [UInt32] {
        var block = [UInt8](bytes)
        if block.count < blockLen {
            block.append(contentsOf: [UInt8](repeating: 0, count: blockLen - block.count))
        }
        var out = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let b0 = UInt32(block[4 * i])
            let b1 = UInt32(block[4 * i + 1]) << 8
            let b2 = UInt32(block[4 * i + 2]) << 16
            let b3 = UInt32(block[4 * i + 3]) << 24
            out[i] = b0 | b1 | b2 | b3
        }
        return out
    }

    private static func keyWords(_ key: [UInt8]) -> [UInt32] {
        precondition(key.count == 32, "BLAKE3 key must be 32 bytes")
        return Array(words(key[0..<32]).prefix(8))
    }

    // MARK: - Output and chunk state

    private struct Output {
        let inputCV: [UInt32]
        let blockWords: [UInt32]
        let counter: UInt64
        let blockLen: UInt32
        let flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(Blake3.compress(inputCV, blockWords, counter, blockLen, flags).prefix(8))
        }

        func rootBytes() -> [UInt8] {
            let w = Blake3.compress(inputCV, blockWords, 0, blockLen, flags | Blake3.root)
            var out = [UInt8]()
            out.reserveCapacity(32)
            for word in w.prefix(8) {
                out.append(UInt8(truncatingIfNeeded: word))
                out.append(UInt8(truncatingIfNeeded: word >> 8))
                out.append(UInt8(truncatingIfNeeded: word >> 16))
                out.append(UInt8(truncatingIfNeeded: word >> 24))
            }
            return out
        }
    }

    private struct ChunkState {
        var cv: [UInt32]
        let chunkCounter: UInt64
        var block: [UInt8] = []
        var blocksCompressed: UInt8 = 0
        let flags: UInt32

        init(key: [UInt32], chunkCounter: UInt64, flags: UInt32) {
            self.cv = key
            self.chunkCounter = chunkCounter
            self.flags = flags
            block.reserveCapacity(Blake3.blockLen)
        }

        var length: Int { Blake3.blockLen * Int(blocksCompressed) + block.count }

        private var startFlag: UInt32 { blocksCompressed == 0 ? Blake3.chunkStart : 0 }

        mutating func update(_ input: ArraySlice<UInt8>) {
            var input = input
            while !input.isEmpty {
                if block.count == Blake3.blockLen {
                    let w = Blake3.words(block[...])
                    cv = Array(Blake3.compress(cv, w, chunkCounter, UInt32(Blake3.blockLen), flags | startFlag).prefix(8))
                    blocksCompressed += 1
                    block.removeAll(keepingCapacity: true)
                }
                let take = min(Blake3.blockLen - block.count, input.count)
                block.append(contentsOf: input.prefix(take))
                input = input.dropFirst(take)
            }
        }

        func output() -> Output {
            Output(
                inputCV: cv,
                blockWords: Blake3.words(block[...]),
                counter: chunkCounter,
                blockLen: UInt32(block.count),
                flags: flags | startFlag | Blake3.chunkEnd
            )
        }
    }

    private static func parentOutput(_ left: [UInt32], _ right: [UInt32], key: [UInt32], flags: UInt32) -> Output {
        Output(inputCV: key, blockWords: left + right, counter: 0, blockLen: UInt32(blockLen), flags: parent | flags)
    }

    // MARK: - Hasher

    private let key: [UInt32]
    private let flags: UInt32
    private var chunk: ChunkState
    private var cvStack: [[UInt32]] = []

    /// The default (unkeyed) hash.
    init() {
        key = Self.iv
        flags = 0
        chunk = ChunkState(key: Self.iv, chunkCounter: 0, flags: 0)
    }

    /// The keyed hash (`blake3::Hasher::new_keyed`); `key` is exactly 32 bytes.
    init(key keyBytes: [UInt8]) {
        let k = Self.keyWords(keyBytes)
        key = k
        flags = Self.keyedHash
        chunk = ChunkState(key: k, chunkCounter: 0, flags: Self.keyedHash)
    }

    /// rusty-kaspa's `blake3_hasher!` domains: the domain string as the key, zero padded to 32.
    init(domain: String) {
        var k = [UInt8](domain.utf8)
        precondition(k.count <= 32, "BLAKE3 domain longer than its key")
        k.append(contentsOf: [UInt8](repeating: 0, count: 32 - k.count))
        self.init(key: k)
    }

    private mutating func addChunkCV(_ newCV: [UInt32], totalChunks: UInt64) {
        var cv = newCV
        var total = totalChunks
        while total & 1 == 0 {
            let left = cvStack.removeLast()
            cv = Self.parentOutput(left, cv, key: key, flags: flags).chainingValue()
            total >>= 1
        }
        cvStack.append(cv)
    }

    mutating func update(_ data: [UInt8]) {
        var input = data[...]
        while !input.isEmpty {
            if chunk.length == Self.chunkLen {
                let cv = chunk.output().chainingValue()
                let total = chunk.chunkCounter + 1
                addChunkCV(cv, totalChunks: total)
                chunk = ChunkState(key: key, chunkCounter: total, flags: flags)
            }
            let take = min(Self.chunkLen - chunk.length, input.count)
            chunk.update(input.prefix(take))
            input = input.dropFirst(take)
        }
    }

    mutating func update(_ data: Data) {
        update([UInt8](data))
    }

    /// The 32-byte digest. The hasher can keep being updated afterwards (as in the reference).
    func finalize() -> Data {
        var output = chunk.output()
        var remaining = cvStack.count
        while remaining > 0 {
            remaining -= 1
            output = Self.parentOutput(cvStack[remaining], output.chainingValue(), key: key, flags: flags)
        }
        return Data(output.rootBytes())
    }

    // MARK: - One-shot

    static func hash(_ data: Data) -> Data {
        var h = Blake3()
        h.update(data)
        return h.finalize()
    }

    static func hash(_ bytes: [UInt8]) -> Data {
        var h = Blake3()
        h.update(bytes)
        return h.finalize()
    }

    static func keyedHash(key: [UInt8], _ data: Data) -> Data {
        var h = Blake3(key: key)
        h.update(data)
        return h.finalize()
    }
}
