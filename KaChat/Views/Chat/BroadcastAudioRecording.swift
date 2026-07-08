import SwiftUI
import AVFoundation

/// Records a short voice message for a broadcast channel, reusing the exact same Opus/WebM
/// encoding pipeline as 1:1 chat's voice messages (`WebMOpusEncoder`, `ChatDetailView.swift`) so
/// the wire format is identical - a cap of 10s / ~13KB keeps it well inside a single self-stash
/// transaction's payload.
@MainActor
final class BroadcastAudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case encoding
        case failed(String)
    }

    static let maxDuration: TimeInterval = 10
    private static let maxBytes = 13_000
    private static let bitrate: Int32 = 6_000
    private static let sampleRate: Double = 48_000

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var pcmURL: URL?

    func start() {
        guard state == .idle else { return }
        Task {
            let granted = await Self.requestPermission()
            guard granted else {
                state = .failed("Microphone access denied")
                return
            }
            beginRecording()
        }
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("broadcast_rec_\(UUID().uuidString).caf")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record()

            self.recorder = recorder
            self.pcmURL = url
            self.elapsedSeconds = 0
            self.state = .recording
            startTimer()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder?.delegate = nil
        recorder = nil
        if let pcmURL {
            try? FileManager.default.removeItem(at: pcmURL)
        }
        pcmURL = nil
        state = .idle
        elapsedSeconds = 0
    }

    /// Stops recording, encodes to Opus/WebM, and delivers wire-ready data. Safe to call once
    /// `elapsedSeconds` reaches `maxDuration` too (the caller drives that cutoff).
    func stopAndEncode() async throws -> (data: Data, fileName: String, mimeType: String) {
        timer?.invalidate()
        timer = nil
        guard state == .recording, let recorder, let pcmURL else {
            throw KasiaError.networkError("Not recording")
        }
        state = .encoding
        recorder.stop()
        self.recorder = nil

        defer {
            try? FileManager.default.removeItem(at: pcmURL)
            self.pcmURL = nil
            if state == .encoding { state = .idle }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broadcast_voice_\(UUID().uuidString).webm")
        try await WebMOpusEncoder.encode(
            pcmURL: pcmURL,
            outputURL: outputURL,
            bitrate: Self.bitrate,
            sampleRate: Self.sampleRate,
            maxBytes: Self.maxBytes
        )
        let data = try Data(contentsOf: outputURL)
        try? FileManager.default.removeItem(at: outputURL)
        state = .idle
        return (data, "voice.webm", "audio/webm")
    }
}

/// Plays back a single voice message's decoded audio. One instance per message bubble (matches
/// Android's per-bubble `MediaPlayer` - no single "now playing" registry there either).
@MainActor
final class BroadcastAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var durationText = "0:00"

    private var player: AVAudioPlayer?
    private var decodedURL: URL?
    private var isPreparing = false

    func prepare(data: Data) {
        guard player == nil, !isPreparing else { return }
        isPreparing = true
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
                let player = try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
                await MainActor.run {
                    self.decodedURL = decoded.url
                    player.delegate = self
                    self.player = player
                    self.durationText = Self.formatDuration(player.duration)
                    self.isReady = true
                    self.isPreparing = false
                }
            } catch {
                NSLog("[BroadcastAudioPlayer] Failed to decode voice message: %@", error.localizedDescription)
                await MainActor.run { self.isPreparing = false }
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            if player.currentTime >= player.duration { player.currentTime = 0 }
            player.play()
            isPlaying = true
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.isFinite ? duration : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    deinit {
        if let decodedURL {
            try? FileManager.default.removeItem(at: decodedURL)
        }
    }
}

/// A compact play/pause + duration bubble for a voice message, styled to match the surrounding
/// text bubble's colors rather than Android's Material look.
struct BroadcastAudioBubble: View {
    let data: Data
    let isOwnMessage: Bool
    @StateObject private var player = BroadcastAudioPlayer()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
            }
            .disabled(!player.isReady)

            Text(player.durationText)
                .font(.caption)
                .monospacedDigit()

            if !player.isReady {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .foregroundColor(isOwnMessage ? .white : .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 130, alignment: .leading)
        .task {
            player.prepare(data: data)
        }
    }
}
