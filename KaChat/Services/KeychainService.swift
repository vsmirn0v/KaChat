import Foundation
import Security
import CryptoKit

final class KeychainService {
    static let shared = KeychainService()

    private let serviceName = "com.kachat.app"
    private let keychainAccessGroup: String? = {
        if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
           !prefix.isEmpty {
            return prefix + "com.kachat.app"
        }
        return nil
    }()
    private let secureEnclaveTag = "com.kachat.app.secure-enclave-key"
    private let secureEnclaveHeader = Data([0x4B, 0x53, 0x45, 0x31]) // "KSE1"

    /// Device identifier derived from SE public key hash (cached)
    private var cachedDeviceId: String?

    private enum KeychainKey: String {
        case seedPhrase = "kachat_seed_phrase"
        case wallet = "kachat_wallet"
        case privateKey = "kachat_private_key"
    }

    private enum SecureEnclaveAlgorithm: UInt8 {
        case eciesCofactorSha256AesGcm = 1
        case eciesStandardSha256AesGcm = 2

        var secKeyAlgorithm: SecKeyAlgorithm {
            switch self {
            case .eciesCofactorSha256AesGcm:
                return .eciesEncryptionCofactorX963SHA256AESGCM
            case .eciesStandardSha256AesGcm:
                return .eciesEncryptionStandardX963SHA256AESGCM
            }
        }
    }

    private init() {}

    // MARK: - Device Identifier

    /// Returns a stable device identifier derived from the Secure Enclave public key hash.
    /// This identifier is unique per device and survives app reinstalls (as long as SE key persists).
    private func deviceIdentifier() throws -> String {
        if let cached = cachedDeviceId {
            return cached
        }

        let seKey = try secureEnclavePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(seKey) else {
            throw KasiaError.keychainError("Failed to get SE public key for device ID")
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw KasiaError.keychainError("Failed to export SE public key")
        }

        // Hash the public key to create a stable, short identifier
        let hash = SHA256.hash(data: publicKeyData)
        let deviceId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        cachedDeviceId = deviceId
        return deviceId
    }

    /// Clears the cached device identifier (used when SE key is deleted)
    private func clearDeviceIdCache() {
        cachedDeviceId = nil
    }

    // MARK: - Seed Phrase (Device-specific, SE-wrapped)

    func saveSeedPhrase(_ seedPhrase: SeedPhrase) throws {
        let data = try JSONEncoder().encode(seedPhrase)
        try saveSensitiveData(data, baseKey: .seedPhrase)
    }

    func loadSeedPhrase() throws -> SeedPhrase? {
        guard let data = try loadSensitiveData(baseKey: .seedPhrase) else {
            return nil
        }
        return try JSONDecoder().decode(SeedPhrase.self, from: data)
    }

    func deleteSeedPhrase() throws {
        try deleteSensitiveData(baseKey: .seedPhrase)
    }

    /// Check if seed phrase exists for current device
    func hasSeedPhrase() -> Bool {
        do {
            return try loadSeedPhrase() != nil
        } catch {
            return false
        }
    }

    // MARK: - Wallet

    func saveWallet(_ wallet: Wallet) throws {
        let data = try JSONEncoder().encode(wallet)
        try save(data: data, forKey: .wallet)
    }

    func loadWallet() throws -> Wallet? {
        guard let data = try load(forKey: .wallet) else {
            return nil
        }
        return try JSONDecoder().decode(Wallet.self, from: data)
    }

    func deleteWallet() throws {
        try delete(forKey: .wallet)
    }

    // MARK: - Private Key (Device-specific, SE-wrapped)

    func savePrivateKey(_ privateKey: Data) throws {
        try saveSensitiveData(privateKey, baseKey: .privateKey)
    }

    func loadPrivateKey() throws -> Data? {
        // Try device-specific storage first
        if let data = try loadSensitiveData(baseKey: .privateKey) {
            return data
        }

        // Migration: try loading from legacy storage
        return try migrateLegacyPrivateKey()
    }

    func deletePrivateKey() throws {
        try deleteSensitiveData(baseKey: .privateKey)
    }

    /// Check if private key exists for current device
    func hasPrivateKey() -> Bool {
        do {
            return try loadPrivateKey() != nil
        } catch {
            return false
        }
    }

    /// Migrate legacy private key from old storage format
    private func migrateLegacyPrivateKey() throws -> Data? {
        // Try shared group first
        if let data = try loadLegacyPrivateKeyData(includeAccessGroup: true) {
            let rawKey: Data
            if data.starts(with: secureEnclaveHeader) {
                rawKey = try unwrapPrivateKey(data)
            } else {
                rawKey = data
            }

            // Save to new device-specific format
            try saveSensitiveData(rawKey, baseKey: .privateKey)
            // Clean up legacy storage
            try? deleteLegacyPrivateKey(includeAccessGroup: true)
            return rawKey
        }

        // Try non-shared group (older legacy)
        guard let legacyData = try loadLegacyPrivateKeyData(includeAccessGroup: false) else {
            return nil
        }

        let rawKey: Data
        if legacyData.starts(with: secureEnclaveHeader) {
            let legacyKey = try secureEnclavePrivateKey(includeAccessGroup: false, createIfMissing: false)
            rawKey = try unwrapPrivateKey(legacyData, using: legacyKey)
            try? deleteSecureEnclaveKey(includeAccessGroup: false)
        } else {
            rawKey = legacyData
        }

        // Save to new device-specific format
        try saveSensitiveData(rawKey, baseKey: .privateKey)
        // Clean up legacy storage
        try? deleteLegacyPrivateKey(includeAccessGroup: false)
        return rawKey
    }

    // MARK: - Clear All

    /// Clears only the active account's default wallet keys, preserving account snapshots.
    func clearCurrentAccountData() throws {
        try deleteSeedPhrase()
        try deleteWallet()
        try deletePrivateKey()
        try? deleteLegacyPrivateKey(includeAccessGroup: true)
        try? deleteLegacyPrivateKey(includeAccessGroup: false)
    }

    func clearAll() throws {
        try deleteSeedPhrase()
        try deleteWallet()
        try deletePrivateKey()
        // Also clean up any legacy storage
        try? deleteLegacyPrivateKey(includeAccessGroup: true)
        try? deleteLegacyPrivateKey(includeAccessGroup: false)
        try deleteSecureEnclaveKey()
        clearDeviceIdCache()
    }

    func privateKeyStorageStatus() -> String {
        do {
            let deviceId = try deviceIdentifier()
            let deviceKey = "\(KeychainKey.privateKey.rawValue).\(deviceId)"

            guard let data = try loadSensitiveDataRaw(keyName: deviceKey) else {
                // Check legacy storage
                if let legacyData = try loadLegacyPrivateKeyData(includeAccessGroup: true) {
                    if legacyData.starts(with: secureEnclaveHeader) {
                        return "legacy wrapped (needs migration)"
                    }
                    return "legacy raw (needs migration)"
                }
                return "missing"
            }

            if data.starts(with: secureEnclaveHeader) {
                let hasKey = secureEnclaveKeyExists(includeAccessGroup: true)
                return "device-specific wrapped (SE: \(hasKey ? "ok" : "missing"), device: \(deviceId))"
            }

            return "device-specific raw (device: \(deviceId))"
        } catch {
            return "error (\(error.localizedDescription))"
        }
    }

    /// Returns the current device identifier for diagnostics
    func currentDeviceId() -> String? {
        try? deviceIdentifier()
    }

    // MARK: - Per-Account Snapshots (Device-specific, SE-wrapped)

    func saveAccountSnapshot(wallet: Wallet, seedPhrase: SeedPhrase, privateKey: Data) throws {
        let seedData = try JSONEncoder().encode(seedPhrase)
        try saveSensitiveDataForAccount(seedData, baseKey: .seedPhrase, publicAddress: wallet.publicAddress)
        try saveSensitiveDataForAccount(privateKey, baseKey: .privateKey, publicAddress: wallet.publicAddress)
    }

    func loadAccountSnapshot(publicAddress: String) throws -> (seedPhrase: SeedPhrase, privateKey: Data)? {
        guard let seedData = try loadSensitiveDataForAccount(baseKey: .seedPhrase, publicAddress: publicAddress),
              let privateKey = try loadSensitiveDataForAccount(baseKey: .privateKey, publicAddress: publicAddress) else {
            return nil
        }

        let seedPhrase = try JSONDecoder().decode(SeedPhrase.self, from: seedData)
        return (seedPhrase, privateKey)
    }

    func deleteAccountSnapshot(publicAddress: String) throws {
        try deleteSensitiveDataForAccount(baseKey: .seedPhrase, publicAddress: publicAddress)
        try deleteSensitiveDataForAccount(baseKey: .privateKey, publicAddress: publicAddress)
    }

    // MARK: - Device-Specific Sensitive Data Storage

    /// Saves sensitive data with device-specific key name and SE wrapping
    private func saveSensitiveData(_ data: Data, baseKey: KeychainKey) throws {
        let deviceId = try deviceIdentifier()
        let keyName = "\(baseKey.rawValue).\(deviceId)"

        // Wrap with Secure Enclave
        let wrapped: Data
        if let wrappedData = tryWrapPrivateKey(data) {
            wrapped = wrappedData
        } else {
            // Fallback to raw storage if SE unavailable
            wrapped = data
        }

        try saveSensitiveDataRaw(wrapped, keyName: keyName)
    }

    /// Loads sensitive data from device-specific storage, unwrapping if needed
    private func loadSensitiveData(baseKey: KeychainKey) throws -> Data? {
        let deviceId = try deviceIdentifier()
        let keyName = "\(baseKey.rawValue).\(deviceId)"

        guard let data = try loadSensitiveDataRaw(keyName: keyName) else {
            return nil
        }

        if data.starts(with: secureEnclaveHeader) {
            return try unwrapPrivateKey(data)
        }

        return data
    }

    /// Deletes sensitive data from device-specific storage
    private func deleteSensitiveData(baseKey: KeychainKey) throws {
        let deviceId = try deviceIdentifier()
        let keyName = "\(baseKey.rawValue).\(deviceId)"
        try deleteSensitiveDataRaw(keyName: keyName)
    }

    private func saveSensitiveDataForAccount(_ data: Data, baseKey: KeychainKey, publicAddress: String) throws {
        let keyName = try accountScopedKeyName(baseKey: baseKey, publicAddress: publicAddress)

        let wrapped: Data
        if let wrappedData = tryWrapPrivateKey(data) {
            wrapped = wrappedData
        } else {
            wrapped = data
        }

        try saveSensitiveDataRaw(wrapped, keyName: keyName)
    }

    private func loadSensitiveDataForAccount(baseKey: KeychainKey, publicAddress: String) throws -> Data? {
        let keyName = try accountScopedKeyName(baseKey: baseKey, publicAddress: publicAddress)
        guard let data = try loadSensitiveDataRaw(keyName: keyName) else {
            return nil
        }
        if data.starts(with: secureEnclaveHeader) {
            return try unwrapPrivateKey(data)
        }
        return data
    }

    private func deleteSensitiveDataForAccount(baseKey: KeychainKey, publicAddress: String) throws {
        let keyName = try accountScopedKeyName(baseKey: baseKey, publicAddress: publicAddress)
        try deleteSensitiveDataRaw(keyName: keyName)
    }

    private func accountScopedKeyName(baseKey: KeychainKey, publicAddress: String) throws -> String {
        let deviceId = try deviceIdentifier()
        let normalizedAddress = publicAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "_")
        return "\(baseKey.rawValue).\(deviceId).\(normalizedAddress)"
    }

    /// Low-level save for device-specific data (no sync, device-only access)
    private func saveSensitiveDataRaw(_ data: Data, keyName: String) throws {
        var query = genericPasswordQueryForKey(keyName, includeAccessGroup: true)

        SecItemDelete(query as CFDictionary)

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // Fallback without access group
            var fallbackQuery = genericPasswordQueryForKey(keyName, includeAccessGroup: false)
            SecItemDelete(fallbackQuery as CFDictionary)
            fallbackQuery[kSecValueData as String] = data
            fallbackQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            fallbackQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse

            let fallbackStatus = SecItemAdd(fallbackQuery as CFDictionary, nil)
            guard fallbackStatus == errSecSuccess else {
                throw KasiaError.keychainError("Failed to save sensitive data: \(fallbackStatus)")
            }
            return
        }
        guard status == errSecSuccess else {
            throw KasiaError.keychainError("Failed to save sensitive data: \(status)")
        }
    }

    /// Low-level load for device-specific data
    private func loadSensitiveDataRaw(keyName: String) throws -> Data? {
        // Try with access group first
        if let data = try loadSensitiveDataRawInternal(keyName: keyName, includeAccessGroup: true) {
            return data
        }
        // Fallback without access group
        return try loadSensitiveDataRawInternal(keyName: keyName, includeAccessGroup: false)
    }

    private func loadSensitiveDataRawInternal(keyName: String, includeAccessGroup: Bool) throws -> Data? {
        var query = genericPasswordQueryForKey(keyName, includeAccessGroup: includeAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound, errSecMissingEntitlement:
            return nil
        default:
            throw KasiaError.keychainError("Failed to load sensitive data: \(status)")
        }
    }

    /// Low-level delete for device-specific data
    private func deleteSensitiveDataRaw(keyName: String) throws {
        // Delete from both access group and non-access group storage
        let queryWithGroup = genericPasswordQueryForKey(keyName, includeAccessGroup: true)
        let status1 = SecItemDelete(queryWithGroup as CFDictionary)

        let queryWithoutGroup = genericPasswordQueryForKey(keyName, includeAccessGroup: false)
        let status2 = SecItemDelete(queryWithoutGroup as CFDictionary)

        // Success if either succeeds or item not found
        let success1 = status1 == errSecSuccess || status1 == errSecItemNotFound || status1 == errSecMissingEntitlement
        let success2 = status2 == errSecSuccess || status2 == errSecItemNotFound || status2 == errSecMissingEntitlement

        guard success1 && success2 else {
            throw KasiaError.keychainError("Failed to delete sensitive data: \(status1), \(status2)")
        }
    }

    /// Generic password query for arbitrary key name
    private func genericPasswordQueryForKey(_ keyName: String, includeAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: keyName,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if includeAccessGroup, let accessGroup = keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    // MARK: - Legacy Storage Helpers (for migration)

    private func loadLegacyPrivateKeyData(includeAccessGroup: Bool) throws -> Data? {
        var query = genericPasswordQuery(for: .privateKey, includeAccessGroup: includeAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound, errSecMissingEntitlement:
            return nil
        default:
            throw KasiaError.keychainError("Failed to load legacy private key: \(status)")
        }
    }

    private func deleteLegacyPrivateKey(includeAccessGroup: Bool) throws {
        let query = genericPasswordQuery(for: .privateKey, includeAccessGroup: includeAccessGroup)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement else {
            throw KasiaError.keychainError("Failed to delete legacy private key: \(status)")
        }
    }

    // MARK: - Private Helpers

    @discardableResult
    private func save(data: Data, forKey key: KeychainKey) throws -> Bool {
        let query = genericPasswordQuery(for: key, includeAccessGroup: true)

        // Delete any existing item
        SecItemDelete(query as CFDictionary)

        // Add new item
        var newQuery = query
        newQuery[kSecValueData as String] = data
        newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        newQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizable

        let status = SecItemAdd(newQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            try saveLegacy(data: data, forKey: key)
            return false
        }
        guard status == errSecSuccess else {
            throw KasiaError.keychainError("Failed to save to keychain: \(status)")
        }
        return true
    }

    private func secureEnclaveKeyExists() -> Bool {
        return secureEnclaveKeyExists(includeAccessGroup: true)
    }

    private func secureEnclaveKeyExists(includeAccessGroup: Bool) -> Bool {
        let tagData = secureEnclaveTag.data(using: .utf8) ?? Data()
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        if includeAccessGroup, let accessGroup = keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            return false
        }
        return status == errSecSuccess
    }

    private func load(forKey key: KeychainKey) throws -> Data? {
        if let data = try load(forKey: key, includeAccessGroup: true) {
            return data
        }
        if let legacy = try load(forKey: key, includeAccessGroup: false) {
            do {
                let savedToShared = try save(data: legacy, forKey: key)
                if savedToShared {
                    try? delete(forKey: key, includeAccessGroup: false)
                }
            } catch {
                // Ignore migration failures; return legacy data.
            }
            return legacy
        }
        return nil
    }

    private func load(forKey key: KeychainKey, includeAccessGroup: Bool) throws -> Data? {
        var query = genericPasswordQuery(for: key, includeAccessGroup: includeAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound, errSecMissingEntitlement:
            return nil
        default:
            throw KasiaError.keychainError("Failed to load from keychain: \(status)")
        }
    }

    private func delete(forKey key: KeychainKey) throws {
        try delete(forKey: key, includeAccessGroup: true)
        try? delete(forKey: key, includeAccessGroup: false)
    }

    private func tryWrapPrivateKey(_ privateKey: Data) -> Data? {
        do {
            return try wrapPrivateKey(privateKey)
        } catch {
            return nil
        }
    }

    private func wrapPrivateKey(_ privateKey: Data, using key: SecKey? = nil) throws -> Data {
        let securePrivateKey = try key ?? secureEnclavePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(securePrivateKey) else {
            throw KasiaError.keychainError("Failed to access Secure Enclave public key")
        }

        let (algorithmId, algorithm) = try preferredAlgorithm(for: publicKey, operation: .encrypt)

        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            publicKey,
            algorithm,
            privateKey as CFData,
            &error
        ) as Data? else {
            throw KasiaError.keychainError("Secure Enclave encryption failed")
        }

        var wrapped = secureEnclaveHeader
        wrapped.append(algorithmId)
        wrapped.append(encrypted)
        return wrapped
    }

    private func unwrapPrivateKey(_ wrapped: Data, using key: SecKey? = nil) throws -> Data {
        guard wrapped.count > secureEnclaveHeader.count + 1 else {
            throw KasiaError.keychainError("Invalid wrapped private key data")
        }

        let algorithmId = wrapped[secureEnclaveHeader.count]
        let encrypted = wrapped.dropFirst(secureEnclaveHeader.count + 1)

        guard let algorithm = SecureEnclaveAlgorithm(rawValue: algorithmId)?.secKeyAlgorithm else {
            throw KasiaError.keychainError("Unknown Secure Enclave algorithm")
        }

        let securePrivateKey = try key ?? secureEnclavePrivateKey()
        guard SecKeyIsAlgorithmSupported(securePrivateKey, .decrypt, algorithm) else {
            throw KasiaError.keychainError("Secure Enclave algorithm not supported for decryption")
        }

        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(
            securePrivateKey,
            algorithm,
            encrypted as CFData,
            &error
        ) as Data? else {
            throw KasiaError.keychainError("Secure Enclave decryption failed")
        }

        return decrypted
    }

    private func preferredAlgorithm(for key: SecKey, operation: SecKeyOperationType) throws -> (UInt8, SecKeyAlgorithm) {
        let preferred: [SecureEnclaveAlgorithm] = [
            .eciesCofactorSha256AesGcm,
            .eciesStandardSha256AesGcm,
        ]

        for algorithm in preferred {
            let secAlgorithm = algorithm.secKeyAlgorithm
            if SecKeyIsAlgorithmSupported(key, operation, secAlgorithm) {
                return (algorithm.rawValue, secAlgorithm)
            }
        }

        throw KasiaError.keychainError("No supported Secure Enclave encryption algorithm")
    }

    private func secureEnclavePrivateKey(includeAccessGroup: Bool = true, createIfMissing: Bool = true) throws -> SecKey {
        let tagData = secureEnclaveTag.data(using: .utf8) ?? Data()
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        if includeAccessGroup, let accessGroup = keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let keyRef = result else {
                throw KasiaError.keychainError("Secure Enclave key retrieval failed")
            }
            guard CFGetTypeID(keyRef) == SecKeyGetTypeID() else {
                throw KasiaError.keychainError("Secure Enclave key retrieval failed")
            }
            return unsafeBitCast(keyRef, to: SecKey.self)
        case errSecItemNotFound:
            guard createIfMissing else {
                throw KasiaError.keychainError("Secure Enclave key not found")
            }
            return try createSecureEnclavePrivateKey(tagData: tagData, includeAccessGroup: includeAccessGroup)
        case errSecMissingEntitlement:
            if includeAccessGroup {
                return try secureEnclavePrivateKey(includeAccessGroup: false, createIfMissing: createIfMissing)
            }
            throw KasiaError.keychainError("Secure Enclave key lookup failed: \(status)")
        default:
            throw KasiaError.keychainError("Secure Enclave key lookup failed: \(status)")
        }
    }

    private func createSecureEnclavePrivateKey(tagData: Data, includeAccessGroup: Bool) throws -> SecKey {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            throw KasiaError.keychainError("Secure Enclave access control creation failed")
        }

        var privateKeyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrAccessControl as String: accessControl,
        ]
        if includeAccessGroup, let accessGroup = keychainAccessGroup {
            privateKeyAttrs[kSecAttrAccessGroup as String] = accessGroup
        }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateKeyAttrs,
        ]
        if includeAccessGroup, let accessGroup = keychainAccessGroup {
            attributes[kSecAttrAccessGroup as String] = accessGroup
        }

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw KasiaError.keychainError("Secure Enclave key creation failed")
        }

        return privateKey
    }

    private func deleteSecureEnclaveKey() throws {
        try deleteSecureEnclaveKey(includeAccessGroup: true)
        try? deleteSecureEnclaveKey(includeAccessGroup: false)
    }

    private func deletePrivateKey(includeAccessGroup: Bool) throws {
        try delete(forKey: .privateKey, includeAccessGroup: includeAccessGroup)
    }

    private func deleteSecureEnclaveKey(includeAccessGroup: Bool) throws {
        let tagData = secureEnclaveTag.data(using: .utf8) ?? Data()
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        if includeAccessGroup, let accessGroup = keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement {
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KasiaError.keychainError("Failed to delete Secure Enclave key: \(status)")
        }
    }

    private func delete(forKey key: KeychainKey, includeAccessGroup: Bool) throws {
        let query = genericPasswordQuery(for: key, includeAccessGroup: includeAccessGroup)

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement {
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KasiaError.keychainError("Failed to delete from keychain: \(status)")
        }
    }

    private func saveLegacy(data: Data, forKey key: KeychainKey) throws {
        let query = genericPasswordQuery(for: key, includeAccessGroup: false)
        SecItemDelete(query as CFDictionary)

        var newQuery = query
        newQuery[kSecValueData as String] = data
        newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        newQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizable

        let status = SecItemAdd(newQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KasiaError.keychainError("Failed to save to keychain: \(status)")
        }
    }

    private func saveLegacyPrivateKeyData(_ data: Data) throws {
        let query = genericPasswordQuery(for: .privateKey, includeAccessGroup: false)
        SecItemDelete(query as CFDictionary)

        var newQuery = query
        newQuery[kSecValueData as String] = data
        newQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        newQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let status = SecItemAdd(newQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KasiaError.keychainError("Failed to save private key to keychain: \(status)")
        }
    }

    private func genericPasswordQuery(for key: KeychainKey, includeAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if includeAccessGroup, let accessGroup = keychainAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
