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

    private let storageKey = "kachat_cold_storage_accounts"

    private init() {
        accounts = loadAccounts()
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

    /// Derives addresses 0...maxAddressIndex for the account and fetches live balances
    /// concurrently — safe here (unlike the spending chain's sequential "used" scan) since
    /// this is only balance lookups, not the REST call that was previously implicated in
    /// rate-limit-driven false "used" results.
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

        return await withTaskGroup(of: ColdStorageAddressEntry?.self) { group in
            for (index, address) in addressesByIndex {
                group.addTask {
                    let balance = (try? await NodePoolService.shared.getUtxosByAddresses([address]))?
                        .reduce(UInt64(0)) { $0 + $1.amount } ?? 0
                    return ColdStorageAddressEntry(
                        index: index,
                        address: address,
                        balanceSompi: balance,
                        label: labels[index],
                        hidden: hidden.contains(index)
                    )
                }
            }
            var results: [ColdStorageAddressEntry] = []
            for await entry in group {
                if let entry { results.append(entry) }
            }
            return results.sorted { $0.index < $1.index }
        }
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
            let used = await ChatService.shared.hasSpendingAddressBeenUsed(address)
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ColdStorageAccount].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
