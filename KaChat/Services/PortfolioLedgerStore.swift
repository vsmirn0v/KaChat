import Foundation

/// Per-wallet persistence for the Portfolio investment ledger. Each wallet gets its own
/// ledger, keyed by wallet address, mirroring ColdStorageManager/ContactsManager's
/// per-wallet UserDefaults key pattern.
enum PortfolioLedgerStore {
    private struct Snapshot: Codable {
        let version: Int
        let transactions: [PortfolioTransaction]
    }

    private static let currentVersion = 1
    private static let legacyKey = "kachat_portfolio_transactions"
    private static let keyPrefix = "kachat_portfolio_transactions_"

    private static func key(forNormalizedWalletAddress walletAddress: String) -> String {
        let sanitized = walletAddress.replacingOccurrences(of: ":", with: "_")
        return "\(keyPrefix)\(sanitized)"
    }

    static func load(walletAddress: String?, userDefaults: UserDefaults = .standard) -> [PortfolioTransaction] {
        guard let walletAddress else { return [] }
        let key = key(forNormalizedWalletAddress: walletAddress)
        if let data = userDefaults.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.version == currentVersion {
            return snapshot.transactions
        }
        // One-time migration: this key predates per-wallet scoping. Claim it for the
        // first wallet that loads after the update, then remove it so no other wallet
        // can also claim it.
        if let legacyData = userDefaults.data(forKey: legacyKey),
           let legacySnapshot = try? JSONDecoder().decode(Snapshot.self, from: legacyData),
           legacySnapshot.version == currentVersion {
            userDefaults.removeObject(forKey: legacyKey)
            userDefaults.set(legacyData, forKey: key)
            return legacySnapshot.transactions
        }
        return []
    }

    static func save(_ transactions: [PortfolioTransaction], walletAddress: String?, userDefaults: UserDefaults = .standard) {
        guard let walletAddress else { return }
        let key = key(forNormalizedWalletAddress: walletAddress)
        let snapshot = Snapshot(version: currentVersion, transactions: transactions)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: key)
    }
}
