import Foundation
import AVFoundation

/// The "ringing" the caller hears while the other side's phone rings: the North American
/// ringback cadence (440 Hz + 480 Hz, two seconds on, four off), synthesised once into a WAV
/// in memory and looped. Nothing is bundled; nothing to localise.
enum CallRingback {
    private static let sampleRate = 16_000
    private static let onSeconds = 2.0
    private static let offSeconds = 4.0

    static let wav: Data = {
        let total = Int(Double(sampleRate) * (onSeconds + offSeconds))
        let on = Int(Double(sampleRate) * onSeconds)
        var pcm = Data(capacity: total * 2)
        for i in 0..<total {
            var sample: Int16 = 0
            if i < on {
                let t = Double(i) / Double(sampleRate)
                // A short fade at both ends of the burst keeps it from clicking.
                let edge = min(1.0, min(Double(i), Double(on - i)) / (0.01 * Double(sampleRate)))
                let value = 0.18 * edge * (sin(2 * .pi * 440 * t) + sin(2 * .pi * 480 * t))
                sample = Int16(max(-1, min(1, value)) * 32_767)
            }
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); append(16)
        append16(1); append16(1); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append16(2); append16(16)
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }()

    static func makePlayer() -> AVAudioPlayer? {
        guard let player = try? AVAudioPlayer(data: wav, fileTypeHint: AVFileType.wav.rawValue) else { return nil }
        player.numberOfLoops = -1
        player.volume = 1
        player.prepareToPlay()
        return player
    }
}
