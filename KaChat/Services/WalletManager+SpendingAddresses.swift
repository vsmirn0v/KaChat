import Foundation
import CryptoKit
import P256K

/// Spending-chain address system: a second BIP44 *account* branch off the same wallet seed,
/// distinct from the identity/chatting address's account (see `WalletManager.deriveKeysFromSeed`,
/// account 0). Addresses are always re-derived live from the seed + index rather than persisted -
/// only the index bounds are stored, in UserDefaults scoped per wallet address (see
/// `currentSpendingAddressIndex`'s doc comment for why that, and not `Wallet`'s own
/// `spendingAddressIndex`/`maxSpendingAddressIndex` fields, is authoritative). Hidden-set and
/// per-address labels live in that same per-address UserDefaults scope.
///
/// Path: m/44'/111111'/1'/0/<index> (the identity address uses m/44'/111111'/0'/0/0 - same
/// purpose/coin type, a separate account index so it can't collide with the identity address,
/// same external/receive chain shape so gap-limit discovery behaves like normal BIP44 wallet
/// recovery).
///
/// Reconstructed after this file's original implementation was accidentally lost to an
/// uncommitted-work-discarding `git checkout` earlier in development (see conversation) -
/// rebuilt from every call site's exact usage, cross-checked against `Wallet`'s own
/// `spendingAddressIndex`/`maxSpendingAddressIndex`/`effective*` fields (which survived, since
/// they live in Models.swift, a file the bad checkout never touched) rather than guessed from
/// scratch. An initial guess (a change=1 branch under account 0) didn't match - this account-1
/// variant is the second attempt. If any spending-chain address was funded before this
/// reconstruction, verify its address still matches after rebuilding (the derivation path
/// chosen here is a standard-shaped BIP44 branch, but is a reconstruction, not guaranteed
/// byte-for-byte identical to what generated the original addresses).
extension WalletManager {

    // MARK: - Persisted bounds (UserDefaults, scoped per wallet - authoritative)

    /// Authoritative source is per-address-keyed UserDefaults, NOT `currentWallet`'s own
    /// `spendingAddressIndex`/`maxSpendingAddressIndex` fields - every path that reconstructs a
    /// `Wallet` from partial data (re-signing into a saved account via `SavedAccountSummary`,
    /// re-importing the same account's seed phrase, the key-repair branch in
    /// `reconcileWalletWithLocalKeyMaterialIfNeeded`) builds a bare `Wallet` whose spending
    /// fields default to nil/0 and then persists that to the single-slot Keychain wallet record,
    /// permanently losing this state if it were the only place it lived - which it used to be,
    /// and was the cause of "log out, log back in, spending addresses reset to just #0". Kept in
    /// sync on the Wallet struct too (`updateSpendingBounds` below) purely as a migration
    /// fallback for anyone who generated spending addresses before this fix - see
    /// `migrateSpendingBoundsIfNeeded()`.
    var currentSpendingAddressIndex: Int {
        persistedSpendingAddressIndex ?? currentWallet?.effectiveSpendingAddressIndex ?? 0
    }

    var maxSpendingAddressIndex: Int {
        let fallback = currentWallet?.effectiveMaxSpendingAddressIndex ?? 0
        return max(persistedMaxSpendingAddressIndex ?? fallback, currentSpendingAddressIndex)
    }

    private var persistedSpendingAddressIndex: Int? {
        get {
            guard let key = spendingDefaultsKey("index") else { return nil }
            return UserDefaults.standard.object(forKey: key) as? Int
        }
        set {
            guard let key = spendingDefaultsKey("index") else { return }
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private var persistedMaxSpendingAddressIndex: Int? {
        get {
            guard let key = spendingDefaultsKey("maxIndex") else { return nil }
            return UserDefaults.standard.object(forKey: key) as? Int
        }
        set {
            guard let key = spendingDefaultsKey("maxIndex") else { return }
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// One-time-per-address migration for wallets that generated spending addresses before this
    /// fix: seeds UserDefaults from the just-loaded Wallet's own (Keychain-persisted) fields the
    /// first time this address is seen with no UserDefaults value yet, so the value survives even
    /// if a later reconstruction path resets the Wallet's own fields before this address's next
    /// genuine `setActiveSpendingAddress`/`generateNextSpendingAddress` call. No-op once
    /// UserDefaults already has a value for this address (including a legitimately-0 one). Called
    /// from `loadWallet()` right after `currentWallet` is set to the freshly-loaded record.
    func migrateSpendingBoundsIfNeeded() {
        guard let wallet = currentWallet else { return }
        if persistedSpendingAddressIndex == nil, let index = wallet.spendingAddressIndex {
            persistedSpendingAddressIndex = index
        }
        if persistedMaxSpendingAddressIndex == nil, let maxIndex = wallet.maxSpendingAddressIndex {
            persistedMaxSpendingAddressIndex = maxIndex
        }
    }

    private func updateSpendingBounds(index: Int? = nil, maxIndex: Int? = nil) async {
        guard var wallet = currentWallet else { return }
        if let index {
            wallet.spendingAddressIndex = index
            persistedSpendingAddressIndex = index
        }
        if let maxIndex {
            wallet.maxSpendingAddressIndex = maxIndex
            persistedMaxSpendingAddressIndex = maxIndex
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

    // Snapshot of the last fully-loaded Manage Addresses list, persisted per wallet so the
    // screen can render INSTANTLY from cache while the live network refresh runs behind it.
    // Balances in the snapshot may be stale for a moment — the refresh replaces them.
    func cachedSpendingAddressList() -> [SpendingAddressEntry] {
        guard let key = spendingDefaultsKey("entries_cache"),
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SpendingAddressEntry].self, from: data) else { return [] }
        return decoded
    }

    func storeSpendingAddressListCache(_ entries: [SpendingAddressEntry]) {
        guard let key = spendingDefaultsKey("entries_cache"),
              let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
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

    // MARK: - Per-UTXO labels

    /// Keyed by address + `"txId:index"` outpoint key, mirroring `ColdStorageManager`'s identical
    /// per-UTXO label scheme (see that file's own copy of this pattern) - a spending address's
    /// UTXOs deserve the same optional naming Cold Storage's already have.
    func setSpendingUtxoLabel(address: String, outpointKey: String, label: String?) {
        var labels = loadSpendingUtxoLabels(address: address)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            labels.removeValue(forKey: outpointKey)
        } else {
            labels[outpointKey] = trimmed
        }
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: spendingUtxoLabelsKey(for: address))
    }

    func loadSpendingUtxoLabels(address: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: spendingUtxoLabelsKey(for: address)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func spendingUtxoLabelsKey(for address: String) -> String {
        "kachat_spending_utxo_labels_" + address
    }

    // MARK: - Derivation

    /// Cache of derived spending ADDRESSES (never keys), persisted per wallet + network.
    /// Two reasons:
    /// 1. Correctness — `spendingPrivateKey(at:)` needs the seed from the keychain, which can
    ///    transiently fail (cold launch / before protected data unlocks). Every caller that did
    ///    `currentSpendingAddress() ?? wallet.publicAddress` then briefly showed the CHATTING
    ///    address under the spending role until a later render resolved it — the "chatting
    ///    balance shows under spending then reverts" flicker. Addresses are deterministic, so a
    ///    cached value is always correct and never needs invalidation.
    /// 2. Speed — skips Secure Enclave decrypt + PBKDF2 + 5 HMAC derivations per lookup.
    private func spendingAddressCacheKey() -> String? {
        guard let base = spendingDefaultsKey("derived_addresses") else { return nil }
        return "\(base)_\(SettingsViewModel.loadSettings().networkType.rawValue)"
    }

    func spendingAddress(at index: Int) -> String? {
        guard index >= 0 else { return nil }
        let cacheKey = spendingAddressCacheKey()
        if let cacheKey,
           let cached = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String],
           let address = cached[String(index)] {
            return address
        }
        guard let privateKey = spendingPrivateKey(at: index) else { return nil }
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let network = SettingsViewModel.loadSettings().networkType
        let address = KaspaAddress.fromPublicKey(publicKeyData, network: network).address
        if let cacheKey {
            var cached = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
            cached[String(index)] = address
            UserDefaults.standard.set(cached, forKey: cacheKey)
        }
        return address
    }

    func spendingPrivateKey(at index: Int) -> Data? {
        guard index >= 0, let seedPhrase = try? getSeedPhrase() else { return nil }
        guard var seed = BIP39.shared.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else { return nil }
        defer { seed.zeroOut() }

        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)
        let account = deriveChildKey(from: coinType, index: 1 | 0x80000000) // separate account branch, not the identity's account 0
        let change = deriveChildKey(from: account, index: 0) // external/receive chain, same as identity's own chain
        let addressIndex = deriveChildKey(from: change, index: UInt32(index))
        return addressIndex.key
    }

    func currentSpendingAddress() -> String? {
        spendingAddress(at: currentSpendingAddressIndex)
    }

    func currentSpendingPrivateKey() -> Data? {
        spendingPrivateKey(at: currentSpendingAddressIndex)
    }

    /// Derives the shared "change" node (m/44'/111111'/1'/0) once, for reuse across every index
    /// in a range - `spendingAddress(at:)`/`spendingPrivateKey(at:)` above each redo the expensive
    /// parts (Secure Enclave seed-phrase decrypt, PBKDF2-2048 mnemonic-to-seed, 4 HMAC-SHA512
    /// hardened derivations) from scratch per call, which is fine for a single lookup but was the
    /// dominant cost in `getSpendingAddressList()`/`discoverSpendingAddresses()` below calling one
    /// of those once per address - Manage Addresses' load time scaled with the number of revealed
    /// addresses for no reason, since only the final per-index derivation actually differs.
    private func spendingChangeKey() -> (key: Data, chainCode: Data)? {
        guard let seedPhrase = try? getSeedPhrase() else { return nil }
        guard var seed = BIP39.shared.mnemonicToSeed(seedPhrase.phrase, passphrase: seedPhrase.passphrase ?? "") else { return nil }
        defer { seed.zeroOut() }
        let masterKey = deriveMasterKey(from: seed)
        let purpose = deriveChildKey(from: masterKey, index: 44 | 0x80000000)
        let coinType = deriveChildKey(from: purpose, index: 111111 | 0x80000000)
        let account = deriveChildKey(from: coinType, index: 1 | 0x80000000)
        return deriveChildKey(from: account, index: 0)
    }

    private func spendingAddress(at index: Int, changeKey: (key: Data, chainCode: Data)) -> String? {
        guard index >= 0 else { return nil }
        let cacheKey = spendingAddressCacheKey()
        if let cacheKey,
           let cached = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String],
           let address = cached[String(index)] {
            return address
        }
        let privateKey = deriveChildKey(from: changeKey, index: UInt32(index)).key
        guard let publicKeyData = try? deriveSchnorrPublicKey(from: privateKey) else { return nil }
        let network = SettingsViewModel.loadSettings().networkType
        let address = KaspaAddress.fromPublicKey(publicKeyData, network: network).address
        if let cacheKey {
            var cached = (UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String]) ?? [:]
            cached[String(index)] = address
            UserDefaults.standard.set(cached, forKey: cacheKey)
        }
        return address
    }

    // MARK: - Mutation

    /// Switches which spending address is "primary" - a pure pointer change, moves no funds.
    /// Also extends `maxSpendingAddressIndex` if this index hasn't been revealed yet.
    func setActiveSpendingAddress(_ index: Int) async {
        guard index >= 0 else { return }
        let changed = index != currentSpendingAddressIndex
        let newMax = index > maxSpendingAddressIndex ? index : nil
        await updateSpendingBounds(index: index, maxIndex: newMax)
        // Let open screens (Manage Addresses) refresh which row is primary immediately -
        // a payment send rotates the primary through here, and without this the old primary's
        // row kept its stale star (and hid its Hide action) until the next full reload.
        if changed {
            NotificationCenter.default.post(name: .spendingPrimaryChanged, object: nil)
        }
    }

    /// Reveals a new, never-used spending address slot (extends `maxSpendingAddressIndex` by
    /// one) without changing which address is currently primary.
    func generateNextSpendingAddress() async {
        await updateSpendingBounds(maxIndex: maxSpendingAddressIndex + 1)
    }

    /// "Generate New Spending Address" - a SEQUENCE, not a single answer: every press yields
    /// the NEXT fresh address, forever. The chosen index is the lowest one that is truly
    /// unused (zero balance, no on-chain history, not the primary, never offered to a contact
    /// as a payment-pool reservation) AND currently hidden - i.e. not already sitting in the
    /// Manage Addresses list. Recycling un-hides it. An index that is already visible is never
    /// picked (that was the old stall: the lowest unused index, once revealed, satisfied every
    /// check again on the next press, so Generate kept returning the same row and appeared to
    /// stop working). When no hidden unused index remains, the chain extends by one past the
    /// all-time max, which is always safe. A probe failure (used-ness unknown) skips that
    /// index rather than recycling it. Returns the chosen index.
    func lowestUnusedSpendingAddress() async -> Int {
        let entries = await getSpendingAddressList().sorted { $0.index < $1.index }
        // Only ACTIVE live-pool offers are excluded from recycling: a reverted reservation
        // (revoked, superseded, or funded-and-swept) that the user has since hidden is a
        // legitimate recycle candidate again.
        let reserved: Set<String> = {
            guard let wallet = currentWallet else { return [] }
            return Set(PaymentPoolStore.shared.activeOfferedReservationAddresses(wallet: wallet.publicAddress))
        }()
        for entry in entries {
            guard entry.hidden else { continue } // already visible - the user has it; move on
            if entry.isCurrent { continue }
            if entry.balanceSompi > 0 { continue }
            if reserved.contains(entry.address) { continue }
            // Recycle only on a CONFIRMED-unused probe; nil (probe failed) skips the index -
            // extending the chain below is always safe, recycling an unknown one is not.
            let usedState = await ChatService.shared.spendingAddressUsedState(entry.address)
            if usedState == false {
                _ = await setSpendingAddressHidden(index: entry.index, hidden: false)
                if let wallet = currentWallet {
                    PaymentPoolStore.shared.markReclaimed(address: entry.address, wallet: wallet.publicAddress)
                }
                return entry.index
            }
        }
        await generateNextSpendingAddress()
        let newIndex = maxSpendingAddressIndex
        _ = await setSpendingAddressHidden(index: newIndex, hidden: false)
        return newIndex
    }

    /// Reveals a specific index from the Address Visibility pager, extending the chain when the
    /// index is beyond the current max - intermediate newly-covered indices are marked hidden so
    /// checking ONE far-out row doesn't flood the main list with everything below it.
    func revealSpendingAddress(at index: Int) async {
        let currentMax = maxSpendingAddressIndex
        if index > currentMax {
            await updateSpendingBounds(maxIndex: index)
            if index - 1 > currentMax {
                var hiddenSet = hiddenSpendingIndices
                for i in (currentMax + 1)..<index { hiddenSet.insert(i) }
                hiddenSpendingIndices = hiddenSet
            }
        }
        _ = await setSpendingAddressHidden(index: index, hidden: false)
    }

    /// Reveals and returns `count` brand-new spending-chain slots in one step - used by the
    /// fresh-address payment pool feature (`ChatService+PaymentPools`) to reserve addresses to
    /// offer a contact. Indices start strictly past `maxSpendingAddressIndex`, and the max is
    /// bumped to cover them before returning, so: (a) they have never been revealed, funded, or
    /// offered before, and (b) no later payment-change address or reservation can ever land on
    /// the same index (`sendPaymentInternal`'s fresh change index and this both always start at
    /// max+1). The addresses stay listed in Manage Addresses like any other revealed slot - the
    /// per-contact reservation itself lives in `PaymentPoolStore`, not here.
    ///
    /// Returns an empty array (reserving nothing, bumping nothing) if derivation fails.
    func reserveFreshSpendingAddresses(count: Int) async -> [(index: Int, address: String)] {
        guard count > 0, let changeKey = spendingChangeKey() else { return [] }
        let base = maxSpendingAddressIndex + 1
        var result: [(index: Int, address: String)] = []
        for offset in 0..<count {
            let index = base + offset
            guard let address = spendingAddress(at: index, changeKey: changeKey) else { return [] }
            result.append((index: index, address: address))
        }
        await updateSpendingBounds(maxIndex: base + count - 1)
        return result
    }

    /// Derives the spending addresses for an arbitrary index range with a SINGLE seed decrypt
    /// (shared change-node key), reading/filling the persistent per-index address cache.
    /// Built for the Address Visibility pager's beyond-revealed pages: calling the public
    /// `spendingAddress(at:)` once per row re-did the Secure Enclave decrypt + PBKDF2 per
    /// index, which froze (or, on a transient keychain failure, blanked) a whole 50-row page.
    /// Returns an empty map when the seed is unavailable this instant - callers should treat
    /// that as "try again", never as "these indices don't exist".
    func spendingAddresses(inRange range: Range<Int>) -> [Int: String] {
        guard !range.isEmpty else { return [:] }
        // Serve fully-cached ranges without touching the keychain at all.
        var result: [Int: String] = [:]
        var missing: [Int] = []
        if let cacheKey = spendingAddressCacheKey(),
           let cached = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] {
            for index in range {
                if let address = cached[String(index)] {
                    result[index] = address
                } else {
                    missing.append(index)
                }
            }
        } else {
            missing = Array(range)
        }
        guard !missing.isEmpty else { return result }
        guard let changeKey = spendingChangeKey() else { return result }
        for index in missing {
            if let address = spendingAddress(at: index, changeKey: changeKey) {
                result[index] = address
            }
        }
        return result
    }

    /// True if `address` is one of this wallet's own revealed spending-chain addresses
    /// (0...maxSpendingAddressIndex) - used to reject a received pool that tries to feed our own
    /// addresses back to us. One seed decrypt + one derivation per revealed index; call off the
    /// hot path.
    func isOwnSpendingAddress(_ address: String) -> Bool {
        guard let changeKey = spendingChangeKey() else { return false }
        for index in 0...maxSpendingAddressIndex {
            if spendingAddress(at: index, changeKey: changeKey) == address {
                return true
            }
        }
        return false
    }

    /// Every revealed spending-chain address (0...maxSpendingAddressIndex), derived with a
    /// single seed decrypt via the shared change-node key - for callers that need the whole
    /// set WITHOUT balances (e.g. AddressActivityNotifier's own-address watch set), unlike
    /// `getSpendingAddressList()` which also fires a UTXO fetch.
    func allSpendingAddresses() -> [String] {
        guard let changeKey = spendingChangeKey() else { return [] }
        return (0...maxSpendingAddressIndex).compactMap { spendingAddress(at: $0, changeKey: changeKey) }
    }

    /// Hides a spending address from the main Manage Addresses list. Refused (returns false)
    /// for the current primary address, one with a nonzero balance, or one ACTIVELY offered to
    /// a contact in a live payment pool (those stay visible so the user always sees which
    /// addresses are held ready for contacts to pay into) - re-enforced here server-side
    /// regardless of what the UI already checked. A reservation that reverted (revoked,
    /// superseded, or funded-and-swept) is a normal address again and hides fine.
    func setSpendingAddressHidden(index: Int, hidden: Bool) async -> Bool {
        guard index != currentSpendingAddressIndex else { return false }
        if hidden, let address = spendingAddress(at: index) {
            if let walletAddress = currentWallet?.publicAddress,
               PaymentPoolStore.shared.activeOfferedReservationAddresses(wallet: walletAddress).contains(address) {
                return false
            }
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

    /// Read-only snapshot of the hidden set, so Manage Addresses can apply bulk
    /// visibility edits to its already-loaded rows instantly on sheet dismiss
    /// (before the full balance/used reload finishes).
    func hiddenSpendingIndexSet() -> Set<Int> {
        hiddenSpendingIndices
    }

    /// Removes payment-pool reservation indices from the hidden set, bypassing the async
    /// balance path (unhiding needs no network guard). Reservations are born VISIBLE - fresh
    /// indices start past the all-time max and were never hidden - so for new offers this is a
    /// no-op; it matters for reservations recorded under the old born-hidden design (before
    /// the product change that surfaces them in Manage Addresses) that get (re-)offered now.
    func unhideReservedIndices(_ indices: [Int]) {
        var current = hiddenSpendingIndices
        let before = current.count
        for index in indices { current.remove(index) }
        guard current.count != before else { return }
        hiddenSpendingIndices = current
    }

    /// One-shot repair for the old born-hidden payment-pool design: any address in an ACTIVE
    /// live pool that is still sitting in the hidden set becomes visible, so users with
    /// outstanding pools see them in Manage Addresses without re-offering. Deliberately scoped
    /// to the active set - a reservation that already reverted (revoked, superseded, funded)
    /// is a normal address and stays however the user left it. Cheap set intersection - safe
    /// to call on every Manage Addresses load and on wallet load.
    func unhideOfferedReservationsIfNeeded() {
        guard let walletAddress = currentWallet?.publicAddress else { return }
        let offered = PaymentPoolStore.shared.activeOfferedReservationAddresses(wallet: walletAddress)
        guard !offered.isEmpty else { return }
        var hidden = hiddenSpendingIndices
        var unhidden = 0
        for address in offered {
            if let index = PaymentPoolStore.shared.reservationIndex(for: address, wallet: walletAddress),
               hidden.contains(index) {
                hidden.remove(index)
                unhidden += 1
            }
        }
        guard unhidden > 0 else { return }
        hiddenSpendingIndices = hidden
        AppLog.log("[WalletManager] Un-hid %d offered payment-pool addresses (legacy born-hidden migration)", unhidden)
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
        if let changeKey = spendingChangeKey() {
            for index in 0...maxIndex {
                if let address = spendingAddress(at: index, changeKey: changeKey) {
                    addressesByIndex[index] = address
                }
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

    /// Where a discovery scan currently is, so a UI can count up instead of showing an unmoving
    /// spinner for the half-minute a gap-limit walk takes. Mirrors `ColdStorageManager`'s.
    struct SpendingDiscoveryProgress: Equatable {
        let checkingIndex: Int
        let foundCount: Int
    }

    /// Gap-limit scan for spending addresses worth surfacing, matching Cold Storage's discovery
    /// exactly (`ColdStorageManager.discoverAddresses`). Extends `maxSpendingAddressIndex` to
    /// cover the highest match. Returns how many addresses were FOUND, not the new bound.
    ///
    /// Two deliberate differences from what this used to do:
    ///
    /// An address is worth surfacing when it HOLDS SOMETHING - a balance, or a KNS domain - not
    /// when it has transaction history. History still decides the "Unused" badge on a row (address
    /// reuse is a privacy problem), but every address ever touched and emptied is not what this
    /// list is for.
    ///
    /// And the walk starts at index 0, never at the stored high-water mark, because the answer
    /// CHANGES: an address that was empty last month can hold a balance today, and a scan starting
    /// past it would never look again.
    @discardableResult
    func discoverSpendingAddresses(
        gapLimit: Int = 20,
        onProgress: (@MainActor (SpendingDiscoveryProgress) -> Void)? = nil
    ) async -> Int {
        guard let changeKey = spendingChangeKey() else { return 0 }

        var lastMatchIndex = -1
        var matchCount = 0
        var consecutiveMisses = 0
        var index = 0

        while consecutiveMisses < gapLimit {
            if let onProgress {
                let snapshot = SpendingDiscoveryProgress(checkingIndex: index, foundCount: matchCount)
                await MainActor.run { onProgress(snapshot) }
            }
            guard let address = spendingAddress(at: index, changeKey: changeKey) else { break }

            // Balance first: it short-circuits the KNS lookup for the common case.
            let hasBalance = !((try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []).isEmpty
            let matches = hasBalance ? true : await KNSService.shared.ownsAnyDomain(address)

            if matches {
                lastMatchIndex = index
                matchCount += 1
                consecutiveMisses = 0
            } else {
                consecutiveMisses += 1
            }
            index += 1
        }

        // The stored bound has to cover the highest match so those rows can be derived and shown,
        // and it only ever grows: an address that held funds last month and is empty now should
        // not vanish from the list.
        if lastMatchIndex > maxSpendingAddressIndex {
            await updateSpendingBounds(maxIndex: lastMatchIndex)
        }
        return matchCount
    }
}

extension Notification.Name {
    /// Posted after the primary spending address pointer changes - a manual "Set as Primary"
    /// or the automatic post-send rotation (`ChatService.sendPaymentInternal` calling
    /// `setActiveSpendingAddress` with the fresh change index). Open screens that render an
    /// `isCurrent` star or gate actions on "not the primary" reload on it so the old primary
    /// row becomes hideable right away.
    static let spendingPrimaryChanged = Notification.Name("spendingPrimaryChanged")
}
