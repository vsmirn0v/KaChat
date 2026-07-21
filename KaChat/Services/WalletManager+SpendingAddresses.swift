import Foundation
import CryptoKit
import P256K

/// Spending-chain address system: a second BIP44 derivation branch (change=1) off the same
/// wallet seed, distinct from the identity/chatting address (change=0, index=0, see
/// `WalletManager.deriveKeysFromSeed`). Addresses are always re-derived live from the seed +
/// index rather than persisted - only the index bounds are stored, directly on `Wallet`
/// (`spendingAddressIndex`/`maxSpendingAddressIndex`, persisted via Keychain alongside the
/// rest of the wallet - see `Wallet.effectiveSpendingAddressIndex` in Models.swift). Hidden-set
/// and per-address labels aren't part of `Wallet`, so those stay in UserDefaults, scoped per
/// wallet address.
///
/// Path: m/44'/111111'/0'/1/<index> (the identity address uses m/44'/111111'/0'/0/0 - same
/// account, "internal" change branch instead of "external", the standard BIP44 convention for
/// a second address chain on the same account).
///
/// Reconstructed after this file's original implementation was accidentally lost to an
/// uncommitted-work-discarding `git checkout` earlier in development (see conversation) -
/// rebuilt from every call site's exact usage, cross-checked against `Wallet`'s own
/// `spendingAddressIndex`/`maxSpendingAddressIndex`/`effective*` fields (which survived, since
/// they live in Models.swift, a file the bad checkout never touched) rather than guessed from
/// scratch. If any spending-chain address was funded before this reconstruction, verify its
/// address still matches after rebuilding (the derivation path chosen here is the standard
/// BIP44 convention, but is a reconstruction, not guaranteed byte-for-byte identical to what
/// generated the original addresses).
extension WalletManager {

    // MARK: - Persisted bounds (on Wallet itself, Keychain-backed)

    var currentSpendingAddressIndex: Int {
        currentWallet?.effectiveSpendingAddressIndex ?? 0
    }

    var maxSpendingAddressIndex: Int {
        currentWallet?.effectiveMaxSpendingAddressIndex ?? 0
    }

    private func updateSpendingBounds(index: Int? = nil, maxIndex: Int? = nil) async {
        guard var wallet = currentWallet else { return }
        if let index {
            wallet.spendingAddressIndex = index
        }
        if let maxIndex {
            wallet.maxSpendingAddressIndex = maxIndex
        }
        try? await saveWalletOnly(wallet)
        currentWallet = wallet
    }

    // MARK: - Hidden-set / labels (UserDefaults, scoped per wallet - not part of Wallet itself)

    private func spendingDefaultsKey(_ suffix: String) -> String? {
        guard let address = currentWallet?.publicAddress else { return nil }
        return "kachat_spending_\(suffix)_\(address)"
    }

    private var hiddenSpendingIndices: Set<Int> {
        get {
            guard let key = spendingDefaultsKey("hidden") else { return [] }
            let array = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
            return Set(array)
        }
        set {
            guard let key = spendingDefaultsKey("hidden") else { return }
            UserDefaults.standard.set(Array(newValue), forKey: key)
        }
    }

    private var spendingLabels: [Int: String] {
        get {
            guard let key = spendingDefaultsKey("labels"),
                  let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([Int: String].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            guard let key = spendingDefaultsKey("labels"), let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Derivation

    func spendingAddress(at index: Int) -> String? {
        guard let privateKey = spendingPrivateKey(at: index) else { return nil }
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let network = SettingsViewModel.loadSettings().networkType
        return KaspaAddress.fromPublicKey(publicKeyData, network: network).address
    }

    func spendingPrivateKey(at index: Int) -> Data? {
        guard index >= 0, let seedPhrase = try? getSeedPhrase() else { return nil }
        guard var seed = BIP39.shared.mnemonicToSeed(seedPhrase.phrase, passphrase: "") else { return nil }
        defer { seed.zeroOut() }

        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)
        let account = deriveChildKey(from: coinType, index: 0 | 0x80000000)
        let change = deriveChildKey(from: account, index: 1) // internal/spending chain
        let addressIndex = deriveChildKey(from: change, index: UInt32(index))
        return addressIndex.key
    }

    func currentSpendingAddress() -> String? {
        spendingAddress(at: currentSpendingAddressIndex)
    }

    func currentSpendingPrivateKey() -> Data? {
        spendingPrivateKey(at: currentSpendingAddressIndex)
    }

    // MARK: - Mutation

    /// Switches which spending address is "primary" - a pure pointer change, moves no funds.
    /// Also extends `maxSpendingAddressIndex` if this index hasn't been revealed yet.
    func setActiveSpendingAddress(_ index: Int) async {
        guard index >= 0 else { return }
        let newMax = index > maxSpendingAddressIndex ? index : nil
        await updateSpendingBounds(index: index, maxIndex: newMax)
    }

    /// Reveals a new, never-used spending address slot (extends `maxSpendingAddressIndex` by
    /// one) without changing which address is currently primary.
    func generateNextSpendingAddress() async {
        await updateSpendingBounds(maxIndex: maxSpendingAddressIndex + 1)
    }

    /// Hides a spending address from the main Manage Addresses list. Refused (returns false)
    /// for the current primary address or one with a nonzero balance - re-enforced here
    /// server-side regardless of what the UI already checked.
    func setSpendingAddressHidden(index: Int, hidden: Bool) async -> Bool {
        guard index != currentSpendingAddressIndex else { return false }
        if hidden, let address = spendingAddress(at: index) {
            let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
            let balance = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            guard balance == 0 else { return false }
        }
        var current = hiddenSpendingIndices
        if hidden {
            current.insert(index)
        } else {
            current.remove(index)
        }
        hiddenSpendingIndices = current
        return true
    }

    func setSpendingAddressLabel(index: Int, label: String) {
        var labels = spendingLabels
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            labels.removeValue(forKey: index)
        } else {
            labels[index] = trimmed
        }
        spendingLabels = labels
    }

    /// Live-derived list of every revealed spending address (0...maxSpendingAddressIndex),
    /// with current balances. `everUsed` is left at its default (false) - callers that need it
    /// check history separately (`ChatService.hasSpendingAddressBeenUsed`), same as before.
    func getSpendingAddressList() async -> [SpendingAddressEntry] {
        let maxIndex = maxSpendingAddressIndex
        let activeIndex = currentSpendingAddressIndex
        let hidden = hiddenSpendingIndices
        let labels = spendingLabels

        var addressesByIndex: [Int: String] = [:]
        for index in 0...maxIndex {
            if let address = spendingAddress(at: index) {
                addressesByIndex[index] = address
            }
        }

        let allUtxos = (try? await NodePoolService.shared.getUtxosByAddresses(Array(addressesByIndex.values))) ?? []
        var balanceByAddress: [String: UInt64] = [:]
        for utxo in allUtxos {
            balanceByAddress[utxo.address, default: 0] += utxo.amount
        }

        return addressesByIndex.keys.sorted().map { index in
            let address = addressesByIndex[index] ?? ""
            return SpendingAddressEntry(
                index: index,
                address: address,
                balanceSompi: balanceByAddress[address] ?? 0,
                isCurrent: index == activeIndex,
                everUsed: false,
                label: labels[index],
                hidden: hidden.contains(index)
            )
        }
    }

    /// Gap-limit scan beyond the current max index for addresses with on-chain history, mirroring
    /// standard BIP44 wallet-recovery discovery. Extends `maxSpendingAddressIndex` to cover any
    /// found. Returns how many new indices were revealed.
    func discoverSpendingAddresses(gapLimit: Int = 20) async -> Int {
        var index = maxSpendingAddressIndex + 1
        var consecutiveUnused = 0
        var highestFound = maxSpendingAddressIndex

        while consecutiveUnused < gapLimit {
            guard let address = spendingAddress(at: index) else { break }
            let used = await ChatService.shared.hasSpendingAddressBeenUsed(address)
            if used {
                highestFound = index
                consecutiveUnused = 0
            } else {
                consecutiveUnused += 1
            }
            index += 1
        }

        guard highestFound > maxSpendingAddressIndex else { return 0 }
        let revealed = highestFound - maxSpendingAddressIndex
        await updateSpendingBounds(maxIndex: highestFound)
        return revealed
    }
}
