import Foundation

/// Global (not wallet-scoped) persistence for the Portfolio investment ledger, matching
/// Android's design: portfolio entries are manual and independent of any particular
/// wallet/address, so there's a single ledger regardless of which wallet is active.
enum PortfolioLedgerStore {
    private struct Snapshot: Codable {
        let version: Int
        let transactions: [PortfolioTransaction]
    }

    private static let currentVersion = 1
    private static let key = "kachat_portfolio_transactions"

    static func load(userDefaults: UserDefaults = .standard) -> [PortfolioTransaction] {
        guard let data = userDefaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == currentVersion else {
            return []
        }
        return snapshot.transactions
    }

    static func save(_ transactions: [PortfolioTransaction], userDefaults: UserDefaults = .standard) {
        let snapshot = Snapshot(version: currentVersion, transactions: transactions)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: key)
    }
}
