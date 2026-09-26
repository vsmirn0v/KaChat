import Foundation
import CryptoKit
import CommonCrypto

/// Simple Mode password management (Settings > Security > Simple Mode, and the onboarding
/// "Who will use KaChat?" step).
///
/// Storage design:
/// - The password itself is NEVER stored. A random 16-byte salt plus SHA-256(salt || password)
///   is kept as a JSON record in the Keychain via `KeychainService` (device-scoped and Secure
///   Enclave-wrapped, the same pattern as the seed phrase).
/// - The ON/OFF flag lives in `AppSettings.childModeEnabled` (fast to read from every gate:
///   dock, deep links, notification paths) - but turning simple mode OFF is only ever done after
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

    /// The stored record: random salt + PBKDF2-HMAC-SHA256(password, salt) over `iterations`
    /// rounds. JSON-encoded because every other Keychain payload in the app is (wallet, seed
    /// phrase, group bags). Records written before the work factor existed carry no
    /// `iterations` and were a single SHA-256; they verify the old way once and are rewritten.
    private struct PasswordRecord: Codable {
        let salt: Data
        let hash: Data
        var iterations: Int?
    }

    /// About 60 ms on a recent iPhone: nothing at the lock, an eternity for a brute force of
    /// an extracted record.
    private static let pbkdf2Iterations = 120_000

    // MARK: - Attempt limiting

    private static let failedAttemptsKey = "kachat_simple_mode_failed_attempts"
    private static let lockedUntilKey = "kachat_simple_mode_locked_until"
    private static let freeAttempts = 5

    /// Seconds left before another attempt is accepted, nil when attempts are open. Five
    /// wrong answers earn 30 seconds; each one after doubles it, up to an hour.
    var lockoutRemainingSeconds: Int? {
        let until = UserDefaults.standard.double(forKey: Self.lockedUntilKey)
        let remaining = until - Date().timeIntervalSince1970
        return remaining > 0 ? Int(remaining.rounded(.up)) : nil
    }

    private func recordFailedAttempt() {
        let defaults = UserDefaults.standard
        let attempts = defaults.integer(forKey: Self.failedAttemptsKey) + 1
        defaults.set(attempts, forKey: Self.failedAttemptsKey)
        guard attempts >= Self.freeAttempts else { return }
        let penalty = min(3600.0, 30.0 * pow(2.0, Double(attempts - Self.freeAttempts)))
        defaults.set(Date().timeIntervalSince1970 + penalty, forKey: Self.lockedUntilKey)
    }

    private func clearFailedAttempts() {
        UserDefaults.standard.removeObject(forKey: Self.failedAttemptsKey)
        UserDefaults.standard.removeObject(forKey: Self.lockedUntilKey)
    }

    // MARK: - Queries

    /// A password has been set at some point (wizard "Child" choice, or Settings flow) -
    /// drives whether the Simple Mode screen shows "set a password" or "change password".
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
            throw KasiaError.keychainError("Simple Mode password cannot be empty")
        }
        var saltBytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        guard status == errSecSuccess else {
            throw KasiaError.keychainError("Failed to generate Simple Mode salt")
        }
        let salt = Data(saltBytes)
        let record = PasswordRecord(salt: salt, hash: Self.derive(password: password, salt: salt, iterations: Self.pbkdf2Iterations), iterations: Self.pbkdf2Iterations)
        let data = try JSONEncoder().encode(record)
        try KeychainService.shared.saveChildModePasswordRecord(data)
        clearFailedAttempts()
    }

    /// Constant-shape check of `password` against the stored record. False when no record
    /// exists (nothing to verify against - callers gate on `hasPassword` first).
    func verifyPassword(_ password: String) -> Bool {
        guard lockoutRemainingSeconds == nil else { return false }
        guard let data = try? KeychainService.shared.loadChildModePasswordRecord(),
              let record = try? JSONDecoder().decode(PasswordRecord.self, from: data) else {
            return false
        }
        let candidate: Data
        if let iterations = record.iterations {
            candidate = Self.derive(password: password, salt: record.salt, iterations: iterations)
        } else {
            candidate = Self.legacyHash(password: password, salt: record.salt)
        }
        // Constant-time comparison - not strictly required for a parental-control PIN, but free.
        guard candidate.count == record.hash.count else { recordFailedAttempt(); return false }
        var difference: UInt8 = 0
        for (a, b) in zip(candidate, record.hash) { difference |= a ^ b }
        guard difference == 0 else {
            recordFailedAttempt()
            return false
        }
        clearFailedAttempts()
        if record.iterations == nil {
            // A record from before the work factor: the password is known good right now, so
            // rewrite it with one.
            try? setPassword(password)
        }
        return true
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

    private static func derive(password: String, salt: Data, iterations: Int) -> Data {
        var output = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            UInt32(iterations),
            &output, output.count
        )
        guard status == kCCSuccess else { return Data() }
        return Data(output)
    }

    /// The pre-work-factor record: a single SHA-256(salt || password).
    private static func legacyHash(password: String, salt: Data) -> Data {
        var input = salt
        input.append(Data(password.utf8))
        return Data(SHA256.hash(data: input))
    }
}
