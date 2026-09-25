import Foundation

enum PortfolioTransactionType: String, Codable, CaseIterable {
    case buy
    case sell
}

/// A manually-entered investment ledger row. Deliberately not derived from on-chain address
/// activity — a wallet's tx history can't distinguish a real "buy" from an ordinary incoming
/// KaChat payment or protocol self-stash overhead. Wallet-scoped (see `PortfolioLedgerStore`) and,
/// within a wallet, further scoped to one of up to 5 user-created `Portfolio` ledgers via
/// `portfolioId`.
struct PortfolioTransaction: Identifiable, Codable, Equatable {
    let id: String
    var type: PortfolioTransactionType
    var amountSompi: Int64
    var fiatValue: Double
    var timestamp: Date
    var notes: String?
    var portfolioId: UUID
    /// The Kaspa address this row was auto-imported from via "Add Kaspa Address" — nil for manual
    /// or CSV-imported rows. Paired with `sourceTxId` purely to dedupe re-imports of the same
    /// address (re-entering it only adds transactions not already present for that address).
    var sourceAddress: String?
    /// The on-chain transaction id this row was derived from — nil for manual/CSV rows.
    var sourceTxId: String?

    var amountKas: Double { Double(amountSompi) / 100_000_000.0 }

    init(
        id: String,
        type: PortfolioTransactionType,
        amountSompi: Int64,
        fiatValue: Double,
        timestamp: Date,
        notes: String?,
        portfolioId: UUID,
        sourceAddress: String? = nil,
        sourceTxId: String? = nil
    ) {
        self.id = id
        self.type = type
        self.amountSompi = amountSompi
        self.fiatValue = fiatValue
        self.timestamp = timestamp
        self.notes = notes
        self.portfolioId = portfolioId
        self.sourceAddress = sourceAddress
        self.sourceTxId = sourceTxId
    }

    /// Rows persisted before multi-portfolio support won't have `portfolioId` in their JSON.
    /// Decode a placeholder here rather than failing the whole snapshot — `PortfolioLedgerStore`'s
    /// v1->v2 migration immediately overwrites it with the wallet's real default portfolio id.
    /// `sourceAddress`/`sourceTxId` are genuinely optional (not a migration placeholder) and
    /// simply decode to nil for any row persisted before "Add Kaspa Address" existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(PortfolioTransactionType.self, forKey: .type)
        amountSompi = try container.decode(Int64.self, forKey: .amountSompi)
        fiatValue = try container.decode(Double.self, forKey: .fiatValue)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        portfolioId = try container.decodeIfPresent(UUID.self, forKey: .portfolioId) ?? UUID()
        sourceAddress = try container.decodeIfPresent(String.self, forKey: .sourceAddress)
        sourceTxId = try container.decodeIfPresent(String.self, forKey: .sourceTxId)
    }
}

/// One of up to 5 named, independent buy/sell ledgers a wallet can have — e.g. "Investing",
/// "Long Term" — all still tracking the same on-chain wallet/address. Only the manually-entered
/// transaction ledger and its derived P&L are separated per portfolio; nothing about the wallet
/// itself (balance, address, keys) changes based on which portfolio is active.
/// Reads a number the way a person pasted or typed it: "1,234.56" (grouping commas),
/// "1.234,56" or "1,5" (decimal-comma locales), "$ 9.60", " 12 " - all the shapes a copied
/// amount arrives in. `Double("1,234.56")` is nil, which made a pasted amount silently refuse
/// to add.
enum PortfolioNumber {
    static func parse(_ text: String) -> Double? {
        var cleaned = text.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty else { return nil }
        let commas = cleaned.filter { $0 == "," }.count
        let dots = cleaned.filter { $0 == "." }.count
        if commas > 0 && dots > 0 {
            // Both present: whichever comes last is the decimal mark, the other is grouping.
            let lastComma = cleaned.lastIndex(of: ",")!
            let lastDot = cleaned.lastIndex(of: ".")!
            if lastComma > lastDot {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if commas > 0 {
            // Commas only: one comma followed by anything but exactly three digits is a
            // decimal comma ("1,5"); otherwise they are thousands separators ("1,234,567").
            let parts = cleaned.split(separator: ",", omittingEmptySubsequences: false)
            if commas == 1, parts.count == 2, parts[1].count != 3 {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if dots > 1 {
            // "1.234.567" - dots as grouping.
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
        }
        return Double(cleaned)
    }
}

struct Portfolio: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var sortOrder: Int
    let createdAt: Date
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
struct PricePoint: Equatable, Codable {
    let timestamp: Date
    let value: Double
}

/// What a chart's big number flips to on a tap - picked under the gear on the chart screens,
/// one at a time or none. Bitcoin is a currency CoinGecko quotes KAS in directly; the others
/// are USD-priced assets KAS is divided by (see `MarketPairService`).
enum ChartPair: String, CaseIterable, Codable {
    case bitcoin
    case voo
    case gold
    case silver

    var code: String {
        switch self {
        case .bitcoin: return "BTC"
        case .voo: return "VOO"
        case .gold: return "XAU"
        case .silver: return "XAG"
        }
    }

    var title: String {
        switch self {
        case .bitcoin: return "Bitcoin"
        case .voo: return "VOO"
        case .gold: return "Gold"
        case .silver: return "Silver"
        }
    }

    var subtitle: String {
        switch self {
        case .bitcoin: return "Kaspa priced in bitcoin"
        case .voo: return "Shares of Vanguard's S&P 500 ETF"
        case .gold: return "Troy ounces of gold"
        case .silver: return "Troy ounces of silver"
        }
    }

    var yahooSymbol: String? {
        switch self {
        case .bitcoin: return nil
        case .voo: return "VOO"
        case .gold: return "GC=F"
        case .silver: return "SI=F"
        }
    }

    /// Written after an amount: "0.0000203 oz".
    var unitSuffix: String {
        switch self {
        case .bitcoin: return ""
        case .voo: return " VOO"
        case .gold, .silver: return " oz"
        }
    }

    private static let storageKey = "kachat_chart_pair"

    /// The pick on disk. Absent means bitcoin - the default; an empty string means none.
    static var stored: ChartPair? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .bitcoin }
            return ChartPair(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue?.rawValue ?? "", forKey: storageKey) }
    }
}

/// What a chart is counting in: the app currency (or bitcoin / US dollars when flipped to
/// the bitcoin pair), or a pair's own unit.
enum ChartUnit: Equatable {
    case currency(AppCurrency)
    case pair(ChartPair)

    var code: String {
        switch self {
        case .currency(let currency): return currency.code
        case .pair(let pair): return pair.code
        }
    }
}
