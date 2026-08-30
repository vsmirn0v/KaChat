import Foundation

/// Manages the current wallet's list of up to 5 named `Portfolio` ledgers and which one is
/// active. A portfolio is purely a bookkeeping split of the manually-entered buy/sell ledger —
/// it never changes the wallet's real address, keys, or on-chain balance (see `Portfolio` doc
/// comment). Mirrors ColdStorageManager's per-wallet singleton/key pattern, plus a cap and an
/// "active" selector that ColdStorageManager doesn't need.
@MainActor
final class PortfolioManager: ObservableObject {
    static let shared = PortfolioManager()
    static let maxPortfolios = 5

    @Published private(set) var portfolios: [Portfolio] = []
    @Published private(set) var activePortfolioId: UUID?

    private var activeWalletAddress: String?

    private init() {}

    /// Portfolios are scoped per wallet, same as the ledger itself. Ensures at least one
    /// portfolio ("Portfolio 1") always exists for a wallet that has one, seeding it on first
    /// load — this is also the default portfolio pre-existing transactions get back-filled into
    /// (see `PortfolioLedgerStore`'s v1->v2 migration), so it must be resolved *before*
    /// `PortfolioViewModel.shared.setCurrentWallet` runs for the same wallet.
    func setCurrentWallet(_ walletAddress: String?) {
        let normalizedAddress = normalizeWalletAddress(walletAddress)
        guard activeWalletAddress != normalizedAddress else { return }
        activeWalletAddress = normalizedAddress

        guard let normalizedAddress else {
            portfolios = []
            activePortfolioId = nil
            return
        }

        var loaded = PortfolioLedgerStore.loadPortfolios(walletAddress: normalizedAddress)
        if loaded.isEmpty {
            let seeded = Portfolio(id: UUID(), name: "Portfolio 1", sortOrder: 0, createdAt: Date())
            loaded = [seeded]
            PortfolioLedgerStore.savePortfolios(loaded, walletAddress: normalizedAddress)
        }
        // Tie-broken by createdAt: `sortOrder` was never renumbered after a delete, so older
        // installs can hold duplicates (delete the middle of three, add another, and the new one
        // is handed a sortOrder the survivor already has). Swift's sort is not stable, so equal
        // keys alone let two cards swap places between launches.
        portfolios = Self.normalizingSortOrder(loaded.sorted {
            $0.sortOrder == $1.sortOrder ? $0.createdAt < $1.createdAt : $0.sortOrder < $1.sortOrder
        })

        let storedActiveId = PortfolioLedgerStore.loadActivePortfolioId(walletAddress: normalizedAddress)
        activePortfolioId = (storedActiveId.flatMap { id in portfolios.contains { $0.id == id } ? id : nil })
            ?? portfolios.first?.id
    }

    private func normalizeWalletAddress(_ walletAddress: String?) -> String? {
        guard let walletAddress = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !walletAddress.isEmpty else {
            return nil
        }
        return walletAddress.lowercased()
    }

    // MARK: - CRUD

    /// Rewrites `sortOrder` to match array position. Called after every mutation so the stored
    /// order is always 0..<count with no gaps and no duplicates.
    private static func normalizingSortOrder(_ list: [Portfolio]) -> [Portfolio] {
        list.enumerated().map { index, portfolio in
            var updated = portfolio
            updated.sortOrder = index
            return updated
        }
    }

    @discardableResult
    func addPortfolio(name: String) -> Portfolio? {
        guard portfolios.count < Self.maxPortfolios else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Portfolio \(portfolios.count + 1)" : trimmed
        let portfolio = Portfolio(id: UUID(), name: resolved, sortOrder: portfolios.count, createdAt: Date())
        portfolios = Self.normalizingSortOrder(portfolios + [portfolio])
        persist()
        setActivePortfolio(portfolio.id)
        return portfolio
    }

    /// Moves cards to match a drag-and-drop reorder. `orderedIds` must be a permutation of the
    /// current list; anything else is ignored rather than partially applied.
    func reorderPortfolios(_ orderedIds: [UUID]) {
        guard Set(orderedIds) == Set(portfolios.map(\.id)), orderedIds.count == portfolios.count else { return }
        let byId = Dictionary(uniqueKeysWithValues: portfolios.map { ($0.id, $0) })
        portfolios = Self.normalizingSortOrder(orderedIds.compactMap { byId[$0] })
        persist()
    }

    func renamePortfolio(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = portfolios.firstIndex(where: { $0.id == id }) else { return }
        portfolios[idx].name = trimmed
        persist()
    }

    /// Never allows deleting the last remaining portfolio — every wallet must always have at
    /// least one. Also deletes that portfolio's own ledger rows.
    func deletePortfolio(_ id: UUID) {
        guard portfolios.count > 1, portfolios.contains(where: { $0.id == id }) else { return }
        portfolios = Self.normalizingSortOrder(portfolios.filter { $0.id != id })
        persist()
        PortfolioLedgerStore.deleteTransactions(portfolioId: id, walletAddress: activeWalletAddress)
        if activePortfolioId == id {
            setActivePortfolio(portfolios.first?.id)
        }
    }

    func setActivePortfolio(_ id: UUID?) {
        guard id == nil || portfolios.contains(where: { $0.id == id }) else { return }
        activePortfolioId = id
        PortfolioLedgerStore.saveActivePortfolioId(id, walletAddress: activeWalletAddress)
    }

    private func persist() {
        PortfolioLedgerStore.savePortfolios(portfolios, walletAddress: activeWalletAddress)
    }

    /// Permanently deletes this wallet's portfolio list (and, via the ledger store, every
    /// portfolio's transactions), used when a saved account is removed from the device entirely.
    /// Mirrors ColdStorageManager.clearAllLocalData.
    func clearAllLocalData() {
        PortfolioLedgerStore.clearAllLocalData(walletAddress: activeWalletAddress)
        portfolios = []
        activePortfolioId = nil
    }
}
