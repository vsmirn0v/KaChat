import Foundation

enum PortfolioTransactionType: String, Codable, CaseIterable {
    case buy
    case sell
}

/// A manually-entered investment ledger row. Deliberately not derived from on-chain address
/// activity — a wallet's tx history can't distinguish a real "buy" from an ordinary incoming
/// KaChat payment or protocol self-stash overhead. Global (not wallet-scoped), matching Android.
struct PortfolioTransaction: Identifiable, Codable, Equatable {
    let id: String
    var type: PortfolioTransactionType
    var amountSompi: Int64
    var fiatValue: Double
    var timestamp: Date
    var notes: String?

    var amountKas: Double { Double(amountSompi) / 100_000_000.0 }
}

/// All-time P&L, not per-lot realized/unrealized — money still held (valued at the current
/// price) plus money already taken out via sells, minus money originally put in. Correct
/// regardless of buy/sell ordering, no FIFO/average-cost lot tracking needed.
struct PortfolioSummary: Equatable {
    var holdingsKas: Double = 0
    var totalInvested: Double = 0
    var totalProceeds: Double = 0
    var currentValue: Double = 0
    var totalPL: Double = 0
    var totalPLPercent: Double = 0
    /// Lifetime cost basis per KAS across every buy (totalInvested / total KAS ever bought) —
    /// not divided by current holdings, so a sell doesn't change it. Nil with no buys yet.
    var averageBuyPriceUsd: Double?
}

/// A single (timestamp, value) sample, used for both raw KAS/USD price history and the
/// derived portfolio-value-over-time series.
struct PricePoint: Equatable {
    let timestamp: Date
    let value: Double
}
