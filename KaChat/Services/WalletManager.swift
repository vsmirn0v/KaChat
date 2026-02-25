import Foundation
import CryptoKit
import P256K

struct SavedAccountSummary: Identifiable, Equatable, Codable {
    let alias: String
    let publicAddress: String
    let publicKey: String

    var id: String { publicAddress }

    var displayAlias: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Saved Account" : trimmed
    }

    var shortPublicAddress: String {
        guard publicAddress.count > 16 else { return publicAddress }
        return "\(publicAddress.prefix(10))...\(publicAddress.suffix(6))"
    }

    var formattedPublicAddress: String {
        if publicAddress.contains(":") {
            return publicAddress
        }
        return "kaspa:\(publicAddress)"
    }

    var shortPublicKey: String {
        guard publicKey.count > 24 else { return publicKey }
        return "\(publicKey.prefix(12))...\(publicKey.suffix(8))"
    }

    init(wallet: Wallet) {
        self.alias = wallet.alias
        self.publicAddress = wallet.publicAddress
        self.publicKey = wallet.publicKey
    }
}

@MainActor
final class WalletManager: ObservableObject {
    static let shared = WalletManager()

    @Published var currentWallet: Wallet?
    @Published var isLoading = true
    @Published var error: KasiaError?
    @Published var isBalanceRefreshing = false
    @Published private(set) var hasStoredWallet = false
    @Published private(set) var isLoggedOut = false
    @Published private(set) var savedAccounts: [SavedAccountSummary] = []

    private let keychainService = KeychainService.shared
    private let bip39 = BIP39.shared
    private let nodePool = NodePoolService.shared
    private let balanceCachePrefix = "kachat_balance_cache_"
    private let logoutFlagKey = "kachat_session_logged_out"
    private let savedAccountsKey = "kachat_saved_accounts"

    private init() {
        savedAccounts = loadSavedAccountsFromStorage()
        hasStoredWallet = !savedAccounts.isEmpty
        logPrivateKeyStorageStatus()
        Task {
            await loadWallet()
        }
    }

    // MARK: - Public Methods

    func loadWallet(force: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        do {
            // Try to load from keychain first
            if let wallet = try keychainService.loadWallet() {
                if UserDefaults.standard.bool(forKey: logoutFlagKey), !force {
                    updateSavedAccounts(from: wallet)
                    currentWallet = nil
                    isBalanceRefreshing = false
                    isLoggedOut = true
                    ContactsManager.shared.setActiveWalletAddress(nil)
                    await MessageStore.shared.setCurrentWallet(nil)
                    SharedDataManager.syncWalletAddressForExtension()
                    SharedDataManager.setPrivateKeyAvailable(false)
                    return
                }

                UserDefaults.standard.removeObject(forKey: logoutFlagKey)
                isLoggedOut = false
                let canonicalWallet = reconcileWalletWithLocalKeyMaterialIfNeeded(wallet)
                updateSavedAccounts(from: canonicalWallet)
                snapshotStoredWalletIfPossible()
                var updated = canonicalWallet
                if let cached = loadCachedBalance(for: canonicalWallet.publicAddress) {
                    updated.balanceSompi = cached
                }
                self.currentWallet = updated
                isBalanceRefreshing = true
                ContactsManager.shared.setActiveWalletAddress(canonicalWallet.publicAddress)
                // Switch MessageStore to this wallet's store and CloudKit zone
                await MessageStore.shared.setCurrentWallet(canonicalWallet.publicAddress)
                SharedDataManager.syncWalletAddressForExtension()
                SharedDataManager.setPrivateKeyAvailable(true)
                Task { _ = try? await refreshBalance() }
                return
            }

            // No stored wallet - clear logout state and return to onboarding.
            hasStoredWallet = !savedAccounts.isEmpty
            isLoggedOut = false
            currentWallet = nil
            isBalanceRefreshing = false
            UserDefaults.standard.removeObject(forKey: logoutFlagKey)
            ContactsManager.shared.setActiveWalletAddress(nil)
            await MessageStore.shared.setCurrentWallet(nil)
            SharedDataManager.syncWalletAddressForExtension()
            SharedDataManager.setPrivateKeyAvailable(false)
        } catch {
            self.error = .keychainError(error.localizedDescription)
        }
    }

    func createWallet(alias: String = "My Account", wordCount: Int = 24) async throws -> (wallet: Wallet, seedPhrase: SeedPhrase) {
        // Use async version to ensure word list is loaded
        guard let seedPhrase = await bip39.generateMnemonicAsync(wordCount: wordCount) else {
            throw KasiaError.invalidSeedPhrase
        }
        let wallet = try await importWallet(from: seedPhrase, alias: alias)
        return (wallet, seedPhrase)
    }

    func importWallet(from seedPhrase: SeedPhrase, alias: String = "My Account") async throws -> Wallet {
        // Validate BIP39 checksum to catch typos in seed phrases
        guard bip39.validateMnemonic(seedPhrase.phrase) else {
            throw KasiaError.invalidSeedPhrase
        }

        // Derive keys from seed phrase
        let (publicKey, publicAddress) = try deriveKeysFromSeed(seedPhrase)

        // Determine whether this import is switching to a different account.
        // When user logs out, `currentWallet` is nil but keychain still has the
        // last signed-in account. Use stored account identity to avoid wiping
        // per-account contacts/archived state on same-account re-login.
        let existingStoredAddress = try? keychainService.loadWallet()?.publicAddress
        let previousAddress = currentWallet?.publicAddress ?? existingStoredAddress
        let isNewWallet = previousAddress != publicAddress

        let wallet = Wallet(
            publicAddress: publicAddress,
            publicKey: publicKey,
            alias: alias,
            createdAt: Date()
        )

        snapshotStoredWalletIfPossible()

        // Save wallet
        try await saveWallet(wallet, seedPhrase: seedPhrase)

        var updated = wallet
        if let cached = loadCachedBalance(for: wallet.publicAddress) {
            updated.balanceSompi = cached
        }
        self.currentWallet = updated
        isBalanceRefreshing = true
        updateSavedAccounts(from: wallet)
        isLoggedOut = false
        UserDefaults.standard.removeObject(forKey: logoutFlagKey)
        ContactsManager.shared.setActiveWalletAddress(wallet.publicAddress)
        // Switch MessageStore to this wallet's store and CloudKit zone FIRST
        // This must happen before resetForNewWallet() to avoid clearing the wrong store
        await MessageStore.shared.setCurrentWallet(wallet.publicAddress)
        SharedDataManager.syncWalletAddressForExtension()
        SharedDataManager.setPrivateKeyAvailable(true)

        // Reset chat and contacts data when importing a new/different wallet
        // This ensures lastPollTime=0 so all historical messages are fetched
        if isNewWallet {
            print("[WalletManager] Importing new wallet, resetting chat and contacts data")
            // Pass skipStoreClear=true since the new wallet's store is already empty
            ChatService.shared.resetForNewWallet(skipStoreClear: true)
            ContactsManager.shared.deleteAllContacts()
        }

        // Ensure realtime sync/subscription starts even if UI lifecycle hooks
        // (e.g. MainTabView.onAppear) do not fire immediately after import.
        ChatService.shared.startPolling()

        Task { _ = try? await refreshBalance() }
        return wallet
    }

    func importWallet(from phrase: String, alias: String = "My Account") async throws -> Wallet {
        // Debug: count words
        let words = phrase.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard let seedPhrase = SeedPhrase(phrase: phrase) else {
            throw KasiaError.seedPhraseParsingFailed(wordCount: words.count)
        }
        return try await importWallet(from: seedPhrase, alias: alias)
    }

    func deleteWallet(preserveOutgoingMessages: Bool = false) async throws {
        let walletAddressToDelete = currentWallet?.publicAddress

        // Unregister from push notifications before clearing wallet
        await PushNotificationManager.shared.unregister()

        // Clear shared data (App Group)
        SharedDataManager.clearAllSharedData()

        // Clear message store BEFORE removing the persistent store
        // (clearAll requires a valid store to operate on)
        if preserveOutgoingMessages {
            MessageStore.shared.clearIncomingMessages()
        } else {
            MessageStore.shared.clearAll()
        }

        try keychainService.clearAll()
        currentWallet = nil
        updateSavedAccounts(from: nil)
        isLoggedOut = false
        isBalanceRefreshing = false
        UserDefaults.standard.removeObject(forKey: logoutFlagKey)
        if let walletAddressToDelete {
            ContactsManager.shared.deletePersistedContacts(forWalletAddress: walletAddressToDelete)
        }
        ContactsManager.shared.setActiveWalletAddress(nil)

        // Switch MessageStore back to default store (no wallet)
        await MessageStore.shared.setCurrentWallet(nil)
        SharedDataManager.syncWalletAddressForExtension()
        SharedDataManager.setPrivateKeyAvailable(false)
    }

    /// Logs out the active session while preserving locally stored wallet and message data.
    func logout() async {
        guard let wallet = currentWallet else { return }

        await PushNotificationManager.shared.unregister()
        ChatService.shared.stopPolling()
        resetInMemoryChatStateForAccountSwitch()

        updateSavedAccounts(from: wallet)
        currentWallet = nil
        isBalanceRefreshing = false
        isLoggedOut = true
        UserDefaults.standard.set(true, forKey: logoutFlagKey)
        ContactsManager.shared.setActiveWalletAddress(nil)

        await MessageStore.shared.setCurrentWallet(nil)
        SharedDataManager.syncWalletAddressForExtension()
        SharedDataManager.setPrivateKeyAvailable(false)
    }

    /// Signs back in using wallet data already stored on this device.
    func signInToStoredWallet() async {
        resetInMemoryChatStateForAccountSwitch()
        await loadWallet(force: true)
        if currentWallet != nil {
            ChatService.shared.startPolling()
        }
    }

    @discardableResult
    func signInToSavedAccount(_ account: SavedAccountSummary) async -> Bool {
        guard savedAccounts.contains(account) else { return false }

        do {
            if let storedWallet = try keychainService.loadWallet(),
               storedWallet.publicAddress == account.publicAddress {
                resetInMemoryChatStateForAccountSwitch()
                await loadWallet(force: true)
                if currentWallet != nil {
                    ChatService.shared.startPolling()
                }
                return currentWallet?.publicAddress == account.publicAddress
            }

            snapshotStoredWalletIfPossible()

            guard let snapshot = try keychainService.loadAccountSnapshot(publicAddress: account.publicAddress) else {
                self.error = .keychainError("No local keys for this account. Re-import with seed phrase.")
                return false
            }

            let wallet = Wallet(
                publicAddress: account.publicAddress,
                publicKey: account.publicKey,
                alias: account.alias,
                createdAt: Date()
            )
            try keychainService.saveWallet(wallet)
            try keychainService.saveSeedPhrase(snapshot.seedPhrase)
            try keychainService.savePrivateKey(snapshot.privateKey)

            resetInMemoryChatStateForAccountSwitch()
            await loadWallet(force: true)
            if currentWallet != nil {
                ChatService.shared.startPolling()
            }
            return currentWallet?.publicAddress == account.publicAddress
        } catch {
            self.error = .keychainError(error.localizedDescription)
            return false
        }
    }

    /// Removes a saved account entry.
    /// If the removed entry matches the locally stored wallet, local key material
    /// and message store data are cleared as well.
    func removeSavedAccount(_ account: SavedAccountSummary) async {
        guard savedAccounts.contains(account) else { return }

        let isStoredAccount: Bool
        do {
            let storedWallet = try keychainService.loadWallet()
            isStoredAccount = storedWallet?.publicAddress == account.publicAddress
            if !isStoredAccount {
                try? keychainService.deleteAccountSnapshot(publicAddress: account.publicAddress)
                ContactsManager.shared.deletePersistedContacts(forWalletAddress: account.publicAddress)
                removeSavedAccountFromStorage(account)
                return
            }
        } catch {
            self.error = .keychainError(error.localizedDescription)
            await loadWallet(force: false)
            return
        }

        await PushNotificationManager.shared.unregister()
        ChatService.shared.stopPolling()

        // Remove local message DB for the stored wallet, then clear local key material.
        await MessageStore.shared.setCurrentWallet(account.publicAddress)
        MessageStore.shared.clearAll()
        await MessageStore.shared.destroyLocalStoreFiles()

        do {
            try keychainService.deleteAccountSnapshot(publicAddress: account.publicAddress)
            try keychainService.clearCurrentAccountData()
        } catch {
            self.error = .keychainError(error.localizedDescription)
            await loadWallet(force: false)
            return
        }

        removeSavedAccountFromStorage(account)
        currentWallet = nil
        isBalanceRefreshing = false
        isLoggedOut = false
        UserDefaults.standard.removeObject(forKey: logoutFlagKey)

        await MessageStore.shared.setCurrentWallet(nil)
        ChatService.shared.resetForNewWallet(skipStoreClear: true)
        ContactsManager.shared.deleteAllContacts()
        ContactsManager.shared.setActiveWalletAddress(nil)
        SharedDataManager.clearAllSharedData()
        SharedDataManager.syncWalletAddressForExtension()
        SharedDataManager.setPrivateKeyAvailable(false)
    }

    func updateAlias(_ alias: String) async throws {
        guard var wallet = currentWallet else {
            throw KasiaError.walletNotFound
        }
        wallet.alias = alias
        try await saveWalletOnly(wallet)
        currentWallet = wallet
        updateSavedAccounts(from: wallet)
    }

    func getSeedPhrase() throws -> SeedPhrase? {
        return try keychainService.loadSeedPhrase()
    }

    /// Get the private key data for the current wallet (used for decryption)
    func getPrivateKey() -> Data? {
        do {
            if let privateKey = try keychainService.loadPrivateKey() {
                return privateKey
            }
            guard let seedPhrase = try getSeedPhrase() else { return nil }
            return derivePrivateKeyFromSeed(seedPhrase)
        } catch {
            print("[WalletManager] Failed to get private key: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sign an arbitrary message using the current wallet's Schnorr private key.
    /// Returns hex-encoded 64-byte Schnorr signature.
    enum ArbitraryMessageSigningMode {
        /// Kaspa wallet-compatible personal message signing:
        /// schnorr_sign(blake2b-256(key="PersonalMessageSigningHash", msg=utf8(message))).
        case kaspaPersonalMessage
        case rawUTF8
        case sha256Digest
    }

    func signArbitraryMessage(
        _ message: String,
        mode: ArbitraryMessageSigningMode = .rawUTF8
    ) throws -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.encryptionError("Cannot sign empty message")
        }
        guard let privateKey = getPrivateKey() else {
            throw KasiaError.walletNotFound
        }

        var messageBytes: [UInt8]
        switch mode {
        case .kaspaPersonalMessage:
            let digest = Blake2b.hash(
                Data(message.utf8),
                digestLength: 32,
                key: "PersonalMessageSigningHash"
            )
            messageBytes = Array(digest)
        case .rawUTF8:
            // Keep bytes exactly as provided by caller (no normalization).
            messageBytes = Array(message.utf8)
        case .sha256Digest:
            // Legacy mode used by some existing server integrations.
            messageBytes = Array(SHA256.hash(data: Data(message.utf8)))
        }

        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        let signature = try key.signature(message: &messageBytes, auxiliaryRand: nil)
        for index in messageBytes.indices {
            messageBytes[index] = 0
        }

        return Data(signature.bytes).hexString
    }

    /// Ensures the non-sensitive wallet record matches locally stored signing key material.
    /// If keychain sync returns a stale wallet record from another device/account, prefer
    /// local key material so message decryption and signing keep working on this device.
    private func reconcileWalletWithLocalKeyMaterialIfNeeded(_ wallet: Wallet) -> Wallet {
        guard let localWallet = walletFromLocalKeyMaterial(alias: wallet.alias, createdAt: wallet.createdAt) else {
            return wallet
        }
        guard localWallet.publicKey != wallet.publicKey else {
            return wallet
        }

        NSLog(
            "[WalletManager] Wallet record mismatch detected (stored=%@ local=%@). Repairing wallet record from local keys.",
            String(wallet.publicAddress.suffix(12)),
            String(localWallet.publicAddress.suffix(12))
        )
        do {
            try keychainService.saveWallet(localWallet)
        } catch {
            NSLog("[WalletManager] Failed to persist repaired wallet record: %@", error.localizedDescription)
        }
        return localWallet
    }

    private func walletFromLocalKeyMaterial(alias: String, createdAt: Date) -> Wallet? {
        if let privateKey = try? keychainService.loadPrivateKey(),
           let wallet = try? walletFromPrivateKey(privateKey, alias: alias, createdAt: createdAt) {
            return wallet
        }
        if let seedPhrase = try? keychainService.loadSeedPhrase(),
           let keyPair = try? deriveKeysFromSeed(seedPhrase) {
            return Wallet(
                publicAddress: keyPair.publicAddress,
                publicKey: keyPair.publicKey,
                alias: alias,
                createdAt: createdAt
            )
        }
        return nil
    }

    private func walletFromPrivateKey(_ privateKey: Data, alias: String, createdAt: Date) throws -> Wallet {
        let publicKeyData = try deriveSchnorrPublicKey(from: privateKey)
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()
        let settings = SettingsViewModel.loadSettings()
        let kaspaAddress = KaspaAddress.fromPublicKey(publicKeyData, network: settings.networkType)

        return Wallet(
            publicAddress: kaspaAddress.address,
            publicKey: publicKeyHex,
            alias: alias,
            createdAt: createdAt
        )
    }

    private func updateSavedAccounts(from wallet: Wallet?) {
        if let wallet {
            let summary = SavedAccountSummary(wallet: wallet)
            savedAccounts.removeAll { $0.publicAddress == summary.publicAddress }
            savedAccounts.insert(summary, at: 0)
            persistSavedAccountsToStorage()
        }
        hasStoredWallet = !savedAccounts.isEmpty
    }

    private func removeSavedAccountFromStorage(_ account: SavedAccountSummary) {
        savedAccounts.removeAll { $0.publicAddress == account.publicAddress }
        hasStoredWallet = !savedAccounts.isEmpty
        if savedAccounts.isEmpty {
            UserDefaults.standard.removeObject(forKey: savedAccountsKey)
        } else {
            persistSavedAccountsToStorage()
        }
    }

    private func loadSavedAccountsFromStorage() -> [SavedAccountSummary] {
        guard let data = UserDefaults.standard.data(forKey: savedAccountsKey) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([SavedAccountSummary].self, from: data) else {
            UserDefaults.standard.removeObject(forKey: savedAccountsKey)
            return []
        }
        return decoded
    }

    private func persistSavedAccountsToStorage() {
        guard let data = try? JSONEncoder().encode(savedAccounts) else { return }
        UserDefaults.standard.set(data, forKey: savedAccountsKey)
    }

    /// Clears in-memory chat/contact state so data from a previous account cannot leak into UI.
    /// Keeps on-disk wallet stores intact.
    private func resetInMemoryChatStateForAccountSwitch() {
        ChatService.shared.resetForNewWallet(skipStoreClear: true)
        ContactsManager.shared.clearInMemoryContacts(syncShared: true, updatePush: false)
    }

    private func snapshotStoredWalletIfPossible() {
        do {
            guard let wallet = try keychainService.loadWallet(),
                  let seedPhrase = try keychainService.loadSeedPhrase(),
                  let privateKey = try keychainService.loadPrivateKey() else {
                return
            }
            try keychainService.saveAccountSnapshot(wallet: wallet, seedPhrase: seedPhrase, privateKey: privateKey)
        } catch {
            NSLog("[WalletManager] Failed to snapshot current account: %@", error.localizedDescription)
        }
    }

    /// Refresh balance by summing UTXOs for the current wallet
    func refreshBalance() async throws -> UInt64 {
        guard let wallet = currentWallet else {
            throw KasiaError.walletNotFound
        }
        isBalanceRefreshing = true
        defer { isBalanceRefreshing = false }
        let utxos = try await nodePool.getUtxosByAddresses([wallet.publicAddress])
        let total = utxos.reduce(0) { $0 + $1.amount }
        await MainActor.run {
            if var w = self.currentWallet {
                w.balanceSompi = total
                self.currentWallet = w
            }
        }
        storeCachedBalance(total, for: wallet.publicAddress)
        return total
    }

    /// Update balance from a UTXO fetch if it targets the current wallet.
    func updateBalanceIfCurrentWallet(address: String, utxos: [UTXO]) {
        guard let wallet = currentWallet, wallet.publicAddress == address else { return }
        let total = utxos.reduce(0) { $0 + $1.amount }
        if wallet.balanceSompi == total { return }
        var updated = wallet
        updated.balanceSompi = total
        currentWallet = updated
        storeCachedBalance(total, for: address)
        isBalanceRefreshing = false
    }

    private func balanceCacheKey(for address: String) -> String {
        "\(balanceCachePrefix)\(address)"
    }

    private func loadCachedBalance(for address: String) -> UInt64? {
        let key = balanceCacheKey(for: address)
        if let number = UserDefaults.standard.object(forKey: key) as? NSNumber {
            return number.uint64Value
        }
        if let value = UserDefaults.standard.object(forKey: key) as? UInt64 {
            return value
        }
        return nil
    }

    private func storeCachedBalance(_ sompi: UInt64, for address: String) {
        let key = balanceCacheKey(for: address)
        UserDefaults.standard.set(NSNumber(value: sompi), forKey: key)
    }

    /// Derive the raw private key from seed phrase
    private func derivePrivateKeyFromSeed(_ seedPhrase: SeedPhrase) -> Data? {
        guard let seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: "") else {
            return nil
        }

        // Derive master key using BIP32
        let masterKey = deriveMasterKey(from: seed)

        // Derive child key using BIP44 path: m/44'/111111'/0'/0/0
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)
        let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)
        let change = deriveChildKey(from: account, index: 0)
        let addressIndex = deriveChildKey(from: change, index: 0)

        return addressIndex.key
    }

    private func deriveKeysFromSeed(_ seedPhrase: SeedPhrase) throws -> (publicKey: String, publicAddress: String) {
        // Derive seed using BIP39 standard (PBKDF2 with 2048 iterations)
        guard var seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: "") else {
            throw KasiaError.invalidSeedPhrase
        }
        defer { seed.zeroOut() }

        // Derive master key using BIP32
        let masterKey = deriveMasterKey(from: seed)

        // Derive child key using BIP44 path: m/44'/111111'/0'/0/0
        // 111111 (0x1B207) is Kaspa's coin type
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)       // 44'
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)    // 111111'
        let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)         // 0'
        let change = deriveChildKey(from: account, index: 0)                         // 0
        let addressIndex = deriveChildKey(from: change, index: 0)                    // 0

        let privateKeyData = addressIndex.key

        // Derive public key using secp256k1
        let publicKeyData = try deriveSchnorrPublicKey(from: privateKeyData)

        // Create Kaspa address using bech32 encoding
        let settings = SettingsViewModel.loadSettings()
        let network = settings.networkType

        let kaspaAddress = KaspaAddress.fromPublicKey(publicKeyData, network: network)
        let publicAddress = kaspaAddress.address

        // Public key as hex
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()

        return (publicKeyHex, publicAddress)
    }

    private func logPrivateKeyStorageStatus() {
        let preStatus = keychainService.privateKeyStorageStatus()
        NSLog("[WalletManager] Private key storage (pre-migration): %@", preStatus)

        do {
            let migratedKey = try keychainService.loadPrivateKey()
            if migratedKey == nil {
                NSLog("[WalletManager] Private key migration check: no key found")
            }
        } catch {
            NSLog("[WalletManager] Private key migration check failed: %@", error.localizedDescription)
        }

        let postStatus = keychainService.privateKeyStorageStatus()
        NSLog("[WalletManager] Private key storage (post-migration): %@", postStatus)
    }

    /// Derive master key from seed using BIP32
    private func deriveMasterKey(from seed: Data) -> (key: Data, chainCode: Data) {
        let key = SymmetricKey(data: "Bitcoin seed".data(using: .utf8)!)
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: key)
        let hmacData = Data(hmac)

        let privateKey = hmacData.prefix(32)
        let chainCode = hmacData.suffix(32)

        return (Data(privateKey), Data(chainCode))
    }

    // secp256k1 curve order n
    private static let secp256k1_n: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ]

    /// Derive child key using BIP32
    private func deriveChildKey(from parent: (key: Data, chainCode: Data), index: UInt32) -> (key: Data, chainCode: Data) {
        var data = Data()

        if index >= 0x80000000 {
            // Hardened derivation
            data.append(0x00)
            data.append(parent.key)
        } else {
            // Normal derivation - need public key
            if let pubKey = try? deriveCompressedPublicKey(from: parent.key) {
                data.append(pubKey)
            } else {
                data.append(0x00)
                data.append(parent.key)
            }
        }

        // Append index as big-endian
        data.append(UInt8((index >> 24) & 0xFF))
        data.append(UInt8((index >> 16) & 0xFF))
        data.append(UInt8((index >> 8) & 0xFF))
        data.append(UInt8(index & 0xFF))

        let key = SymmetricKey(data: parent.chainCode)
        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: key)
        let hmacData = Data(hmac)

        let il = Data(hmacData.prefix(32))
        let ir = Data(hmacData.suffix(32))

        // Use secp256k1 library's tweak_add for proper scalar addition (mod n)
        // This is what Kaspa's Rust implementation uses
        do {
            let parentPrivKey = try P256K.Signing.PrivateKey(dataRepresentation: parent.key)
            let childPrivKey = try parentPrivKey.add(Array(il))
            return (childPrivKey.dataRepresentation, ir)
        } catch {
            // Fallback to manual addition if tweak fails (shouldn't happen with valid keys)
            let childKey = addModN(il, parent.key)
            return (childKey, ir)
        }
    }

    /// Add two 32-byte big integers modulo secp256k1 curve order n (fallback only)
    private func addModN(_ a: Data, _ b: Data) -> Data {
        // First, add a + b as big integers
        var result = [UInt8](repeating: 0, count: 33) // Extra byte for overflow
        var carry: UInt16 = 0

        for i in (0..<32).reversed() {
            let sum = UInt16(a[i]) + UInt16(b[i]) + carry
            result[i + 1] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        result[0] = UInt8(carry)

        // Now reduce modulo n if result >= n
        let n = Self.secp256k1_n

        // Compare result with n (result has 33 bytes, n has 32)
        var resultIsGreaterOrEqual = result[0] > 0 // If there's overflow, definitely greater

        if !resultIsGreaterOrEqual {
            // Compare the 32-byte portions
            for i in 0..<32 {
                if result[i + 1] > n[i] {
                    resultIsGreaterOrEqual = true
                    break
                } else if result[i + 1] < n[i] {
                    break
                }
            }
            // If all bytes equal, result == n, so still need to reduce
            if !resultIsGreaterOrEqual {
                var allEqual = true
                for i in 0..<32 {
                    if result[i + 1] != n[i] {
                        allEqual = false
                        break
                    }
                }
                if allEqual {
                    resultIsGreaterOrEqual = true
                }
            }
        }

        if resultIsGreaterOrEqual {
            // Subtract n from result
            var borrow: Int16 = 0
            for i in (0..<32).reversed() {
                let diff = Int16(result[i + 1]) - Int16(n[i]) - borrow
                if diff < 0 {
                    result[i + 1] = UInt8((diff + 256) & 0xFF)
                    borrow = 1
                } else {
                    result[i + 1] = UInt8(diff & 0xFF)
                    borrow = 0
                }
            }
            // Handle borrow from the overflow byte
            result[0] = UInt8(Int16(result[0]) - borrow)
        }

        // Return last 32 bytes
        return Data(result.suffix(32))
    }

    /// Derive compressed public key (33 bytes) from private key using secp256k1
    private func deriveCompressedPublicKey(from privateKey: Data) throws -> Data {
        let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
        return privKey.publicKey.dataRepresentation
    }

    /// Derive Schnorr public key (32 bytes, x-only) from private key using secp256k1
    private func deriveSchnorrPublicKey(from privateKey: Data) throws -> Data {
        let privKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        // Get the x-only public key for Schnorr (32 bytes)
        return Data(privKey.xonly.bytes)
    }

    // MARK: - Storage

    private func saveWallet(_ wallet: Wallet, seedPhrase: SeedPhrase) async throws {
        try keychainService.saveWallet(wallet)
        try keychainService.saveSeedPhrase(seedPhrase)
        if let privateKey = derivePrivateKeyFromSeed(seedPhrase) {
            try keychainService.savePrivateKey(privateKey)
            try keychainService.saveAccountSnapshot(wallet: wallet, seedPhrase: seedPhrase, privateKey: privateKey)
        }
    }

    private func saveWalletOnly(_ wallet: Wallet) async throws {
        try keychainService.saveWallet(wallet)
    }
}
