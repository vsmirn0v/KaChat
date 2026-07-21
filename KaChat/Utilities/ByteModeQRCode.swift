import Foundation
import CoreImage
import UIKit

/// Encodes/decodes raw binary QR codes in pure ISO/IEC 18004 byte mode, matching exactly what
/// KasSigner's firmware itself produces/expects (`bootloader/src/qr/encoder.rs`: versions 1-6,
/// error correction level L, single byte-mode segment, no smart segmentation).
///
/// This does NOT use `CIFilter.qrCodeGenerator`/`CIDetector.messageString` — both were verified
/// (via standalone round-trip testing before this shipped) to be unsuitable for arbitrary binary:
/// the high-level generator silently re-segments input data (mixing in numeric/alphanumeric mode
/// for byte runs that happen to look like digits), and the high-level decoded "message string" is
/// built via a path that truncates at embedded 0x00 bytes — fatal for a binary protocol like KSPT
/// whose fields (locktime, subnetwork id, sequence, etc.) are routinely all-zero. Instead this
/// talks to the lower-level `CIQRCodeDescriptor`/`CIBarcodeGenerator` API directly, which exposes
/// the exact pre-segmentation/post-error-correction codeword stream (see Apple's own doc comment
/// on `errorCorrectedPayload`: "re-ordered to the state immediately following 'Bitstream to
/// codeword conversion'" — i.e. the linear bit stream this code parses).
enum ByteModeQRCode {
    /// KasSigner's own version table (`qr/encoder.rs` VERSION_TABLE), byte-mode capacity at ECC
    /// level L. KaChat only ever needs to encode within this range since QrFrameChunker's frame
    /// sizes were chosen to fit it.
    private static let dataCodewordsByVersion: [Int: Int] = [1: 19, 2: 34, 3: 55, 4: 80, 5: 108, 6: 136]
    private static let byteCapacityByVersion: [Int: Int] = [1: 17, 2: 32, 3: 53, 4: 78, 5: 106, 6: 134]
    private static let maxSupportedVersion = 6

    enum QRError: LocalizedError {
        case tooLargeForSupportedVersions(Int)
        case descriptorCreationFailed
        case generatorUnavailable
        case renderFailed
        case badModeIndicator(Int)
        case truncated

        var errorDescription: String? {
            switch self {
            case .tooLargeForSupportedVersions(let n): return "Payload too large for a single QR frame (\(n) bytes)"
            case .descriptorCreationFailed: return "Could not build QR code descriptor"
            case .generatorUnavailable: return "QR barcode generator unavailable"
            case .renderFailed: return "Could not render QR code image"
            case .badModeIndicator(let m): return "Not a byte-mode QR segment (mode=\(m))"
            case .truncated: return "QR payload is truncated"
            }
        }
    }

    // MARK: - Encoding

    /// Renders `data` as a pure byte-mode QR image (white background, no quiet-zone margin baked
    /// in — callers add their own margin/border in SwiftUI). Picks the smallest KasSigner-
    /// supported version (1-6) that fits.
    static func generateImage(for data: Data) throws -> UIImage {
        guard let version = (1...maxSupportedVersion).first(where: { (byteCapacityByVersion[$0] ?? 0) >= data.count }) else {
            throw QRError.tooLargeForSupportedVersions(data.count)
        }
        let codewords = try buildByteModeCodewords(data, version: version)

        guard let descriptor = CIQRCodeDescriptor(
            payload: codewords,
            symbolVersion: version,
            maskPattern: 0,
            errorCorrectionLevel: .levelL
        ) else {
            throw QRError.descriptorCreationFailed
        }
        guard let generator = CIFilter(name: "CIBarcodeGenerator") else {
            throw QRError.generatorUnavailable
        }
        generator.setValue(descriptor, forKey: "inputBarcodeDescriptor")
        guard let outputImage = generator.value(forKey: "outputImage") as? CIImage else {
            throw QRError.renderFailed
        }

        // CIBarcodeGenerator only bakes in about a 1-module quiet zone (verified empirically:
        // a 25-module V2 symbol comes back with a 27x27 extent, not 33x33), well short of
        // ISO/IEC 18004's recommended 4-module quiet zone. A too-thin quiet zone is a common,
        // very plausible cause of a physical scanner (photographing this screen from a few
        // inches away, in whatever ambient light) failing to lock onto the symbol at all — pad
        // out to the full 4 modules here rather than leaving it to chance.
        let extraQuietZoneModules: CGFloat = 3
        let paddedExtent = outputImage.extent.insetBy(dx: -extraQuietZoneModules, dy: -extraQuietZoneModules)
        let background = CIImage(color: .white).cropped(to: paddedExtent)
        let withQuietZone = outputImage.composited(over: background)

        let scale: CGFloat = 10
        let scaled = withQuietZone.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw QRError.renderFailed
        }
        return UIImage(cgImage: cgImage)
    }

    /// Builds the raw byte-mode data-codeword stream (mode + count + data + terminator +
    /// padding), matching ISO/IEC 18004 section 6.4.10 "Bitstream to codeword conversion" — the
    /// same stage `CIQRCodeDescriptor.errorCorrectedPayload` corresponds to per Apple's header
    /// docs. Verified round-trip (encode here -> CIBarcodeGenerator -> CIDetector -> decode
    /// below) against binary payloads spanning every version/capacity boundary, including
    /// all-zero and all-0xFF payloads, before this shipped.
    private static func buildByteModeCodewords(_ data: Data, version: Int) throws -> Data {
        guard let capacity = dataCodewordsByVersion[version] else {
            throw QRError.tooLargeForSupportedVersions(data.count)
        }
        var writer = BitWriter()
        writer.append(0b0100, bitCount: 4) // byte mode
        let countBits = version <= 9 ? 8 : 16
        writer.append(data.count, bitCount: countBits)
        for byte in data {
            writer.append(Int(byte), bitCount: 8)
        }
        let capacityBits = capacity * 8
        let terminatorBits = max(0, min(4, capacityBits - writer.bitCount))
        if terminatorBits > 0 { writer.append(0, bitCount: terminatorBits) }
        writer.padToByteBoundary(maxBits: capacityBits)

        var bytes = writer.bytes
        guard bytes.count <= capacity else {
            throw QRError.tooLargeForSupportedVersions(data.count)
        }
        var padToggle = true
        while bytes.count < capacity {
            bytes.append(padToggle ? 0xEC : 0x11)
            padToggle.toggle()
        }
        return Data(bytes)
    }

    // MARK: - Decoding

    /// Extracts the raw byte-mode payload from a decoded QR's error-corrected codeword stream.
    static func extractPayload(errorCorrectedPayload: Data, symbolVersion: Int) throws -> Data {
        var reader = BitReader(errorCorrectedPayload)
        let mode = reader.readBits(4)
        guard mode == 0b0100 else { throw QRError.badModeIndicator(mode) }
        let countBits = symbolVersion <= 9 ? 8 : 16
        let count = reader.readBits(countBits)
        guard count >= 0 else { throw QRError.truncated }

        var out = [UInt8]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(UInt8(reader.readBits(8)))
        }
        return Data(out)
    }

    /// Extracts the raw byte-mode payload directly from a CIQRCodeFeature (still-image decode,
    /// e.g. CIDetector on a captured frame).
    static func extractPayload(from feature: CIQRCodeFeature) throws -> Data {
        guard let descriptor = feature.symbolDescriptor else {
            throw QRError.truncated
        }
        return try extractPayload(errorCorrectedPayload: descriptor.errorCorrectedPayload, symbolVersion: descriptor.symbolVersion)
    }
}

// MARK: - Bit-level helpers

private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var currentByte: UInt8 = 0
    private var bitsInCurrentByte: Int = 0
    private(set) var bitCount: Int = 0

    mutating func append(_ value: Int, bitCount count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            let bit = (value >> i) & 1
            currentByte = (currentByte << 1) | UInt8(bit)
            bitsInCurrentByte += 1
            bitCount += 1
            if bitsInCurrentByte == 8 {
                bytes.append(currentByte)
                currentByte = 0
                bitsInCurrentByte = 0
            }
        }
    }

    mutating func padToByteBoundary(maxBits: Int) {
        while bitsInCurrentByte != 0 && bitCount < maxBits {
            append(0, bitCount: 1)
        }
        if bitsInCurrentByte != 0 {
            // Ran out of capacity mid-byte (shouldn't happen given capacity checks upstream) —
            // flush what's there rather than silently dropping bits.
            bytes.append(currentByte << (8 - bitsInCurrentByte))
            currentByte = 0
            bitsInCurrentByte = 0
        }
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var bitPos: Int = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }

    mutating func readBits(_ count: Int) -> Int {
        var result = 0
        for _ in 0..<count {
            let byteIndex = bitPos / 8
            let bitIndex = 7 - (bitPos % 8)
            let bit = byteIndex < bytes.count ? Int((bytes[byteIndex] >> bitIndex) & 1) : 0
            result = (result << 1) | bit
            bitPos += 1
        }
        return result
    }
}
