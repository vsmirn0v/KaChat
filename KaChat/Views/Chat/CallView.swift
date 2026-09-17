import SwiftUI
import Combine
import WebRTC

/// The in-app call screen, shown by `MainTabView` whenever `CallService.session` exists:
/// ringing in, ringing out, connecting, connected and the brief "Call ended" beat.
///
/// Voice calls look like the phone's own call screen: name and timer up top, big round buttons
/// with labels underneath, the red hang-up at the bottom. Video calls are two equal tiles, the
/// other person on top and you underneath, both shown exactly as the camera sees them (no
/// mirroring - the picture the other side gets is the picture you see), with a slim control
/// bar below.
struct CallView: View {
    @ObservedObject var call: CallService.ActiveCall
    @ObservedObject private var callService = CallService.shared
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject var contactsManager: ContactsManager
    @State private var now = Date()

    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isVideoLayout: Bool {
        call.video && (call.phase == .connected || call.phase == .connecting)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isVideoLayout {
                videoLayout
            } else {
                voiceLayout
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

    // MARK: - Voice (and every ringing/ended state)

    private var voiceLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                KNSAvatarView(
                    avatarURLString: knsService.profileCache[call.contact.address]?.avatarURL,
                    fallbackText: contactsManager.displayName(for: call.contact),
                    size: 120,
                    contactAddress: call.contact.address
                )
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                Text(contactsManager.displayName(for: call.contact))
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(statusText)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                    .monospacedDigit()
            }
            .padding(.top, 56)
            .padding(.horizontal, 24)

            Spacer()

            switch call.phase {
            case .ringingIn:
                incomingControls
            case .ended:
                bigButton(systemName: "xmark", tint: Color.white.opacity(0.22), size: 84, label: "Close") {
                    callService.dismissEnded()
                }
            default:
                VStack(spacing: 40) {
                    HStack(spacing: 44) {
                        bigButton(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill",
                                  tint: call.isMuted ? .white : Color.white.opacity(0.22),
                                  size: 84, label: "mute", foreground: call.isMuted ? .black : .white) {
                            callService.toggleMute()
                        }
                        bigButton(systemName: "speaker.wave.3.fill",
                                  tint: call.isSpeakerOn ? .white : Color.white.opacity(0.22),
                                  size: 84, label: "speaker", foreground: call.isSpeakerOn ? .black : .white) {
                            callService.toggleSpeaker()
                        }
                    }
                    bigButton(systemName: "phone.down.fill", tint: .red, size: 84, label: nil) {
                        callService.hangUp()
                    }
                }
            }
        }
        .padding(.bottom, 52)
    }

    private var incomingControls: some View {
        HStack(spacing: 96) {
            bigButton(systemName: "phone.down.fill", tint: .red, size: 84, label: "Decline") {
                callService.declineIncoming()
            }
            bigButton(systemName: call.video ? "video.fill" : "phone.fill", tint: .green, size: 84, label: "Accept") {
                callService.acceptIncoming()
            }
        }
    }

    // MARK: - Video

    private var videoLayout: some View {
        GeometryReader { proxy in
            let barHeight: CGFloat = 96
            let tileHeight = max(120, (proxy.size.height - barHeight - 12 - 8) / 2)
            VStack(spacing: 12) {
                videoTile(track: call.remoteVideoTrack,
                          name: contactsManager.displayName(for: call.contact),
                          placeholder: call.phase == .connected ? "Camera off" : (call.statusDetail ?? "Connecting\u{2026}"),
                          address: call.contact.address)
                    .frame(height: tileHeight)
                videoTile(track: call.isCameraOff ? nil : call.localVideoTrack,
                          name: "You",
                          placeholder: "Camera off",
                          address: nil)
                    .frame(height: tileHeight)
                videoControlBar
                    .frame(height: barHeight)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder
    private func videoTile(track: RTCVideoTrack?, name: String, placeholder: String, address: String?) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.12))
            if let track {
                RTCVideoView(track: track)
            } else {
                VStack(spacing: 10) {
                    if let address {
                        KNSAvatarView(
                            avatarURLString: knsService.profileCache[address]?.avatarURL,
                            fallbackText: name,
                            size: 72,
                            contactAddress: address
                        )
                    } else {
                        Image(systemName: "video.slash.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            HStack(spacing: 6) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                if address != nil, call.phase == .connected, let start = call.connectedAt {
                    let seconds = max(0, Int(now.timeIntervalSince(start)))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.45)))
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var videoControlBar: some View {
        HStack(spacing: 22) {
            smallControl(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill", active: call.isMuted) {
                callService.toggleMute()
            }
            smallControl(systemName: "speaker.wave.3.fill", active: call.isSpeakerOn) {
                callService.toggleSpeaker()
            }
            smallControl(systemName: call.isCameraOff ? "video.slash.fill" : "video.fill", active: call.isCameraOff) {
                callService.toggleCamera()
            }
            smallControl(systemName: "arrow.triangle.2.circlepath.camera.fill", active: false) {
                callService.flipCamera()
            }
            Button {
                callService.hangUp()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.red))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pieces

    private var statusText: String {
        switch call.phase {
        case .ringingOut: return "calling\u{2026}"
        case .ringingIn: return call.video ? "KaChat Video" : "KaChat Audio"
        case .connecting: return call.statusDetail ?? "connecting\u{2026}"
        case .connected:
            if let detail = call.statusDetail { return detail }
            guard let start = call.connectedAt else { return "connected" }
            let seconds = max(0, Int(now.timeIntervalSince(start)))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .ended(let reason):
            switch reason {
            case "declined": return "Declined"
            case "no_host": return "One person in this chat needs Nextcloud Talk set up to make calls."
            case "no_answer":
                // A request nobody hosted rings out exactly like an unanswered call - the
                // other side never says anything on chain - so the hint rides along here.
                return call.hostsThisCall ? "No answer" : "No answer. If they don't have Nextcloud Talk, one of you needs it to make calls."
            case "missed": return "Missed call"
            case "busy": return "Busy"
            case "failed": return callService.lastError ?? "Call failed"
            default: return "Call ended"
            }
        }
    }

    private func bigButton(systemName: String, tint: Color, size: CGFloat, label: String?, foreground: Color = .white, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(foreground)
                    .frame(width: size, height: size)
                    .background(Circle().fill(tint))
            }
            .buttonStyle(.plain)
            if let label {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private func smallControl(systemName: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 52, height: 52)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }
}

/// A WebRTC video track on screen (Metal-backed), shown as the camera sees it - never mirrored.
struct RTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = .black
        context.coordinator.attach(track, to: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, to: uiView)
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
