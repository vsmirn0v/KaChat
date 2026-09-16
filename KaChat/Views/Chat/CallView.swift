import SwiftUI
import WebRTC

/// The in-app call screen, shown by `MainTabView` whenever `CallService.session` exists:
/// ringing in, ringing out, connecting, connected and the brief "Call ended" beat. One view for
/// voice and video - a video call just puts the remote picture behind everything and a local
/// preview in the corner.
struct CallView: View {
    @ObservedObject var call: CallService.ActiveCall
    @ObservedObject private var callService = CallService.shared
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject var contactsManager: ContactsManager
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if call.video, let remote = call.remoteVideoTrack, call.phase == .connected {
                RTCVideoView(track: remote, mirrored: false)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header
                    .padding(.top, 24)
                Spacer()
                if call.phase == .ringingIn {
                    incomingControls
                } else {
                    inCallControls
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)

            if call.video, let local = call.localVideoTrack, !call.isCameraOff {
                VStack {
                    HStack {
                        Spacer()
                        RTCVideoView(track: local, mirrored: true)
                            .frame(width: 110, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
                            .padding(.top, 16)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(clock) { now = $0 }
        .onChange(of: call.phase) { phase in
            if case .ended = phase {
                Haptics.impact(.medium)
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 12) {
            KNSAvatarView(
                avatarURLString: knsService.profileCache[call.contact.address]?.avatarURL,
                fallbackText: contactsManager.displayName(for: call.contact),
                size: 96,
                contactAddress: call.contact.address
            )
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            Text(contactsManager.displayName(for: call.contact))
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 28)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(call.video && call.phase == .connected ? 0.35 : 0))
        )
    }

    private var statusText: String {
        switch call.phase {
        case .ringingOut: return "Calling\u{2026}"
        case .ringingIn: return call.video ? "Incoming video call" : "Incoming voice call"
        case .connecting: return call.statusDetail ?? "Connecting\u{2026}"
        case .connected:
            if let detail = call.statusDetail { return detail }
            guard let start = call.connectedAt else { return "Connected" }
            let seconds = max(0, Int(now.timeIntervalSince(start)))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .ended(let reason):
            switch reason {
            case "declined": return "Declined"
            case "no_answer": return "No answer"
            case "missed": return "Missed call"
            case "busy": return "Busy"
            case "failed": return callService.lastError ?? "Call failed"
            default: return "Call ended"
            }
        }
    }

    private var incomingControls: some View {
        HStack(spacing: 64) {
            VStack(spacing: 8) {
                roundButton(systemName: "phone.down.fill", tint: .red, size: 72) {
                    callService.declineIncoming()
                }
                Text("Decline").font(.caption).foregroundColor(.white.opacity(0.8))
            }
            VStack(spacing: 8) {
                roundButton(systemName: call.video ? "video.fill" : "phone.fill", tint: .green, size: 72) {
                    callService.acceptIncoming()
                }
                Text("Accept").font(.caption).foregroundColor(.white.opacity(0.8))
            }
        }
    }

    private var inCallControls: some View {
        VStack(spacing: 28) {
            if case .ended = call.phase {
                EmptyView()
            } else {
                HStack(spacing: 28) {
                    control(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill", label: call.isMuted ? "Unmute" : "Mute", active: call.isMuted) {
                        callService.toggleMute()
                    }
                    control(systemName: call.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill", label: "Speaker", active: call.isSpeakerOn) {
                        callService.toggleSpeaker()
                    }
                    if call.video {
                        control(systemName: call.isCameraOff ? "video.slash.fill" : "video.fill", label: "Camera", active: call.isCameraOff) {
                            callService.toggleCamera()
                        }
                        control(systemName: "arrow.triangle.2.circlepath.camera.fill", label: "Flip", active: false) {
                            callService.flipCamera()
                        }
                    }
                }
            }
            if case .ended = call.phase {
                roundButton(systemName: "xmark", tint: Color.white.opacity(0.2), size: 64) {
                    callService.dismissEnded()
                }
            } else {
                roundButton(systemName: "phone.down.fill", tint: .red, size: 72) {
                    callService.hangUp()
                }
            }
        }
    }

    private func control(systemName: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            roundButton(systemName: systemName, tint: active ? .white : Color.white.opacity(0.2), size: 56, foreground: active ? .black : .white, action: action)
            Text(label).font(.caption2).foregroundColor(.white.opacity(0.8))
        }
    }

    private func roundButton(systemName: String, tint: Color, size: CGFloat, foreground: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: size, height: size)
                .background(Circle().fill(tint))
        }
        .buttonStyle(.plain)
    }
}

/// A WebRTC video track on screen (Metal-backed).
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    let mirrored: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = .black
        context.coordinator.attach(track, to: view)
        applyMirror(view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, to: uiView)
        applyMirror(uiView)
    }

    private func applyMirror(_ view: RTCMTLVideoView) {
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var current: RTCVideoTrack?

        func attach(_ track: RTCVideoTrack, to view: RTCMTLVideoView) {
            guard current !== track else { return }
            current?.remove(view)
            track.add(view)
            current = track
        }
    }
}
