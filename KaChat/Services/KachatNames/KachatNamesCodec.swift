import Foundation

/// `.kachat` names on Kaspa covenants: the transaction core (design: KACHAT_NAMES.md, byte-level
/// reference: kachat-domains/README.md, source of truth: the kachat-domains Rust harness and CLI).
///
/// Everything in `KachatNames` except `KachatNamesService` is pure value code (Foundation, BLAKE3,
/// BLAKE2b): codecs, the manifest, the version-1 transaction with its hashes and masses, and the
/// builders. It is checked byte for byte against `KaChatTests/KachatNamesVectors.json`, written by
/// the kachat-domains `kachat-names-vectors` generator from the CLI's own builders.
enum KachatNames {

    /// Errors the core throws. Messages are for logs and developer UI; the screens map them.
    struct Failure: LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }

        /// The manifest describes an earlier registry (v1 or v2): this app builds for registry v3
        /// (the price record, seller-bound offers, periodMs) and waits for its genesis manifest.
        /// Not an error to show as one: the screens say the registry is being set up.
        static let outdatedRegistry = Failure("manifest: an earlier registry; this app needs the registry v3 manifest (new genesis pending)")
        var isOutdatedRegistry: Bool { self == Failure.outdatedRegistry }
    }

    // MARK: - Constants (rusty-kaspa a41a333, kachat-domains params)

    static let sompiPerKas: UInt64 = 100_000_000
    /// A mainnet period. Registry v3 reads the period from the manifest (`Params.periodMs`):
    /// testnet-10 runs a 10-minute clock.
    static let yearMs: Int64 = 31_536_000_000
    /// rusty-kaspa `LOCK_TIME_THRESHOLD`: lock times below it are DAA scores, above unix ms.
    static let lockTimeThreshold: UInt64 = 500_000_000_000
    /// `"kachat-commit:v1"`, the commit hash domain.
    static let commitDomain = Data("kachat-commit:v1".utf8)
    /// Value of a commit UTXO (returned at registration).
    static let commitValue: UInt64 = 20_000_000
    /// Change below this is not worth a UTXO (its storage mass alone would outweigh it).
    static let minChange: UInt64 = 20_000_000
    /// The builders aim for at least this much change.
    static let targetChange: UInt64 = 100_000_000
    /// Relay floor after Toccata: 100 sompi per gram of max(compute, normalized transient).
    static let minFeerate: Double = 100.0
    /// register, extend and renew sum at most 8 inputs and 8 outputs (the contracts' bounded loops).
    static let maxInputsFeeEntry = 8
    /// Every other operation: keep transactions small anyway.
    static let maxInputs = 24
    /// The highest listing price the name contract accepts.
    static let maxListPrice: UInt64 = 2_900_000_000_000_000_000
    static let zero32 = Data(repeating: 0, count: 32)
    static let ff32 = Data(repeating: 0xff, count: 32)
    static let sighashAll: UInt8 = 0x01

    // MARK: - Hex

    static func hex(_ data: Data) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return out
    }

    static func unhex(_ string: String) throws -> Data {
        let chars = Array(string.utf8)
        guard chars.count % 2 == 0 else { throw Failure("odd-length hex") }
        func nibble(_ c: UInt8) throws -> UInt8 {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: throw Failure("bad hex digit")
            }
        }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            out.append(try nibble(chars[i]) << 4 | nibble(chars[i + 1]))
            i += 2
        }
        return out
    }

    static func unhex32(_ string: String) throws -> Data {
        let d = try unhex(string)
        guard d.count == 32 else { throw Failure("expected 32 hex bytes") }
        return d
    }

    // MARK: - Little-endian helpers

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }) }
    static func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) }) }

    // MARK: - Hashes

    static func blake3(_ data: Data) -> Data { Blake3.hash(data) }

    /// Unkeyed BLAKE2b-256 (the P2SH script hash).
    static func blake2b256(_ data: Data) -> Data {
        var h = Blake2b(digestLength: 32, key: nil)
        h.update(data)
        return h.finalize()
    }

    /// rusty-kaspa `blake2b_hasher!` (keyed BLAKE2b-256, the domain string as the key).
    static func blake2bKeyed(_ domain: String, _ data: Data) -> Data {
        var h = Blake2b(digestLength: 32, key: Data(domain.utf8))
        h.update(data)
        return h.finalize()
    }

    /// rusty-kaspa `blake3_hasher!` (keyed BLAKE3, the domain string zero padded to 32 bytes).
    static func blake3Keyed(_ domain: String, _ data: Data) -> Data {
        var h = Blake3(domain: domain)
        h.update(data)
        return h.finalize()
    }

    // MARK: - Names

    enum Codec {
        /// What a person types, made canonical: trimmed, lowercased, `.kachat` dropped.
        static func normalize(_ raw: String) -> String {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s.hasSuffix(".kachat") { s.removeLast(".kachat".count) }
            return s
        }

        /// The gap's rule: `a-z 0-9 -`, 1..32 bytes, no hyphen at either end.
        static func validate(_ name: String) throws {
            let b = Array(name.utf8)
            guard !b.isEmpty, b.count <= 32 else { throw Failure("a name is 1..32 characters") }
            for c in b {
                let ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d
                guard ok else { throw Failure("a name is a-z, 0-9 and '-' only") }
            }
            guard b.first != 0x2d, b.last != 0x2d else { throw Failure("a name cannot start or end with '-'") }
        }

        static func isValid(_ name: String) -> Bool { (try? validate(name)) != nil }

        /// `key = blake3(name)`.
        static func key(_ name: String) -> Data { KachatNames.blake3(Data(name.utf8)) }

        /// The name zero padded to 32 bytes (the name state field).
        static func padded(_ name: String) -> Data {
            var d = Data(name.utf8.prefix(32))
            d.append(Data(repeating: 0, count: 32 - d.count))
            return d
        }

        /// The name in a padded field (bytes up to the first zero).
        static func unpadded(_ field: Data) -> String {
            let bytes = field.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// Price tier index for a name of `length` bytes: 1, 2, 3, 4, 5+.
        static func tier(_ length: Int) -> Int { min(max(length, 1), 5) - 1 }

        // MARK: Commit

        /// `blake3("kachat-commit:v1" || name || ownerKey || salt)`.
        static func commitment(name: String, owner: Data, salt: Data) -> Data {
            var h = Blake3()
            h.update(KachatNames.commitDomain)
            h.update(Data(name.utf8))
            h.update(owner)
            h.update(salt)
            return h.finalize()
        }

        /// `0x20 <c> OP_DROP 0x20 <ownerKey> OP_CHECKSIG` (68 bytes).
        static func commitRedeem(commitment c: Data, owner: Data) -> Data {
            var d = Data([0x20])
            d.append(c)
            d.append(contentsOf: [0x75, 0x20])
            d.append(owner)
            d.append(0xac)
            return d
        }

        // MARK: Integers

        /// 8-byte little-endian sign-magnitude (state ints, template part lengths).
        static func num8(_ v: Int64) -> Data {
            precondition(v != Int64.min, "num8 of Int64.min")
            var out = KachatNames.le64(v.magnitude)
            if v < 0 { out[out.startIndex + 7] |= 0x80 }
            return out
        }

        static func decodeNum8(_ d: Data) throws -> Int64 {
            guard d.count == 8 else { throw Failure("state int must be 8 bytes") }
            return try scriptNum(d)
        }

        /// Minimal script number bytes (rusty-kaspa `serialize_i64(v, None)`); empty for 0.
        static func minimalNumber(_ v: Int64) -> Data {
            precondition(v != Int64.min)
            var magnitude = v.magnitude
            var out = Data()
            while magnitude > 0 {
                out.append(UInt8(magnitude & 0xff))
                magnitude >>= 8
            }
            if let last = out.last, last & 0x80 != 0 {
                out.append(v < 0 ? 0x80 : 0x00)
            } else if v < 0 {
                out[out.endIndex - 1] |= 0x80
            }
            return out
        }

        /// Little-endian sign-magnitude bytes -> Int64.
        static func scriptNum(_ b: Data) throws -> Int64 {
            if b.isEmpty { return 0 }
            guard b.count <= 8 else { throw Failure("script number longer than 8 bytes") }
            let bytes = [UInt8](b)
            var v: UInt64 = 0
            for (k, byte) in bytes.enumerated() {
                let x = k == bytes.count - 1 ? byte & 0x7f : byte
                v |= UInt64(x) << (8 * UInt64(k))
            }
            let negative = bytes[bytes.count - 1] & 0x80 != 0
            let value = Int64(bitPattern: v)
            return negative ? -value : value
        }

        // MARK: States

        /// Gap state, 66 bytes: `0x20 lo 0x20 hi`.
        static func gapState(lo: Data, hi: Data) -> Data {
            var d = Data([0x20]); d.append(lo); d.append(0x20); d.append(hi)
            return d
        }

        /// Name state (registry v2 and v3, unchanged), 126 bytes:
        /// `0x20 key 0x20 name 0x20 owner 0x08 price 0x08 periodStart 0x08 expiresAt`
        /// (price at bytes 100..108, periodStart 109..117, expiresAt 118..126).
        static func nameState(_ f: NameFields) -> Data {
            var d = Data([0x20]); d.append(f.key)
            d.append(0x20); d.append(f.paddedName)
            d.append(0x20); d.append(f.owner)
            d.append(0x08); d.append(num8(f.price))
            d.append(0x08); d.append(num8(f.periodStart))
            d.append(0x08); d.append(num8(f.expiresAt))
            return d
        }

        /// Offer state (registry v3), 108 bytes: `0x20 key 0x20 buyer 0x20 seller 0x08 refundAfter`.
        static func offerState(_ f: OfferFields) -> Data {
            var d = Data([0x20]); d.append(f.key)
            d.append(0x20); d.append(f.buyer)
            d.append(0x20); d.append(f.seller)
            d.append(0x08); d.append(num8(f.refundAfter))
            return d
        }

        /// Price shard state (registry v3), 87 bytes: `0x08 shard 0x20 authority (0x08 price) x5`.
        static func priceState(_ f: PriceFields) -> Data {
            var d = Data([0x08]); d.append(num8(f.shard))
            d.append(0x20); d.append(f.authority)
            for p in f.prices {
                d.append(0x08); d.append(num8(Int64(p)))
            }
            return d
        }

        static func decodePriceState(_ s: Data) throws -> PriceFields {
            let b = [UInt8](s)
            guard b.count == 87, b[0] == 0x08, b[9] == 0x20 else { throw Failure("not a price state") }
            var prices: [UInt64] = []
            for t in 0..<5 {
                let at = 42 + t * 9
                guard b[at] == 0x08 else { throw Failure("not a price state") }
                let v = try decodeNum8(Data(b[(at + 1)..<(at + 9)]))
                guard v >= 0 else { throw Failure("negative price") }
                prices.append(UInt64(v))
            }
            return PriceFields(shard: try decodeNum8(Data(b[1..<9])), authority: Data(b[10..<42]), prices: prices)
        }

        static func decodeGapState(_ s: Data) throws -> (lo: Data, hi: Data) {
            let b = [UInt8](s)
            guard b.count == 66, b[0] == 0x20, b[33] == 0x20 else { throw Failure("not a gap state") }
            return (Data(b[1..<33]), Data(b[34..<66]))
        }

        static func decodeNameState(_ s: Data) throws -> NameFields {
            let b = [UInt8](s)
            guard b.count == 126, b[0] == 0x20, b[33] == 0x20, b[66] == 0x20, b[99] == 0x08, b[108] == 0x08, b[117] == 0x08 else {
                throw Failure("not a name state")
            }
            return NameFields(
                key: Data(b[1..<33]), paddedName: Data(b[34..<66]), owner: Data(b[67..<99]),
                price: try decodeNum8(Data(b[100..<108])), periodStart: try decodeNum8(Data(b[109..<117])),
                expiresAt: try decodeNum8(Data(b[118..<126]))
            )
        }

        static func decodeOfferState(_ s: Data) throws -> OfferFields {
            let b = [UInt8](s)
            guard b.count == 108, b[0] == 0x20, b[33] == 0x20, b[66] == 0x20, b[99] == 0x08 else { throw Failure("not an offer state") }
            return OfferFields(key: Data(b[1..<33]), buyer: Data(b[34..<66]), seller: Data(b[67..<99]),
                               refundAfter: try decodeNum8(Data(b[100..<108])))
        }

        // MARK: Scripts

        /// `OP_BLAKE2B <blake2b-256(redeem)> OP_EQUAL` (rusty-kaspa `pay_to_script_hash_script`).
        static func p2shScript(_ redeem: Data) -> Data {
            var d = Data([0xaa, 0x20])
            d.append(KachatNames.blake2b256(redeem))
            d.append(0x87)
            return d
        }

        /// Schnorr P2PK: `0x20 <x-only key> OP_CHECKSIG`.
        static func p2pkScript(_ xonly: Data) -> Data {
            var d = Data([0x20]); d.append(xonly); d.append(0xac)
            return d
        }

        /// The x-only key of a Schnorr P2PK script, nil for anything else.
        static func p2pkKey(_ script: Data) -> Data? {
            let b = [UInt8](script)
            guard b.count == 34, b[0] == 0x20, b[33] == 0xac else { return nil }
            return Data(b[1..<33])
        }

        /// Canonical minimal push (rusty-kaspa `ScriptBuilder::add_data`).
        static func pushData(_ data: Data) -> Data {
            let n = data.count
            if n == 0 { return Data([0x00]) }
            if n == 1 {
                let v = data[data.startIndex]
                if v >= 1 && v <= 16 { return Data([0x50 + v]) }
                if v == 0x81 { return Data([0x4f]) }
            }
            var out: Data
            if n <= 75 {
                out = Data([UInt8(n)])
            } else if n <= 0xff {
                out = Data([0x4c, UInt8(n)])
            } else if n <= 0xffff {
                out = Data([0x4d]); out.append(KachatNames.le16(UInt16(n)))
            } else {
                out = Data([0x4e]); out.append(KachatNames.le32(UInt32(n)))
            }
            out.append(data)
            return out
        }

        /// A script integer (rusty-kaspa `ScriptBuilder::add_i64`): OP_0, OP_1NEGATE, OP_1..OP_16,
        /// else a minimal sign-magnitude push.
        static func pushInt(_ v: Int64) -> Data {
            if v == 0 { return Data([0x00]) }
            if v == -1 { return Data([0x4f]) }
            if v >= 1 && v <= 16 { return Data([0x50 + UInt8(v)]) }
            return pushData(minimalNumber(v))
        }

        /// Every push of a push-only script, as bytes (OP_0 -> [], OP_n -> [n], OP_1NEGATE -> [0x81]).
        static func parsePushes(_ script: Data) throws -> [Data] {
            let s = [UInt8](script)
            var out: [Data] = []
            var i = 0
            func take(_ n: Int) throws -> Data {
                guard i + n <= s.count else { throw Failure("truncated push") }
                defer { i += n }
                return Data(s[i..<(i + n)])
            }
            while i < s.count {
                let op = s[i]
                i += 1
                switch op {
                case 0x00: out.append(Data())
                case 0x01...0x4b: out.append(try take(Int(op)))
                case 0x4c:
                    let n = Int(try take(1)[0])
                    out.append(try take(n))
                case 0x4d:
                    let l = [UInt8](try take(2))
                    out.append(try take(Int(l[0]) | Int(l[1]) << 8))
                case 0x4e:
                    let l = [UInt8](try take(4))
                    let n = Int(l[0]) | Int(l[1]) << 8 | Int(l[2]) << 16 | Int(l[3]) << 24
                    out.append(try take(n))
                case 0x4f: out.append(Data([0x81]))
                case 0x51...0x60: out.append(Data([op - 0x50]))
                default: throw Failure(String(format: "not a push-only script (opcode 0x%02x)", op))
                }
            }
            return out
        }

        // MARK: Templates and covenant ids

        /// silverscript `template_hash`: `blake3(num8(|prefix|) || prefix || num8(|suffix|) || suffix)`.
        static func templateHash(prefix: Data, suffix: Data) -> Data {
            var h = Blake3()
            h.update(num8(Int64(prefix.count)))
            h.update(prefix)
            h.update(num8(Int64(suffix.count)))
            h.update(suffix)
            return h.finalize()
        }

        /// rusty-kaspa `covenant_id(outpoint, authorized outputs)` (KIP-20).
        static func covenantId(outpoint: Outpoint, authorized: [(index: UInt32, output: TxOutput)]) -> Data {
            var d = outpoint.txid
            d.append(KachatNames.le32(outpoint.index))
            d.append(KachatNames.le64(UInt64(authorized.count)))
            for (index, o) in authorized {
                d.append(KachatNames.le32(index))
                d.append(KachatNames.le64(o.value))
                d.append(KachatNames.le16(o.scriptVersion))
                d.append(KachatNames.le64(UInt64(o.script.count)))
                d.append(o.script)
            }
            return KachatNames.blake2bKeyed("CovenantID", d)
        }

        // MARK: Payload markers (KACHAT_NAMES_INDEXER.md B4)

        /// `kchat:1:name:<op>:<name>`: informational, on every name transaction except commits.
        static func namePayload(op: String, name: String) -> Data { Data("kchat:1:name:\(op):\(name)".utf8) }

        /// `kchat:1:offer:<keyHex>:<buyerXonlyHex>:<sellerXonlyHex>:<refundAfterDaa>` (registry v3):
        /// how an indexer finds offers.
        static func offerPayload(_ f: OfferFields) -> Data {
            Data("kchat:1:offer:\(KachatNames.hex(f.key)):\(KachatNames.hex(f.buyer)):\(KachatNames.hex(f.seller)):\(f.refundAfter)".utf8)
        }

        /// `kchat:1:profile:<json>`: an address profile record (KACHAT_NAMES.md section 7).
        static func profilePayload(json: Data) -> Data {
            var d = Data("kchat:1:profile:".utf8)
            d.append(json)
            return d
        }

        static let maxProfileJSONBytes = 2048
    }

    // MARK: - Typed states

    struct NameFields: Equatable {
        var key: Data
        var paddedName: Data
        var owner: Data
        var price: Int64
        /// unix ms, the start of the current paid period (registry v2): register sets it to `now`,
        /// `renew` to the old expiry; every other entry keeps it.
        var periodStart: Int64
        var expiresAt: Int64

        init(key: Data, paddedName: Data, owner: Data, price: Int64, periodStart: Int64, expiresAt: Int64) {
            self.key = key
            self.paddedName = paddedName
            self.owner = owner
            self.price = price
            self.periodStart = periodStart
            self.expiresAt = expiresAt
        }

        init(name: String, owner: Data, price: Int64, periodStart: Int64, expiresAt: Int64) {
            self.init(key: Codec.key(name), paddedName: Codec.padded(name), owner: owner, price: price,
                      periodStart: periodStart, expiresAt: expiresAt)
        }

        var name: String { Codec.unpadded(paddedName) }
        var encoded: Data { Codec.nameState(self) }

        /// transfer / buy / offer accept: new owner, listing cleared, period and expiry kept.
        func withOwner(_ owner: Data) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: 0, periodStart: periodStart, expiresAt: expiresAt)
        }

        /// list: the price, period and expiry kept.
        func withPrice(_ price: Int64) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: price, periodStart: periodStart, expiresAt: expiresAt)
        }

        /// What `extend(years)` leaves: the same period start, the expiry `years` periods later.
        func extended(_ years: Int64, periodMs: Int64) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: price, periodStart: periodStart,
                       expiresAt: expiresAt + years * periodMs)
        }

        /// What `renew(years)` leaves: a new period from the old expiry, so no time is lost or gained.
        func renewed(_ years: Int64, periodMs: Int64) -> NameFields {
            NameFields(key: key, paddedName: paddedName, owner: owner, price: price, periodStart: expiresAt,
                       expiresAt: expiresAt + years * periodMs)
        }
    }

    struct OfferFields: Equatable {
        var key: Data
        var buyer: Data
        /// The name's owner the offer was made to (registry v3): only they can accept or decline it.
        var seller: Data
        var refundAfter: Int64
        var encoded: Data { Codec.offerState(self) }
    }

    /// A price shard's state (registry v3).
    struct PriceFields: Equatable {
        var shard: Int64
        var authority: Data
        /// sompi per period for names of 1, 2, 3, 4, 5+ bytes (registering and renewing)
        var prices: [UInt64]
        var encoded: Data { Codec.priceState(self) }

        func price(forLength n: Int) -> UInt64 { prices[Codec.tier(n)] }
    }
}
