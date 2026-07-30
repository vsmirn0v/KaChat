import Foundation
import LocalAuthentication

/// Gates sensitive actions (viewing the seed phrase, unlocking a saved account) behind whatever
/// the device's own lock screen is set to — Face ID/Touch ID, falling back to the device passcode
/// — mirroring Android's `authenticateWithDeviceCredential`. Falls straight through to
/// `onSuccess` when the device has no passcode configured at all, since there's no credential to
/// require.
enum DeviceAuth {
    static func authenticate(
        reason: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping () -> Void = {}
    ) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            onSuccess()
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
}
