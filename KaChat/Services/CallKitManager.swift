import Foundation
import CallKit
import AVFoundation
import UIKit
import WebRTC

/// The phone's own call machinery around `CallService`: incoming KaChat calls ring through
/// CallKit like a phone call (lock screen, full-screen answer UI, Recents, "busy" against a
/// cellular call), outgoing ones are registered with it so the system treats them the same,
/// and the audio session is handed over by iOS at the right moments.
///
/// CallKit is a mirror, not the state machine. `CallService` decides what a call is; this
/// class reports it and relays the user's answer / hang-up / mute taps from the system UI back
/// to `CallService.perform*`. Where CallKit refuses to take part (a region where it is
/// disabled, Do Not Disturb filtering an incoming call, Mac Catalyst quirks) every method
/// reports failure and `CallService` falls back to ringing inside the app as before.
final class CallKitManager: NSObject {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    /// True from `didActivate` to `didDeactivate` of the audio session for the current call:
    /// iOS owns activation then, and WebRTC must not touch it.
    private(set) var audioSessionActive = false

    /// Calls CallKit is showing right now (reported incoming, or started outgoing). Used to
    /// tell "the user hung up in the system UI" from "the call ended on its own".
    private var knownCalls: Set<UUID> = []

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        if let icon = UIImage(named: "CallKitIcon") ?? UIImage(systemName: "phone.fill") {
            config.iconTemplateImageData = icon.pngData()
        }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        // WebRTC must not start or stop the audio unit on its own once CallKit is in the
        // picture: iOS activates the session when a call is answered or started and tells us
        // in `didActivate`. Set once, before any peer connection exists.
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
    }

    /// Touch at launch so the provider exists before the first VoIP push or call.
    func prepare() {}

    // MARK: - Reporting (CallService -> CallKit)

    /// Rings the phone. `completion(nil)` means CallKit is showing the call; an error means it
    /// is not (Do Not Disturb, a blocked number, CallKit unavailable) and the caller should
    /// either ring in-app or treat the call as missed. Reporting the same UUID twice is
    /// harmless - iOS answers `callUUIDAlreadyExists`, which counts as the report a VoIP push
    /// demands.
    func reportIncoming(uuid: UUID, displayName: String, handle: String, video: Bool, completion: @escaping (Error?) -> Void) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = displayName
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        knownCalls.insert(uuid)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                let alreadyKnown = (error as? CXErrorCodeIncomingCallError)?.code == .callUUIDAlreadyExists
                if !alreadyKnown {
                    self?.knownCalls.remove(uuid)
                    AppLog.log("[CallKit] Incoming call not shown: %@", error.localizedDescription)
                }
                completion(alreadyKnown ? nil : error)
            } else {
                completion(nil)
            }
        }
    }

    /// Refreshes the name and video flag of a call already reported (a VoIP push reports before
    /// the contact list is loaded; the real name comes a moment later).
    func updateCall(uuid: UUID, displayName: String, video: Bool) {
        guard knownCalls.contains(uuid) else { return }
        let update = CXCallUpdate()
        update.localizedCallerName = displayName
        update.hasVideo = video
        provider.reportCall(with: uuid, updated: update)
    }

    /// A VoIP push that did not turn into a ringing call (stale, calls off for that contact,
    /// busy, unknown sender) must still be reported - iOS ends VoIP pushes for an app that
    /// swallows one. Reported and ended in the same breath; Recents shows a missed call, which
    /// is what it was.
    func reportDroppedIncoming(uuid: UUID, displayName: String, handle: String, video: Bool, reason: CXCallEndedReason) {
        reportIncoming(uuid: uuid, displayName: displayName, handle: handle, video: video) { [weak self] _ in
            self?.provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
            self?.knownCalls.remove(uuid)
        }
    }

    /// Registers an outgoing call. `completion(false)` = CallKit refused; the call goes on
    /// in-app only.
    func requestStart(uuid: UUID, displayName: String, handle: String, video: Bool, completion: @escaping (Bool) -> Void) {
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.contactIdentifier = displayName
        action.isVideo = video
        knownCalls.insert(uuid)
        controller.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                self?.knownCalls.remove(uuid)
                AppLog.log("[CallKit] Start call refused: %@", error.localizedDescription)
                completion(false)
            } else {
                let update = CXCallUpdate()
                update.localizedCallerName = displayName
                update.hasVideo = video
                self?.provider.reportCall(with: uuid, updated: update)
                completion(true)
            }
        }
    }

    func reportOutgoingConnecting(uuid: UUID) {
        guard knownCalls.contains(uuid) else { return }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
    }

    func reportOutgoingConnected(uuid: UUID) {
        guard knownCalls.contains(uuid) else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// The call ended for a reason that did not come through a CallKit action (the other side
    /// hung up, nobody answered, it failed). Ends the system call to match.
    func reportEnded(uuid: UUID, reason: CXCallEndedReason) {
        guard knownCalls.contains(uuid) else { return }
        knownCalls.remove(uuid)
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    func isKnown(_ uuid: UUID) -> Bool {
        knownCalls.contains(uuid)
    }

    // MARK: - Requests (in-app buttons -> CallKit -> CallService.perform*)

    /// Answer / hang up / mute pressed inside the app. The action goes through CallKit so the
    /// system UI stays in step; `completion(false)` means CallKit did not take it and the
    /// caller should perform the change directly.
    func requestAnswer(uuid: UUID, completion: @escaping (Bool) -> Void) {
        request(CXAnswerCallAction(call: uuid), uuid: uuid, completion: completion)
    }

    func requestEnd(uuid: UUID, completion: @escaping (Bool) -> Void) {
        request(CXEndCallAction(call: uuid), uuid: uuid, completion: completion)
    }

    func requestMute(uuid: UUID, muted: Bool, completion: @escaping (Bool) -> Void) {
        request(CXSetMutedCallAction(call: uuid, muted: muted), uuid: uuid, completion: completion)
    }

    private func request(_ action: CXAction, uuid: UUID, completion: @escaping (Bool) -> Void) {
        guard knownCalls.contains(uuid) else { completion(false); return }
        controller.request(CXTransaction(action: action)) { error in
            if let error {
                AppLog.log("[CallKit] %@ refused: %@", String(describing: type(of: action)), error.localizedDescription)
            }
            completion(error == nil)
        }
    }

    // MARK: - Audio

    /// Category and mode for a call, applied before CallKit activates the session (it keeps
    /// whatever was configured at activation). Safe to call repeatedly.
    static func configureAudioSession(video: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(.playAndRecord, mode: video ? .videoChat : .voiceChat, options: video ? [.defaultToSpeaker, .allowBluetoothHFP] : [.allowBluetoothHFP])
        } catch {
            AppLog.log("[CallKit] Audio session category failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            self.knownCalls.removeAll()
            await CallService.shared.performEnd(reason: "failed")
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard let call = CallService.shared.session, call.uuid == action.callUUID else {
                action.fail()
                return
            }
            CallKitManager.configureAudioSession(video: call.video)
            action.fulfill()
            self.provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            // A VoIP push reports the call before the app has finished loading the wallet
            // behind it; the user can answer in that window. Give the call a moment to exist.
            var waited = 0
            while CallService.shared.session?.uuid != action.callUUID, waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard let call = CallService.shared.session, call.uuid == action.callUUID else {
                action.fail()
                return
            }
            CallKitManager.configureAudioSession(video: call.video)
            CallService.shared.performAccept()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.knownCalls.remove(action.callUUID)
            guard let call = CallService.shared.session, call.uuid == action.callUUID else {
                // Ending something we do not hold yet or any more: a VoIP-pushed call still
                // waiting for the app to load (remember the decline so it never rings), a
                // placeholder, an already-finished call.
                CallService.shared.noteEndedBeforeRinging(action.callUUID)
                action.fulfill()
                return
            }
            call.endedByCallKit = true
            await CallService.shared.performEnd(reason: nil)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            guard let call = CallService.shared.session, call.uuid == action.callUUID else {
                action.fail()
                return
            }
            CallService.shared.performSetMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(audioSession)
        rtc.isAudioEnabled = true
        Task { @MainActor in
            self.audioSessionActive = true
            CallService.shared.audioSessionBecameActive()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(audioSession)
        Task { @MainActor in
            self.audioSessionActive = false
        }
    }
}
