import Foundation

/// KSPT ("Kaspa Signable Partial Transaction") — the compact binary transport format KasSigner's
/// firmware scans/displays for air-gapped signing. Verified against KasSigner's own source
/// (`bootloader/src/wallet/pskt.rs`, `kassee/src/kspt.rs`) — field order and widths below must
/// match exactly, or the device either rejects the QR outright or (worse) silently misparses it.
/// Port of the Android client's `KsptCodec.kt`, same wire format.
///
/// Wire layout (all multi-byte integers little-endian):
/// ```
/// Header:  magic(4)="KSPT"  version(1)=0x01  flags(1) [bit0: signed, bit1: has redeem script]
/// Global:  txVersion(2)  numInputs(1)  numOutputs(1)  lockTime(8)  subnetworkId(20)  gas(8)
///          payloadLen(2)  payload(payloadLen)
/// Input:   prevTxId(32)  prevIndex(4)  amount(8)  sequence(8)  sigOpCount(1)
///          spkVersion(2)  spkLen(1)  spkScript(spkLen)
///          [if signed: sigLen(1)  signature(sigLen)  sighashType(1)]
/// Output:  value(8)  spkVersion(2)  spkLen(1)  spkScript(spkLen)
/// ```
/// KaChat only ever produces/consumes plain single-sig (flags bit1 unset) — the multisig/redeem-
/// script variant (KSPT v2) exists in KasSigner but isn't something this app builds or needs to
/// parse.
enum KsptCodec {
    static let magic: [UInt8] = [0x4B, 0x53, 0x50, 0x54] // "KSPT"
    private static let version: UInt8 = 0x01
    private static let flagSigned: UInt8 = 0x01
    private static let flagHasRedeemScript: UInt8 = 0x02

    static let maxInputs = 8
    static let maxOutputs = 4

    /// Starts with the 4-byte "KSPT" magic — the same check KasSigner's own frame-0 detector uses.
    static func looksLikeKspt(_ bytes: Data) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == magic
    }

    struct UnsignedInput {
        let prevTxId: String // 64 hex chars
        let prevIndex: UInt32
        let amountSompi: UInt64
        let sequence: UInt64
        let sigOpCount: UInt8
        let spkVersion: UInt16
        let spkScriptHex: String
    }

    struct UnsignedOutput {
        let valueSompi: UInt64
        let spkVersion: UInt16
        let spkScriptHex: String
    }

    enum KsptError: LocalizedError {
        case invalidInputCount(Int)
        case invalidOutputCount(Int)
        case payloadTooLarge(Int)
        case badHexLength(String, Int, Int)
        case scriptTooLarge(Int)
        case badMagic
        case unsupportedVersion(UInt8)
        case multisigUnsupported
        case truncated

        var errorDescription: String? {
            switch self {
            case .invalidInputCount(let n): return "KSPT supports 1-\(maxInputs) inputs, got \(n)"
            case .invalidOutputCount(let n): return "KSPT supports 1-\(maxOutputs) outputs, got \(n)"
            case .payloadTooLarge(let n): return "KSPT payload must be <=128 bytes, got \(n)"
            case .badHexLength(let field, let expected, let got): return "\(field) must be \(expected) bytes, got \(got)"
            case .scriptTooLarge(let n): return "scriptPublicKey must be <=64 bytes, got \(n)"
            case .badMagic: return "Not a KSPT payload (bad magic)"
            case .unsupportedVersion(let v): return "Unsupported KSPT version \(v)"
            case .multisigUnsupported: return "Multisig/redeem-script KSPT isn't supported"
            case .truncated: return "KSPT payload is truncated"
            }
        }
    }

    /// Builds the unsigned KSPT bytes for the given transaction shape. Doesn't take a
    /// `KaspaRpcTransaction` directly — its inputs alone have no UTXO amount or scriptPublicKey
    /// (those live on the selected UTXO list, not the tx itself), so callers assemble
    /// `UnsignedInput`/`UnsignedOutput` from their selection result instead of this function
    /// re-deriving it.
    static func encodeUnsigned(
        txVersion: UInt16,
        lockTime: UInt64,
        subnetworkIdHex: String,
        gas: UInt64,
        payloadHex: String?,
        inputs: [UnsignedInput],
        outputs: [UnsignedOutput]
    ) throws -> Data {
        guard (1...maxInputs).contains(inputs.count) else { throw KsptError.invalidInputCount(inputs.count) }
        guard (1...maxOutputs).contains(outputs.count) else { throw KsptError.invalidOutputCount(outputs.count) }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(version)
        out.append(0x00) // unsigned, no redeem script

        let payloadBytes = payloadHex.flatMap { Data(hexString: $0) } ?? Data()
        guard payloadBytes.count <= 128 else { throw KsptError.payloadTooLarge(payloadBytes.count) }

        out.appendU16LE(txVersion)
        out.append(UInt8(inputs.count))
        out.append(UInt8(outputs.count))
        out.appendU64LE(lockTime)
        guard let subnetworkBytes = Data(hexString: subnetworkIdHex), subnetworkBytes.count == 20 else {
            throw KsptError.badHexLength("subnetworkId", 20, Data(hexString: subnetworkIdHex)?.count ?? -1)
        }
        out.append(subnetworkBytes)
        out.appendU64LE(gas)
        out.appendU16LE(UInt16(payloadBytes.count))
        out.append(payloadBytes)

        for input in inputs {
            guard let txIdBytes = Data(hexString: input.prevTxId), txIdBytes.count == 32 else {
                throw KsptError.badHexLength("prevTxId", 32, Data(hexString: input.prevTxId)?.count ?? -1)
            }
            out.append(txIdBytes)
            out.appendU32LE(input.prevIndex)
            out.appendU64LE(input.amountSompi)
            out.appendU64LE(input.sequence)
            out.append(input.sigOpCount)
            out.appendU16LE(input.spkVersion)
            let spkBytes = Data(hexString: input.spkScriptHex) ?? Data()
            guard spkBytes.count <= 64 else { throw KsptError.scriptTooLarge(spkBytes.count) }
            out.append(UInt8(spkBytes.count))
            out.append(spkBytes)
        }

        for output in outputs {
            out.appendU64LE(output.valueSompi)
            out.appendU16LE(output.spkVersion)
            let spkBytes = Data(hexString: output.spkScriptHex) ?? Data()
            guard spkBytes.count <= 64 else { throw KsptError.scriptTooLarge(spkBytes.count) }
            out.append(UInt8(spkBytes.count))
            out.append(spkBytes)
        }

        return out
    }

    struct DecodedInput {
        let prevTxId: String
        let prevIndex: UInt32
        let amountSompi: UInt64
        let sequence: UInt64
        let sigOpCount: UInt8
        let spkVersion: UInt16
        let spkScriptHex: String
        // Present only when the payload is a signed response (flags bit0 set) and this input was
        // actually signed (sigLen > 0) — a still-unsigned input in a partially-signed response
        // round-trips with signatureHex=nil.
        let signatureHex: String?
        let sighashType: UInt8?
    }

    struct DecodedOutput {
        let valueSompi: UInt64
        let spkVersion: UInt16
        let spkScriptHex: String
    }

    struct Decoded {
        let signed: Bool
        let txVersion: UInt16
        let lockTime: UInt64
        let subnetworkIdHex: String
        let gas: UInt64
        let payloadHex: String
        let inputs: [DecodedInput]
        let outputs: [DecodedOutput]
    }

    static func decode(_ bytes: Data) throws -> Decoded {
        guard looksLikeKspt(bytes) else { throw KsptError.badMagic }
        var reader = ByteReader(bytes)
        reader.skip(4) // magic

        let ver = try reader.readU8()
        guard ver == version else { throw KsptError.unsupportedVersion(ver) }
        let flags = try reader.readU8()
        let signed = flags & flagSigned != 0
        guard flags & flagHasRedeemScript == 0 else { throw KsptError.multisigUnsupported }

        let txVersion = try reader.readU16LE()
        let numInputs = Int(try reader.readU8())
        let numOutputs = Int(try reader.readU8())
        guard (1...maxInputs).contains(numInputs) else { throw KsptError.invalidInputCount(numInputs) }
        guard (1...maxOutputs).contains(numOutputs) else { throw KsptError.invalidOutputCount(numOutputs) }
        let lockTime = try reader.readU64LE()
        let subnetworkBytes = try reader.readBytes(20)
        let gas = try reader.readU64LE()
        let payloadLen = Int(try reader.readU16LE())
        guard payloadLen <= 128 else { throw KsptError.payloadTooLarge(payloadLen) }
        let payloadBytes = try reader.readBytes(payloadLen)

        var inputs: [DecodedInput] = []
        for _ in 0..<numInputs {
            let txIdBytes = try reader.readBytes(32)
            let prevIndex = try reader.readU32LE()
            let amount = try reader.readU64LE()
            let sequence = try reader.readU64LE()
            let sigOpCount = try reader.readU8()
            let spkVersion = try reader.readU16LE()
            let spkLen = Int(try reader.readU8())
            guard spkLen <= 64 else { throw KsptError.scriptTooLarge(spkLen) }
            let spkBytes = try reader.readBytes(spkLen)

            var sigHex: String?
            var sighashType: UInt8?
            if signed {
                let sigLen = Int(try reader.readU8())
                guard sigLen <= 64 else { throw KsptError.scriptTooLarge(sigLen) }
                if sigLen > 0 {
                    let sigBytes = try reader.readBytes(sigLen)
                    sigHex = sigBytes.hexString
                    sighashType = try reader.readU8()
                }
            }

            inputs.append(DecodedInput(
                prevTxId: txIdBytes.hexString,
                prevIndex: prevIndex,
                amountSompi: amount,
                sequence: sequence,
                sigOpCount: sigOpCount,
                spkVersion: spkVersion,
                spkScriptHex: spkBytes.hexString,
                signatureHex: sigHex,
                sighashType: sighashType
            ))
        }

        var outputs: [DecodedOutput] = []
        for _ in 0..<numOutputs {
            let value = try reader.readU64LE()
            let spkVersion = try reader.readU16LE()
            let spkLen = Int(try reader.readU8())
            guard spkLen <= 64 else { throw KsptError.scriptTooLarge(spkLen) }
            let spkBytes = try reader.readBytes(spkLen)
            outputs.append(DecodedOutput(valueSompi: value, spkVersion: spkVersion, spkScriptHex: spkBytes.hexString))
        }

        return Decoded(
            signed: signed,
            txVersion: txVersion,
            lockTime: lockTime,
            subnetworkIdHex: subnetworkBytes.hexString,
            gas: gas,
            payloadHex: payloadBytes.hexString,
            inputs: inputs,
            outputs: outputs
        )
    }
}

/// Minimal little-endian byte cursor used only by KsptCodec.decode.
private struct ByteReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }

    mutating func skip(_ count: Int) { offset += count }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= bytes.count else { throw KsptCodec.KsptError.truncated }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    mutating func readU8() throws -> UInt8 {
        guard offset < bytes.count else { throw KsptCodec.KsptError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readU16LE() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[b.startIndex]) | (UInt16(b[b.startIndex + 1]) << 8)
    }

    mutating func readU32LE() throws -> UInt32 {
        let b = try readBytes(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[b.startIndex + i]) << (8 * i) }
        return v
    }

    mutating func readU64LE() throws -> UInt64 {
        let b = try readBytes(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[b.startIndex + i]) << (8 * i) }
        return v
    }
}

private extension Data {
    mutating func appendU16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendU32LE(_ value: UInt32) {
        for i in 0..<4 { append(UInt8((value >> (8 * i)) & 0xFF)) }
    }

    mutating func appendU64LE(_ value: UInt64) {
        for i in 0..<8 { append(UInt8((value >> (8 * i)) & 0xFF)) }
    }
}
