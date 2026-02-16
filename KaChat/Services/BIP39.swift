import Foundation
import CryptoKit

/// BIP39 Mnemonic implementation for Kaspa wallets
/// Uses bundled English word list only (offline, deterministic)
final class BIP39 {
    static let shared = BIP39()

    private var wordList: [String] = []

    private init() {
        loadWordList()
    }

    // MARK: - Word List Management

    private func loadWordList() {
        guard let bundled = loadBundledWordList(), bundled.count == 2048 else {
            preconditionFailure("BIP39 english.txt missing or invalid (expected exactly 2048 words).")
        }
        wordList = bundled
    }

    // MARK: - Mnemonic Generation

    /// Ensure word list is loaded (async)
    func ensureWordListLoaded() async {
        precondition(wordList.count == 2048, "BIP39 word list is not loaded.")
    }

    /// Generate a new mnemonic with proper entropy and checksum (async version)
    func generateMnemonicAsync(wordCount: Int = 24) async -> SeedPhrase? {
        await ensureWordListLoaded()
        return generateMnemonic(wordCount: wordCount)
    }

    /// Generate a new mnemonic with proper entropy and checksum
    func generateMnemonic(wordCount: Int = 24) -> SeedPhrase? {
        precondition(wordList.count == 2048, "BIP39 word list is not loaded.")

        guard wordCount == 12 || wordCount == 24 else { return nil }

        // BIP39 entropy sizes: 12w = 128 bits, 24w = 256 bits
        let entropyBytes = (wordCount / 3) * 4 // 16 or 32
        let checksumBits = entropyBytes / 4     // 4 or 8

        // Generate secure random entropy
        var entropy = Data(count: entropyBytes)
        let result = entropy.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, entropyBytes, ptr.baseAddress!)
        }
        guard result == errSecSuccess else { return nil }

        // Compute checksum bits (first checksumBits of SHA256(entropy))
        let hash = SHA256.hash(data: entropy)
        let firstByte: UInt8 = Array(hash).first ?? 0
        let checksumMask: UInt8 = checksumBits == 8 ? 0xFF : (0xFF << (8 - checksumBits)) & 0xFF
        let checksumValue = (firstByte & checksumMask) >> (8 - checksumBits)

        // Helper to read a bit from entropy
        func bitFromEntropy(_ bitIndex: Int) -> Int {
            let byteIndex = bitIndex / 8
            let bitInByte = 7 - (bitIndex % 8)
            let byte = entropy[entropy.index(entropy.startIndex, offsetBy: byteIndex)]
            return Int((byte >> bitInByte) & 0x01)
        }

        // Build words from entropy+checksum bits
        var words: [String] = []
        for i in 0..<wordCount {
            var idx = 0
            for j in 0..<11 {
                let bitPosition = i * 11 + j
                let bit: Int
                if bitPosition < entropyBytes * 8 {
                    bit = bitFromEntropy(bitPosition)
                } else {
                    // checksum bits
                    let cBitPos = bitPosition - entropyBytes * 8
                    bit = Int((checksumValue >> (checksumBits - 1 - cBitPos)) & 0x01)
                }
                idx = (idx << 1) | bit
            }
            guard idx < wordList.count else { return nil }
            words.append(wordList[idx])
        }

        guard words.count == wordCount else { return nil }
        return SeedPhrase(words: words)
    }

    /// Validate a mnemonic phrase
    func validateMnemonic(_ phrase: String) -> Bool {
        let words = phrase.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Check word count
        guard words.count == 12 || words.count == 24 else {
            return false
        }

        precondition(wordList.count == 2048, "BIP39 word list is not loaded.")

        // Verify all words are in the list
        for word in words {
            guard wordList.contains(word) else {
                return false
            }
        }

        // Convert words to indices
        var indices: [Int] = []
        for word in words {
            guard let index = wordList.firstIndex(of: word) else {
                return false
            }
            indices.append(index)
        }

        let checksumBits = words.count / 3
        let entropyBytesCount = (words.count / 3) * 4 // 16 or 32
        let entropyBits = entropyBytesCount * 8

        // Recreate combined bits from indices
        var fullBits: [Int] = []
        for index in indices {
            for b in (0..<11).reversed() {
                fullBits.append((index >> b) & 1)
            }
        }

        // Split entropy/checksum bits
        let entropyBitSlice = fullBits.prefix(entropyBits)
        let checksumBitSlice = fullBits.suffix(checksumBits)

        // Convert entropy bits to bytes
        var entropyBytes = Data(count: entropyBytesCount)
        for (i, bit) in entropyBitSlice.enumerated() {
            let byteIndex = i / 8
            let bitInByte = 7 - (i % 8)
            entropyBytes[byteIndex] |= UInt8(bit << bitInByte)
        }

        // Compute expected checksum
        let hash = SHA256.hash(data: entropyBytes)
        let firstByte: UInt8 = Array(hash).first ?? 0
        let mask: UInt8 = checksumBits == 8 ? 0xFF : (0xFF << (8 - checksumBits)) & 0xFF
        let expectedChecksum = Int((firstByte & mask) >> (8 - checksumBits))

        let actualChecksum = checksumBitSlice.reduce(0) { ($0 << 1) | $1 }

        return expectedChecksum == actualChecksum
    }

    /// Derive seed from mnemonic (BIP39 standard)
    func mnemonicToSeed(_ mnemonic: String, passphrase: String = "") -> Data? {
        let mnemonicData = mnemonic.decomposedStringWithCompatibilityMapping.data(using: .utf8)!
        let salt = ("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.data(using: .utf8)!

        // PBKDF2 with 2048 iterations
        return pbkdf2(password: mnemonicData, salt: salt, iterations: 2048, keyLength: 64)
    }

    // MARK: - Private Helpers

    private func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data? {
        var derivedKey = Data(count: keyLength)

        let result = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        return result == kCCSuccess ? derivedKey : nil
    }

    /// Load bundled english.txt word list
    private func loadBundledWordList() -> [String]? {
        guard let url = Bundle.main.url(forResource: "english", withExtension: "txt") else {
            return nil
        }
        guard let content = try? String(contentsOf: url) else { return nil }
        let words = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return words.count == 2048 ? words : nil
    }

    /// Check if full word list is loaded
    var isFullWordListLoaded: Bool {
        return wordList.count == 2048
    }

    /// Get word at index
    func getWord(at index: Int) -> String? {
        guard index >= 0 && index < wordList.count else { return nil }
        return wordList[index]
    }

    /// Get index of word
    func getIndex(of word: String) -> Int? {
        return wordList.firstIndex(of: word.lowercased())
    }
}

// Import CommonCrypto for PBKDF2
import CommonCrypto
