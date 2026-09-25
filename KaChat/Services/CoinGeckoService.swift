import Foundation

/// Free public CoinGecko REST client for KAS/fiat price and price history, used by Portfolio.
/// No API key required. Mirrors the cache-on-failure philosophy used throughout the app's
/// other REST clients (e.g. KNSService): return nil/empty on any failure rather than throwing,
/// so callers can fall back to their own last-known-good state instead of crashing or showing
/// a hard error. Currency is caller-supplied (`AppCurrency`, Settings > Customization > Currency) -
/// CoinGecko's public API natively supports any of its listed `vs_currency` values, so switching
/// away from USD needs no change on CoinGecko's side, just passing the selected code through.
/// `Sendable` (all stored properties immutable) - PortfolioViewModel hands the instance from
/// its @MainActor context to a nonisolated fetch+downsample helper running off the main actor.
final class CoinGeckoService: Sendable {
    static let shared = CoinGeckoService()

    private let session: URLSession
    private let baseURL = "https://api.coingecko.com"

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    private struct SimplePriceResponse: Decodable {
        let kaspa: [String: Double]
    }

    private struct MarketChartResponse: Decodable {
        let prices: [[Double]]
    }

    private struct HistoryResponse: Decodable {
        struct MarketData: Decodable {
            let currentPrice: [String: Double]?

            enum CodingKeys: String, CodingKey {
                case currentPrice = "current_price"
            }
        }
        /// Absent (rather than present-with-nulls) when CoinGecko has no snapshot for the
        /// requested date — a very recent date, or a date before Kaspa was listed.
        let marketData: MarketData?

        enum CodingKeys: String, CodingKey {
            case marketData = "market_data"
        }
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Market cap and market-cap rank for KAS, in the requested currency.
    ///
    /// From CoinGecko's `/coins/markets`, the same keyless source the rest of this client uses.
    /// CoinMarketCap's own API needs a key, and its rank agrees with CoinGecko's in all but the
    /// occasional off-by-one around ties, so this is the figure people recognise without shipping
    /// a second provider and a secret to reach it.
    func getMarketStats(currency: AppCurrency) async -> (marketCap: Double, rank: Int?)? {
        guard var components = URLComponents(string: baseURL + "/api/v3/coins/markets") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: currency.rawValue),
            URLQueryItem(name: "ids", value: "kaspa")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode([MarketsRow].self, from: data)
            guard let row = decoded.first, let cap = row.marketCap else { return nil }
            return (marketCap: cap, rank: row.marketCapRank)
        } catch {
            return nil
        }
    }

    private struct MarketsRow: Decodable {
        let marketCap: Double?
        let marketCapRank: Int?

        enum CodingKeys: String, CodingKey {
            case marketCap = "market_cap"
            case marketCapRank = "market_cap_rank"
        }
    }

    /// `change24hPercent` is nil only on a decode/response oddity, not treated as a separate
    /// failure from the price fetch itself — CoinGecko returns both in the same call
    /// (`include_24hr_change=true`), so there's no second request to independently fail.
    func getCurrentPrice(currency: AppCurrency) async -> (price: Double, change24hPercent: Double?)? {
        guard var components = URLComponents(string: baseURL + "/api/v3/simple/price") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "ids", value: "kaspa"),
            URLQueryItem(name: "vs_currencies", value: currency.rawValue),
            URLQueryItem(name: "include_24hr_change", value: "true")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(SimplePriceResponse.self, from: data)
            guard let price = decoded.kaspa[currency.rawValue] else { return nil }
            let change24h = decoded.kaspa["\(currency.rawValue)_24h_change"]
            return (price: price, change24hPercent: change24h)
        } catch {
            return nil
        }
    }

    /// (timestamp, price) points in the requested currency, oldest first. Empty array on any
    /// failure rather than throwing — callers must not blindly overwrite existing cached history
    /// with an empty result (see PortfolioViewModel.fetchPriceHistory).
    ///
    /// CoinGecko's keyless tier throttles bursts hard (429 for a stretch after just a few rapid
    /// calls) — a launch plus a couple of chart-range taps was enough to make every subsequent
    /// range fetch come back empty, leaving the chart stuck on whatever range loaded first. A
    /// 429/5xx here gets one retry, honoring Retry-After (capped at 10s).
    /// `days == 0` is the all-time chart - see `fetchAllTimeHistory`.
    /// All-time. CoinGecko's public tier stops at 365 days (error 10012 past it), so the
    /// older part comes from Gate.io's daily KAS/USDT candles - public, no key, trading there
    /// since 2023-03-21 - and CoinGecko's own last 365 days sit on top unchanged. Gate quotes
    /// USDT; the older points are scaled into the chosen currency by the ratio at the seam
    /// (CoinGecko's first point over Gate's close of that day), which is exact for USD and a
    /// constant-rate approximation for any other currency. Daily granularity throughout.
    /// In bitcoin the older part is KAS/USDT over BTC/USDT for the same day - a constant
    /// ratio would be wrong across years in which bitcoin itself moved several times over.
    private func fetchAllTimeHistory(currency: AppCurrency) async -> [PricePoint] {
        async let recentTask = getPriceHistory(days: 365, currency: currency)
        async let bitcoinTask = fetchGateDailyCloses(pair: currency == .bitcoin ? "BTC_USDT" : nil)
        let gate = await fetchGateDailyCloses(pair: "KAS_USDT")
        let recent = await recentTask
        let bitcoin = await bitcoinTask
        guard !gate.isEmpty else { return recent }
        if currency == .bitcoin {
            let bitcoinByDay = Dictionary(bitcoin.map { ($0.timestamp, $0.value) }, uniquingKeysWith: { first, _ in first })
            let inBitcoin = gate.compactMap { point -> PricePoint? in
                guard let bitcoinPrice = bitcoinByDay[point.timestamp], bitcoinPrice > 0 else { return nil }
                return PricePoint(timestamp: point.timestamp, value: point.value / bitcoinPrice)
            }
            guard let firstRecent = recent.first else { return inBitcoin }
            return inBitcoin.filter { $0.timestamp < firstRecent.timestamp } + recent
        }
        guard let firstRecent = recent.first else {
            return currency == .usDollar ? gate : []
        }
        let anchor = gate.last(where: { $0.timestamp <= firstRecent.timestamp }) ?? gate[gate.count - 1]
        let ratio = anchor.value > 0 ? firstRecent.value / anchor.value : 1
        let older = gate
            .filter { $0.timestamp < firstRecent.timestamp }
            .map { PricePoint(timestamp: $0.timestamp, value: $0.value * ratio) }
        return older + recent
    }

    /// Gate.io daily closes for a pair, oldest first, paged backwards until the listing.
    /// No pair: nothing (so a caller can ask conditionally in one `async let`).
    private func fetchGateDailyCloses(pair: String?) async -> [PricePoint] {
        guard let pair else { return [] }
        return await fetchGateCandles(pair: pair, interval: "1d", intervalSeconds: 86_400, pointCount: 6000)
    }

    /// Gate.io candle closes for a pair at an interval, oldest first, the newest `pointCount`
    /// of them, paged backwards 1000 at a time and stopping early where the listing begins.
    /// Row shape: [time, quote volume, close, high, low, open, ...].
    private func fetchGateCandles(pair: String, interval: String, intervalSeconds: Int64, pointCount: Int) async -> [PricePoint] {
        var closes: [Int64: Double] = [:]
        var to = Int64(Date().timeIntervalSince1970)
        var remaining = pointCount
        for _ in 0..<8 where remaining > 0 {
            let limit = min(1000, remaining)
            guard var components = URLComponents(string: "https://api.gateio.ws/api/v4/spot/candlesticks") else { break }
            components.queryItems = [
                URLQueryItem(name: "currency_pair", value: pair),
                URLQueryItem(name: "interval", value: interval),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "to", value: String(to))
            ]
            guard let url = components.url,
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let rows = try? JSONDecoder().decode([[String]].self, from: data),
                  !rows.isEmpty else { break }
            var earliest = to
            for row in rows where row.count >= 3 {
                if let time = Int64(row[0]), let close = Double(row[2]) {
                    closes[time] = close
                    earliest = min(earliest, time)
                }
            }
            remaining -= rows.count
            if rows.count < limit || earliest >= to { break }
            to = earliest - intervalSeconds
        }
        return closes.keys.sorted().map { PricePoint(timestamp: Date(timeIntervalSince1970: TimeInterval($0)), value: closes[$0] ?? 0) }
    }

    /// The same range from Gate.io when CoinGecko will not serve it: 5-minute candles for a
    /// day, hourly for 90 days, daily beyond. Gate quotes USDT, which is the dollar series;
    /// bitcoin divides by BTC/USDT candle for candle; any other currency is scaled by the
    /// ratio of the latest known KAS price in it (`spotHint`) to Gate's latest close - a
    /// constant-rate approximation, and without a spot to scale by there is no series.
    private func fetchGateHistory(days: Int, currency: AppCurrency, spotHint: Double?) async -> [PricePoint] {
        let (interval, seconds, count): (String, Int64, Int)
        switch days {
        case ...1: (interval, seconds, count) = ("5m", 300, 288)
        case ...90: (interval, seconds, count) = ("1h", 3600, days * 24)
        default: (interval, seconds, count) = ("1d", 86_400, days)
        }
        async let bitcoinTask = currency == .bitcoin
            ? fetchGateCandles(pair: "BTC_USDT", interval: interval, intervalSeconds: seconds, pointCount: count)
            : []
        let kas = await fetchGateCandles(pair: "KAS_USDT", interval: interval, intervalSeconds: seconds, pointCount: count)
        let bitcoin = await bitcoinTask
        guard !kas.isEmpty else { return [] }
        switch currency {
        case .usDollar:
            return kas
        case .bitcoin:
            let bitcoinByTime = Dictionary(bitcoin.map { ($0.timestamp, $0.value) }, uniquingKeysWith: { first, _ in first })
            return kas.compactMap { point in
                guard let bitcoinPrice = bitcoinByTime[point.timestamp], bitcoinPrice > 0 else { return nil }
                return PricePoint(timestamp: point.timestamp, value: point.value / bitcoinPrice)
            }
        default:
            guard let spotHint, spotHint > 0, let latest = kas.last?.value, latest > 0 else { return [] }
            let ratio = spotHint / latest
            return kas.map { PricePoint(timestamp: $0.timestamp, value: $0.value * ratio) }
        }
    }

    /// CoinGecko first, Gate.io when it refuses (its keyless tier throttles bursts for a
    /// stretch, and a range used to stay blank for as long as that lasted). `spotHint` is
    /// the latest known KAS price in `currency`, for Gate's non-dollar scaling.
    func getPriceHistory(days: Int, currency: AppCurrency, spotHint: Double? = nil) async -> [PricePoint] {
        if days == 0 { return await fetchAllTimeHistory(currency: currency) }
        let fromCoinGecko = await fetchCoinGeckoHistory(days: days, currency: currency)
        if !fromCoinGecko.isEmpty { return fromCoinGecko }
        return await fetchGateHistory(days: days, currency: currency, spotHint: spotHint)
    }

    private func fetchCoinGeckoHistory(days: Int, currency: AppCurrency) async -> [PricePoint] {
        guard var components = URLComponents(string: baseURL + "/api/v3/coins/kaspa/market_chart") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: currency.rawValue),
            URLQueryItem(name: "days", value: String(days))
        ]
        guard let url = components.url else { return [] }

        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { return [] }
                if http.statusCode == 200 {
                    let decoded = try JSONDecoder().decode(MarketChartResponse.self, from: data)
                    return decoded.prices.compactMap { point -> PricePoint? in
                        guard point.count >= 2 else { return nil }
                        return PricePoint(timestamp: Date(timeIntervalSince1970: point[0] / 1000), value: point[1])
                    }
                }
                guard attempt == 0, http.statusCode == 429 || http.statusCode >= 500 else { return [] }
                let retryAfter = min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2, 10)
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            } catch {
                // Includes Task cancellation during the retry sleep — bail out quietly.
                return []
            }
        }
        return []
    }

    /// The daily snapshot price CoinGecko recorded for `date` (daily granularity only — CoinGecko's
    /// `/coins/{id}/history` endpoint has no intraday resolution). Nil on any failure or when
    /// CoinGecko simply has no data for that date, so callers (see `PortfolioAddressImporter`)
    /// must treat this the same as any other "couldn't price this" case rather than assuming
    /// nil only means a network error.
    ///
    /// Same 429/5xx retry as `getPriceHistory`: the keyless tier throttles bursts, and this
    /// endpoint is the per-day fallback the portfolio price backfill leans on — one Retry-After-
    /// honoring retry (capped at 10s) turns a throttle window into a delay instead of a miss.
    func getHistoricalPrice(date: Date, currency: AppCurrency) async -> Double? {
        guard var components = URLComponents(string: baseURL + "/api/v3/coins/kaspa/history") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "date", value: Self.historyDateFormatter.string(from: date)),
            URLQueryItem(name: "localization", value: "false")
        ]
        guard let url = components.url else { return nil }

        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { return nil }
                if http.statusCode == 200 {
                    let decoded = try JSONDecoder().decode(HistoryResponse.self, from: data)
                    return decoded.marketData?.currentPrice?[currency.rawValue]
                }
                guard attempt == 0, http.statusCode == 429 || http.statusCode >= 500 else { return nil }
                let retryAfter = min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2, 10)
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            } catch {
                // Includes Task cancellation during the retry sleep — bail out quietly.
                return nil
            }
        }
        return nil
    }
}
