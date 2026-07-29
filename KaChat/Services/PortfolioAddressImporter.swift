import Foundation

/// Fetches a Kaspa address's on-chain transaction history and converts it into Portfolio ledger
/// rows — every received transaction becomes a buy, every sent transaction becomes a sell, priced
/// at that day's historical KAS price. Deliberately no filtering of "real trades" vs ordinary
/// KaChat payments/protocol overhead (see `PortfolioTransaction`'s doc comment on why manual entry
/// was originally chosen) — this is an explicit, simpler alternative the user opted into. Every
/// matching transaction is imported even if its day's price couldn't be fetched — it lands with
/// `fiatValue: 0` and a note flagging it, rather than being silently dropped from the ledger.
enum PortfolioAddressImporter {
    /// Marks a `PortfolioTransaction.notes` value as "auto-imported but couldn't be priced" —
    /// checked by `PortfolioTransactionsView`'s transaction row to show a warning icon flagging
    /// rows that still need the user to fill in a price.
    static let priceUnavailableNote = "Price unavailable — set manually"

    struct ImportResult {
        let imported: [PortfolioTransaction]
        /// How many of `imported` couldn't be priced (that day's historical price fetch failed
        /// twice) — still imported with `fiatValue: 0` rather than dropped, so the user can fill
        /// the price in themselves via the normal edit sheet, same as any other ledger row.
        let missingPriceCount: Int
    }

    enum ImportError: LocalizedError {
        case invalidAddress
        case noTransactions
        case noActivePortfolio

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "That doesn't look like a valid Kaspa address."
            case .noTransactions: return "No new transactions found for this address."
            case .noActivePortfolio: return "No active portfolio to import into."
            }
        }
    }

    /// Caps both the REST fetch and (indirectly, since it bounds unique days) the number of
    /// historical-price requests a single import can trigger.
    private static let maxTransactions = 500
    /// Spacing between historical-price requests — CoinGecko's free public API rate-limits
    /// aggressively; this keeps a full import comfortably under typical limits even for an
    /// address with many distinct trading days.
    private static let priceRequestSpacingNanoseconds: UInt64 = 1_200_000_000

    /// - Parameters:
    ///   - existingTxIds: on-chain tx ids already present (for this address) in the active
    ///     portfolio's ledger — re-importing the same address only adds transactions not in here.
    static func importAddress(
        _ address: String,
        portfolioId: UUID,
        existingTxIds: Set<String>,
        currency: AppCurrency,
        onProgress: @escaping (String) -> Void
    ) async -> Result<ImportResult, ImportError> {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KaspaAddress.isValid(trimmed) else {
            return .failure(.invalidAddress)
        }

        onProgress("Fetching transactions…")
        let fullTransactions = await ChatService.shared.fetchFullTransactionsPaginated(
            for: trimmed,
            pageSize: 50,
            maxTransactions: maxTransactions
        )

        struct Candidate {
            let txId: String
            let isOutgoing: Bool
            let amountSompi: UInt64
            let timestamp: Date
            let day: Date
        }

        let calendar = Calendar(identifier: .gregorian)
        var candidates: [Candidate] = []
        for tx in fullTransactions {
            // No usable block time means we can't date (and therefore can't price) the row —
            // and it's already excluded from re-import if its txId is in existingTxIds.
            guard !existingTxIds.contains(tx.transactionId),
                  let blockTime = tx.blockTime,
                  let direction = tx.direction(for: trimmed) else { continue }
            let timestamp = Date(timeIntervalSince1970: Double(blockTime) / 1000)
            let day = calendar.startOfDay(for: timestamp)
            candidates.append(
                Candidate(txId: tx.transactionId, isOutgoing: direction.isOutgoing, amountSompi: direction.amountSompi, timestamp: timestamp, day: day)
            )
        }

        guard !candidates.isEmpty else {
            return .failure(.noTransactions)
        }

        // One historical-price fetch per unique day (not per transaction) — CoinGecko's history
        // endpoint is daily-granularity anyway, and this keeps request count bounded even for a
        // very active address. Paced sequentially to stay under the free tier's rate limit.
        let uniqueDays = Array(Set(candidates.map { $0.day })).sorted()
        var priceByDay: [Date: Double] = [:]
        for (index, day) in uniqueDays.enumerated() {
            onProgress("Pricing \(index + 1)/\(uniqueDays.count) days…")
            var price = await CoinGeckoService.shared.getHistoricalPrice(date: day, currency: currency)
            if price == nil {
                // One retry — a single transient failure shouldn't cost that whole day's rows.
                try? await Task.sleep(nanoseconds: priceRequestSpacingNanoseconds)
                price = await CoinGeckoService.shared.getHistoricalPrice(date: day, currency: currency)
            }
            priceByDay[day] = price
            if index < uniqueDays.count - 1 {
                try? await Task.sleep(nanoseconds: priceRequestSpacingNanoseconds)
            }
        }

        // Every candidate is imported regardless of whether its day's price could be fetched —
        // a row with no price is still real ledger data (type, amount, date, source tx) the user
        // can see and fill the price into themselves, rather than silently disappearing.
        var imported: [PortfolioTransaction] = []
        var missingPriceCount = 0
        for candidate in candidates {
            let price = priceByDay[candidate.day]
            if price == nil { missingPriceCount += 1 }
            let amountKas = Double(candidate.amountSompi) / 100_000_000.0
            imported.append(
                PortfolioTransaction(
                    id: UUID().uuidString,
                    type: candidate.isOutgoing ? .sell : .buy,
                    amountSompi: Int64(candidate.amountSompi),
                    fiatValue: amountKas * (price ?? 0),
                    timestamp: candidate.timestamp,
                    notes: price == nil ? Self.priceUnavailableNote : nil,
                    portfolioId: portfolioId,
                    sourceAddress: trimmed,
                    sourceTxId: candidate.txId
                )
            )
        }

        return .success(ImportResult(imported: imported, missingPriceCount: missingPriceCount))
    }
}
