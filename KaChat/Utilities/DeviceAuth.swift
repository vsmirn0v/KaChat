import Foundation
import LocalAuthentication
import UIKit

/// Gates sensitive actions (viewing the seed phrase, unlocking a saved account) behind whatever
/// the device's own lock screen is set to — Face ID/Touch ID, falling back to the device passcode
/// — mirroring Android's `authenticateWithDeviceCredential`.
///
/// A device with no passcode at all used to fall straight through to `onSuccess`: the "gate"
/// on the recovery phrase was then no gate, and anyone holding the unlocked phone could read
/// it. Now it refuses, says why, and calls `onFailure`.
enum DeviceAuth {
    static func authenticate(
        reason: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping () -> Void = {}
    ) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            presentPasscodeRequired()
            onFailure()
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                if success {
                    onSuccess()
                } else {
                    onFailure()
                }
            }
        }
    }

    /// One alert, from wherever the reveal was asked: the callers are spread over several
    /// screens that have no shared message surface.
    private static func presentPasscodeRequired() {
        let alert = UIAlertController(
            title: "Passcode Required",
            message: "Set a passcode on this iPhone (Settings > Face ID & Passcode) to view or unlock secret keys in KaChat.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else { return }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(alert, animated: true)
    }
}
