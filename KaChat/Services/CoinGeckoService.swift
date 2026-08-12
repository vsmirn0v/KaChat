import Foundation

/// Free public CoinGecko REST client for KAS/fiat price and price history, used by Portfolio.
/// No API key required. Mirrors the cache-on-failure philosophy used throughout the app's
/// other REST clients (e.g. KNSService): return nil/empty on any failure rather than throwing,
/// so callers can fall back to their own last-known-good state instead of crashing or showing
/// a hard error. Currency is caller-supplied (`AppCurrency`, Settings > Customization > Currency) -
/// CoinGecko's public API natively supports any of its listed `vs_currency` values, so switching
/// away from USD needs no change on CoinGecko's side, just passing the selected code through.
final class CoinGeckoService {
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
    func getPriceHistory(days: Int, currency: AppCurrency) async -> [PricePoint] {
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
    func getHistoricalPrice(date: Date, currency: AppCurrency) async -> Double? {
        guard var components = URLComponents(string: baseURL + "/api/v3/coins/kaspa/history") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "date", value: Self.historyDateFormatter.string(from: date)),
            URLQueryItem(name: "localization", value: "false")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(HistoryResponse.self, from: data)
            return decoded.marketData?.currentPrice?[currency.rawValue]
        } catch {
            return nil
        }
    }
}
