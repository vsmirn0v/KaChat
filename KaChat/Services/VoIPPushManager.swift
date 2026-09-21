import Foundation
import PushKit

/// The VoIP push channel: the one way a closed KaChat can ring.
///
/// APNs alert pushes cannot wake a terminated app into a ringing state; VoIP pushes can, on the
/// condition that every single one is turned into a CallKit call before the handler returns
/// (an app that swallows one loses the privilege). `CallService.handleVoIPPush` honours that:
/// a push that should not ring is reported and ended in the same breath.
///
/// The caller's phone asks the push service to send this push right after its opening call
/// message went on chain (`PushNotificationManager.requestRing`), so a callee's phone rings
/// within seconds even when KaChat is not running; the chain message is what carries the
/// room when the push cannot be decrypted, and what settles the call in both chats afterwards.
final class VoIPPushManager: NSObject {
    static let shared = VoIPPushManager()

    private var registry: PKPushRegistry?

    private override init() {
        super.init()
    }

    /// Registers for VoIP pushes. Called from `didFinishLaunching` - Apple requires the
    /// registration to exist by then so a push that launches the app finds it.
    func start() {
        guard registry == nil else { return }
        CallKitManager.shared.prepare()
        // No CallKit, no VoIP pushes: iOS requires every one to become a CallKit call.
        guard CallKitManager.isAvailable else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }
}

extension VoIPPushManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        Task { @MainActor in
            PushNotificationManager.shared.didUpdateVoIPToken(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
            PushNotificationManager.shared.didUpdateVoIPToken(nil)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        // The registry's queue is main, so this is synchronous with the handler: the CallKit
        // report happens before `completion()` as iOS requires.
        MainActor.assumeIsolated {
            CallService.shared.handleVoIPPush(payload.dictionaryPayload)
        }
        completion()
    }
}
