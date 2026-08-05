import Foundation

struct ColdStorageAccount: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    let kpubString: String
    var maxAddressIndex: Int
    let importedAt: Date

    init(id: UUID = UUID(), label: String, kpubString: String, maxAddressIndex: Int = 0, importedAt: Date = Date()) {
        self.id = id
        self.label = label
        self.kpubString = kpubString
        self.maxAddressIndex = maxAddressIndex
        self.importedAt = importedAt
    }
}

struct ColdStorageAddressEntry: Identifiable {
    let index: Int
    let address: String
    let balanceSompi: UInt64
    var everUsed: Bool = false
    var label: String?
    var hidden: Bool = false

    var id: String { address }
    var displayLabel: String { label?.isEmpty == false ? label! : "Address #\(index)" }
    var shortAddress: String {
        guard address.count > 20 else { return address }
        return address.prefix(14) + "..." + address.suffix(6)
    }
}

enum ColdStorageError: LocalizedError {
    case invalidKpub

    var errorDescription: String? {
        switch self {
        case .invalidKpub:
            return "That doesn't look like a valid Kaspa extended public key (kpub)."
        }
    }
}

/// Manages watch-only "cold storage" accounts imported via kpub extended public key
/// (e.g. exported from a KasSigner hardware device). Storage here is intentionally
/// separate from WalletManager/KeychainService — a kpub contains no private key or
/// mnemonic material, so it needs neither Secure Enclave wrapping nor the per-wallet
/// CloudKit zone machinery used for the app's spending wallet.
@MainActor
final class ColdStorageManager: ObservableObject {
    static let shared = ColdStorageManager()

    @Published private(set) var accounts: [ColdStorageAccount] = []

    private let legacyStorageKey = "kachat_cold_storage_accounts"
    private let storageKeyPrefix = "kachat_cold_storage_accounts_"
    private var activeWalletAddress: String?

    private init() {
        // No wallet set yet at app launch; setCurrentWallet(_:) is called once the
        // active wallet is known, which loads (and migrates, if needed) the real list.
        accounts = []
    }

    /// Cold storage accounts are watch-only imports, but they must still be scoped per
    /// spending wallet — otherwise switching accounts on this device leaks one wallet's
    /// imported kpubs/labels/hidden-address state into another's view. Mirrors
    /// ContactsManager.setActiveWalletAddress's key-per-wallet pattern.
    func setCurrentWallet(_ walletAddress: String?) {
        let normalizedAddress = normalizeWalletAddress(walletAddress)
        guard activeWalletAddress != normalizedAddress else { return }
        activeWalletAddress = normalizedAddress
        accounts = normalizedAddress == nil ? [] : loadAccounts()
    }

    private func normalizeWalletAddress(_ walletAddress: String?) -> String? {
        guard let walletAddress = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !walletAddress.isEmpty else {
            return nil
        }
        return walletAddress.lowercased()
    }

    private var storageKey: String? {
        guard let activeWalletAddress else { return nil }
        let sanitized = activeWalletAddress.replacingOccurrences(of: ":", with: "_")
        return "\(storageKeyPrefix)\(sanitized)"
    }

    // MARK: - Import / management

    /// Re-importing an already-known kpub updates that account's name in place rather than
    /// creating a duplicate entry.
    @discardableResult
    func importAccount(kpubString: String, label: String) -> Result<ColdStorageAccount, ColdStorageError> {
        let trimmedKpub = kpubString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KaspaExtendedPublicKey(kpubString: trimmedKpub) != nil else {
            return .failure(.invalidKpub)
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = trimmedLabel.isEmpty ? "Cold Storage \(accounts.count + 1)" : trimmedLabel

        if let idx = accounts.firstIndex(where: { $0.kpubString == trimmedKpub }) {
            accounts[idx].label = resolvedLabel
            saveAccounts()
            return .success(accounts[idx])
        }

        let account = ColdStorageAccount(label: resolvedLabel, kpubString: trimmedKpub)
        accounts.append(account)
        saveAccounts()
        return .success(account)
    }

    func removeAccount(_ account: ColdStorageAccount) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
    }

    func renameAccount(_ account: ColdStorageAccount, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].label = trimmed
        saveAccounts()
    }

    // MARK: - Address list / balances

    /// Derives addresses 0...maxAddressIndex for the account and fetches live balances with a
    /// single batched `getUtxosByAddresses` call covering every address at once (mirrors
    /// Kaspium's `UtxosNotifier.refresh`, which does the same one-call-for-the-whole-set fetch
    /// rather than a request per address) instead of the previous per-address `withTaskGroup`,
    /// which fired one gRPC round trip per address even though `getUtxosByAddresses` already
    /// accepts the whole address list. Safe to batch here (unlike the spending chain's
    /// sequential "used" scan below) since this is only balance lookups against a gRPC node,
    /// not the REST call that was previously implicated in rate-limit-driven false "used" results.
    func getAddressList(for account: ColdStorageAccount) async -> [ColdStorageAddressEntry] {
        guard let extendedKey = KaspaExtendedPublicKey(kpubString: account.kpubString) else { return [] }
        let network = AppSettings.load().networkType
        let labels = loadAddressLabels(accountId: account.id)
        let hidden = loadHiddenIndices(accountId: account.id)

        var addressesByIndex: [Int: String] = [:]
        for index in 0...account.maxAddressIndex {
            if let address = try? extendedKey.receiveAddress(at: UInt32(index), network: network) {
                addressesByIndex[index] = address
            }
        }

        let allAddresses = Array(addressesByIndex.values)
        let utxos = (try? await NodePoolService.shared.getUtxosByAddresses(allAddresses)) ?? []
        var balanceByAddress: [String: UInt64] = [:]
        for utxo in utxos {
            balanceByAddress[utxo.address, default: 0] += utxo.amount
        }

        return addressesByIndex.map { index, address in
            ColdStorageAddressEntry(
                index: index,
                address: address,
                balanceSompi: balanceByAddress[address] ?? 0,
                label: labels[index],
                hidden: hidden.contains(index)
            )
        }.sorted { $0.index < $1.index }
    }

    /// Scans forward from index 0, stopping after `gapLimit` consecutive never-used
    /// addresses, and raises maxAddressIndex to cover every used address found. Sequential
    /// by design, matching WalletManager.discoverSpendingAddresses' rate-limit reasoning.
    @discardableResult
    func discoverAddresses(for account: ColdStorageAccount, gapLimit: Int = 20) async -> Int {
        guard let extendedKey = KaspaExtendedPublicKey(kpubString: account.kpubString) else {
            return account.maxAddressIndex
        }
        let network = AppSettings.load().networkType

        var lastUsedIndex = -1
        var consecutiveUnused = 0
        var index: UInt32 = 0

        while consecutiveUnused < gapLimit {
            guard let address = try? extendedKey.receiveAddress(at: index, network: network) else { break }
            // An address counts as "used" if it currently holds UTXOs OR has transaction history.
            // Checking UTXOs first (a gRPC call, not the rate-limited REST history path) guarantees
            // discovery never skips a funded address whose history the indexer doesn't return, so it
            // surfaces ALL UTXO-bearing addresses - and short-circuits the REST call when UTXOs exist.
            let hasUtxos = !((try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []).isEmpty
            // Can't use `||` here: its right side is a non-async autoclosure. An explicit branch
            // keeps the same short-circuit (only hit the rate-limited REST history check when the
            // address holds no UTXOs).
            let used: Bool
            if hasUtxos {
                used = true
            } else {
                used = await ChatService.shared.hasSpendingAddressBeenUsed(address)
            }
            if used {
                lastUsedIndex = Int(index)
                consecutiveUnused = 0
            } else {
                consecutiveUnused += 1
            }
            index += 1
        }

        let discovered = lastUsedIndex + 1
        if discovered > account.maxAddressIndex, let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].maxAddressIndex = discovered
            saveAccounts()
        }
        return discovered
    }

    func generateNextAddress(for account: ColdStorageAccount) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[idx].maxAddressIndex += 1
        saveAccounts()
    }

    // MARK: - Per-address labels

    func setAddressLabel(accountId: UUID, index: Int, label: String?) {
        var labels = loadAddressLabels(accountId: accountId)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            labels.removeValue(forKey: index)
        } else {
            labels[index] = trimmed
        }
        saveAddressLabels(labels, accountId: accountId)
    }

    private func loadAddressLabels(accountId: UUID) -> [Int: String] {
        guard let data = UserDefaults.standard.data(forKey: addressLabelsKey(for: accountId)),
              let decoded = try? JSONDecoder().decode([Int: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveAddressLabels(_ labels: [Int: String], accountId: UUID) {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: addressLabelsKey(for: accountId))
    }

    private func addressLabelsKey(for accountId: UUID) -> String {
        "kachat_cold_storage_labels_" + accountId.uuidString
    }

    // MARK: - Per-UTXO labels

    /// Keyed by address (the UTXOs tab is per-address, not per-account) + `"txId:index"` outpoint
    /// key, mirroring per-address labels above exactly.
    func setUtxoLabel(address: String, outpointKey: String, label: String?) {
        var labels = loadUtxoLabels(address: address)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            labels.removeValue(forKey: outpointKey)
        } else {
            labels[outpointKey] = trimmed
        }
        saveUtxoLabels(labels, address: address)
    }

    func loadUtxoLabels(address: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: utxoLabelsKey(for: address)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveUtxoLabels(_ labels: [String: String], address: String) {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: utxoLabelsKey(for: address))
    }

    private func utxoLabelsKey(for address: String) -> String {
        "kachat_cold_storage_utxo_labels_" + address
    }

    // MARK: - Hidden addresses

    /// Refuses to hide the address currently holding a balance (mirrors
    /// WalletManager.setSpendingAddressHidden — hiding is a display preference, never a way
    /// to lose sight of real funds). Unhiding always succeeds.
    @discardableResult
    func setAddressHidden(accountId: UUID, index: Int, hidden: Bool, balanceSompi: UInt64) -> Bool {
        if hidden && balanceSompi > 0 { return false }
        var indices = loadHiddenIndices(accountId: accountId)
        if hidden {
            indices.insert(index)
        } else {
            indices.remove(index)
        }
        saveHiddenIndices(indices, accountId: accountId)
        return true
    }

    private func loadHiddenIndices(accountId: UUID) -> Set<Int> {
        guard let data = UserDefaults.standard.data(forKey: hiddenIndicesKey(for: accountId)),
              let decoded = try? JSONDecoder().decode(Set<Int>.self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveHiddenIndices(_ indices: Set<Int>, accountId: UUID) {
        guard let data = try? JSONEncoder().encode(indices) else { return }
        UserDefaults.standard.set(data, forKey: hiddenIndicesKey(for: accountId))
    }

    private func hiddenIndicesKey(for accountId: UUID) -> String {
        "kachat_cold_storage_hidden_" + accountId.uuidString
    }

    // MARK: - Persistence

    private func loadAccounts() -> [ColdStorageAccount] {
        guard let storageKey else { return [] }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ColdStorageAccount].self, from: data) {
            return decoded
        }
        // One-time migration: this key predates per-wallet scoping. Claim it for the
        // first wallet that loads after the update, then remove it so no other wallet
        // can also claim it.
        if let legacyData = UserDefaults.standard.data(forKey: legacyStorageKey),
           let legacyDecoded = try? JSONDecoder().decode([ColdStorageAccount].self, from: legacyData) {
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
            UserDefaults.standard.set(legacyData, forKey: storageKey)
            return legacyDecoded
        }
        return []
    }

    private func saveAccounts() {
        guard let storageKey, let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Permanently deletes this wallet's cold storage data (accounts list plus each
    /// account's labels/hidden-address state), used when a saved account is removed
    /// from the device entirely. Mirrors GroupChatService.clearAllLocalData().
    func clearAllLocalData() {
        let idsToClear = accounts.map { $0.id }
        if let storageKey {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        for id in idsToClear {
            UserDefaults.standard.removeObject(forKey: addressLabelsKey(for: id))
            UserDefaults.standard.removeObject(forKey: hiddenIndicesKey(for: id))
        }
        accounts = []
    }
}
