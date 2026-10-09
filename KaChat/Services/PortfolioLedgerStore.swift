import Foundation

/// Per-wallet persistence for the Portfolio investment ledger and the wallet's list of
/// up-to-5 named portfolios. Each wallet gets its own ledger (all its portfolios' transactions
/// together, self-describing their `portfolioId`) and its own portfolio list, keyed by wallet
/// address, mirroring ColdStorageManager/ContactsManager's per-wallet UserDefaults key pattern.
enum PortfolioLedgerStore {
    private struct Snapshot: Codable {
        let version: Int
        let transactions: [PortfolioTransaction]
    }

    private static let currentVersion = 2
    private static let legacyKey = "kachat_portfolio_transactions"
    private static let keyPrefix = "kachat_portfolio_transactions_"
    private static let portfoliosKeyPrefix = "kachat_portfolios_"
    private static let activePortfolioKeyPrefix = "kachat_active_portfolio_"
    private static let feesKeyPrefix = "kachat_portfolio_fees_"

    private static func sanitize(_ walletAddress: String) -> String {
        walletAddress.replacingOccurrences(of: ":", with: "_")
    }

    private static func key(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(keyPrefix)\(sanitize(walletAddress))"
    }

    private static func portfoliosKey(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(portfoliosKeyPrefix)\(sanitize(walletAddress))"
    }

    private static func activePortfolioKey(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(activePortfolioKeyPrefix)\(sanitize(walletAddress))"
    }

    // MARK: - Transactions

    /// `defaultPortfolioId` is used only to back-fill rows persisted before multi-portfolio
    /// support existed (both the legacy global key and version-1 per-wallet snapshots) — callers
    /// should resolve/create the wallet's default portfolio (see `PortfolioManager`) before
    /// calling this, so every pre-existing transaction lands somewhere real rather than under a
    /// throwaway id.
    static func load(walletAddress: String?, defaultPortfolioId: UUID, userDefaults: UserDefaults = .standard) -> [PortfolioTransaction] {
        guard let walletAddress else { return [] }
        let key = key(forNormalizedWalletAddress: walletAddress)
        if let data = userDefaults.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            if snapshot.version == currentVersion {
                return snapshot.transactions
            }
            // v1 -> v2: back-fill every pre-portfolio-scoping row into the caller's default
            // portfolio, then persist at the new version so this only runs once.
            let migrated = backfill(snapshot.transactions, defaultPortfolioId: defaultPortfolioId)
            save(migrated, walletAddress: walletAddress, userDefaults: userDefaults)
            return migrated
        }
        // One-time migration: this key predates per-wallet scoping. Claim it for the
        // first wallet that loads after the update, then remove it so no other wallet
        // can also claim it.
        if let legacyData = userDefaults.data(forKey: legacyKey),
           let legacySnapshot = try? JSONDecoder().decode(Snapshot.self, from: legacyData) {
            userDefaults.removeObject(forKey: legacyKey)
            let migrated = backfill(legacySnapshot.transactions, defaultPortfolioId: defaultPortfolioId)
            save(migrated, walletAddress: walletAddress, userDefaults: userDefaults)
            return migrated
        }
        return []
    }

    private static func backfill(_ transactions: [PortfolioTransaction], defaultPortfolioId: UUID) -> [PortfolioTransaction] {
        transactions.map { tx in
            var tx = tx
            tx.portfolioId = defaultPortfolioId
            return tx
        }
    }

    static func save(_ transactions: [PortfolioTransaction], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = key(forNormalizedWalletAddress: walletAddress)
        let snapshot = Snapshot(version: currentVersion, transactions: transactions)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: key)
    }

    /// Removes every transaction belonging to `portfolioId`, used when that portfolio is deleted.
    static func deleteTransactions(portfolioId: UUID, walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = key(forNormalizedWalletAddress: walletAddress)
        guard let data = userDefaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let remaining = snapshot.transactions.filter { $0.portfolioId != portfolioId }
        save(remaining, walletAddress: walletAddress, userDefaults: userDefaults)
    }

    // MARK: - Fees

    private static func feesKey(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(feesKeyPrefix)\(sanitize(walletAddress))"
    }

    static func loadFees(walletAddress: String?, userDefaults: UserDefaults = .standard) -> [PortfolioFeeRecord] {
        guard let walletAddress,
              let data = userDefaults.data(forKey: feesKey(forNormalizedWalletAddress: walletAddress)),
              let fees = try? JSONDecoder().decode([PortfolioFeeRecord].self, from: data) else { return [] }
        return fees
    }

    static func saveFees(_ fees: [PortfolioFeeRecord], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress, let data = try? JSONEncoder().encode(fees) else { return }
        userDefaults.set(data, forKey: feesKey(forNormalizedWalletAddress: walletAddress))
    }

    // MARK: - Portfolio list

    static func loadPortfolios(walletAddress: String?, userDefaults: UserDefaults = .standard) -> [Portfolio] {
        guard let walletAddress else { return [] }
        let key = portfoliosKey(forNormalizedWalletAddress: walletAddress)
        guard let data = userDefaults.data(forKey: key),
              let portfolios = try? JSONDecoder().decode([Portfolio].self, from: data) else {
            return []
        }
        return portfolios
    }

    static func savePortfolios(_ portfolios: [Portfolio], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = portfoliosKey(forNormalizedWalletAddress: walletAddress)
        guard let data = try? JSONEncoder().encode(portfolios) else { return }
        userDefaults.set(data, forKey: key)
    }

    static func loadActivePortfolioId(walletAddress: String?, userDefaults: UserDefaults = .standard) -> UUID? {
        guard let walletAddress else { return nil }
        let key = activePortfolioKey(forNormalizedWalletAddress: walletAddress)
        guard let raw = userDefaults.string(forKey: key) else { return nil }
        return UUID(uuidString: raw)
    }

    static func saveActivePortfolioId(_ id: UUID?, walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = activePortfolioKey(forNormalizedWalletAddress: walletAddress)
        if let id {
            userDefaults.set(id.uuidString, forKey: key)
        } else {
            userDefaults.removeObject(forKey: key)
        }
    }

    /// Wipes this wallet's entire portfolio ledger and portfolio list — used when a saved
    /// account is removed from the device entirely. Mirrors ColdStorageManager.clearAllLocalData.
    static func clearAllLocalData(walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        userDefaults.removeObject(forKey: key(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: portfoliosKey(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: activePortfolioKey(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: feesKey(forNormalizedWalletAddress: walletAddress))
        userDefaults.removeObject(forKey: tombstonesKey(forNormalizedWalletAddress: walletAddress))
    }

    // MARK: - Nextcloud sync (NEXTCLOUD_SYNC.md section 5, Portfolios)

    private static let tombstonesKeyPrefix = "kachat_portfolio_tombstones_"

    private static func tombstonesKey(forNormalizedWalletAddress walletAddress: String) -> String {
        "\(tombstonesKeyPrefix)\(sanitize(walletAddress))"
    }

    static func loadTombstones(walletAddress: String?, userDefaults: UserDefaults = .standard) -> [PortfolioTombstone] {
        guard let walletAddress,
              let data = userDefaults.data(forKey: tombstonesKey(forNormalizedWalletAddress: walletAddress)),
              let decoded = try? JSONDecoder().decode([PortfolioTombstone].self, from: data) else { return [] }
        return decoded
    }

    static func saveTombstones(_ tombstones: [PortfolioTombstone], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress, let data = try? JSONEncoder().encode(tombstones) else { return }
        userDefaults.set(data, forKey: tombstonesKey(forNormalizedWalletAddress: walletAddress))
    }

    /// Adds deletions to this wallet's tombstones (the newest per item kept).
    static func recordDeletions(_ new: [PortfolioTombstone], walletAddress: String?) {
        guard !new.isEmpty else { return }
        saveTombstones(PortfolioSync.mergeTombstones([loadTombstones(walletAddress: walletAddress), new]), walletAddress: walletAddress)
    }

    /// `current` as it will be saved: every item new since `previous`, or changed in anything
    /// but its stamp, stamped `now`; and the ids `previous` had that `current` doesn't (deleted).
    static func stamped<T: Identifiable & Equatable>(
        previous: [T], current: [T], now: Date,
        stamp: (inout T, Date?) -> Void
    ) -> (items: [T], removed: [T.ID]) where T.ID: Hashable {
        func unstamped(_ item: T) -> T { var copy = item; stamp(&copy, nil); return copy }
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = current.map { item -> T in
            if let old = before[item.id], unstamped(old) == unstamped(item) { return item }
            var changed = item
            stamp(&changed, now)
            return changed
        }
        let kept = Set(current.map(\.id))
        return (items, previous.map(\.id).filter { !kept.contains($0) })
    }
}

/// One wallet's portfolios as Nextcloud Automatic Sync carries them, and how two copies merge.
/// Pure: the archive merge and the restore both use it. Per item the newest `updatedAt` wins,
/// unless a tombstone at or after it deletes it; a transaction or fee lives only while its
/// portfolio does.
struct PortfolioSync: Equatable {
    var portfolios: [Portfolio] = []
    var transactions: [PortfolioTransaction] = []
    var fees: [PortfolioFeeRecord] = []
    var tombstones: [PortfolioTombstone] = []

    /// A wallet's untouched seed - "Portfolio 1", never edited, holding nothing. Every install
    /// creates its own (each with its own id), so seeds are never synced: a device restoring the
    /// real list drops its seed instead of showing two "Portfolio 1"s.
    static func isPristineSeed(_ p: Portfolio, transactions: [PortfolioTransaction], fees: [PortfolioFeeRecord]) -> Bool {
        p.updatedAt == nil && p.name == "Portfolio 1"
            && !transactions.contains { $0.portfolioId == p.id } && !fees.contains { $0.portfolioId == p.id }
    }

    /// What this device uploads: everything but a pristine seed.
    func forArchive() -> PortfolioSync {
        var copy = self
        copy.portfolios = portfolios.filter { !Self.isPristineSeed($0, transactions: transactions, fees: fees) }
        return copy
    }

    var isEmpty: Bool { portfolios.isEmpty && transactions.isEmpty && fees.isEmpty && tombstones.isEmpty }

    static func mergeTombstones(_ sides: [[PortfolioTombstone]]) -> [PortfolioTombstone] {
        var newest: [String: PortfolioTombstone] = [:]
        for t in sides.joined() {
            let key = "\(t.kind.rawValue):\(t.id)"
            if let have = newest[key], have.deletedAt >= t.deletedAt { continue }
            newest[key] = t
        }
        return newest.values.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }

    /// Folds what two devices each made on their own before sync existed (IOS-073): portfolios
    /// with the same name and no `updatedAt` become one (the oldest id stays), their rows and
    /// fees move with them, and a row whose `(portfolio, sourceTxId)` is already there - the same
    /// imported transaction - is dropped (the newest copy stays).
    static func foldEquivalents(_ sides: [PortfolioSync]) -> [PortfolioSync] {
        var keep: [String: Portfolio] = [:]
        for p in sides.flatMap(\.portfolios) where p.updatedAt == nil {
            if let have = keep[p.name], have.createdAt <= p.createdAt { continue }
            keep[p.name] = p
        }
        var remap: [UUID: UUID] = [:]
        for p in sides.flatMap(\.portfolios) where p.updatedAt == nil {
            if let canonical = keep[p.name], canonical.id != p.id { remap[p.id] = canonical.id }
        }
        // per imported transaction, the copy that stays: the newest edit, ties by the smaller id
        // (the same choice on every device, so the copies don't trade places back and forth)
        var winner: [String: PortfolioTransaction] = [:]
        for t in sides.flatMap(\.transactions) {
            guard let source = t.sourceTxId, !source.isEmpty else { continue }
            let key = "\((remap[t.portfolioId] ?? t.portfolioId).uuidString):\(source)"
            if let have = winner[key] {
                let a = have.updatedAt ?? .distantPast, b = t.updatedAt ?? .distantPast
                if b > a || (b == a && t.id < have.id) { winner[key] = t }
            } else {
                winner[key] = t
            }
        }
        return sides.map { side in
            var copy = side
            copy.portfolios = side.portfolios.filter { remap[$0.id] == nil }
            copy.transactions = side.transactions.compactMap { t in
                var moved = t
                moved.portfolioId = remap[t.portfolioId] ?? t.portfolioId
                guard let source = moved.sourceTxId, !source.isEmpty else { return moved }
                let key = "\(moved.portfolioId.uuidString):\(source)"
                return winner[key]?.id == t.id ? moved : nil
            }
            copy.fees = side.fees.map { f in
                guard let target = remap[f.portfolioId] else { return f }
                return PortfolioFeeRecord(txId: f.txId, portfolioId: target, sourceAddress: f.sourceAddress,
                                          amountSompi: f.amountSompi, timestamp: f.timestamp, fiatValue: f.fiatValue)
            }
            return copy
        }
    }

    static func merge(_ sides: [PortfolioSync]) -> PortfolioSync {
        let sides = foldEquivalents(sides)
        let tombstones = mergeTombstones(sides.map(\.tombstones))
        func deletedAt(_ kind: PortfolioTombstone.Kind, _ id: String) -> Date? {
            tombstones.first { $0.kind == kind && $0.id == id }?.deletedAt
        }
        // portfolios: newest stamp per id, unless deleted at or after it
        var portfolios: [UUID: Portfolio] = [:]
        for p in sides.flatMap(\.portfolios) {
            let stamp = p.updatedAt ?? p.createdAt
            if let have = portfolios[p.id], (have.updatedAt ?? have.createdAt) >= stamp { continue }
            portfolios[p.id] = p
        }
        portfolios = portfolios.filter { _, p in
            guard let gone = deletedAt(.portfolio, p.id.uuidString) else { return true }
            return gone < (p.updatedAt ?? p.createdAt)
        }
        var transactions: [String: PortfolioTransaction] = [:]
        for t in sides.flatMap(\.transactions) {
            let stamp = t.updatedAt ?? .distantPast
            if let have = transactions[t.id], (have.updatedAt ?? .distantPast) >= stamp { continue }
            transactions[t.id] = t
        }
        transactions = transactions.filter { _, t in
            guard portfolios[t.portfolioId] != nil else { return false }
            guard let gone = deletedAt(.transaction, t.id) else { return true }
            return gone < (t.updatedAt ?? .distantPast)
        }
        var fees: [String: PortfolioFeeRecord] = [:]
        for f in sides.flatMap(\.fees) where portfolios[f.portfolioId] != nil {
            // a priced copy beats an unpriced one; otherwise either (they are the same fee)
            if let have = fees[f.id], have.fiatValue != nil || f.fiatValue == nil { continue }
            fees[f.id] = f
        }
        let txList = Array(transactions.values)
        let feeList = Array(fees.values)
        var list = Array(portfolios.values)
        // a seed only while nothing else is there
        if list.contains(where: { !isPristineSeed($0, transactions: txList, fees: feeList) }) {
            list.removeAll { isPristineSeed($0, transactions: txList, fees: feeList) }
        }
        list.sort { $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder }
        for i in list.indices { list[i].sortOrder = i }
        return PortfolioSync(
            portfolios: list,
            transactions: txList.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp },
            fees: feeList.sorted { $0.id < $1.id },
            tombstones: tombstones
        )
    }
}
