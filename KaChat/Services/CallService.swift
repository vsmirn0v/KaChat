import Foundation
import AudioToolbox
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
        @Published var isSpeakerOn: Bool
        @Published var isCameraOff = false
        @Published var remoteVideoTrack: RTCVideoTrack?
        @Published var localVideoTrack: RTCVideoTrack?
        @Published var statusDetail: String?

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

        init(id: String, contact: Contact, isOutgoing: Bool, server: URL?, token: String, video: Bool, phase: Phase, hostsThisCall: Bool) {
            self.id = id
            self.contact = contact
            self.isOutgoing = isOutgoing
            self.server = server
            self.token = token
            self.hostsThisCall = hostsThisCall
            self.video = video
            self.phase = phase
            self.isSpeakerOn = video
        }
    }

    @Published private(set) var session: ActiveCall?
    /// A one-line reason the last attempt failed, for a toast in the chat.
    @Published var lastError: String?

    /// How long an outgoing call rings before giving up, and how long an invite stays
    /// answerable after it was mined (the chat delivers with a few seconds' lag, and an old
    /// invite from a closed app must not ring hours later).
    private let ringTimeout: TimeInterval = 75
    private let inviteFreshness: TimeInterval = 90

    private init() {
        handledCallIds = Set(UserDefaults.standard.stringArray(forKey: Self.handledCallIdsKey) ?? [])
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

    /// Whether the call button shows for this contact. Chat Info's "Allow calls" switch is the
    /// only gate: a phone with no Nextcloud of its own can still start a call by asking the
    /// contact to host it (`call_request`), so hosting ability is not required here. If neither
    /// side can host, the attempt rings out to "no answer".
    func canCall(_ contact: Contact) -> Bool {
        contact.callsDisabled != true
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
        guard contact.callsDisabled != true else { return }
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
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await ChatService.shared.sendMessage(to: contact, content: CallCodec.encode(CallRequestContent(callId: callId, video: video)))
                } catch {
                    self.lastError = error.localizedDescription
                    await self.finish(reason: "failed", notifyPeer: false)
                    return
                }
                call.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(self?.ringTimeout ?? 75) * 1_000_000_000)
                    guard let self, let current = self.session, current === call, current.phase == .ringingOut else { return }
                    await self.finish(reason: "no_answer", notifyPeer: true)
                }
            }
            return
        }
        // Token is filled in once the conversation exists; the screen shows "Calling" meanwhile.
        let call = ActiveCall(id: callId, contact: contact, isOutgoing: true, server: server, token: "", video: video, phase: .ringingOut, hostsThisCall: true)
        session = call
        UIApplication.shared.isIdleTimerDisabled = true

        Task { [weak self] in
            guard let self else { return }
            let client = NextcloudTalkClient(server: server, auth: .basic(username: account.username, appPassword: account.appPassword))
            call.client = client
            do {
                let name = ContactsManager.shared.displayName(for: contact)
                let token = try await client.createPublicConversation(named: "KaChat call with \(name)")
                guard self.session === call else { await client.deleteConversation(token: token); return }
                let live = ActiveCall(id: call.id, contact: contact, isOutgoing: true, server: server, token: token, video: video, phase: .ringingOut, hostsThisCall: true)
                live.client = client
                self.session = live
                try await self.joinAndSignal(call: live)
                self.markHandled(live.id)
                let invite = CallInviteContent(callId: live.id, server: server.absoluteString, token: token, video: video)
                try await ChatService.shared.sendMessage(to: contact, content: CallCodec.encode(invite))
                live.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(self?.ringTimeout ?? 75) * 1_000_000_000)
                    guard let self, let current = self.session, current === live, current.phase == .ringingOut else { return }
                    await self.finish(reason: "no_answer", notifyPeer: true)
                }
            } catch {
                AppLog.log("[Call] Starting call failed: %@", error.localizedDescription)
                self.lastError = error.localizedDescription
                await self.finish(reason: "failed", notifyPeer: false)
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
            guard contact.callsDisabled != true, age < inviteFreshness else { return }
            guard canHost, let account = NextcloudService.shared.account, let server = account.serverURL else {
                // Neither side can host. Say so right away rather than letting their phone
                // ring out - the requester's screen turns this into "someone in this chat
                // needs Nextcloud Talk".
                markHandled(request.callId)
                Task { try? await ChatService.shared.sendMessage(to: contact, content: CallCodec.encode(CallResponseContent(callId: request.callId, accepted: false, reason: "no_host"))) }
                return
            }
            if let current = session {
                if current.id != request.callId {
                    Task { try? await ChatService.shared.sendMessage(to: contact, content: CallCodec.encode(CallResponseContent(callId: request.callId, accepted: false))) }
                }
                return
            }
            markHandled(request.callId)
            let call = ActiveCall(id: request.callId, contact: contact, isOutgoing: false, server: server, token: "", video: request.video, phase: .ringingIn, hostsThisCall: true)
            session = call
            UIApplication.shared.isIdleTimerDisabled = true
            startRinging(call)
            call.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, let current = self.session, current === call, current.phase == .ringingIn else { return }
                await self.finish(reason: "missed", notifyPeer: false)
            }
            // Open the room now so the requester can already be waiting in it as a guest when
            // we accept; we join the call itself on accept.
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
                    await self.finish(reason: "failed", notifyPeer: true)
                }
            }
        case .invite(let invite):
            guard let server = URL(string: invite.server), server.scheme?.lowercased() == "https" else { return }
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
                        await self.finish(reason: "failed", notifyPeer: true)
                    }
                }
                return
            }
            // Once per call id, ever - see `handledCallIds`. A re-ingested invite for a call that
            // already rang (or already ended) is history, not a phone ringing.
            guard !handledCallIds.contains(invite.callId) else { return }
            guard let contact = ContactsManager.shared.getContact(byAddress: contactAddress) else { return }
            guard contact.callsDisabled != true else { return }
            guard age < inviteFreshness else { return }
            if let current = session {
                // Already on a call: a different invite gets a decline (the caller sees "busy"
                // rather than ringing out); this same invite delivered twice is simply ignored.
                if current.id != invite.callId {
                    Task { try? await ChatService.shared.sendMessage(to: contact, content: CallCodec.encode(CallResponseContent(callId: invite.callId, accepted: false))) }
                }
                return
            }
            markHandled(invite.callId)
            let call = ActiveCall(id: invite.callId, contact: contact, isOutgoing: false, server: server, token: invite.token, video: invite.video, phase: .ringingIn, hostsThisCall: false)
            session = call
            UIApplication.shared.isIdleTimerDisabled = true
            startRinging(call)
            call.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, let current = self.session, current === call, current.phase == .ringingIn else { return }
                await self.finish(reason: "missed", notifyPeer: false)
            }
        case .response(let response):
            // A response or an end for a call this device is not on means that call is over;
            // remember it so its invite, should it arrive later in the same batch, stays quiet.
            markHandled(response.callId)
            guard let call = session, call.id == response.callId, call.isOutgoing else { return }
            if response.accepted {
                if call.phase == .ringingOut { call.phase = .connecting }
            } else {
                let reason = response.reason == "no_host" ? "no_host" : "declined"
                Task { await finish(reason: reason, notifyPeer: false) }
            }
        case .end(let end):
            markHandled(end.callId)
            guard let call = session, call.id == end.callId else { return }
            Task { await finish(reason: call.phase == .ringingIn ? "missed" : "remote_hangup", notifyPeer: false) }
        }
    }

    func acceptIncoming() {
        guard let call = session, call.phase == .ringingIn else { return }
        stopRinging(call)
        call.timeoutTask?.cancel()
        call.phase = .connecting
        Task { [weak self] in
            guard let self else { return }
            if call.hostsThisCall {
                // A call the contact asked us to host: the room was opened when it rang; the
                // owning client is already on the call. Wait for the room if the invite is
                // still on its way out.
                var waited = 0
                while call.token.isEmpty, waited < 100, self.session === call {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    waited += 1
                }
                guard self.session === call, !call.token.isEmpty, call.client != nil else {
                    await self.finish(reason: "failed", notifyPeer: true)
                    return
                }
            } else {
                guard let server = call.server else { return }
                call.client = NextcloudTalkClient(server: server, auth: .guest)
            }
            do {
                try await self.joinAndSignal(call: call)
                try? await ChatService.shared.sendMessage(to: call.contact, content: CallCodec.encode(CallResponseContent(callId: call.id, accepted: true)))
            } catch {
                AppLog.log("[Call] Joining call failed: %@", error.localizedDescription)
                self.lastError = error.localizedDescription
                await self.finish(reason: "failed", notifyPeer: true)
            }
        }
    }

    func declineIncoming() {
        guard let call = session, call.phase == .ringingIn else { return }
        stopRinging(call)
        let contact = call.contact
        let callId = call.id
        Task { try? await ChatService.shared.sendMessage(to: contact, content: CallCodec.encode(CallResponseContent(callId: callId, accepted: false))) }
        Task { await finish(reason: "declined", notifyPeer: false) }
    }

    func hangUp() {
        guard let call = session else { return }
        if case .ended = call.phase { return }
        Task { await finish(reason: call.isOutgoing && call.phase == .ringingOut ? "cancelled" : "hangup", notifyPeer: true) }
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
        call.isMuted.toggle()
        call.webrtc?.setMuted(call.isMuted)
    }

    func toggleSpeaker() {
        guard let call = session else { return }
        call.isSpeakerOn.toggle()
        call.webrtc?.setSpeaker(call.isSpeakerOn)
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

    // MARK: - Talk + WebRTC plumbing

    /// Joins the conversation and the call, brings up the peer connection, and starts the
    /// signaling pull loop. Shared by both directions; only the `client` (own account vs
    /// guest) differs.
    private func joinAndSignal(call: ActiveCall) async throws {
        guard let client = call.client else { return }
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
                if call.connectedAt == nil { call.connectedAt = Date() }
                call.phase = .connected
                call.statusDetail = nil
            case .disconnected:
                call.statusDetail = "Reconnecting"
            case .failed:
                Task { await self.finish(reason: "failed", notifyPeer: true) }
            default:
                break
            }
        }
        webrtc.setSpeaker(call.isSpeakerOn)
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
                    await finish(reason: "remote_hangup", notifyPeer: false)
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
                await finish(reason: "remote_hangup", notifyPeer: false)
            }
        case .message(let data):
            guard let from = data["from"] as? String, let type = data["type"] as? String else { return }
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

    private func finish(reason: String, notifyPeer: Bool) async {
        guard let call = session else { return }
        if case .ended = call.phase { return }
        stopRinging(call)
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

        if notifyPeer {
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
        // Let the "Call ended" state show for a moment, then clear the screen.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let current = self.session, current === call else { return }
            self.session = nil
        }
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
