import Foundation
import AVFoundation
import WebRTC

/// One peer connection for a KaChat call: local microphone (and camera, for video calls), the
/// remote tracks, and the offer/answer/candidate plumbing `CallService` drives over Talk's
/// signaling channel. Deliberately small - a 1:1 call is one connection, one audio track, at
/// most one video track each way.
final class WebRTCClient: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }()

    private let connection: RTCPeerConnection
    private let audioTrack: RTCAudioTrack
    private(set) var localVideoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private var usingFrontCamera = true

    /// Fired on the main queue.
    var onLocalCandidate: ((RTCIceCandidate) -> Void)?
    var onConnectionState: ((RTCIceConnectionState) -> Void)?
    var onRemoteVideoTrack: ((RTCVideoTrack) -> Void)?

    private(set) var wantsVideo: Bool

    init(iceServers: [NextcloudTalkClient.IceServer], video: Bool) {
        wantsVideo = video
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { server in
            if let username = server.username, let credential = server.credential {
                return RTCIceServer(urlStrings: server.urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: server.urls)
        }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: nil) else {
            fatalError("WebRTC: could not create a peer connection")
        }
        self.connection = connection

        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "kachat-audio")
        super.init()
        connection.delegate = self
        connection.add(audioTrack, streamIds: ["kachat"])

        if video {
            let videoSource = Self.factory.videoSource()
            let track = Self.factory.videoTrack(with: videoSource, trackId: "kachat-video")
            connection.add(track, streamIds: ["kachat"])
            localVideoTrack = track
            capturer = RTCCameraVideoCapturer(delegate: videoSource)
        }
    }

    // MARK: - Media control

    /// Turns a voice call's connection into a video one: adds the camera track (the first
    /// offer already carried a receive-only video line, so the track attaches to it) and
    /// starts capturing. The caller renegotiates afterwards. Returns the local track.
    @discardableResult
    func enableVideo() -> RTCVideoTrack? {
        if let localVideoTrack { return localVideoTrack }
        let videoSource = Self.factory.videoSource()
        let track = Self.factory.videoTrack(with: videoSource, trackId: "kachat-video")
        connection.add(track, streamIds: ["kachat"])
        localVideoTrack = track
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
        wantsVideo = true
        startCaptureIfNeeded()
        return track
    }

    func startCaptureIfNeeded() {
        guard let capturer else { return }
        let position: AVCaptureDevice.Position = usingFrontCamera ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
                ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        // Prefer a 720p-ish format: enough for a phone screen, kind to the uplink.
        let format = formats.min { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return abs(Int(l.width) * Int(l.height) - 1280 * 720) < abs(Int(r.width) * Int(r.height) - 1280 * 720)
        } ?? formats.first
        guard let format else { return }
        let fps = format.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max().map { min($0, 30) } ?? 30
        capturer.startCapture(with: device, format: format, fps: fps)
    }

    func stopCapture() {
        capturer?.stopCapture()
    }

    func flipCamera() {
        usingFrontCamera.toggle()
        startCaptureIfNeeded()
    }

    func setMuted(_ muted: Bool) {
        audioTrack.isEnabled = !muted
    }

    func setVideoEnabled(_ enabled: Bool) {
        localVideoTrack?.isEnabled = enabled
        if enabled { startCaptureIfNeeded() } else { stopCapture() }
    }

    /// True when CallKit holds this call: iOS activates and deactivates the audio session
    /// itself and hands it to WebRTC through `CallKitManager` - this client must only pick the
    /// route. False (CallKit refused the call) and this client runs the session as before.
    var audioManagedByCallKit = false

    /// The audio route: earpiece or speaker. Activates the session too when this client, not
    /// CallKit, owns it. Each step stands alone - a category the system refuses to change
    /// mid-call must not stop the override, and a failed override must not stop activation.
    func setSpeaker(_ speaker: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: speaker ? [.defaultToSpeaker, .allowBluetoothHFP] : [.allowBluetoothHFP])
        } catch {
            AppLog.log("[WebRTC] Audio category failed: %@", error.localizedDescription)
        }
        do {
            try session.overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {
            AppLog.log("[WebRTC] Audio route change failed: %@", error.localizedDescription)
        }
        session.unlockForConfiguration()
        if !audioManagedByCallKit {
            activateAudioSession()
        }
    }

    /// Brings the audio session up under this client's own control and lets WebRTC start the
    /// audio unit. Used when CallKit is not on the call, and as the recovery path when it is
    /// but never activated the session.
    func activateAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setActive(true)
        } catch {
            AppLog.log("[WebRTC] Audio session activation failed: %@", error.localizedDescription)
        }
        session.unlockForConfiguration()
        session.isAudioEnabled = true
    }

    // MARK: - Negotiation

    func createOffer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        let offer = try await connection.offer(for: constraints)
        try await connection.setLocalDescription(offer)
        return offer
    }

    func createAnswer() async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue
            ],
            optionalConstraints: nil
        )
        let answer = try await connection.answer(for: constraints)
        try await connection.setLocalDescription(answer)
        return answer
    }

    func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        try await connection.setRemoteDescription(description)
    }

    func addRemoteCandidate(_ candidate: RTCIceCandidate) async {
        do {
            try await connection.add(candidate)
        } catch {
            AppLog.log("[WebRTC] Adding remote candidate failed: %@", error.localizedDescription)
        }
    }

    var hasRemoteDescription: Bool { connection.remoteDescription != nil }

    func close() {
        stopCapture()
        onLocalCandidate = nil
        onConnectionState = nil
        onRemoteVideoTrack = nil
        connection.close()
        if !audioManagedByCallKit {
            RTCAudioSession.sharedInstance().isAudioEnabled = false
        }
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        remoteVideoTrack = track
        DispatchQueue.main.async { [weak self] in
            self?.onRemoteVideoTrack?(track)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionState?(newState)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        DispatchQueue.main.async { [weak self] in
            self?.onLocalCandidate?(candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        remoteVideoTrack = track
        DispatchQueue.main.async { [weak self] in
            self?.onRemoteVideoTrack?(track)
        }
    }
}
