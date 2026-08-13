import Foundation
import CryptoKit

/// Child Mode password management (Settings > Security > Child Mode, and the onboarding
/// "Who will use KaChat?" step).
///
/// Storage design:
/// - The password itself is NEVER stored. A random 16-byte salt plus SHA-256(salt || password)
///   is kept as a JSON record in the Keychain via `KeychainService` (device-scoped and Secure
///   Enclave-wrapped, the same pattern as the seed phrase).
/// - The ON/OFF flag lives in `AppSettings.childModeEnabled` (fast to read from every gate:
///   dock, deep links, notification paths) - but turning child mode OFF is only ever done after
///   `verifyPassword` succeeds against the Keychain record, so editing the settings blob alone
///   isn't enough to silently re-enable the hidden features from the UI flows.
/// - Deliberately NO biometrics anywhere in this feature: the whole point is that the device
///   owner (the child) can pass Face ID but must not know the parent's password.
///
/// Kept intentionally UI-framework-free and singleton-shaped so the Android/desktop ports can
/// mirror the same API against their own keystores.
@MainActor
final class ChildModeService {
    static let shared = ChildModeService()

    private init() {}

    /// The stored record: random salt + SHA-256(salt || UTF-8 password). JSON-encoded because
    /// every other Keychain payload in the app is (wallet, seed phrase, group bags).
    private struct PasswordRecord: Codable {
        let salt: Data
        let hash: Data
    }

    // MARK: - Queries

    /// A password has been set at some point (wizard "Child" choice, or Settings flow) -
    /// drives whether the Child Mode screen shows "set a password" or "change password".
    var hasPassword: Bool {
        KeychainService.shared.hasChildModePasswordRecord()
    }

    /// Convenience mirror of the settings flag for call sites that don't hold a view model.
    var isEnabled: Bool {
        AppSettings.load().childModeEnabled
    }

    // MARK: - Password lifecycle

    /// Hashes and stores `password` (free-form: 4 digits, 8 digits, or anything non-empty -
    /// the UI enforces non-empty + confirmation, this just refuses the degenerate empty case).
    func setPassword(_ password: String) throws {
        guard !password.isEmpty else {
            throw KasiaError.keychainError("Child Mode password cannot be empty")
        }
        var saltBytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        guard status == errSecSuccess else {
            throw KasiaError.keychainError("Failed to generate Child Mode salt")
        }
        let salt = Data(saltBytes)
        let record = PasswordRecord(salt: salt, hash: Self.hash(password: password, salt: salt))
        let data = try JSONEncoder().encode(record)
        try KeychainService.shared.saveChildModePasswordRecord(data)
    }

    /// Constant-shape check of `password` against the stored record. False when no record
    /// exists (nothing to verify against - callers gate on `hasPassword` first).
    func verifyPassword(_ password: String) -> Bool {
        guard let data = try? KeychainService.shared.loadChildModePasswordRecord(),
              let record = try? JSONDecoder().decode(PasswordRecord.self, from: data) else {
            return false
        }
        let candidate = Self.hash(password: password, salt: record.salt)
        // Constant-time comparison - not strictly required for a parental-control PIN, but free.
        guard candidate.count == record.hash.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, record.hash) { difference |= a ^ b }
        return difference == 0
    }

    /// Traditional change flow: current password must verify, then the new one replaces the
    /// record (fresh salt). Returns false (and changes nothing) on a wrong current password.
    func changePassword(current: String, to newPassword: String) throws -> Bool {
        guard verifyPassword(current) else { return false }
        try setPassword(newPassword)
        return true
    }

    /// Full reset to the never-configured state: the current password must verify, then the
    /// Keychain record is deleted AND the `childModeEnabled` flag is switched off through the
    /// standard settings save path (`AppSettings.save` posts `.settingsDidChange`, so push
    /// re-registration and the dock gating react exactly as they do for the normal OFF toggle).
    /// Returns false (and changes nothing) on a wrong password.
    ///
    /// NOTE for UI callers holding a `SettingsViewModel`: its `.settingsDidChange` observer
    /// deliberately ignores save notifications (object != nil), so refresh its in-memory
    /// `settings.childModeEnabled` yourself after this returns true (see ChildModeSettingsView).
    func clearConfiguration(current password: String) throws -> Bool {
        guard verifyPassword(password) else { return false }
        try KeychainService.shared.deleteChildModePasswordRecord()
        var settings = AppSettings.load()
        if settings.childModeEnabled {
            settings.childModeEnabled = false
            AppSettings.save(settings)
        }
        return true
    }

    private static func hash(password: String, salt: Data) -> Data {
        var input = salt
        input.append(Data(password.utf8))
        return Data(SHA256.hash(data: input))
    }
}
