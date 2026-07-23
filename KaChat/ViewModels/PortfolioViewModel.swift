import Foundation
import SwiftUI

@MainActor
final class PortfolioViewModel: ObservableObject {
    /// Shared instance so writes from outside Portfolio itself (e.g. SwapService's "Add to
    /// Portfolio" after a finished swap) update the same `@Published transactions` array
    /// PortfolioView is observing, instead of writing straight to PortfolioLedgerStore behind
    /// its back - that used to leave Portfolio showing stale data until the app was relaunched
    /// (the view model only ever loaded from disk once, in its own init).
    static let shared = PortfolioViewModel()

    @Published private(set) var transactions: [PortfolioTransaction] = []
    @Published private(set) var currentPriceUsd: Double?
    @Published private(set) var priceHistory: [PricePoint] = []
    @Published private(set) var priceRangeDays: Int = 1
    @Published var scrubbedPricePoint: PricePoint?

    /// Per-range (days -> history) cache. Re-selecting an already-fetched range applies
    /// instantly with no network call, and (more importantly) avoids hitting CoinGecko's
    /// public-API rate limit from repeated taps of the range cycle. Cleared only by
    /// refreshPrice() (an explicit "get me current data" action) — selecting a range merely
    /// serves from cache or fetches once per range per session.
    private var priceHistoryCache: [Int: [PricePoint]] = [:]
    private var priceHistoryTask: Task<Void, Never>?
    private let coinGecko: CoinGeckoService

    var transactionsDescending: [PortfolioTransaction] {
        transactions.sorted { $0.timestamp > $1.timestamp }
    }

    var summary: PortfolioSummary {
        Self.computeSummary(transactions: transactions, currentPriceUsd: currentPriceUsd ?? 0)
    }

    var valueHistory: [PricePoint] {
        Self.computeValueHistory(transactions: transactions, priceHistory: priceHistory)
    }

    init(coinGecko: CoinGeckoService = .shared) {
        self.coinGecko = coinGecko
        transactions = PortfolioLedgerStore.load()
        refreshPrice()
    }

    /// Explicit "get current data" action: refetches the live price and clears the price
    /// history cache so every range gets refetched fresh (bypassing whatever's cached).
    func refreshPrice() {
        Task { [weak self] in
            guard let self else { return }
            if let price = await self.coinGecko.getCurrentPriceUsd() {
                self.currentPriceUsd = price
            }
        }
        priceHistoryCache.removeAll()
        fetchPriceHistory(days: priceRangeDays)
    }

    /// Same refresh as refreshPrice(), but awaits both fetches — for pull-to-refresh, whose
    /// spinner needs to stay up until the data has actually arrived rather than returning the
    /// instant the underlying fire-and-forget Tasks are merely kicked off.
    func refreshPriceAsync() async {
        priceHistoryTask?.cancel()
        priceHistoryCache.removeAll()
        async let price = coinGecko.getCurrentPriceUsd()
        async let history = coinGecko.getPriceHistory(days: priceRangeDays)
        if let price = await price {
            currentPriceUsd = price
        }
        let result = await history
        if !result.isEmpty {
            priceHistoryCache[priceRangeDays] = result
            priceHistory = result
        }
    }

    /// Switches the price chart's window (1/7/30 days) and refetches history for it if not
    /// already cached this session.
    func setPriceRangeDays(_ days: Int) {
        guard priceRangeDays != days else { return }
        priceRangeDays = days
        fetchPriceHistory(days: days)
    }

    func cyclePriceRange() {
        let next: Int
        switch priceRangeDays {
        case 1: next = 7
        case 7: next = 30
        default: next = 1
        }
        setPriceRangeDays(next)
    }

    /// Serves `days` from cache if already fetched this session; otherwise fetches it,
    /// cancelling any still-in-flight fetch first (rapid range-cycle taps would otherwise fire
    /// overlapping requests). On failure, `priceHistory` is deliberately left alone rather than
    /// overwritten with the empty array CoinGeckoService returns on any error — a failed fetch
    /// is simply retried the next time this range is selected, since it's still uncached. This
    /// preserves whatever chart is currently on screen instead of blanking it (the chart card
    /// only renders when priceHistory.count >= 2).
    private func fetchPriceHistory(days: Int) {
        if let cached = priceHistoryCache[days] {
            priceHistory = cached
            return
        }
        priceHistoryTask?.cancel()
        priceHistoryTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.coinGecko.getPriceHistory(days: days)
            guard !Task.isCancelled else { return }
            if !result.isEmpty {
                self.priceHistoryCache[days] = result
                self.priceHistory = result
            }
        }
    }

    // MARK: - Ledger CRUD

    func addTransaction(
        type: PortfolioTransactionType,
        amountKas: Double,
        fiatValue: Double,
        timestamp: Date,
        notes: String?
    ) {
        let tx = PortfolioTransaction(
            id: UUID().uuidString,
            type: type,
            amountSompi: Int64((amountKas * 100_000_000).rounded()),
            fiatValue: fiatValue,
            timestamp: timestamp,
            notes: notes
        )
        transactions.append(tx)
        persist()
    }

    func updateTransaction(
        id: String,
        type: PortfolioTransactionType,
        amountKas: Double,
        fiatValue: Double,
        timestamp: Date,
        notes: String?
    ) {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return }
        transactions[index] = PortfolioTransaction(
            id: id,
            type: type,
            amountSompi: Int64((amountKas * 100_000_000).rounded()),
            fiatValue: fiatValue,
            timestamp: timestamp,
            notes: notes
        )
        persist()
    }

    func deleteTransaction(id: String) {
        transactions.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        PortfolioLedgerStore.save(transactions)
    }

    // MARK: - CSV (CoinMarketCap "Transaction History" format)

    /// Column order matches CoinMarketCap's portfolio Transaction History export exactly:
    /// `Date (UTC±H:MM),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes`
    /// — so a file exported from CoinMarketCap imports here unmodified, and a file exported
    /// from here imports back into CoinMarketCap unmodified.
    private static let trackedToken = "KAS"

    /// CoinMarketCap formats numeric columns with thousands-separator commas above 999 (e.g.
    /// "10,597.25", "6,093,184.09"), which plain `Double(_:)` rejects outright — parsing every
    /// such row would otherwise silently fail and get skipped. Strips those before parsing.
    private static func parseLenientDouble(_ raw: String) -> Double? {
        Double(raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ""))
    }

    private static func makeDateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter
    }

    /// CoinMarketCap bakes the exporting user's local UTC offset into the date column's own
    /// header name (e.g. "Date (UTC-4:00)") rather than into each row, so the offset has to be
    /// parsed once from the header before any row's timestamp can be interpreted correctly.
    /// Falls back to UTC if the header doesn't look like CoinMarketCap's (or is missing).
    private static func parseHeaderUTCOffset(_ header: String) -> TimeZone {
        let utcTimeZone = TimeZone(identifier: "UTC") ?? .current
        guard let utcRange = header.range(of: "UTC", options: .caseInsensitive),
              let closeParen = header[utcRange.upperBound...].firstIndex(of: ")") else {
            return utcTimeZone
        }
        let offsetString = header[utcRange.upperBound..<closeParen]
        let parts = offsetString.split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else {
            return utcTimeZone
        }
        let sign = offsetString.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (abs(hours) * 3600 + minutes * 60)) ?? utcTimeZone
    }

    /// Writes a CoinMarketCap-compatible CSV to a temp file and returns its URL for a share
    /// sheet. Rows are exported in ascending timestamp order, always in UTC (spelled out in the
    /// header) so re-importing never depends on the exporting device's local timezone. Fee /
    /// Fee Currency are written as zero/USD — the ledger doesn't keep fee as a separate line
    /// item; any fee captured at import time is already folded into Total value (USD).
    func exportCsvURL() -> URL? {
        let dateFormatter = Self.makeDateFormatter(timeZone: TimeZone(identifier: "UTC") ?? .current)
        var csv = "Date (UTC+0:00),Token,Type,Price (USD),Amount,Total value (USD),Fee,Fee Currency,Notes\n"
        for tx in transactions.sorted(by: { $0.timestamp < $1.timestamp }) {
            let date = dateFormatter.string(from: tx.timestamp)
            let amount = tx.amountKas
            let price = amount != 0 ? tx.fiatValue / amount : 0
            let notes = (tx.notes ?? "").replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(date)\",\"\(Self.trackedToken)\",\"\(tx.type.rawValue)\",\"\(price)\",\"\(amount)\",\"\(tx.fiatValue)\",\"0.00\",\"USD\",\"\(notes)\"\n"
        }

        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("portfolio_exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        let fileTimestamp = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = exportDir.appendingPathComponent("kachat-portfolio-\(fileTimestamp).csv")

        do {
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Parses a CoinMarketCap "Transaction History" CSV — same column order exportCsvURL
    /// writes, so real CoinMarketCap exports import here directly too. Only rows for the
    /// tracked token (KAS) are imported; other tokens in a mixed-portfolio CMC export are
    /// silently skipped, as are malformed rows and unsupported Type values (only buy/sell are
    /// tracked). Fee is folded into Total value (USD) when the fee is itself denominated in
    /// USD — added for buys, subtracted for sells — since the ledger doesn't track fee as a
    /// separate line item. A row whose timestamp exactly matches an existing transaction
    /// replaces it in place (same id, new data) rather than adding a duplicate — re-importing
    /// a corrected or re-exported CSV updates the ledger instead of piling up copies. Returns
    /// the number of rows imported or replaced.
    func importCsv(from url: URL) -> Int {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return 0
        }

        var lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return 0 }
        let header = lines.removeFirst()
        let dateFormatter = Self.makeDateFormatter(timeZone: Self.parseHeaderUTCOffset(header))

        var indexByTimestamp: [Date: Int] = [:]
        for (index, tx) in transactions.enumerated() {
            indexByTimestamp[tx.timestamp] = index
        }

        var imported = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let fields = Self.parseCsvLine(line)
            guard fields.count >= 6 else { continue }

            let token = fields[1].trimmingCharacters(in: .whitespaces)
            guard token.caseInsensitiveCompare(Self.trackedToken) == .orderedSame else { continue }

            let typeRaw = fields[2].trimmingCharacters(in: .whitespaces).lowercased()
            guard let type = PortfolioTransactionType(rawValue: typeRaw) else { continue }
            guard let timestamp = dateFormatter.date(from: fields[0].trimmingCharacters(in: .whitespaces)) else { continue }
            guard let kas = Self.parseLenientDouble(fields[4]) else { continue }
            guard let totalValue = Self.parseLenientDouble(fields[5]) else { continue }

            var fiatValue = totalValue
            if fields.count > 7 {
                let feeCurrency = fields[7].trimmingCharacters(in: .whitespaces)
                if feeCurrency.caseInsensitiveCompare("USD") == .orderedSame,
                   let fee = Self.parseLenientDouble(fields[6]) {
                    switch type {
                    case .buy: fiatValue += fee
                    case .sell: fiatValue = max(fiatValue - fee, 0)
                    }
                }
            }

            let notes = fields.count > 8 && !fields[8].isEmpty ? fields[8] : nil

            if let existingIndex = indexByTimestamp[timestamp] {
                transactions[existingIndex] = PortfolioTransaction(
                    id: transactions[existingIndex].id,
                    type: type,
                    amountSompi: Int64((kas * 100_000_000).rounded()),
                    fiatValue: fiatValue,
                    timestamp: timestamp,
                    notes: notes
                )
            } else {
                transactions.append(
                    PortfolioTransaction(
                        id: UUID().uuidString,
                        type: type,
                        amountSompi: Int64((kas * 100_000_000).rounded()),
                        fiatValue: fiatValue,
                        timestamp: timestamp,
                        notes: notes
                    )
                )
                indexByTimestamp[timestamp] = transactions.count - 1
            }
            imported += 1
        }

        if imported > 0 { persist() }
        return imported
    }

    /// Splits on commas outside double quotes, unescapes "" back to " within a quoted field.
    private static func parseCsvLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes, c == "\"", i + 1 < chars.count, chars[i + 1] == "\"" {
                current.append("\"")
                i += 1
            } else if c == "\"" {
                inQuotes.toggle()
            } else if c == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        return fields
    }

    // MARK: - Pure functions

    static func computeSummary(transactions: [PortfolioTransaction], currentPriceUsd: Double) -> PortfolioSummary {
        var holdingsSompi: Int64 = 0
        var totalInvested: Double = 0
        var totalProceeds: Double = 0
        var totalBoughtSompi: Int64 = 0
        for tx in transactions {
            switch tx.type {
            case .buy:
                holdingsSompi += tx.amountSompi
                totalInvested += tx.fiatValue
                totalBoughtSompi += tx.amountSompi
            case .sell:
                holdingsSompi -= tx.amountSompi
                totalProceeds += tx.fiatValue
            }
        }
        let holdingsKas = Double(holdingsSompi) / 100_000_000.0
        let currentValue = holdingsKas * currentPriceUsd
        let totalPL = (currentValue + totalProceeds) - totalInvested
        let totalPLPercent = totalInvested > 0 ? (totalPL / totalInvested) * 100.0 : 0.0
        let totalBoughtKas = Double(totalBoughtSompi) / 100_000_000.0
        let averageBuyPriceUsd = totalBoughtKas > 0 ? totalInvested / totalBoughtKas : nil
        return PortfolioSummary(
            holdingsKas: holdingsKas,
            totalInvested: totalInvested,
            totalProceeds: totalProceeds,
            currentValue: currentValue,
            totalPL: totalPL,
            totalPLPercent: totalPLPercent,
            averageBuyPriceUsd: averageBuyPriceUsd
        )
    }

    /// Replays the transaction ledger against each price-history point to get holdings *as of
    /// that moment* (not current holdings) — a buy/sell made partway through the window
    /// changes the value curve's shape from that point on, not retroactively. A transaction
    /// exactly at a price point's timestamp counts as included (strictly-greater is the break
    /// condition, matching Android).
    static func computeValueHistory(transactions: [PortfolioTransaction], priceHistory: [PricePoint]) -> [PricePoint] {
        guard !priceHistory.isEmpty else { return [] }
        let sortedTx = transactions.sorted { $0.timestamp < $1.timestamp }
        return priceHistory.map { point in
            var holdingsSompi: Int64 = 0
            for tx in sortedTx {
                if tx.timestamp > point.timestamp { break }
                switch tx.type {
                case .buy: holdingsSompi += tx.amountSompi
                case .sell: holdingsSompi -= tx.amountSompi
                }
            }
            let holdingsKas = Double(holdingsSompi) / 100_000_000.0
            return PricePoint(timestamp: point.timestamp, value: holdingsKas * point.value)
        }
    }
}
