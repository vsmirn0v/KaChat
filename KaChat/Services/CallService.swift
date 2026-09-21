import Foundation
import AudioToolbox
import AVFoundation
import CallKit
import Combine
import Intents
import UIKit
import WebRTC

/// Voice and video calls between two KaChat contacts, carried by Nextcloud Talk and WebRTC and
/// never leaving the app.
///
/// How a call works: the CALLER's own Nextcloud (it must have Talk with calls enabled) gets a
/// throwaway public conversation; its token goes to the contact inside an ordinary encrypted
/// 1:1 message (`CallInviteContent`), the contact joins that conversation as a Talk GUEST on
/// the caller's server, and the two phones negotiate one WebRTC peer connection over Talk's
/// internal signaling channel. So exactly one side needs a Nextcloud, ringing rides the chat
/// itself (a few seconds, one on-chain message per event), and the media never touches KaChat's
/// own servers - only the caller's Nextcloud (STUN/TURN as it is configured there).
///
/// One call at a time. `session` is the whole UI state; `MainTabView` shows the call screens
/// off it, `ChatDetailView` offers the buttons when `canCall(_:)`.
@MainActor
final class CallService: ObservableObject {
    static let shared = CallService()

    enum Phase: Equatable {
        /// Caller: invite sent, waiting for the contact to pick up.
        case ringingOut
        /// Callee: invite received, the phone is ringing.
        case ringingIn
        /// Both sides are in the Talk call and the media is being negotiated.
        case connecting
        case connected
        /// Over; `reason` is the bubble's wording key ("hangup", "declined", "no_answer",
        /// "missed", "remote_hangup", "failed", "busy").
        case ended(String)
    }

    /// The live call. A class so the call screens observe it directly; there is never more than
    /// one and `CallService` owns its lifetime.
    final class ActiveCall: ObservableObject, Identifiable {
        let id: String
        /// The same call under CallKit's name. Derived from `id` (a UUID string on both
        /// phones) so a VoIP push and the chain message for one call agree on it.
        let uuid: UUID
        let contact: Contact
        let isOutgoing: Bool
        /// The Talk server and room. Unknown (nil / empty) while a call we asked the contact
        /// to host is still waiting for their invite.
        var server: URL?
        var token: String
        /// Whether THIS device owns the Talk room (its own Nextcloud): the outgoing side of a
        /// hosted call, or the incoming side of a call the contact asked us to host. The owner
        /// joins with its account and deletes the room at the end; the other side is a guest.
        let hostsThisCall: Bool
        let startedAt = Date()
        @Published var video: Bool
        @Published var phase: Phase
        @Published var connectedAt: Date?
        @Published var isMuted = false
        /// What the phone is actually doing: true while sound comes out of the loudspeaker.
        /// Tracked from the audio route itself (`routeChanged`) once audio runs, so the
        /// button never claims a state the hardware is not in.
        @Published var isSpeakerOn: Bool
        /// What the user asked for (video calls start on the speaker); applied whenever the
        /// audio session comes up, and what `isSpeakerOn` converges to.
        var speakerRequested: Bool
        @Published var isCameraOff = false
        @Published var remoteVideoTrack: RTCVideoTrack?
        @Published var localVideoTrack: RTCVideoTrack?
        @Published var statusDetail: String?
        /// A voice call being asked to become a video call: `.outgoing` while we wait for the
        /// other side's answer, `.incoming` while they wait for ours (the call screen asks).
        enum VideoRequest { case outgoing, incoming }
        @Published var videoRequest: VideoRequest?
        /// A short line shown on the call screen for a few seconds ("Alex declined video").
        @Published var notice: String?
        var videoRequestTimeout: Task<Void, Never>?

        // Plumbing - main-actor only, touched by CallService.
        var client: NextcloudTalkClient?
        var mySessionId: String?
        var mySid = String(UUID().uuidString.prefix(8))
        var peerSessionId: String?
        var peerSid: String?
        var webrtc: WebRTCClient?
        var pendingCandidates: [RTCIceCandidate] = []
        var pullTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var offerFallbackTask: Task<Void, Never>?
        var ringTimer: Timer?
        var sawPeerInCall = false
        /// Whether this side's opening message (invite / request) has gone out. The closing
        /// `call_end` is only ever sent by the side that initiated the call, and only after
        /// its opening message did - so a call that failed before ringing costs nothing.
        var openingMessageSent = false
        /// The user ended this call from the system call UI (or its in-app twin routed through
        /// CallKit): the end action is CallKit's own report, so `finish` must not report again.
        var endedByCallKit = false
        /// Stops the ringback the moment the call leaves `.ringingOut`.
        var phaseObserver: AnyCancellable?
        /// Ringback asked for before CallKit activated the audio session; played on activation.
        var ringbackPending = false

        init(id: String, contact: Contact, isOutgoing: Bool, server: URL?, token: String, video: Bool, phase: Phase, hostsThisCall: Bool) {
            self.id = id
            self.uuid = UUID(uuidString: id) ?? UUID()
            self.contact = contact
            self.isOutgoing = isOutgoing
            self.server = server
            self.token = token
            self.hostsThisCall = hostsThisCall
            self.video = video
            self.phase = phase
            self.isSpeakerOn = video
            self.speakerRequested = video
        }
    }

    @Published private(set) var session: ActiveCall?
    /// The call screen is tucked away: the user is elsewhere in KaChat (or in another app)
    /// while the call goes on. A video call floats as the system's Picture in Picture; a voice
    /// call shows the green return bar. `restore()` brings the screen back.
    @Published private(set) var isMinimized = false
    /// A one-line reason the last attempt failed, for a toast in the chat.
    @Published var lastError: String?

    /// How long an outgoing call rings before giving up (a phone's own calls give up after
    /// about half a minute; the chat adds a few seconds of delivery lag on top), how long the
    /// callee's phone rings, and how long an invite stays answerable after it was mined (an
    /// old invite from a closed app must not ring hours later).
    private let ringTimeout: TimeInterval = 35
    private let incomingRingTimeout: TimeInterval = 30
    private let inviteFreshness: TimeInterval = 45

    private var audioObservers: [NSObjectProtocol] = []

    private init() {
        handledCallIds = Set(UserDefaults.standard.stringArray(forKey: Self.handledCallIdsKey) ?? [])
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.routeChanged() }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.ensureAudioRunning(reason: "interruption ended") }
        })
    }

    /// Every call id this device has already rung, answered, or seen end. An invite is an
    /// ordinary on-chain message and the ingest paths re-deliver recent messages freely - a
    /// relaunch's UTXO resync re-resolves the last few with a fresh "now" block time - so
    /// without this a call that was over rang again on every reopen. Persisted, bounded.
    private static let handledCallIdsKey = "kachat_calls_handled_ids"
    private var handledCallIds: Set<String>
    private var handledCallOrder: [String] = []

    private func markHandled(_ callId: String) {
        guard !handledCallIds.contains(callId) else { return }
        handledCallIds.insert(callId)
        handledCallOrder.append(callId)
        if handledCallOrder.count > 200 {
            let dropped = handledCallOrder.removeFirst()
            handledCallIds.remove(dropped)
        }
        UserDefaults.standard.set(Array(handledCallIds), forKey: Self.handledCallIdsKey)
    }

    // MARK: - Availability

    /// Whether calls are allowed with this contact - the per-contact switch, OFF by default.
    /// The call button shows regardless; tapping it on a contact that is not yet enabled asks
    /// first. This is the only gate: a phone with no Nextcloud of its own can still start a
    /// call by asking the contact to host it (`call_request`), so hosting ability is not
    /// required here.
    func canCall(_ contact: Contact) -> Bool {
        contact.callsEnabled == true
    }

    /// Whether this device can open a Talk room itself: a connected Nextcloud with Talk calls
    /// enabled.
    var canHost: Bool {
        let nextcloud = NextcloudService.shared
        return nextcloud.account != nil && nextcloud.talkCallsAvailable
    }

    // MARK: - Outgoing

    func startCall(with contact: Contact, video: Bool) {
        guard session == nil else { return }
        guard contact.callsEnabled == true else { return }
        lastError = nil
        let callId = UUID().uuidString.lowercased()
        guard canHost, let account = NextcloudService.shared.account, let server = account.serverURL else {
            // No Nextcloud here: ask the contact to host. Their phone opens the room and rings
            // (if their "Allow calls" switch is on for us) and answers with an invite that this
            // call joins as a guest - see `handleIncoming(.invite)`.
            let call = ActiveCall(id: callId, contact: contact, isOutgoing: true, server: nil, token: "", video: video, phase: .ringingOut, hostsThisCall: false)
            session = call
            markHandled(callId)
            UIApplication.shared.isIdleTimerDisabled = true
            registerOutgoingWithCallKit(call)
            if video { CallCameraPreview.shared.start() }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let request = CallCodec.encode(CallRequestContent(callId: callId, video: video))
                    try await ChatService.shared.sendMessage(to: contact, content: request)
                    call.openingMessageSent = true
                    CallKitManager.shared.reportOutgoingConnecting(uuid: call.uuid)
                    self.requestRing(for: call, content: request, kind: "request")
                    self.startRingback(for: call)
                } catch {
                    self.lastError = error.localizedDescription
                    await self.finish(reason: "failed")
                    return
                }
                call.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(self?.ringTimeout ?? 35) * 1_000_000_000)
                    guard let self, let current = self.session, current === call, current.phase == .ringingOut else { return }
                    await self.finish(reason: "no_answer")
                }
            }
            return
        }
        // Token is filled in once the conversation exists; the screen shows "Calling" meanwhile.
        let call = ActiveCall(id: callId, contact: contact, isOutgoing: true, server: server, token: "", video: video, phase: .ringingOut, hostsThisCall: true)
        session = call
        UIApplication.shared.isIdleTimerDisabled = true
        registerOutgoingWithCallKit(call)
        if video { CallCameraPreview.shared.start() }

        Task { [weak self] in
            guard let self else { return }
            let client = NextcloudTalkClient(server: server, auth: .basic(username: account.username, appPassword: account.appPassword))
            call.client = client
            do {
                let name = ContactsManager.shared.displayName(for: contact)
                let token = try await client.createPublicConversation(named: "KaChat call with \(name)")
                guard self.session === call else { await client.deleteConversation(token: token); return }
                call.token = token
                try await self.joinAndSignal(call: call)
                self.markHandled(call.id)
                let invite = CallCodec.encode(CallInviteContent(callId: call.id, server: server.absoluteString, token: token, video: video))
                try await ChatService.shared.sendMessage(to: contact, content: invite)
                call.openingMessageSent = true
                CallKitManager.shared.reportOutgoingConnecting(uuid: call.uuid)
                self.requestRing(for: call, content: invite, kind: "invite")
                self.startRingback(for: call)
                call.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(self?.ringTimeout ?? 35) * 1_000_000_000)
                    guard let self, let current = self.session, current === call, current.phase == .ringingOut else { return }
                    await self.finish(reason: "no_answer")
                }
            } catch {
                AppLog.log("[Call] Starting call failed: %@", error.localizedDescription)
                self.lastError = error.localizedDescription
                await self.finish(reason: "failed")
            }
        }
    }

    // MARK: - Incoming (driven by ChatService.addMessageToConversation)

    func handleIncoming(_ envelope: CallEnvelope, message: ChatMessage, contactAddress: String) {
        guard !message.isOutgoing else { return }
        let age = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(message.blockTime) / 1000))
        switch envelope {
        case .request(let request):
            // The contact has no Nextcloud and asks us to host their call. Only if their
            // "Allow calls" switch is on and this device can host; otherwise it stays quiet and
            // their phone rings out to "no answer".
            guard !handledCallIds.contains(request.callId) else { return }
            guard let contact = ContactsManager.shared.getContact(byAddress: contactAddress) else { return }
            guard contact.callsEnabled == true, age < inviteFreshness else { return }
            guard canHost else {
                // Neither side can host. Nothing goes on chain from this side - the caller is
                // the only one who pays for a call - so the requester's ring-out is what tells
                // them one of the two needs Nextcloud Talk.
                markHandled(request.callId)
                return
            }
            if session != nil {
                // Busy: silent, and the caller rings out. Same invite delivered twice: ignored.
                return
            }
            markHandled(request.callId)
            _ = hostRequestedCall(id: request.callId, contact: contact, video: request.video)
        case .invite(let invite):
            guard let server = URL(string: invite.server), server.scheme?.lowercased() == "https" else { return }
            // A call already ringing off its VoIP push alone (the push could not be decrypted
            // on a locked phone): this is the same invite, now with the room in it. Fill it in;
            // if the user has already answered, `performAccept` is waiting for exactly this.
            if let current = session, !current.isOutgoing, !current.hostsThisCall, current.id == invite.callId, current.token.isEmpty {
                current.server = server
                current.token = invite.token
                current.video = invite.video
                return
            }
            // The contact hosting the call WE asked for: this invite is the answer to our
            // request, so join it straight away as a guest - their phone is the one ringing.
            if let current = session, current.isOutgoing, !current.hostsThisCall, current.id == invite.callId, current.phase == .ringingOut {
                current.server = server
                current.token = invite.token
                current.phase = .connecting
                current.timeoutTask?.cancel()
                let client = NextcloudTalkClient(server: server, auth: .guest)
                current.client = client
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.joinAndSignal(call: current)
                    } catch {
                        AppLog.log("[Call] Joining the hosted call failed: %@", error.localizedDescription)
                        self.lastError = error.localizedDescription
                        await self.finish(reason: "failed")
                    }
                }
                return
            }
            // Once per call id, ever - see `handledCallIds`. A re-ingested invite for a call that
            // already rang (or already ended) is history, not a phone ringing.
            guard !handledCallIds.contains(invite.callId) else { return }
            guard let contact = ContactsManager.shared.getContact(byAddress: contactAddress) else { return }
            guard contact.callsEnabled == true else { return }
            guard age < inviteFreshness else { return }
            if session != nil {
                // Already on a call: stay silent and let the caller ring out. This same invite
                // delivered twice is simply ignored.
                return
            }
            markHandled(invite.callId)
            let call = ActiveCall(id: invite.callId, contact: contact, isOutgoing: false, server: server, token: invite.token, video: invite.video, phase: .ringingIn, hostsThisCall: false)
            ringIncoming(call)
        case .response(let response):
            // A response or an end for a call this device is not on means that call is over;
            // remember it so its invite, should it arrive later in the same batch, stays quiet.
            markHandled(response.callId)
            guard let call = session, call.id == response.callId, call.isOutgoing else { return }
            if response.accepted {
                if call.phase == .ringingOut { call.phase = .connecting }
            } else {
                let reason = response.reason == "no_host" ? "no_host" : "declined"
                Task { await finish(reason: reason) }
            }
        case .end(let end):
            markHandled(end.callId)
            guard let call = session, call.id == end.callId else { return }
            Task { await finish(reason: call.phase == .ringingIn ? "missed" : "remote_hangup") }
        }
    }

    // The in-app Answer / Decline / Hang up / Mute buttons go through CallKit when it holds
    // the call, so the system's call UI (lock screen, Dynamic Island, Recents) stays in step;
    // CallKit then calls back into the `perform*` methods below, which are also what its own
    // UI drives. When CallKit is not in on the call, the buttons perform the change directly.

    func acceptIncoming() {
        guard let call = session, call.phase == .ringingIn else { return }
        guard CallKitManager.shared.isKnown(call.uuid) else { performAccept(); return }
        CallKitManager.shared.requestAnswer(uuid: call.uuid) { [weak self] accepted in
            guard !accepted else { return }
            Task { @MainActor in self?.performAccept() }
        }
    }

    func declineIncoming() {
        guard let call = session, call.phase == .ringingIn else { return }
        guard CallKitManager.shared.isKnown(call.uuid) else { Task { await performDecline() }; return }
        CallKitManager.shared.requestEnd(uuid: call.uuid) { [weak self] accepted in
            guard !accepted else { return }
            Task { @MainActor in await self?.performDecline() }
        }
    }

    func hangUp() {
        guard let call = session else { return }
        if case .ended = call.phase { return }
        guard CallKitManager.shared.isKnown(call.uuid) else { Task { await performEnd(reason: nil) }; return }
        CallKitManager.shared.requestEnd(uuid: call.uuid) { [weak self] accepted in
            guard !accepted else { return }
            Task { @MainActor in await self?.performEnd(reason: nil) }
        }
    }

    /// Answers the ringing call. Entered from CallKit's answer action, or directly when
    /// CallKit is not holding the call.
    func performAccept() {
        guard let call = session, call.phase == .ringingIn else { return }
        stopRinging(call)
        call.timeoutTask?.cancel()
        call.phase = .connecting
        donateCallInteraction(call)
        Task { [weak self] in
            guard let self else { return }
            // The room may still be on its way: a call we host opens it while ringing, and a
            // call rung off its VoIP push alone learns the room from the chain message. Give
            // it a moment, and nudge the fetch for that chat so the message lands sooner.
            if call.token.isEmpty, !call.hostsThisCall {
                Task { await ChatService.shared.fetchNewMessages(forActiveOnly: call.contact.address) }
            }
            var waited = 0
            while call.token.isEmpty, waited < 150, self.session === call {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard self.session === call, !call.token.isEmpty else {
                await self.finish(reason: "failed")
                return
            }
            if call.hostsThisCall {
                // The owning client opened the room and is already on the call.
                guard call.client != nil else {
                    await self.finish(reason: "failed")
                    return
                }
            } else {
                guard let server = call.server else {
                    await self.finish(reason: "failed")
                    return
                }
                call.client = NextcloudTalkClient(server: server, auth: .guest)
            }
            do {
                try await self.joinAndSignal(call: call)
            } catch {
                AppLog.log("[Call] Joining call failed: %@", error.localizedDescription)
                self.lastError = error.localizedDescription
                await self.finish(reason: "failed")
            }
        }
    }

    /// Ends whatever the call is doing: a ringing incoming call is declined, a ringing
    /// outgoing one cancelled, a live one hung up. `reason` overrides that wording (CallKit
    /// resetting mid-call reports "failed").
    func performEnd(reason: String?) async {
        guard let call = session else { return }
        if case .ended = call.phase { return }
        if let reason {
            await finish(reason: reason)
            return
        }
        switch call.phase {
        case .ringingIn:
            await performDecline()
        case .ringingOut:
            await finish(reason: "cancelled")
        default:
            await finish(reason: "hangup")
        }
    }

    func performSetMuted(_ muted: Bool) {
        guard let call = session else { return }
        call.isMuted = muted
        call.webrtc?.setMuted(muted)
    }

    private func performDecline() async {
        guard let call = session, call.phase == .ringingIn else { return }
        stopRinging(call)
        if !call.hostsThisCall, let server = call.server, !call.token.isEmpty {
            // Tell the caller through Talk, not the chain: join their room as a guest, hand
            // their session one "kachat_decline", and leave. Best effort - if it fails the
            // caller simply rings out.
            let token = call.token
            Task.detached {
                let client = NextcloudTalkClient(server: server, auth: .guest)
                guard let sessionId = try? await client.joinConversation(token: token) else { return }
                if let events = try? await client.pullSignaling(token: token, sessionId: sessionId) {
                    for case .usersInRoom(let users) in events {
                        for user in users where user.sessionId != sessionId {
                            let message = NextcloudTalkClient.PeerMessage(to: user.sessionId, sid: "decline", roomType: "video", type: "kachat_decline", payload: [:])
                            try? await client.sendSignaling(token: token, sessionId: sessionId, messages: [message])
                        }
                    }
                }
                await client.leaveConversation(token: token)
            }
        }
        // A hosted request we are declining: `finish` deletes the room, and the requester
        // waiting in it reads the 404 as the decline.
        await finish(reason: "declined")
    }

    /// Clears an ended call off the screen.
    func dismissEnded() {
        if let call = session, case .ended = call.phase {
            session = nil
        }
    }

    // MARK: - In-call controls

    func toggleMute() {
        guard let call = session else { return }
        let muted = !call.isMuted
        guard CallKitManager.shared.isKnown(call.uuid) else { performSetMuted(muted); return }
        CallKitManager.shared.requestMute(uuid: call.uuid, muted: muted) { [weak self] accepted in
            guard !accepted else { return }
            Task { @MainActor in self?.performSetMuted(muted) }
        }
    }

    func toggleSpeaker() {
        guard let call = session else { return }
        // Flip from where the audio actually is, not from where we last asked it to be.
        call.speakerRequested = !call.isSpeakerOn
        call.isSpeakerOn = call.speakerRequested
        call.webrtc?.setSpeaker(call.speakerRequested)
        // The route change notification settles the displayed state a moment later.
    }

    func toggleCamera() {
        guard let call = session, call.video else { return }
        call.isCameraOff.toggle()
        call.webrtc?.setVideoEnabled(!call.isCameraOff)
        if let client = call.client {
            let token = call.token
            let sendsVideo = !call.isCameraOff
            Task { await client.updateCallFlags(token: token, video: sendsVideo) }
        }
    }

    func flipCamera() {
        session?.webrtc?.flipCamera()
    }

    /// Turns the voice call into a video call, for both sides, without hanging up: our camera
    /// goes on, the other phone is told to turn its own on, and the connection is
    /// renegotiated with the new tracks.
    /// Asks the other side to turn this voice call into a video call. Nothing changes until
    /// they say yes: a camera never comes on because someone else pressed a button.
    func upgradeToVideo() {
        guard let call = session, !call.video, call.webrtc != nil, call.videoRequest == nil else { return }
        switch call.phase {
        case .connecting, .connected: break
        default: return
        }
        call.videoRequest = .outgoing
        call.notice = nil
        send(call: call, type: "kachat_video_request", payload: [:])
        call.videoRequestTimeout?.cancel()
        call.videoRequestTimeout = Task { [weak self, weak call] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, let call, self.session === call, call.videoRequest == .outgoing else { return }
            call.videoRequest = nil
            self.showNotice("No answer to your video request", on: call)
        }
    }

    /// The answer to the other side's video request, from the call screen's prompt.
    func answerVideoRequest(accept: Bool) {
        guard let call = session, call.videoRequest == .incoming else { return }
        call.videoRequest = nil
        guard accept else {
            send(call: call, type: "kachat_video_decline", payload: [:])
            return
        }
        // Our camera first, then the yes: the requester offers on hearing it, and our answer
        // to that offer already carries our video.
        switchToVideo(call)
        send(call: call, type: "kachat_video_accept", payload: [:])
    }

    /// This side of the call becomes video: camera on, speaker on, everyone told.
    private func switchToVideo(_ call: ActiveCall) {
        guard !call.video, let webrtc = call.webrtc else { return }
        call.video = true
        call.isCameraOff = false
        call.speakerRequested = true
        call.localVideoTrack = webrtc.enableVideo()
        webrtc.setSpeaker(true)
        CallKitManager.shared.updateCall(uuid: call.uuid, displayName: ContactsManager.shared.displayName(for: call.contact), video: true)
        if let client = call.client {
            let token = call.token
            Task { await client.updateCallFlags(token: token, video: true) }
        }
    }

    private func showNotice(_ text: String, on call: ActiveCall) {
        call.notice = text
        Task { [weak call] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if call?.notice == text { call?.notice = nil }
        }
    }

    /// Asks iOS for the microphone and then the camera, right when calls are switched on for
    /// someone - so the first call is not the moment two system prompts get in the way.
    /// Each prompt appears once per install; afterwards this is a no-op.
    static func requestMediaPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        }
    }

    /// Puts the call screen away while the call continues. Video calls float as Picture in
    /// Picture when the other side's video is already showing; otherwise the green return
    /// bar is what brings the screen back.
    func minimize() {
        guard let call = session else { return }
        if case .ended = call.phase { return }
        isMinimized = true
        if call.video, call.remoteVideoTrack != nil {
            CallPictureInPicture.shared.start()
        }
    }

    func restore() {
        guard session != nil else { return }
        isMinimized = false
        CallPictureInPicture.shared.stop()
    }

    // MARK: - Talk + WebRTC plumbing

    /// Joins the conversation and the call, brings up the peer connection, and starts the
    /// signaling pull loop. Shared by both directions; only the `client` (own account vs
    /// guest) differs.
    private func joinAndSignal(call: ActiveCall) async throws {
        guard let client = call.client else { return }
        if call.video { await CallCameraPreview.shared.stop() }
        let settings = try await client.signalingSettings(token: call.token)
        guard settings.mode.lowercased() != "external" else {
            throw NextcloudTalkClient.TalkError.externalSignalingUnsupported
        }
        let sessionId = try await client.joinConversation(token: call.token)
        call.mySessionId = sessionId
        if case .guest = client.auth {
            await client.setGuestDisplayName(token: call.token, name: ownDisplayName())
        }
        try await client.joinCall(token: call.token, video: call.video)

        let webrtc = WebRTCClient(iceServers: settings.iceServers, video: call.video)
        // With CallKit on the call, iOS activates the audio session itself (see
        // `CallKitManager.provider(_:didActivate:)`); WebRTC must not.
        webrtc.audioManagedByCallKit = CallKitManager.shared.isKnown(call.uuid)
        call.webrtc = webrtc
        call.localVideoTrack = webrtc.localVideoTrack
        webrtc.onLocalCandidate = { [weak self, weak call] candidate in
            guard let self, let call else { return }
            self.send(call: call, type: "candidate", payload: [
                "candidate": [
                    "candidate": candidate.sdp,
                    "sdpMid": candidate.sdpMid ?? "",
                    "sdpMLineIndex": Int(candidate.sdpMLineIndex)
                ]
            ])
        }
        webrtc.onRemoteVideoTrack = { [weak call] track in
            call?.remoteVideoTrack = track
        }
        webrtc.onConnectionState = { [weak self, weak call] state in
            guard let self, let call else { return }
            switch state {
            case .connected, .completed:
                if call.connectedAt == nil {
                    call.connectedAt = Date()
                    if call.isOutgoing { CallKitManager.shared.reportOutgoingConnected(uuid: call.uuid) }
                    // Audio watchdog: media is flowing, so a couple of seconds from now the
                    // audio unit must be running too. If CallKit never activated the session
                    // (it happens when another app held it at answer time) take it over.
                    Task { [weak self, weak call] in
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        guard let self, let call, self.session === call else { return }
                        self.ensureAudioRunning(reason: "watchdog")
                    }
                }
                call.phase = .connected
                call.statusDetail = nil
                self.routeChanged()
            case .disconnected:
                call.statusDetail = "Reconnecting"
            case .failed:
                Task { await self.finish(reason: "failed") }
            default:
                break
            }
        }
        webrtc.setSpeaker(call.speakerRequested)
        if call.video { webrtc.startCaptureIfNeeded() }

        call.pullTask = Task { [weak self, weak call] in
            guard let self, let call else { return }
            await self.pullLoop(call: call)
        }
    }

    private func pullLoop(call: ActiveCall) async {
        guard let client = call.client, let sessionId = call.mySessionId else { return }
        while !Task.isCancelled {
            do {
                let events = try await client.pullSignaling(token: call.token, sessionId: sessionId)
                guard !Task.isCancelled, session === call else { return }
                for event in events {
                    await handle(event, call: call)
                }
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as NextcloudTalkClient.TalkError {
                switch error {
                case .conversationGone, .sessionLost:
                    AppLog.log("[Call] Signaling ended: %@", error.localizedDescription)
                    let declined = !call.hostsThisCall && call.connectedAt == nil
                    await finish(reason: declined ? "declined" : "remote_hangup")
                    return
                default:
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func handle(_ event: NextcloudTalkClient.SignalingEvent, call: ActiveCall) async {
        switch event {
        case .usersInRoom(let users):
            let mine = call.mySessionId ?? ""
            let others = users.filter { $0.sessionId != mine && $0.inCall != 0 }
            if call.peerSessionId == nil, let peer = others.first {
                call.peerSessionId = peer.sessionId
                call.sawPeerInCall = true
                if call.phase == .ringingOut || call.phase == .ringingIn { call.phase = .connecting }
                call.timeoutTask?.cancel()
                // "Larger session ids call smaller ones" - the same tie-break the Talk web
                // client uses, so exactly one side offers. The other side still offers itself
                // if nothing arrives within ten seconds, in case the first offer was lost.
                if peer.sessionId < mine {
                    await sendOffer(call: call)
                } else {
                    call.offerFallbackTask = Task { [weak self, weak call] in
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard let self, let call, self.session === call,
                              call.webrtc?.hasRemoteDescription == false else { return }
                        await self.sendOffer(call: call)
                    }
                }
            } else if let peer = call.peerSessionId, call.sawPeerInCall,
                      !others.contains(where: { $0.sessionId == peer }) {
                // The other side left the call (hung up, or their app died).
                await finish(reason: "remote_hangup")
            }
        case .message(let data):
            guard let from = data["from"] as? String, let type = data["type"] as? String else { return }
            if type == "kachat_decline" {
                // The callee said no through Talk (no chain message from their side).
                if call.isOutgoing, call.connectedAt == nil { await finish(reason: "declined") }
                return
            }
            if type == "kachat_video_request" || type == "kachat_video_upgrade" {
                // They want video. Ask; never switch a camera on unasked. (`_upgrade` is what
                // builds before the request flow sent - it gets the same question.) The call
                // screen comes back up if it was tucked away, so the question is seen.
                guard !call.video, call.videoRequest == nil else { return }
                call.videoRequest = .incoming
                restore()
                return
            }
            if type == "kachat_video_accept" {
                guard call.videoRequest == .outgoing else { return }
                call.videoRequestTimeout?.cancel()
                call.videoRequest = nil
                switchToVideo(call)
                await sendOffer(call: call)
                return
            }
            if type == "kachat_video_decline" {
                guard call.videoRequest == .outgoing else { return }
                call.videoRequestTimeout?.cancel()
                call.videoRequest = nil
                showNotice("\(ContactsManager.shared.displayName(for: call.contact)) declined video", on: call)
                return
            }
            if call.peerSessionId == nil { call.peerSessionId = from }
            guard from == call.peerSessionId, let webrtc = call.webrtc else { return }
            let payload = data["payload"] as? [String: Any] ?? [:]
            switch type {
            case "offer":
                call.peerSid = data["sid"] as? String
                call.offerFallbackTask?.cancel()
                guard let sdp = payload["sdp"] as? String else { return }
                do {
                    try await webrtc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
                    await flushCandidates(call: call)
                    let answer = try await webrtc.createAnswer()
                    send(call: call, type: "answer", payload: ["type": "answer", "sdp": answer.sdp, "nick": ownDisplayName()])
                } catch {
                    AppLog.log("[Call] Answering offer failed: %@", error.localizedDescription)
                }
            case "answer":
                guard let sdp = payload["sdp"] as? String else { return }
                do {
                    try await webrtc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
                    await flushCandidates(call: call)
                } catch {
                    AppLog.log("[Call] Applying answer failed: %@", error.localizedDescription)
                }
            case "candidate":
                guard let inner = payload["candidate"] as? [String: Any],
                      let sdp = inner["candidate"] as? String else { return }
                let mid = inner["sdpMid"] as? String
                let index = (inner["sdpMLineIndex"] as? Int) ?? Int((inner["sdpMLineIndex"] as? Double) ?? 0)
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: mid)
                if webrtc.hasRemoteDescription {
                    await webrtc.addRemoteCandidate(candidate)
                } else {
                    call.pendingCandidates.append(candidate)
                }
            default:
                break
            }
        }
    }

    private func sendOffer(call: ActiveCall) async {
        guard let webrtc = call.webrtc else { return }
        do {
            let offer = try await webrtc.createOffer()
            send(call: call, type: "offer", payload: ["type": "offer", "sdp": offer.sdp, "nick": ownDisplayName()])
        } catch {
            AppLog.log("[Call] Creating offer failed: %@", error.localizedDescription)
        }
    }

    private func flushCandidates(call: ActiveCall) async {
        guard let webrtc = call.webrtc else { return }
        let queued = call.pendingCandidates
        call.pendingCandidates.removeAll()
        for candidate in queued {
            await webrtc.addRemoteCandidate(candidate)
        }
    }

    private func send(call: ActiveCall, type: String, payload: [String: Any]) {
        guard let client = call.client, let mine = call.mySessionId, let peer = call.peerSessionId else { return }
        let message = NextcloudTalkClient.PeerMessage(
            to: peer,
            sid: call.peerSid ?? call.mySid,
            roomType: "video",
            type: type,
            payload: payload
        )
        let token = call.token
        Task {
            do {
                try await client.sendSignaling(token: token, sessionId: mine, messages: [message])
            } catch {
                AppLog.log("[Call] Sending %@ failed: %@", type, error.localizedDescription)
            }
        }
    }

    // MARK: - Teardown

    private func finish(reason: String) async {
        guard let call = session else { return }
        if case .ended = call.phase { return }
        stopRinging(call)
        stopRingback()
        call.videoRequestTimeout?.cancel()
        call.videoRequest = nil
        CallPictureInPicture.shared.tearDown()
        if call.video { await CallCameraPreview.shared.stop() }
        call.timeoutTask?.cancel()
        call.offerFallbackTask?.cancel()
        call.pullTask?.cancel()
        call.client?.cancelPull()
        call.webrtc?.close()
        call.webrtc = nil
        call.remoteVideoTrack = nil
        call.localVideoTrack = nil
        let duration = call.connectedAt.map { Int(Date().timeIntervalSince($0)) }
        call.phase = .ended(reason)
        UIApplication.shared.isIdleTimerDisabled = false
        if !call.endedByCallKit {
            CallKitManager.shared.reportEnded(uuid: call.uuid, reason: Self.callKitReason(for: reason))
        }

        // The caller is the only side that ever puts a call on chain: one opening message
        // (invite or request) and one closing message with how it went and, if it connected,
        // for how long. A callee's hang-up reaches the caller through the room instead.
        if call.isOutgoing, call.openingMessageSent {
            let end = CallEndContent(callId: call.id, reason: reason, durationSeconds: duration)
            try? await ChatService.shared.sendMessage(to: call.contact, content: CallCodec.encode(end))
        }
        if let client = call.client, !call.token.isEmpty {
            let token = call.token
            let owner = call.hostsThisCall
            Task.detached {
                await client.leaveCall(token: token)
                await client.leaveConversation(token: token)
                if owner { await client.deleteConversation(token: token) }
            }
        }
        // Let the "Call ended" state show for a moment, then clear the screen. A call that was
        // tucked away has no screen to show it on: gone at once, no re-presenting to say so.
        if isMinimized {
            isMinimized = false
            session = nil
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let current = self.session, current === call else { return }
            self.session = nil
        }
    }

    // MARK: - CallKit, VoIP push, Contacts

    /// Puts an incoming call on screen and rings it - through CallKit when it will take it
    /// (the phone's own incoming-call UI, lock screen included), inside the app otherwise.
    private func ringIncoming(_ call: ActiveCall) {
        session = call
        UIApplication.shared.isIdleTimerDisabled = true
        call.timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.incomingRingTimeout ?? 30) * 1_000_000_000)
            guard let self, let current = self.session, current === call, current.phase == .ringingIn else { return }
            await self.finish(reason: "missed")
        }
        let name = ContactsManager.shared.displayName(for: call.contact)
        CallKitManager.shared.updateCall(uuid: call.uuid, displayName: name, video: call.video)
        CallKitManager.shared.reportIncoming(uuid: call.uuid, displayName: name, handle: call.contact.address, video: call.video) { [weak self, weak call] error in
            Task { @MainActor in
                guard let self, let call, self.session === call, call.phase == .ringingIn else { return }
                guard error != nil else { return }
                // CallKit will not show it (Do Not Disturb, a region without CallKit, ...):
                // ring in-app if the user is looking, otherwise it is a missed call.
                if UIApplication.shared.applicationState == .active {
                    self.startRinging(call)
                } else {
                    await self.finish(reason: "missed")
                }
            }
        }
    }

    /// Hosts a call the contact asked for: rings, and opens the room meanwhile so the
    /// requester can be waiting in it as a guest by the time we accept. Returns false when
    /// this device cannot host.
    @discardableResult
    private func hostRequestedCall(id callId: String, contact: Contact, video: Bool) -> Bool {
        guard canHost, let account = NextcloudService.shared.account, let server = account.serverURL else { return false }
        let call = ActiveCall(id: callId, contact: contact, isOutgoing: false, server: server, token: "", video: video, phase: .ringingIn, hostsThisCall: true)
        ringIncoming(call)
        Task { [weak self] in
            guard let self else { return }
            let client = NextcloudTalkClient(server: server, auth: .basic(username: account.username, appPassword: account.appPassword))
            call.client = client
            do {
                let name = ContactsManager.shared.displayName(for: contact)
                let token = try await client.createPublicConversation(named: "KaChat call with \(name)")
                guard self.session === call else { await client.deleteConversation(token: token); return }
                call.token = token
                let invite = CallInviteContent(callId: call.id, server: server.absoluteString, token: token, video: call.video, viaRequest: true)
                try await ChatService.shared.sendMessage(to: contact, content: CallCodec.encode(invite))
            } catch {
                AppLog.log("[Call] Hosting a requested call failed: %@", error.localizedDescription)
                self.lastError = error.localizedDescription
                await self.finish(reason: "failed")
            }
        }
        return true
    }

    /// A VoIP push from the push service: the caller's phone asked it to ring this device the
    /// moment its opening message went on chain. Every push MUST become a CallKit call before
    /// this returns (iOS stops delivering VoIP pushes to an app that swallows one), so a push
    /// that should not ring is reported and ended on the spot.
    ///
    /// Fields: `call_id`, `sender` (the caller's address, vouched for by the signed ring
    /// request), `video`, `kind` ("invite" | "request"), `timestamp` (ms), and `payload` - a
    /// hex copy of the opening message encrypted to this wallet. The payload is decrypted when
    /// the keys are reachable, which gives the room straight away; on a locked phone it may
    /// not be, and then the call rings on the push's word alone and the room comes from the
    /// chain message once the app has fetched it.
    func handleVoIPPush(_ info: [AnyHashable: Any]) {
        let callId = ((info["call_id"] as? String) ?? "").lowercased()
        let sender = (info["sender"] as? String) ?? ""
        let video = Self.flag(info["video"])
        let kind = (info["kind"] as? String) ?? "invite"
        let timestampMs = Self.milliseconds(info["timestamp"]) ?? UInt64(Date().timeIntervalSince1970 * 1000)
        let uuid = UUID(uuidString: callId) ?? UUID()
        let payloadHex = info["payload"] as? String
        let handle = sender.isEmpty ? "KaChat" : sender
        let provisionalName = sender.isEmpty ? "KaChat" : ContactsManager.shared.displayName(for: sender)

        // Report first, always - iOS demands a CallKit call for every VoIP push before this
        // returns, and a push that launched the app arrives before the wallet, contacts and
        // Nextcloud account behind it are loaded. Everything below refines or ends that call.
        CallKitManager.shared.reportIncoming(uuid: uuid, displayName: provisionalName, handle: handle, video: video) { _ in }
        guard !callId.isEmpty, !sender.isEmpty else {
            CallKitManager.shared.reportEnded(uuid: uuid, reason: .failed)
            return
        }
        if let current = session, current.id == callId {
            // The chain message got here first and the call is already ringing (or answered).
            return
        }
        AppLog.log("[Call] VoIP push for %@ from %@ (%@)", String(callId.prefix(8)), String(sender.suffix(8)), kind)

        Task { [weak self] in
            guard let self else { return }
            await self.waitUntilReadyForCalls()
            self.decideVoIPCall(callId: callId, uuid: uuid, sender: sender, video: video, kind: kind, timestampMs: timestampMs, payloadHex: payloadHex)
        }
    }

    /// A launch from a VoIP push races the wallet load: give it up to eight seconds, then a
    /// beat for the contact list and Nextcloud account that follow it synchronously.
    private func waitUntilReadyForCalls() async {
        var waited = 0
        while WalletManager.shared.currentWallet == nil, waited < 80 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        if waited > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
    }

    /// Calls ended from the system UI before the app had them (a VoIP push declined while the
    /// wallet was still loading) - such a call must not ring once the app catches up.
    private var endedBeforeRinging: Set<UUID> = []

    func noteEndedBeforeRinging(_ uuid: UUID) {
        endedBeforeRinging.insert(uuid)
    }

    private func decideVoIPCall(callId: String, uuid: UUID, sender: String, video: Bool, kind: String, timestampMs: UInt64, payloadHex: String?) {
        let drop: (CXCallEndedReason, String) -> Void = { reason, why in
            AppLog.log("[Call] VoIP call %@ not rung: %@", String(callId.prefix(8)), why)
            CallKitManager.shared.reportEnded(uuid: uuid, reason: reason)
        }
        if endedBeforeRinging.remove(uuid) != nil {
            markHandled(callId)
            AppLog.log("[Call] VoIP call %@ declined before it could ring", String(callId.prefix(8)))
            return
        }
        if let current = session, current.id == callId { return }
        guard !handledCallIds.contains(callId) else { drop(.unanswered, "already handled"); return }
        guard let contact = ContactsManager.shared.getContact(byAddress: sender) else { drop(.unanswered, "unknown sender"); return }
        guard contact.callsEnabled == true else { drop(.unanswered, "calls not enabled for this contact"); return }
        let age = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000))
        guard age < inviteFreshness else { drop(.unanswered, "stale (\(Int(age))s)"); return }
        guard session == nil else { drop(.unanswered, "busy"); return }

        var envelope: CallEnvelope?
        if let payloadHex,
           let key = try? KeychainService.shared.loadPrivateKey(),
           let content = ChatService.decryptContextualMessageFromRawPayloadSync(payloadHex, privateKey: key),
           let parsed = CallCodec.parseAny(content),
           parsed.callId == callId {
            envelope = parsed
        }
        markHandled(callId)
        switch envelope {
        case .invite(let invite):
            guard let server = URL(string: invite.server), server.scheme?.lowercased() == "https" else { drop(.failed, "bad server in invite"); return }
            let call = ActiveCall(id: callId, contact: contact, isOutgoing: false, server: server, token: invite.token, video: invite.video, phase: .ringingIn, hostsThisCall: false)
            ringIncoming(call)
        case .request(let request):
            if !hostRequestedCall(id: callId, contact: contact, video: request.video) { drop(.failed, "cannot host (no Nextcloud Talk)") }
        case .response, .end:
            drop(.unanswered, "not an opening message")
        case nil:
            if kind == "request" {
                if !hostRequestedCall(id: callId, contact: contact, video: video) { drop(.failed, "cannot host (no Nextcloud Talk)") }
            } else {
                let call = ActiveCall(id: callId, contact: contact, isOutgoing: false, server: nil, token: "", video: video, phase: .ringingIn, hostsThisCall: false)
                ringIncoming(call)
            }
        }
    }

    /// CallKit activated the audio session for the current call: apply the route the call
    /// wants now that there is a session to route.
    func audioSessionBecameActive() {
        guard let call = session else { return }
        if call.ringbackPending { startRingback(for: call) }
        guard let webrtc = call.webrtc else { return }
        webrtc.setSpeaker(call.speakerRequested)
        routeChanged()
    }

    // MARK: - Ringback

    private var ringbackPlayer: AVAudioPlayer?

    /// What the caller hears while the other phone rings. With CallKit on the call, iOS
    /// activates the audio session itself a moment after the call starts, so the tone waits
    /// for `audioSessionBecameActive`; otherwise the session is brought up here.
    private func startRingback(for call: ActiveCall) {
        guard session === call, call.phase == .ringingOut, ringbackPlayer == nil else { return }
        if call.phaseObserver == nil {
            call.phaseObserver = call.$phase.sink { [weak self] phase in
                if phase != .ringingOut { self?.stopRingback() }
            }
        }
        let callKit = CallKitManager.shared.isKnown(call.uuid)
        if callKit, !CallKitManager.shared.audioSessionActive {
            call.ringbackPending = true
            return
        }
        call.ringbackPending = false
        if !callKit {
            let rtc = RTCAudioSession.sharedInstance()
            rtc.lockForConfiguration()
            try? rtc.setCategory(.playAndRecord, mode: .voiceChat, options: call.video ? [.defaultToSpeaker, .allowBluetoothHFP] : [.allowBluetoothHFP])
            try? rtc.setActive(true)
            rtc.unlockForConfiguration()
        }
        guard let player = CallRingback.makePlayer() else { return }
        ringbackPlayer = player
        player.play()
    }

    private func stopRingback() {
        session?.ringbackPending = false
        ringbackPlayer?.stop()
        ringbackPlayer = nil
    }

    /// The phone's audio route moved (speaker override, headphones, Bluetooth, CallKit
    /// activation): show where the sound really comes out. Only once audio is running - before
    /// that the route says nothing about the call.
    private func routeChanged() {
        guard let call = session, call.webrtc != nil else { return }
        let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
        if call.isSpeakerOn != onSpeaker { call.isSpeakerOn = onSpeaker }
    }

    /// Makes sure the audio unit is up for the current call. Sound can go missing in two
    /// known ways: CallKit never activated the session (another app held it when the call was
    /// answered, so `didActivate` never came) or an interruption ended without it coming
    /// back. Either way, activate it ourselves and let WebRTC run.
    private func ensureAudioRunning(reason: String) {
        guard let call = session, let webrtc = call.webrtc else { return }
        switch call.phase {
        case .connecting, .connected: break
        default: return
        }
        let rtc = RTCAudioSession.sharedInstance()
        if webrtc.audioManagedByCallKit {
            if CallKitManager.shared.audioSessionActive {
                if !rtc.isAudioEnabled {
                    AppLog.log("[Call] Audio re-enabled (%@)", reason)
                    rtc.isAudioEnabled = true
                }
                return
            }
            AppLog.log("[Call] CallKit never activated the audio session (%@) - running it ourselves", reason)
            webrtc.audioManagedByCallKit = false
        }
        webrtc.activateAudioSession()
        webrtc.setSpeaker(call.speakerRequested)
        routeChanged()
    }

    private func registerOutgoingWithCallKit(_ call: ActiveCall) {
        let name = ContactsManager.shared.displayName(for: call.contact)
        CallKitManager.shared.requestStart(uuid: call.uuid, displayName: name, handle: call.contact.address, video: call.video) { _ in }
        donateCallInteraction(call)
    }

    /// Asks the push service to ring the contact's phones right now, with an encrypted copy
    /// of the opening message so a closed app can ring with the room already in hand. Best
    /// effort: without it the chain message still rings an open app, just later.
    private func requestRing(for call: ActiveCall, content: String, kind: String) {
        let contact = call.contact
        Task {
            guard let recipientKey = KaspaAddress.publicKey(from: contact.address) else { return }
            let alias = ChatService.shared.outgoingAlias(for: contact.address)
            guard let payload = try? KasiaTransactionBuilder.buildContextualMessagePayload(alias: alias, message: content, recipientPublicKey: recipientKey) else { return }
            do {
                try await PushNotificationManager.shared.requestRing(to: contact.address, callId: call.id, video: call.video, kind: kind, payloadHex: payload.hexString)
            } catch {
                AppLog.log("[Call] Ring push not sent: %@", error.localizedDescription)
            }
        }
    }

    /// Tells iOS this person is someone KaChat calls. After a few of these, the Contacts app
    /// lists KaChat behind the contact's call and video buttons (matched through the linked
    /// system contact), Siri understands "call X on KaChat", and Recents can call back.
    private func donateCallInteraction(_ call: ActiveCall) {
        let contact = call.contact
        let person = INPerson(
            personHandle: INPersonHandle(value: contact.address, type: .unknown),
            nameComponents: nil,
            displayName: ContactsManager.shared.displayName(for: contact),
            image: nil,
            contactIdentifier: contact.systemContactId,
            customIdentifier: contact.address
        )
        let intent = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [person],
            callCapability: call.video ? .videoCall : .audioCall
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = call.isOutgoing ? .outgoing : .incoming
        interaction.donate { error in
            if let error { AppLog.log("[Call] Intent donation failed: %@", error.localizedDescription) }
        }
    }

    private static func callKitReason(for reason: String) -> CXCallEndedReason {
        switch reason {
        case "no_answer", "missed": return .unanswered
        case "failed", "no_host": return .failed
        default: return .remoteEnded
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["1", "true", "yes"].contains(string.lowercased())
        default: return false
        }
    }

    private static func milliseconds(_ value: Any?) -> UInt64? {
        let raw: UInt64?
        switch value {
        case let number as NSNumber: raw = number.uint64Value
        case let string as String: raw = UInt64(string) ?? UInt64(Double(string) ?? 0)
        default: raw = nil
        }
        guard let raw, raw > 0 else { return nil }
        // Seconds rather than milliseconds (anything before 1973 in ms is really seconds).
        return raw < 100_000_000_000 ? raw * 1000 : raw
    }

    // MARK: - Ringing

    private func startRinging(_ call: ActiveCall) {
        ring()
        call.ringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ring() }
        }
    }

    private func stopRinging(_ call: ActiveCall) {
        call.ringTimer?.invalidate()
        call.ringTimer = nil
    }

    private func ring() {
        AudioServicesPlaySystemSound(1007)
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    private func ownDisplayName() -> String {
        guard let address = WalletManager.shared.currentWallet?.publicAddress else { return "KaChat" }
        if let domain = KNSService.shared.profileCache[address]?.domainName, !domain.isEmpty {
            return domain
        }
        return "KaChat \(address.suffix(6))"
    }
}
