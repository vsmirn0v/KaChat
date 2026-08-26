import Foundation

/// Fetches a Kaspa address's on-chain transaction history and converts it into Portfolio ledger
/// rows — every received transaction becomes a buy, every sent transaction becomes a sell, priced
/// at that day's historical KAS price. Deliberately no filtering of "real trades" vs ordinary
/// KaChat payments/protocol overhead (see `PortfolioTransaction`'s doc comment on why manual entry
/// was originally chosen) — this is an explicit, simpler alternative the user opted into. Every
/// matching transaction is imported even if its day's price couldn't be fetched — it lands with
/// `fiatValue: 0` and a note flagging it, and `PortfolioViewModel.startPriceBackfillIfNeeded()`
/// keeps retrying those prices in the background until they land.
enum PortfolioAddressImporter {
    /// Marks a `PortfolioTransaction.notes` value as "auto-imported but not yet priced" —
    /// recognized via `isPricePending` by `PortfolioTransactionsView`'s row (warning icon) and by
    /// the background price backfill, which fills the price in and clears the note.
    static let priceUnavailableNote = "Price loading, will fill in automatically"
    /// Sentinel written by builds before the background backfill existed. Still recognized so
    /// rows imported by an older version keep their warning icon and get backfilled too.
    static let legacyPriceUnavailableNote = "Price unavailable — set manually"

    /// True when `notes` marks a row whose price is still pending (either sentinel generation).
    static func isPricePending(_ notes: String?) -> Bool {
        notes == priceUnavailableNote || notes == legacyPriceUnavailableNote
    }

    struct ImportResult {
        let imported: [PortfolioTransaction]
        /// How many of `imported` couldn't be priced synchronously — still imported with
        /// `fiatValue: 0` rather than dropped, and picked up by the background price backfill
        /// (the user can also fill any price in manually via the normal edit sheet).
        let missingPriceCount: Int
        /// False when the REST history pagination gave up partway (a page kept failing after
        /// retries) — everything fetched up to that point is still imported, and re-adding the
        /// same address later resumes via the existing txId dedupe.
        let historyComplete: Bool
    }

    enum ImportError: LocalizedError {
        case invalidAddress
        case noTransactions
        case noActivePortfolio
        case historyFetchFailed

        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "That doesn't look like a valid Kaspa address."
            case .noTransactions: return "No new transactions found for this address."
            case .noActivePortfolio: return "No active portfolio to import into."
            case .historyFetchFailed: return "Couldn't fetch this address's transactions. Check your connection and try again."
            }
        }
    }

    /// Caps the REST fetch (and, indirectly, the number of unique days a single import can need
    /// prices for).
    private static let maxTransactions = 500
    /// Spacing between per-day historical-price fallback requests — CoinGecko's free public API
    /// rate-limits aggressively; only the backfill's fallback path pays this, since the main
    /// pricing path is now a single batched range call.
    static let priceRequestSpacingNanoseconds: UInt64 = 1_200_000_000
    /// Backoff schedule for a failing history page: retry the SAME offset with growing pauses
    /// before declaring the fetch incomplete, instead of aborting the whole import on the first
    /// hiccup like `fetchFullTransactionsPaginated` does.
    private static let pageRetryDelaysSeconds: [Double] = [0, 1, 3, 8]

    // MARK: - UTC day bucketing

    /// CoinGecko's history endpoints are UTC-day granularity, so every day key in the pricing
    /// pipeline (candidate rows, cache keys, backfill matching) is a UTC start-of-day.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    static func utcDay(for date: Date) -> Date {
        utcCalendar.startOfDay(for: date)
    }

    // MARK: - Persistent daily price cache

    /// A past day's historical price never changes, so resolved days are cached forever (per
    /// currency) — re-imports and backfill passes never re-pay a network call for a day any
    /// earlier import already priced. Same philosophy as PortfolioViewModel's persisted range
    /// caches, just keyed per day instead of per chart range.
    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func dayCacheDefaultsKey(_ currency: AppCurrency) -> String {
        "kachat_daily_price_cache_\(currency.rawValue)"
    }

    private static func cachedDailyPrices(for days: [Date], currency: AppCurrency) -> [Date: Double] {
        let stored = UserDefaults.standard.dictionary(forKey: dayCacheDefaultsKey(currency)) as? [String: Double] ?? [:]
        var result: [Date: Double] = [:]
        for day in days {
            if let price = stored[dayKeyFormatter.string(from: day)] {
                result[day] = price
            }
        }
        return result
    }

    private static func storeDailyPrices(_ prices: [Date: Double], currency: AppCurrency) {
        guard !prices.isEmpty else { return }
        let key = dayCacheDefaultsKey(currency)
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let today = utcDay(for: Date())
        // Today's "price" is still moving — never freeze it into the forever-cache.
        for (day, price) in prices where day < today {
            stored[dayKeyFormatter.string(from: day)] = price
        }
        UserDefaults.standard.set(stored, forKey: key)
    }

    // MARK: - Batched day pricing

    /// Resolves historical prices for a set of UTC days: persistent cache first, then ONE
    /// `market_chart` range call (through `CoinGeckoService.getPriceHistory`, which carries the
    /// Retry-After-honoring 429/5xx retry) covering every still-unpriced day within CoinGecko's
    /// keyless 365-day window — replacing the old one-request-per-day burst that tripped the
    /// rate limit on any import with more than a handful of trading days. Days it can't cover
    /// (older than a year, or the range call failed) are left unresolved for the per-day
    /// fallback / background backfill.
    static func resolveDailyPrices(for days: [Date], currency: AppCurrency) async -> [Date: Double] {
        let unique = Array(Set(days)).sorted()
        guard !unique.isEmpty else { return [:] }

        var resolved = cachedDailyPrices(for: unique, currency: currency)
        let missing = unique.filter { resolved[$0] == nil }
        guard let oldestMissing = missing.first else { return resolved }

        let daysBack = max(1, Int(ceil(Date().timeIntervalSince(oldestMissing) / 86_400)) + 1)
        let span = min(daysBack, 365) // keyless tier serves at most the last 365 days
        let points = await CoinGeckoService.shared.getPriceHistory(days: span, currency: currency)
        guard !points.isEmpty else { return resolved }

        // Last sample per UTC day = that day's close (daily-granularity ranges have exactly one
        // sample per day; shorter ranges arrive hourly and collapse the same way).
        var byDay: [Date: Double] = [:]
        for point in points {
            byDay[utcDay(for: point.timestamp)] = point.value
        }
        // Cache the WHOLE fetched range, not just the days asked for — future imports and
        // backfill passes for other addresses then price those days without any network call.
        storeDailyPrices(byDay, currency: currency)
        for day in missing {
            if let price = byDay[day] {
                resolved[day] = price
            }
        }
        return resolved
    }

    /// Per-day fallback through `/coins/kaspa/history` for days the batched range couldn't
    /// cover. Cache-first; one paced retry on failure (plus the 429 Retry-After retry inside
    /// `getHistoricalPrice` itself); successful lookups join the forever-cache.
    static func resolveDailyPriceSingle(day: Date, currency: AppCurrency) async -> Double? {
        if let cached = cachedDailyPrices(for: [day], currency: currency)[day] {
            return cached
        }
        var price = await CoinGeckoService.shared.getHistoricalPrice(date: day, currency: currency)
        if price == nil {
            try? await Task.sleep(nanoseconds: priceRequestSpacingNanoseconds)
            price = await CoinGeckoService.shared.getHistoricalPrice(date: day, currency: currency)
        }
        if let price {
            storeDailyPrices([day: price], currency: currency)
        }
        return price
    }

    // MARK: - Resumable history fetch

    private struct HistoryFetchResult {
        let transactions: [KaspaFullTransactionResponse]
        /// False when a page kept failing after every retry — `transactions` still holds
        /// everything fetched before the failure.
        let complete: Bool
    }

    /// Same endpoint and paging as `ChatService.fetchFullTransactionsPaginated`, but a failing
    /// page retries the SAME offset on a growing backoff instead of aborting — and when the
    /// retries are exhausted, whatever was fetched so far is returned (marked incomplete) so the
    /// import can still save the rows it has.
    private static func fetchTransactionsResumable(
        address: String,
        pageSize: Int,
        maxTransactions: Int,
        onProgress: @escaping (String) -> Void
    ) async -> HistoryFetchResult {
        var all: [KaspaFullTransactionResponse] = []
        var offset = 0

        while all.count < maxTransactions {
            guard let url = await ChatService.shared.kaspaRestURL(
                path: "/addresses/\(address)/full-transactions",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)"),
                    URLQueryItem(name: "resolve_previous_outpoints", value: "light")
                ]
            ) else {
                return HistoryFetchResult(transactions: all, complete: false)
            }

            var page: [KaspaFullTransactionResponse]?
            for (attempt, delaySeconds) in pageRetryDelaysSeconds.enumerated() {
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
                if Task.isCancelled {
                    return HistoryFetchResult(transactions: all, complete: false)
                }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        AppLog.log("[PortfolioImport] History page at offset %d returned non-2xx (attempt %d)", offset, attempt + 1)
                        continue
                    }
                    page = try JSONDecoder().decode([KaspaFullTransactionResponse].self, from: data)
                    break
                } catch {
                    AppLog.log("[PortfolioImport] History page at offset %d failed (attempt %d): %@", offset, attempt + 1, error.localizedDescription)
                }
            }

            guard let page else {
                AppLog.log("[PortfolioImport] Giving up on offset %d after %d attempts, importing the %d transactions fetched so far", offset, pageRetryDelaysSeconds.count, all.count)
                return HistoryFetchResult(transactions: all, complete: false)
            }
            if page.isEmpty { break }
            all.append(contentsOf: page)
            onProgress("Fetching transactions… (\(all.count))")
            if page.count < pageSize { break }
            offset += pageSize
        }

        return HistoryFetchResult(transactions: all, complete: true)
    }

    // MARK: - Import

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
        let history = await fetchTransactionsResumable(
            address: trimmed,
            pageSize: 50,
            maxTransactions: maxTransactions,
            onProgress: onProgress
        )

        struct Candidate {
            let txId: String
            let isOutgoing: Bool
            let amountSompi: UInt64
            let timestamp: Date
            let day: Date
        }

        var candidates: [Candidate] = []
        for tx in history.transactions {
            // No usable block time means we can't date (and therefore can't price) the row —
            // and it's already excluded from re-import if its txId is in existingTxIds.
            guard !existingTxIds.contains(tx.transactionId),
                  let blockTime = tx.blockTime,
                  let direction = tx.direction(for: trimmed) else { continue }
            let timestamp = Date(timeIntervalSince1970: Double(blockTime) / 1000)
            candidates.append(
                Candidate(txId: tx.transactionId, isOutgoing: direction.isOutgoing, amountSompi: direction.amountSompi, timestamp: timestamp, day: utcDay(for: timestamp))
            )
        }

        guard !candidates.isEmpty else {
            return .failure(history.complete ? .noTransactions : .historyFetchFailed)
        }

        // One BATCHED pricing pass: persistent day cache + a single market_chart range call
        // (see resolveDailyPrices) — not the old paced per-day burst. Anything still unpriced
        // is imported anyway and handed to the background backfill.
        onProgress("Fetching prices…")
        let uniqueDays = Array(Set(candidates.map { $0.day }))
        let priceByDay = await resolveDailyPrices(for: uniqueDays, currency: currency)

        // Every candidate is imported regardless of whether its day's price could be fetched —
        // a row with no price is still real ledger data (type, amount, date, source tx) that
        // shows up immediately; its price fills in as the backfill lands it.
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

        return .success(ImportResult(imported: imported, missingPriceCount: missingPriceCount, historyComplete: history.complete))
    }
}
