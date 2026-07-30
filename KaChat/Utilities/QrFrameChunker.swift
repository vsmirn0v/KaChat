import Foundation

/// Multi-frame (animated) QR chunking, matching KasSigner's own raw-byte scheme exactly —
/// verified against `kassee/src/qr.rs` and the device firmware's `process_multiframe`/
/// `is_multiframe` (`bootloader/src/handlers/camera_loop.rs`). Fully symmetric: the same
/// chunker/dechunker works whether KaChat is sending an unsigned KSPT to the device or receiving
/// the signed one back. Port of the Android client's `QrFrameChunker.kt`, same wire format.
///
/// ```
/// <=134 bytes total: no wrapper at all — the raw payload is a single QR frame.
/// otherwise: [frameNum(1)] [totalFrames(1)] [fragLen(1)] [fragment(fragLen bytes)], balanced
///            across frames (not simply 106 bytes each except possibly the last), capped at
///            64 frames, each frame zero-padded to a minimum of 20 bytes for reliable scanning.
/// ```
enum QrFrameChunker {
    static let singleFrameMax = 134
    static let maxFrameData = 106
    static let maxFrames = 64
    private static let minFrameSize = 20
    private static let headerSize = 3

    enum ChunkError: LocalizedError {
        case payloadTooLarge(Int)
        case fragmentOverflow

        var errorDescription: String? {
            switch self {
            case .payloadTooLarge(let n): return "Payload too large to chunk into QR frames (\(n) bytes)"
            case .fragmentOverflow: return "Chunk fragment overflowed a single byte length field"
            }
        }
    }

    static func chunk(_ data: Data) throws -> [Data] {
        if data.count <= singleFrameMax { return [data] }

        let totalFrames = Int(ceil(Double(data.count) / Double(maxFrameData)))
        guard totalFrames <= maxFrames else { throw ChunkError.payloadTooLarge(data.count) }
        let perFrame = Int(ceil(Double(data.count) / Double(totalFrames)))

        var frames: [Data] = []
        var offset = 0
        let bytes = [UInt8](data)
        for frameNum in 0..<totalFrames {
            let end = min(offset + perFrame, bytes.count)
            let fragment = Array(bytes[offset..<end])
            guard fragment.count <= 255 else { throw ChunkError.fragmentOverflow }

            var frame = [UInt8]()
            frame.append(UInt8(frameNum))
            frame.append(UInt8(totalFrames))
            frame.append(UInt8(fragment.count))
            frame.append(contentsOf: fragment)
            if frame.count < minFrameSize {
                frame.append(contentsOf: [UInt8](repeating: 0, count: minFrameSize - frame.count))
            }
            frames.append(Data(frame))
            offset = end
        }
        return frames
    }

    /// Reassembles frames scanned in any order (or with duplicates/retries) as the camera happens
    /// to catch them mid-animation. `isComplete` identifies a payload that arrived as a single,
    /// unwrapped QR frame (no multi-frame header) — pass a magic-byte check like
    /// `KsptCodec.looksLikeKspt` for whatever payload type is being scanned.
    final class Accumulator {
        private let isComplete: (Data) -> Bool
        private var totalFrames: Int?
        private var received: [Int: Data] = [:]

        init(isComplete: @escaping (Data) -> Bool) {
            self.isComplete = isComplete
        }

        /// Feed one scanned frame's raw bytes. Returns the reassembled payload once every frame
        /// has arrived, else nil.
        func addFrame(_ bytes: Data) -> Data? {
            if isComplete(bytes) { return bytes }
            guard bytes.count >= QrFrameChunker.headerSize else { return nil }

            let arr = [UInt8](bytes)
            let frameNum = Int(arr[0])
            let total = Int(arr[1])
            let fragLen = Int(arr[2])
            guard (2...QrFrameChunker.maxFrames).contains(total), frameNum < total, fragLen > 0 else { return nil }
            guard arr.count >= QrFrameChunker.headerSize + fragLen else { return nil }

            // A frame from a different scan (mismatched total) — reset and start over rather
            // than silently mixing two different transactions' fragments together.
            if let totalFrames, totalFrames != total { reset() }
            totalFrames = total
            received[frameNum] = Data(arr[QrFrameChunker.headerSize..<(QrFrameChunker.headerSize + fragLen)])

            guard let expected = totalFrames, received.count >= expected else { return nil }

            var out = Data()
            for i in 0..<expected {
                guard let piece = received[i] else { return nil }
                out.append(piece)
            }
            return out
        }

        /// (received, total) — nil until the first valid frame arrives.
        var progress: (received: Int, total: Int)? {
            totalFrames.map { (received.count, $0) }
        }

        /// Which frame indices have arrived so far — for a per-slot progress indicator (frames
        /// can arrive out of order).
        var receivedFrameIndices: Set<Int> { Set(received.keys) }

        func reset() {
            totalFrames = nil
            received.removeAll()
        }
    }
}
