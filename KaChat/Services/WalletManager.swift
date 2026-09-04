import Foundation
import CryptoKit
import P256K

struct SavedAccountSummary: Identifiable, Equatable, Codable {
    var alias: String
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

/// Identity derivation-path family of the wallet a seed phrase was imported from - the
/// KasWare-style "which wallet is this seed from?" selection. Different Kaspa wallets put the
/// same seed's funds and KNS domains on different BIP32 branches; picking the right family at
/// import is what lets KaChat find them. Rules replicated exactly from KasWare's
/// ADDRESS_TYPES/RESTORE_WALLETS constants and its `hd-keyring.ts` `_pubkeyFromIndex` derivation
/// switch (see external reference /Users/restosaved/extension):
///
/// - `kaspaStandard`: m/44'/111111'/0'/0/{i} (receive chain, normal final index). KaChat's own
///   family, also KasWare, Kaspium, Core Golang CLI, OKX and Ledger seed imports.
/// - `kaspaLegacy972`: m/44'/972/0'/0'/{i'} - Kaspanet Web Wallet and KDX. NOTE: 972 is
///   deliberately NOT hardened (KasWare's hdPath string "m/44'/972/0'" has no apostrophe on 972
///   and their keyring derives it normally), while the change level and the final index ARE
///   hardened ("m/44'/972/0'/${dType}'/${i}'").
/// - `chainge`: m/44'/111111'/0'/0' - a single hardened leaf; Chainge wallets have exactly ONE
///   address per seed, so no index scanning applies (only index 0 exists).
/// - `oneKey`: the standard m/44'/111111'/0'/0/{i} key, then a BIP340 taproot-style tweak:
///   negate the private key if its compressed pubkey has an odd Y (0x03 prefix), then add
///   taggedHash("TapTweak", xOnlyPubkey) mod n. Address comes from the tweaked key.
///
/// Raw values are persisted (UserDefaults, keyed per derived address) - do not rename cases.
enum WalletSourceFamily: String, Codable, CaseIterable {
    case kaspaStandard
    case kaspaLegacy972
    case chainge
    case oneKey

    /// True when the family has a whole receive chain to scan; false for single-address
    /// families (Chainge), where only index 0 exists.
    var supportsIndexScan: Bool {
        self != .chainge
    }

    /// Human-readable base path, for the import chooser UI.
    var pathDescription: String {
        switch self {
        case .kaspaStandard: return "m/44'/111111'/0'"
        case .kaspaLegacy972: return "m/44'/972/0'"
        case .chainge: return "m/44'/111111'/0'/0'"
        case .oneKey: return "m/44'/111111'/0' (OneKey)"
        }
    }
}

/// One scanned identity-chain slot from `WalletManager.scanChattingAddressCandidates` - the
/// import wizard's "Change Chatting Address" picker lists the interesting ones (balance or
/// domains), always including index 0.
struct ChattingAddressCandidate: Identifiable, Equatable {
    let index: Int
    let address: String
    let balanceSompi: UInt64
    let domains: [KNSDomain]
    let primaryDomain: String?

    var id: Int { index }

    var shortAddress: String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(10))...\(address.suffix(6))"
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
    /// Set by `CreateWalletView` once the user has reviewed their seed phrase and checked "I have
    /// written down my seed phrase...", and by `ImportWalletView` when importing an existing
    /// account - lets the main app show the Welcome Guide automatically after onboarding, whether
    /// the account was freshly created or imported. Deliberately NOT set by
    /// `WalletManager.createWallet` itself, which returns well before the seed phrase has actually
    /// been shown/acknowledged - setting it there would let the guide launch before the user has
    /// had a chance to write anything down. The onboarding views set it *before* the commit call
    /// (see `CreateWalletView`/`ImportWalletView`) so it's already true when `MainTabView` first
    /// appears. Transient/in-memory only (not persisted): the first view to notice it
    /// (`MainTabView`) is expected to flip it back to `false` immediately after presenting the
    /// guide, so this is a one-shot signal, not a flag.
    @Published var justCreatedNewWallet = false

    /// True from the moment `createWallet` starts generating a brand-new wallet until
    /// `CreateWalletView`'s "Continue to App" button clears it (after the user confirms they've
    /// written down the seed phrase) - `ContentView`/`LaunchRouter` treat this as "stay on
    /// onboarding" even though `currentWallet` is already non-nil by then, closing the race where
    /// `currentWallet` (set inside `importWallet`, well before the seed-phrase screen is shown or
    /// confirmed) would otherwise let top-level routing jump straight to `MainTabView` and tear
    /// down the seed-phrase screen before the user ever saw it. Never set for `importWallet`
    /// (typing in an existing phrase needs no review step). Transient/in-memory only, like
    /// `justCreatedNewWallet`.
    @Published var isAwaitingSeedPhraseConfirmation = false

    /// True only when the current session began with a seed IMPORT (`ImportWalletView`), never a
    /// brand-new create - unlike `justCreatedNewWallet`, which both flows set. The Welcome Guide
    /// uses it to offer "Change Chatting Address" on the funding step: an imported seed may hold
    /// its real identity (KNS domains, funded chatting balance) at a nonzero derivation index,
    /// which is meaningless for a freshly generated seed. Set by `ImportWalletView` right before
    /// the import commits, cleared when the guide finishes (or the import fails). Transient/
    /// in-memory only, like `justCreatedNewWallet` - an app kill mid-wizard loses it, which just
    /// hides the option on the resumed run.
    @Published var justImportedWallet = false

    /// Per-wallet ("account") toggle for whether the "Setup Guide" re-entry points (the Profile
    /// tab's "Welcome Guide" row and the "Edit KNS Profile" screen's "Setup Guide" button) are
    /// shown - scoped to `currentWallet?.publicAddress` rather than global `AppSettings`, mirroring
    /// `spendingDefaultsKey` in `WalletManager+SpendingAddresses.swift`, so switching to a
    /// different account on the same device doesn't carry the choice over. Defaults to `true`
    /// (unset key) to match pre-existing behavior for anyone who had these guides visible before
    /// this toggle existed.
    var showSetupGuides: Bool {
        get {
            guard let key = showSetupGuidesDefaultsKey else { return true }
            return UserDefaults.standard.object(forKey: key) as? Bool ?? true
        }
        set {
            guard let key = showSetupGuidesDefaultsKey else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            objectWillChange.send()
        }
    }

    private var showSetupGuidesDefaultsKey: String? {
        guard let address = currentWallet?.publicAddress else { return nil }
        return "kachat_show_setup_guides_\(address)"
    }

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
                    BroadcastService.shared.setCurrentWallet(nil)
                    GroupChatService.shared.setCurrentWallet(nil)
                    ColdStorageManager.shared.setCurrentWallet(nil)
                    PortfolioManager.shared.setCurrentWallet(nil)
                    PortfolioViewModel.shared.setCurrentWallet(nil)
                    NextcloudService.shared.setCurrentWallet(nil)
                    SharedDataManager.syncWalletAddressForExtension()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
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
                migrateSpendingBoundsIfNeeded()
                // Legacy payment-pool reservations were born hidden; they are visible product
                // surface now, so surface any outstanding ones without waiting for a re-offer.
                unhideOfferedReservationsIfNeeded()
                isBalanceRefreshing = true
                ContactsManager.shared.setActiveWalletAddress(canonicalWallet.publicAddress)
                ChatService.shared.loadChatListSnapshot(for: canonicalWallet.publicAddress)
                SharedDataManager.syncWalletAddressForExtension()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
                SharedDataManager.setPrivateKeyAvailable(true)
                isLoading = false
                // Switch MessageStore to this wallet's store and CloudKit zone
                await MessageStore.shared.setCurrentWallet(canonicalWallet.publicAddress)
                BroadcastService.shared.setCurrentWallet(canonicalWallet.publicAddress)
                GroupChatService.shared.setCurrentWallet(canonicalWallet.publicAddress)
                // Discover group invites for THIS account right away - switching accounts in-app
                // does not fire a scenePhase .active, so without this a group you were added to
                // under this account would not appear until the app was backgrounded/foregrounded.
                Task { await GroupChatService.shared.performCatchUpSync() }
                ColdStorageManager.shared.setCurrentWallet(canonicalWallet.publicAddress)
                PortfolioManager.shared.setCurrentWallet(canonicalWallet.publicAddress)
                PortfolioViewModel.shared.setCurrentWallet(canonicalWallet.publicAddress)
                NextcloudService.shared.setCurrentWallet(canonicalWallet.publicAddress)
                await ChatService.shared.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
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
            BroadcastService.shared.setCurrentWallet(nil)
            GroupChatService.shared.setCurrentWallet(nil)
            ColdStorageManager.shared.setCurrentWallet(nil)
            PortfolioManager.shared.setCurrentWallet(nil)
            PortfolioViewModel.shared.setCurrentWallet(nil)
            NextcloudService.shared.setCurrentWallet(nil)
            SharedDataManager.syncWalletAddressForExtension()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            SharedDataManager.setPrivateKeyAvailable(false)
        } catch {
            self.error = .keychainError(error.localizedDescription)
        }
    }

    /// Does NOT set `justCreatedNewWallet` - that fires later, once the caller (`CreateWalletView`)
    /// confirms the user has actually reviewed and acknowledged their seed phrase, not the instant
    /// the wallet is generated (which happens before the seed-phrase screen is even shown). Sets
    /// `isAwaitingSeedPhraseConfirmation` *before* `importWallet` runs (rather than after it
    /// returns) so there's no window where `currentWallet` is already non-nil but the routing
    /// guard isn't up yet - see that property's doc comment.
    /// Generates a fresh mnemonic for the create-account flow WITHOUT deriving keys or persisting
    /// anything. The wallet is only committed later via `commitCreatedWallet(...)`, once the user
    /// has backed up the phrase and chosen whether to add a BIP39 passphrase. Deferring derivation
    /// is what lets the passphrase - which changes the derived address - be known before we ever
    /// derive or save, so there's no throwaway account to migrate afterwards.
    func generateNewWalletSeedPhrase(wordCount: Int = 24) async throws -> SeedPhrase {
        // Use async version to ensure word list is loaded
        guard let seedPhrase = await bip39.generateMnemonicAsync(wordCount: wordCount) else {
            throw KasiaError.invalidSeedPhrase
        }
        return seedPhrase
    }

    /// Commits a brand-new wallet generated by `generateNewWalletSeedPhrase`: attaches the optional
    /// BIP39 passphrase, derives keys and persists. Import and create both funnel through
    /// `importWallet`, so account setup is identical afterwards. Pass "" for no passphrase.
    @discardableResult
    func commitCreatedWallet(seedPhrase: SeedPhrase, passphrase: String, alias: String) async throws -> Wallet {
        let sp = SeedPhrase(words: seedPhrase.words, passphrase: passphrase.isEmpty ? nil : passphrase)
        return try await importWallet(from: sp, alias: alias)
    }

    /// Convenience one-shot create (generate + commit with no passphrase). Retained for callers
    /// that don't run the interactive onboarding flow; the UI uses generate/commit separately so
    /// it can insert the passphrase step in between.
    func createWallet(alias: String = "My Account", wordCount: Int = 24) async throws -> (wallet: Wallet, seedPhrase: SeedPhrase) {
        let seedPhrase = try await generateNewWalletSeedPhrase(wordCount: wordCount)
        let wallet = try await commitCreatedWallet(seedPhrase: seedPhrase, passphrase: "", alias: alias)
        return (wallet, seedPhrase)
    }

    /// - Parameter chattingAddressIndex: derivation index on the identity chain
    ///   (m/44'/111111'/0'/0/<index>) the chatting address should live at. 0 (the default) is the
    ///   standard identity every fresh import/create starts from; a nonzero value is only ever
    ///   passed by `setChattingAddress(index:)` when the user picks a different identity index
    ///   during the import wizard. Persisted per derived address so key-repair and
    ///   seed-fallback paths re-derive the same identity.
    /// - Parameter family: identity derivation-path family of the wallet this seed comes from
    ///   (the KasWare-style source-wallet selection in the import flow). `.kaspaStandard` for
    ///   every create and for imports of KaChat/KasWare/Kaspium/Core CLI/OKX/Ledger seeds.
    ///   Persisted per derived address, exactly like the chatting index.
    func importWallet(from seedPhrase: SeedPhrase, alias: String = "My Account", chattingAddressIndex: Int = 0, family: WalletSourceFamily = .kaspaStandard) async throws -> Wallet {
        // Validate BIP39 checksum to catch typos in seed phrases
        guard bip39.validateMnemonic(seedPhrase.phrase) else {
            throw KasiaError.invalidSeedPhrase
        }
        guard chattingAddressIndex >= 0 else {
            throw KasiaError.apiError("Invalid chatting address index")
        }

        // Stop any in-flight sync/polling for the *previous* wallet before we make this new wallet
        // active and switch the message store below. Without this the old wallet's historical sync
        // task keeps running across the switch and writes its messages into the new wallet's store,
        // leaking one account's chats into another. `ChatService.isActiveWallet` is the write-time
        // guard that backs this up if a stale task still slips through.
        ChatService.shared.stopPolling()

        // Derive keys from seed phrase (once - the private key is reused for storage below and
        // cached in memory so the initial sync doesn't re-read the keychain per message).
        let (publicKey, publicAddress, privateKeyData) = try deriveKeysFromSeed(seedPhrase, chattingIndex: UInt32(chattingAddressIndex), family: family)
        // Persist the index and family before any consumer can hit a seed-fallback derivation
        // path for the new address (getPrivateKey / wallet reconciliation look both up per
        // address).
        persistChattingAddressIndex(chattingAddressIndex, for: publicAddress)
        persistWalletSourceFamily(family, for: publicAddress)
        cachedPrivateKey = (publicAddress, privateKeyData)

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
            createdAt: accountAddedDate(for: publicAddress)
        )

        snapshotStoredWalletIfPossible()

        // Save wallet
        try await saveWallet(wallet, seedPhrase: seedPhrase, privateKey: privateKeyData)

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
        BroadcastService.shared.setCurrentWallet(wallet.publicAddress)
        GroupChatService.shared.setCurrentWallet(wallet.publicAddress)
        // Discover group invites for this newly-activated account immediately (see the same
        // call in loadWallet) - an in-app account activation does not fire scenePhase .active.
        Task { await GroupChatService.shared.performCatchUpSync() }
        ColdStorageManager.shared.setCurrentWallet(wallet.publicAddress)
        PortfolioManager.shared.setCurrentWallet(wallet.publicAddress)
        PortfolioViewModel.shared.setCurrentWallet(wallet.publicAddress)
        NextcloudService.shared.setCurrentWallet(wallet.publicAddress)
        SharedDataManager.syncWalletAddressForExtension()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        SharedDataManager.setPrivateKeyAvailable(true)

        // Reset chat and contacts data when importing a new/different wallet
        // This ensures lastPollTime=0 so all historical messages are fetched
        if isNewWallet {
            AppLog.log("%@", "[WalletManager] Importing new wallet, resetting chat and contacts data")
            // Stamp the import moment BEFORE any sync starts: everything mined earlier is
            // history the initial sync backfills, and it must land read and silent (no unread
            // badges, no notifications). See ChatService.walletImportBaselineMs.
            ChatService.shared.recordWalletImportBaseline(address: wallet.publicAddress)
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

    /// - Parameter passphrase: optional BIP39 passphrase the account was created with. Must match
    ///   exactly to restore the same account; a different (or empty) passphrase silently derives a
    ///   different, empty account. Pass "" for none.
    func importWallet(from phrase: String, alias: String = "My Account", passphrase: String = "", family: WalletSourceFamily = .kaspaStandard) async throws -> Wallet {
        // Debug: count words
        let words = phrase.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard let seedPhrase = SeedPhrase(phrase: phrase, passphrase: passphrase.isEmpty ? nil : passphrase) else {
            throw KasiaError.seedPhraseParsingFailed(wordCount: words.count)
        }
        return try await importWallet(from: seedPhrase, alias: alias, family: family)
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
            ChatListSnapshotStore.clear(walletAddress: walletAddressToDelete)
            ContactsManager.shared.deletePersistedContacts(forWalletAddress: walletAddressToDelete)
            NextcloudService.shared.purgeStoredState(forWalletAddress: walletAddressToDelete)
        }
        ContactsManager.shared.setActiveWalletAddress(nil)

        // Switch MessageStore back to default store (no wallet)
        await MessageStore.shared.setCurrentWallet(nil)
        BroadcastService.shared.setCurrentWallet(nil)
        GroupChatService.shared.setCurrentWallet(nil)
        ColdStorageManager.shared.setCurrentWallet(nil)
        PortfolioManager.shared.setCurrentWallet(nil)
        PortfolioViewModel.shared.setCurrentWallet(nil)
        NextcloudService.shared.setCurrentWallet(nil)
        SharedDataManager.syncWalletAddressForExtension()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
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
        cachedPrivateKey = nil
        isBalanceRefreshing = false
        isLoggedOut = true
        UserDefaults.standard.set(true, forKey: logoutFlagKey)
        ContactsManager.shared.setActiveWalletAddress(nil)

        await MessageStore.shared.setCurrentWallet(nil)
        BroadcastService.shared.setCurrentWallet(nil)
        GroupChatService.shared.setCurrentWallet(nil)
        ColdStorageManager.shared.setCurrentWallet(nil)
        PortfolioManager.shared.setCurrentWallet(nil)
        PortfolioViewModel.shared.setCurrentWallet(nil)
        NextcloudService.shared.setCurrentWallet(nil)
        SharedDataManager.syncWalletAddressForExtension()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
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
                createdAt: accountAddedDate(for: account.publicAddress)
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
                NextcloudService.shared.purgeStoredState(forWalletAddress: account.publicAddress)
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
        BroadcastService.shared.setCurrentWallet(account.publicAddress)
        BroadcastStore.shared.clearAll()
        GroupChatService.shared.setCurrentWallet(account.publicAddress)
        GroupChatService.shared.clearAllLocalData()
        ColdStorageManager.shared.setCurrentWallet(account.publicAddress)
        ColdStorageManager.shared.clearAllLocalData()
        PortfolioManager.shared.setCurrentWallet(account.publicAddress)
        PortfolioManager.shared.clearAllLocalData()
        PortfolioViewModel.shared.setCurrentWallet(account.publicAddress)
        PortfolioViewModel.shared.clearAllLocalData()
        NextcloudService.shared.purgeStoredState(forWalletAddress: account.publicAddress)

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
        BroadcastService.shared.setCurrentWallet(nil)
        GroupChatService.shared.setCurrentWallet(nil)
        ColdStorageManager.shared.setCurrentWallet(nil)
        PortfolioManager.shared.setCurrentWallet(nil)
        PortfolioViewModel.shared.setCurrentWallet(nil)
        NextcloudService.shared.setCurrentWallet(nil)
        ChatService.shared.resetForNewWallet(skipStoreClear: true)
        ContactsManager.shared.deleteAllContacts()
        ContactsManager.shared.setActiveWalletAddress(nil)
        SharedDataManager.clearAllSharedData()
        SharedDataManager.syncWalletAddressForExtension()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
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

    /// In-memory cache of the active wallet's private key, keyed by address. Avoids a keychain read
    /// (and, if the stored key were ever missing, a full PBKDF2 re-derivation) on every
    /// `getPrivateKey()` call - which the initial sync makes once per handshake/message. The address
    /// key makes serving a stale key after a wallet switch impossible; it's also cleared on logout.
    private var cachedPrivateKey: (address: String, key: Data)?

    /// Get the private key data for the current wallet (used for decryption)
    func getPrivateKey() -> Data? {
        if let cached = cachedPrivateKey, cached.address == currentWallet?.publicAddress {
            return cached.key
        }
        do {
            let key: Data?
            if let privateKey = try keychainService.loadPrivateKey() {
                key = privateKey
            } else if let seedPhrase = try getSeedPhrase() {
                key = derivePrivateKeyFromSeed(seedPhrase)
            } else {
                key = nil
            }
            if let key, let address = currentWallet?.publicAddress {
                cachedPrivateKey = (address, key)
            }
            return key
        } catch {
            AppLog.log("%@", "[WalletManager] Failed to get private key: \(error.localizedDescription)")
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
        guard let localWallet = walletFromLocalKeyMaterial(alias: wallet.alias, createdAt: wallet.createdAt, storedAddress: wallet.publicAddress) else {
            return wallet
        }
        guard localWallet.publicKey != wallet.publicKey else {
            return wallet
        }

        AppLog.log(
            "[WalletManager] Wallet record mismatch detected (stored=%@ local=%@). Repairing wallet record from local keys.",
            String(wallet.publicAddress.suffix(12)),
            String(localWallet.publicAddress.suffix(12))
        )
        do {
            try keychainService.saveWallet(localWallet)
        } catch {
            AppLog.log("[WalletManager] Failed to persist repaired wallet record: %@", error.localizedDescription)
        }
        return localWallet
    }

    /// - Parameter storedAddress: the keychain wallet record's address, used to look up its
    ///   persisted chatting-address index for the seed-fallback derivation. The private-key
    ///   branch needs no index - the stored key IS the chosen identity's key.
    private func walletFromLocalKeyMaterial(alias: String, createdAt: Date, storedAddress: String?) -> Wallet? {
        if let privateKey = try? keychainService.loadPrivateKey(),
           let wallet = try? walletFromPrivateKey(privateKey, alias: alias, createdAt: createdAt) {
            return wallet
        }
        let chattingIndex = storedAddress.map { chattingAddressIndex(for: $0) } ?? 0
        let family = storedAddress.map { walletSourceFamily(for: $0) } ?? .kaspaStandard
        if let seedPhrase = try? keychainService.loadSeedPhrase(),
           let keyPair = try? deriveKeysFromSeed(seedPhrase, chattingIndex: UInt32(chattingIndex), family: family) {
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

    /// Renames a saved account entry (Onboarding's saved-accounts list). If this account
    /// happens to be the currently active wallet, keeps its alias in sync too.
    func renameSavedAccount(_ account: SavedAccountSummary, to newAlias: String) {
        guard let index = savedAccounts.firstIndex(where: { $0.publicAddress == account.publicAddress }) else { return }
        let trimmed = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedAccounts[index].alias = trimmed
        persistSavedAccountsToStorage()

        if currentWallet?.publicAddress == account.publicAddress {
            currentWallet?.alias = trimmed
        }
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

    /// When this account was first added to the app on this device, stamped once and never
    /// moved.
    ///
    /// `Wallet.createdAt` was `Date()` at every site that builds a Wallet - including switching
    /// back to a saved account and re-importing a seed already on the device - so About's
    /// "Created" showed the last time you signed in, not when the account arrived. Keyed by
    /// address in UserDefaults rather than added to the Wallet model: the value has to survive
    /// the account being logged out and the Keychain record being rebuilt from a snapshot, which
    /// is exactly when the old value was being lost.
    ///
    /// An account already on this device from before this fix has no stamp, so it takes the
    /// creation date currently stored for it - the best evidence available - and keeps that from
    /// then on rather than resetting again on the next switch.
    private func accountAddedDate(for address: String) -> Date {
        let key = "kachat_account_added_at.\(address)"
        if let stored = UserDefaults.standard.object(forKey: key) as? Date {
            return stored
        }
        let inherited = (try? keychainService.loadWallet())
            .flatMap { $0.publicAddress == address ? $0.createdAt : nil }
        let date = inherited ?? Date()
        UserDefaults.standard.set(date, forKey: key)
        return date
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
            AppLog.log("[WalletManager] Failed to snapshot current account: %@", error.localizedDescription)
        }
    }

    /// True only when the chatting-address balance is a CONFIRMED zero. `balanceSompi` is `nil`
    /// until the first UTXO fetch (or cached-balance load) completes, so an unknown/still-loading
    /// balance never counts as zero - only an actual fetched/cached 0. Reactive: `balanceSompi`
    /// lives on the published `currentWallet`, so observers re-evaluate the moment any
    /// refresh/UTXO push reports funds. Drives the zero-balance compose gates in 1:1 chats,
    /// group chats, broadcast channels, and KaPosts.
    var hasConfirmedZeroChattingBalance: Bool {
        guard let balance = currentWallet?.balanceSompi else { return false }
        return balance == 0
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
        // Must use the same passphrase as `deriveKeysFromSeed`, or the persisted private key
        // won't match the derived address and the wallet-reconciliation path will keep "repairing"
        // the record on every launch.
        guard let seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else {
            return nil
        }

        // Family + index are the CURRENT wallet's persisted identity parameters (standard
        // family / index 0 unless the user imported from another wallet type or picked a
        // different identity index), so this fallback re-derives the key that actually matches
        // the stored wallet record.
        let baseNode = identityBaseNode(seed: seed, family: currentWalletSourceFamily)
        return identityPrivateKey(at: UInt32(currentChattingAddressIndex), baseNode: baseNode, family: currentWalletSourceFamily)
    }

    private func deriveKeysFromSeed(_ seedPhrase: SeedPhrase, chattingIndex: UInt32 = 0, family: WalletSourceFamily = .kaspaStandard) throws -> (publicKey: String, publicAddress: String, privateKey: Data) {
        // Derive seed using BIP39 standard (PBKDF2 with 2048 iterations). The optional BIP39
        // passphrase carried on the SeedPhrase changes the derived account entirely; reading it
        // here (rather than hardcoding "") is what makes relaunch, reconciliation and
        // `getPrivateKey` all passphrase-correct for free. Must match `derivePrivateKeyFromSeed`.
        guard var seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else {
            throw KasiaError.invalidSeedPhrase
        }
        defer { seed.zeroOut() }

        // Identity path is family-dependent (see WalletSourceFamily): the standard family is
        // m/44'/111111'/0'/0/<chattingIndex> (111111 / 0x1B207 is Kaspa's coin type); imported
        // seeds from other wallets may use the legacy 972 branch, the single Chainge leaf, or
        // OneKey's tweaked standard key. chattingIndex is 0 for every fresh import/create;
        // nonzero only when the user chose a different identity index (setChattingAddress).
        let baseNode = identityBaseNode(seed: seed, family: family)
        guard let privateKeyData = identityPrivateKey(at: chattingIndex, baseNode: baseNode, family: family) else {
            throw KasiaError.apiError("This wallet type has no address at index \(chattingIndex).")
        }

        // Derive public key using secp256k1
        let publicKeyData = try deriveSchnorrPublicKey(from: privateKeyData)

        // Create Kaspa address using bech32 encoding
        let settings = SettingsViewModel.loadSettings()
        let network = settings.networkType

        let kaspaAddress = KaspaAddress.fromPublicKey(publicKeyData, network: network)
        let publicAddress = kaspaAddress.address

        // Public key as hex
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()

        // Return the private key too so callers (import/create) don't re-run the whole
        // PBKDF2 + BIP32 derivation a second time just to persist it - that double derivation on
        // the main actor was a measurable stutter at sign-in.
        return (publicKeyHex, publicAddress, privateKeyData)
    }

    // MARK: - Family-aware identity derivation core

    /// The family's shared base node, from which each address index derives with one final step
    /// (see `identityPrivateKey(at:baseNode:family:)` for how the index applies per family).
    /// Deriving this once per scan/import is the expensive part (HMAC-SHA512 chain); mirrors the
    /// `spendingChangeKey()` reuse pattern.
    private func identityBaseNode(seed: Data, family: WalletSourceFamily) -> (key: Data, chainCode: Data) {
        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)               // 44'
        switch family {
        case .kaspaStandard, .oneKey:
            // m/44'/111111'/0'/0 - OneKey shares the standard chain; only the final key gets
            // its tweak.
            let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)        // 111111'
            let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)             // 0'
            return deriveChildKey(from: account, index: 0)                                  // 0 (receive)
        case .kaspaLegacy972:
            // m/44'/972/0'/0' - 972 deliberately NOT hardened (replicates KasWare's
            // "m/44'/972/0'" string exactly); change level hardened, final index hardened too
            // (applied in identityPrivateKey).
            let coinType = deriveChildKey(from: purpose, index: 972)                        // 972 (normal!)
            let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)             // 0'
            return deriveChildKey(from: account, index: 0 | 0x80000000)                     // 0' (receive)
        case .chainge:
            // m/44'/111111'/0' - the single 0' leaf is applied as the "index 0" step below.
            let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)        // 111111'
            return deriveChildKey(from: coinType, index: 0 | 0x80000000)                    // 0'
        }
    }

    /// Applies the family's index rule to the base node. Returns nil for indexes the family
    /// does not have (Chainge has exactly one address) or if the OneKey tweak fails.
    private func identityPrivateKey(at index: UInt32, baseNode: (key: Data, chainCode: Data), family: WalletSourceFamily) -> Data? {
        switch family {
        case .kaspaStandard:
            return deriveChildKey(from: baseNode, index: index).key                          // .../0/{i}
        case .kaspaLegacy972:
            guard index < 0x80000000 else { return nil }
            return deriveChildKey(from: baseNode, index: index | 0x80000000).key             // .../0'/{i'}
        case .chainge:
            guard index == 0 else { return nil }
            return deriveChildKey(from: baseNode, index: 0 | 0x80000000).key                 // .../0' (single)
        case .oneKey:
            let raw = deriveChildKey(from: baseNode, index: index).key                       // .../0/{i}, then tweak
            return oneKeyTweakedPrivateKey(raw)
        }
    }

    /// OneKey's BIP340 taproot-style key tweak, replicated from KasWare's
    /// `_onekeyPrivateKeyFromOriginPrivateKey` (bip340.ts): if the compressed pubkey has an odd
    /// Y (0x03 prefix), negate the private key mod n; then add
    /// taggedHash("TapTweak", xOnlyPubkey) mod n. The address derives from the tweaked key.
    private func oneKeyTweakedPrivateKey(_ privateKey: Data) -> Data? {
        guard let compressed = try? deriveCompressedPublicKey(from: privateKey), compressed.count == 33 else {
            return nil
        }
        var priv = privateKey
        if compressed.first == 0x03 {
            priv = negateModN(priv)
        }
        let xOnly = Data(compressed.dropFirst())
        let tweak = taggedSHA256(tag: "TapTweak", data: xOnly)
        do {
            let key = try P256K.Signing.PrivateKey(dataRepresentation: priv)
            let tweaked = try key.add(Array(tweak))
            return tweaked.dataRepresentation
        } catch {
            return nil
        }
    }

    /// BIP340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data).
    private func taggedSHA256(tag: String, data: Data) -> Data {
        let tagHash = Data(SHA256.hash(data: Data(tag.utf8)))
        return Data(SHA256.hash(data: tagHash + tagHash + data))
    }

    /// n - key (big-endian, 32 bytes). Valid private keys are nonzero and < n, so no reduction
    /// is needed beyond the plain subtraction.
    private func negateModN(_ key: Data) -> Data {
        let n = Self.secp256k1_n
        let keyBytes = [UInt8](key)
        var result = [UInt8](repeating: 0, count: 32)
        var borrow: Int16 = 0
        for i in (0..<32).reversed() {
            let diff = Int16(n[i]) - Int16(keyBytes[i]) - borrow
            if diff < 0 {
                result[i] = UInt8((diff + 256) & 0xFF)
                borrow = 1
            } else {
                result[i] = UInt8(diff & 0xFF)
                borrow = 0
            }
        }
        return Data(result)
    }

    private func logPrivateKeyStorageStatus() {
        let preStatus = keychainService.privateKeyStorageStatus()
        AppLog.log("[WalletManager] Private key storage (pre-migration): %@", preStatus)

        do {
            let migratedKey = try keychainService.loadPrivateKey()
            if migratedKey == nil {
                AppLog.log("[WalletManager] Private key migration check: no key found")
            }
        } catch {
            AppLog.log("[WalletManager] Private key migration check failed: %@", error.localizedDescription)
        }

        let postStatus = keychainService.privateKeyStorageStatus()
        AppLog.log("[WalletManager] Private key storage (post-migration): %@", postStatus)
    }

    /// Derive master key from seed using BIP32
    func deriveMasterKey(from seed: Data) -> (key: Data, chainCode: Data) {
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
    func deriveChildKey(from parent: (key: Data, chainCode: Data), index: UInt32) -> (key: Data, chainCode: Data) {
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
    func deriveSchnorrPublicKey(from privateKey: Data) throws -> Data {
        let privKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        // Get the x-only public key for Schnorr (32 bytes)
        return Data(privKey.xonly.bytes)
    }

    // MARK: - Chatting-address index (choose identity at import)
    //
    // An imported seed may hold its real identity at a nonzero index on the identity chain
    // (m/44'/111111'/0'/0/<index>) - e.g. the user's KNS domain sits on index 45 in another
    // wallet. The Welcome Guide's funding step (import runs only) lets the user scan that chain
    // and pick a different index as their chatting address. The chosen index is persisted in
    // UserDefaults keyed by the DERIVED address, so every path that re-derives from the seed
    // (getPrivateKey's fallback, reconcileWalletWithLocalKeyMaterialIfNeeded's repair) can find
    // the right index from the wallet record it already has. The keychain-stored private key is
    // simply the chosen index's key, so normal loads never re-derive at all.
    //
    // Collision note: the spending chain lives on a DIFFERENT hardened account branch
    // (m/44'/111111'/1'/0/<index>, see WalletManager+SpendingAddresses.swift), so a chosen
    // identity index can never collide with any spending address - no reservation needed.
    //
    // DECISION: the spending chain stays on KaChat's own m/44'/111111'/1' branch REGARDLESS of
    // the imported wallet's source family. Spending addresses are funds KaChat itself controls
    // and reveals (payment pools, fresh change, reservations) - they are not something the
    // source wallet ever derived, so there is nothing to "find" on the source family's branch,
    // and keeping them on the fixed account-1' branch means no source family (standard account
    // 0', legacy 972, Chainge's single 0' leaf, OneKey's tweaked account-0' keys) can ever
    // collide with them.

    private func chattingIndexKey(for address: String) -> String {
        "kachat_chatting_address_index_\(address)"
    }

    /// Persisted identity-chain index for a derived chatting address (0 when never customized).
    func chattingAddressIndex(for address: String) -> Int {
        UserDefaults.standard.object(forKey: chattingIndexKey(for: address)) as? Int ?? 0
    }

    /// Identity-chain index of the active wallet's chatting address (0 = the standard identity).
    var currentChattingAddressIndex: Int {
        guard let address = currentWallet?.publicAddress else { return 0 }
        return chattingAddressIndex(for: address)
    }

    private func persistChattingAddressIndex(_ index: Int, for address: String) {
        if index == 0 {
            UserDefaults.standard.removeObject(forKey: chattingIndexKey(for: address))
        } else {
            UserDefaults.standard.set(index, forKey: chattingIndexKey(for: address))
        }
    }

    // MARK: - Source-wallet family persistence (same pattern as the chatting index)

    private func walletSourceFamilyKey(for address: String) -> String {
        "kachat_wallet_source_family_\(address)"
    }

    /// Persisted identity path family for a derived address (`.kaspaStandard` when never
    /// customized - every pre-existing wallet).
    func walletSourceFamily(for address: String) -> WalletSourceFamily {
        guard let raw = UserDefaults.standard.string(forKey: walletSourceFamilyKey(for: address)),
              let family = WalletSourceFamily(rawValue: raw) else {
            return .kaspaStandard
        }
        return family
    }

    /// Identity path family of the active wallet.
    var currentWalletSourceFamily: WalletSourceFamily {
        guard let address = currentWallet?.publicAddress else { return .kaspaStandard }
        return walletSourceFamily(for: address)
    }

    private func persistWalletSourceFamily(_ family: WalletSourceFamily, for address: String) {
        if family == .kaspaStandard {
            UserDefaults.standard.removeObject(forKey: walletSourceFamilyKey(for: address))
        } else {
            UserDefaults.standard.set(family.rawValue, forKey: walletSourceFamilyKey(for: address))
        }
    }

    /// Shared identity base node for the ACTIVE wallet's family, derived once for a whole scan -
    /// mirrors `spendingChangeKey()` in WalletManager+SpendingAddresses.swift (same reasoning:
    /// the seed decrypt + PBKDF2 + hardened derivations dominate, and only the final per-index
    /// step differs).
    private func chattingScanBase() -> (node: (key: Data, chainCode: Data), family: WalletSourceFamily)? {
        guard let seedPhrase = try? getSeedPhrase() else { return nil }
        guard var seed = bip39.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else { return nil }
        defer { seed.zeroOut() }
        let family = currentWalletSourceFamily
        return (identityBaseNode(seed: seed, family: family), family)
    }

    private func chattingAddress(at index: Int, baseNode: (key: Data, chainCode: Data), family: WalletSourceFamily) -> String? {
        guard index >= 0, let privateKey = identityPrivateKey(at: UInt32(index), baseNode: baseNode, family: family) else { return nil }
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let network = SettingsViewModel.loadSettings().networkType
        return KaspaAddress.fromPublicKey(publicKeyData, network: network).address
    }

    /// Derives the given identity-chain index range and checks every address in BATCH for KAS
    /// balance (one pooled `getUtxosByAddresses` call, gRPC with REST fallback) and KNS domains
    /// (`KNSService.refreshIfNeeded`, the same capped/debounced batch lookup ContactsManager and
    /// Manage Addresses use - never 50 raw requests). Returns ALL scanned candidates in index
    /// order; the caller filters for interesting ones. Nil when derivation fails (no seed).
    func scanChattingAddressCandidates(indices: Range<Int>) async -> [ChattingAddressCandidate]? {
        guard !indices.isEmpty, let (baseNode, family) = chattingScanBase() else { return nil }

        // Family-aware: single-address families (Chainge) only ever yield index 0; hardened-index
        // families (legacy 972) and the OneKey tweak are handled inside chattingAddress.
        var derived: [(index: Int, address: String)] = []
        for index in indices {
            guard family.supportsIndexScan || index == 0 else { break }
            guard let address = chattingAddress(at: index, baseNode: baseNode, family: family) else { continue }
            derived.append((index, address))
        }
        guard !derived.isEmpty else { return nil }
        let addresses = derived.map(\.address)

        let utxos = (try? await NodePoolService.shared.getUtxosByAddresses(addresses)) ?? []
        var balanceByAddress: [String: UInt64] = [:]
        for utxo in utxos {
            balanceByAddress[utxo.address, default: 0] += utxo.amount
        }

        let network = SettingsViewModel.loadSettings().networkType
        await KNSService.shared.refreshIfNeeded(for: addresses, network: network)

        return derived.map { entry in
            let info = KNSService.shared.domainCache[entry.address]
            return ChattingAddressCandidate(
                index: entry.index,
                address: entry.address,
                balanceSompi: balanceByAddress[entry.address] ?? 0,
                domains: info?.allDomains ?? [],
                primaryDomain: info?.primaryDomain
            )
        }
    }

    /// Switches the wallet's identity to the chatting address at `index` on the identity chain.
    ///
    /// This is a CLEAN identity selection, not a migration: nothing is moved or deleted. If the
    /// imported seed's current (index-0) identity already synced conversation history, that
    /// history lives on-chain and in its own address-keyed storage scope (MessageStore SQLite +
    /// CloudKit zone are keyed by wallet address) - switching simply parks it there, and the UI
    /// confirms with the user first when any conversations exist (see
    /// ChattingAddressDetailView). In-flight sync races are handled the same way any account
    /// switch is: `importWallet` stops polling first, and ChatService's write-time
    /// `isActiveWallet` guard drops anything that still slips through. It funnels through
    /// `importWallet(from:alias:chattingAddressIndex:)` with the already-stored seed, so every
    /// identity consumer switches exactly like an account import does: keychain wallet record +
    /// private key (re-derived for the chosen index), `currentWallet`/`publicAddress`,
    /// `getPrivateKey()` (handshakes/ECIES encryption), ContactsManager scope, MessageStore's
    /// per-wallet SQLite + CloudKit zone (fresh zone keyed by the new address - the old
    /// address's store was empty since no conversations existed), Broadcast/Group/ColdStorage/
    /// Portfolio scopes, share-extension shared data, and ChatService polling + UTXO
    /// subscriptions (restarted for the new address; push registration always reads
    /// `currentWallet.publicAddress` live at register time).
    func setChattingAddress(index: Int) async throws {
        guard index >= 0 else {
            throw KasiaError.apiError("Invalid chatting address index")
        }
        guard index != currentChattingAddressIndex else { return }
        guard let seedPhrase = try keychainService.loadSeedPhrase() else {
            throw KasiaError.walletNotFound
        }

        let alias = currentWallet?.alias ?? "My Account"
        let previousAddress = currentWallet?.publicAddress
        // Captured BEFORE the import switches currentWallet: the index moves WITHIN the wallet's
        // source family (a Kaspanet Web seed keeps scanning/deriving on the 972 branch).
        let family = currentWalletSourceFamily

        _ = try await importWallet(from: seedPhrase, alias: alias, chattingAddressIndex: index, family: family)

        // The old identity's saved-account entry and snapshot are stale the moment the switch
        // lands - the account IS the same seed, now living at the new address. Without this the
        // saved-accounts list keeps a dead index-0 row forever.
        if let previousAddress, previousAddress != currentWallet?.publicAddress {
            savedAccounts.removeAll { $0.publicAddress == previousAddress }
            hasStoredWallet = !savedAccounts.isEmpty
            persistSavedAccountsToStorage()
            try? keychainService.deleteAccountSnapshot(publicAddress: previousAddress)
        }
    }

    // MARK: - Storage

    private func saveWallet(_ wallet: Wallet, seedPhrase: SeedPhrase, privateKey: Data) async throws {
        try keychainService.saveWallet(wallet)
        try keychainService.saveSeedPhrase(seedPhrase)
        // Private key is derived once by the caller (deriveKeysFromSeed) and passed in, rather than
        // re-deriving it here (a second full PBKDF2 + BIP32 pass on the main actor).
        try keychainService.savePrivateKey(privateKey)
        try keychainService.saveAccountSnapshot(wallet: wallet, seedPhrase: seedPhrase, privateKey: privateKey)
    }

    func saveWalletOnly(_ wallet: Wallet) async throws {
        try keychainService.saveWallet(wallet)
    }
}
