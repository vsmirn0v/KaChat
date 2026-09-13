import XCTest
import P256K
@testable import KaChat

/// Regression tests for the code that encrypts, addresses and routes messages and money.
///
/// The app shipped for a long time with no test target at all: a regression in the cipher, the
/// alias derivation or the address codec was caught only by a person noticing. These pin the
/// invariants a person is least likely to notice - a nonce reused, an alias pair that no longer
/// meets in the middle, a checksum accepted when it should not be, a placeholder leaking into a
/// chat-list preview - and the ones that would fail loudly for every user if they broke.
///
/// Adding the target: File > New > Target > Unit Testing Bundle, product name `KaChatTests`,
/// host application KaChat. Delete the template test file it generates and add this one to the
/// new target. Run with Cmd-U.
final class KaChatCoreTests: XCTestCase {

    // MARK: - Helpers

    /// A keypair whose public key has an even Y coordinate. A Kaspa address carries only the
    /// x coordinate, so everything that starts from an address - the alias derivation, the
    /// cipher's 32-byte path - assumes even Y, as BIP-340 does. Real wallets guarantee it; a
    /// random key is odd half the time, so the helper regenerates until it matches.
    private func makeEvenYKeyPair() throws -> (privateKey: Data, compressedPublicKey: Data, xOnly: Data) {
        for _ in 0..<64 {
            let key = try P256K.KeyAgreement.PrivateKey()
            let raw = key.publicKey.dataRepresentation
            let xOnly: Data
            let isEven: Bool
            if raw.count == 33 {
                xOnly = Data(raw.dropFirst())
                isEven = raw[raw.startIndex] == 0x02
            } else if raw.count == 65 {
                xOnly = Data(raw[(raw.startIndex + 1)..<(raw.startIndex + 33)])
                isEven = (raw[raw.endIndex - 1] & 1) == 0
            } else {
                continue
            }
            if isEven {
                return (key.dataRepresentation, Data([0x02]) + xOnly, xOnly)
            }
        }
        throw XCTSkip("Could not produce an even-Y key in 64 attempts")
    }

    private func address(forXOnly xOnly: Data) throws -> String {
        try XCTUnwrap(Bech32.encode(hrp: "kaspa", version: 0, data: xOnly))
    }

    private func message(
        _ content: String,
        at seconds: TimeInterval,
        outgoing: Bool = false,
        type: ChatMessage.MessageType = .contextual,
        status: ChatMessage.DeliveryStatus = .sent
    ) -> ChatMessage {
        ChatMessage(
            txId: UUID().uuidString,
            senderAddress: "kaspa:sender",
            receiverAddress: "kaspa:receiver",
            content: content,
            timestamp: Date(timeIntervalSince1970: seconds),
            blockTime: UInt64(seconds * 1000),
            isOutgoing: outgoing,
            messageType: type,
            deliveryStatus: status
        )
    }

    // MARK: - Cipher

    func testCipherRoundTripsThroughBothPublicKeyForms() throws {
        let pair = try makeEvenYKeyPair()
        let plaintext = "hello, kaspa — 🚀"

        let viaCompressed = try KasiaCipher.encrypt(plaintext, recipientPublicKey: pair.compressedPublicKey)
        XCTAssertEqual(try KasiaCipher.decrypt(viaCompressed, privateKey: pair.privateKey), plaintext)

        // An address only carries the x coordinate, so this is the path every real send takes.
        let viaXOnly = try KasiaCipher.encrypt(plaintext, recipientPublicKey: pair.xOnly)
        XCTAssertEqual(try KasiaCipher.decrypt(viaXOnly, privateKey: pair.privateKey), plaintext)
    }

    func testCipherUsesAFreshNonceAndEphemeralKeyPerMessage() throws {
        let pair = try makeEvenYKeyPair()
        let first = try KasiaCipher.encrypt("same text", recipientPublicKey: pair.compressedPublicKey)
        let second = try KasiaCipher.encrypt("same text", recipientPublicKey: pair.compressedPublicKey)

        // Nonce reuse under one key is the classic AEAD failure; a repeated ephemeral key would
        // mean the same shared secret twice. Either equality here is a real bug.
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertNotEqual(first.ephemeralPublicKey, second.ephemeralPublicKey)
        XCTAssertNotEqual(first.ciphertext, second.ciphertext)
        XCTAssertEqual(first.nonce.count, 12)
    }

    func testCipherRejectsTamperedCiphertext() throws {
        let pair = try makeEvenYKeyPair()
        let sealed = try KasiaCipher.encrypt("do not touch", recipientPublicKey: pair.compressedPublicKey)

        var tampered = sealed.ciphertext
        tampered[tampered.startIndex] ^= 0x01
        let forged = KasiaCipher.EncryptedMessage(
            nonce: sealed.nonce,
            ephemeralPublicKey: sealed.ephemeralPublicKey,
            ciphertext: tampered
        )
        XCTAssertThrowsError(try KasiaCipher.decrypt(forged, privateKey: pair.privateKey),
                             "a flipped ciphertext byte must fail the authentication tag, not decrypt to garbage")
    }

    func testCipherRejectsTheWrongPrivateKey() throws {
        let recipient = try makeEvenYKeyPair()
        let stranger = try makeEvenYKeyPair()
        let sealed = try KasiaCipher.encrypt("for one reader", recipientPublicKey: recipient.compressedPublicKey)
        XCTAssertThrowsError(try KasiaCipher.decrypt(sealed, privateKey: stranger.privateKey))
    }

    // MARK: - Deterministic aliases

    func testAliasPairMeetsInTheMiddle() throws {
        let alice = try makeEvenYKeyPair()
        let bob = try makeEvenYKeyPair()
        let aliceAddress = try address(forXOnly: alice.xOnly)
        let bobAddress = try address(forXOnly: bob.xOnly)

        // The alias Alice puts on messages TO Bob must be the alias Bob watches FOR Alice, or
        // messages are sent to a mailbox nobody reads. Each side derives its half independently
        // from its own private key and the other's address.
        let aliceSendsWith = try DeterministicAlias.deriveTheirAlias(privateKey: alice.privateKey, theirAddress: bobAddress)
        let bobWatchesFor = try DeterministicAlias.deriveMyAlias(privateKey: bob.privateKey, theirAddress: aliceAddress)
        XCTAssertEqual(aliceSendsWith, bobWatchesFor)

        let bobSendsWith = try DeterministicAlias.deriveTheirAlias(privateKey: bob.privateKey, theirAddress: aliceAddress)
        let aliceWatchesFor = try DeterministicAlias.deriveMyAlias(privateKey: alice.privateKey, theirAddress: bobAddress)
        XCTAssertEqual(bobSendsWith, aliceWatchesFor)

        // The two directions are distinct aliases, twelve lowercase hex characters each.
        XCTAssertNotEqual(aliceSendsWith, bobSendsWith)
        for alias in [aliceSendsWith, bobSendsWith] {
            XCTAssertEqual(alias.count, 12)
            XCTAssertNotNil(alias.range(of: "^[0-9a-f]{12}$", options: .regularExpression))
        }
    }

    func testAliasDerivationRejectsAMalformedAddress() throws {
        let alice = try makeEvenYKeyPair()
        XCTAssertThrowsError(try DeterministicAlias.deriveMyAlias(privateKey: alice.privateKey, theirAddress: "kaspa:notanaddress"))
    }

    // MARK: - Address codec

    func testBech32RoundTripsAndValidates() throws {
        let pair = try makeEvenYKeyPair()
        let encoded = try address(forXOnly: pair.xOnly)

        XCTAssertTrue(encoded.hasPrefix("kaspa:"))
        XCTAssertTrue(CryptoUtils.isValidKaspaAddress(encoded))

        let decoded = try XCTUnwrap(Bech32.decode(encoded))
        XCTAssertEqual(decoded.hrp, "kaspa")
        XCTAssertEqual(decoded.version, 0)
        XCTAssertEqual(decoded.data, pair.xOnly)
        XCTAssertEqual(KaspaAddress.publicKey(from: encoded), pair.xOnly)
    }

    func testBech32RejectsACorruptedChecksum() throws {
        let pair = try makeEvenYKeyPair()
        var characters = Array(try address(forXOnly: pair.xOnly))
        // Swap the last two payload characters: the bech32 charset is a permutation, so the
        // result is still well-formed text, and only the checksum can tell it is wrong.
        let last = characters.count - 1
        characters.swapAt(last, last - 1)
        let corrupted = String(characters)
        guard corrupted != String(Array(try address(forXOnly: pair.xOnly))) else {
            throw XCTSkip("the last two characters happened to be equal")
        }
        XCTAssertNil(Bech32.decode(corrupted))
        XCTAssertFalse(CryptoUtils.isValidKaspaAddress(corrupted))
    }

    // MARK: - Hashing

    func testBlake2b256OfEmptyInputMatchesTheReferenceVector() {
        // BLAKE2b-256(""), the value every implementation is checked against.
        let digest = Blake2b.hash(Data(), digestLength: 32)
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(),
                       "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
    }

    func testBlake2bHonorsDigestLengthAndKey() {
        let input = Data("kaspa".utf8)
        XCTAssertEqual(Blake2b.hash(input, digestLength: 32).count, 32)
        XCTAssertEqual(Blake2b.hash(input, digestLength: 64).count, 64)
        XCTAssertEqual(Blake2b.hash(input, digestLength: 32), Blake2b.hash(input, digestLength: 32))
        // Kaspa domain-separates its hashes with a key (e.g. the transaction signing hash); a
        // keyed digest must differ from the unkeyed one, or the separation is not happening.
        XCTAssertNotEqual(Blake2b.hash(input, digestLength: 32, key: "TransactionSigningHash"),
                          Blake2b.hash(input, digestLength: 32))
    }

    // MARK: - Seed phrases

    func testBIP39MatchesTheReferenceVectorAndRejectsABadChecksum() throws {
        let bip39 = BIP39()
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        XCTAssertTrue(bip39.validateMnemonic(mnemonic))

        // The first vector from the BIP-39 reference set, passphrase TREZOR.
        let seed = try XCTUnwrap(bip39.mnemonicToSeed(mnemonic, passphrase: "TREZOR"))
        XCTAssertEqual(seed.map { String(format: "%02x", $0) }.joined(),
                       "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")

        // Same words, last one changed: valid vocabulary, invalid checksum.
        XCTAssertFalse(bip39.validateMnemonic(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"))
    }

    // MARK: - Translation offer

    func testShortRepliesInAnotherLanguageAreDetected() {
        // A real reply that showed no Translate link: eleven letters, one short of the old hard
        // floor, though the recognizer scores it Vietnamese at 1.00.
        XCTAssertEqual(PostTranslationService.detectedLanguage(of: "đang rất hóng")?.languageCode?.identifier, "vi")
        // Short non-Latin text never needed a floor; the script answers by itself.
        XCTAssertEqual(PostTranslationService.detectedLanguage(of: "ありがとう")?.languageCode?.identifier, "ja")
        XCTAssertEqual(PostTranslationService.detectedLanguage(of: "спасибо")?.languageCode?.identifier, "ru")
        XCTAssertEqual(PostTranslationService.detectedLanguage(of: "danke schön")?.languageCode?.identifier, "de")
        // What the floors are for: a coin-flip and a two-letter greeting stay unidentified.
        XCTAssertNil(PostTranslationService.detectedLanguage(of: "gm"))
        XCTAssertNil(PostTranslationService.detectedLanguage(of: "🚀🚀🚀"))
    }

    // MARK: - Conversation model

    func testLastMessageSkipsPlaceholdersAndFollowsWrites() {
        let contact = Contact(address: "kaspa:contact")
        var conversation = Conversation(contact: contact, messages: [
            message("older", at: 100),
            message("newest real", at: 200),
            message(ChatMessage.sentViaOtherDevicePlaceholder, at: 300),
        ])

        // A cross-device placeholder is the newest row but must never be the preview.
        XCTAssertEqual(conversation.lastMessage?.content, "newest real")

        conversation.messages.append(message("appended", at: 400))
        XCTAssertEqual(conversation.lastMessage?.content, "appended", "the cached value must follow a write to messages")

        conversation.messages = [message(ChatMessage.sentViaOtherDevicePlaceholder, at: 500)]
        XCTAssertNil(conversation.lastMessage, "a conversation holding only placeholders reads as empty")
    }

    func testMemoryWindowKeepsHandshakesAndTheNewestMessages() {
        let window = ChatService.inMemoryConversationWindowSize
        var messages: [ChatMessage] = []
        // Three handshakes at the very start - protocol-critical, and the oldest things here.
        for i in 0..<3 {
            messages.append(message("handshake \(i)", at: TimeInterval(i), type: .handshake))
        }
        for i in 0..<(window + 40) {
            messages.append(message("msg \(i)", at: TimeInterval(1000 + i)))
        }

        let trimmed = ChatService.trimMessagesForMemory(messages)

        XCTAssertEqual(trimmed.filter { $0.messageType == .handshake }.count, 3,
                       "handshakes are exempt from the window however old they are")
        XCTAssertEqual(trimmed.filter { $0.messageType != .handshake }.count, window)
        XCTAssertEqual(trimmed.last?.content, "msg \(window + 39)", "the newest message survives")
        XCTAssertFalse(trimmed.contains { $0.content == "msg 0" }, "the oldest regular message is dropped")
        XCTAssertEqual(trimmed, trimmed.sorted(by: ChatService.isMessageOrderedBefore), "order is preserved")
    }
}
