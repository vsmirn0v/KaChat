import Foundation

/// One side of a swap pair — ChangeNOW addresses currencies by (ticker, network) since some
/// tickers exist on more than one chain. Mirrors Android's SwapModels.kt.
struct SwapCoin: Equatable, Hashable {
    let ticker: String
    let network: String
    let displayName: String

    /// Kaspa itself — always one side of every swap this app can do. Verified against
    /// ChangeNOW's live /v2/exchange/currencies list: ticker "kas", network "kas".
    static let kas = SwapCoin(ticker: "kas", network: "kas", displayName: "Kaspa")

    /// Scoped down to a single pair for now: KAS <-> USDC on Polygon. ChangeNOW's network code
    /// for Polygon is "matic" (not "polygon") — confirmed against the live
    /// /v2/exchange/currencies list.
    static let usdcPolygon = SwapCoin(ticker: "usdc", network: "matic", displayName: "USD Coin (Polygon)")

    static let curated: [SwapCoin] = [usdcPolygon]
}

/// Local record of a swap this device initiated, kept for the "Swap History" list — ChangeNOW is
/// the source of truth for the exchange itself, this just remembers it happened and caches the
/// last status we saw so the list has something to show without a network round trip on open.
struct SwapTransaction: Codable, Identifiable, Equatable {
    let id: String // ChangeNOW exchange id — also the primary key
    let fromTicker: String
    let fromNetwork: String
    let toTicker: String
    let toNetwork: String
    let fromAmount: String
    var toAmount: String
    let payinAddress: String
    let payoutAddress: String
    var status: String
    let createdAt: Date
    /// Set once this device auto-sent KAS to payinAddress, when KAS was the "from" side.
    var kasSendTxId: String?
    /// Set once the KAS leg of this swap has been recorded as a portfolio transaction.
    var addedToPortfolio: Bool = false
}
