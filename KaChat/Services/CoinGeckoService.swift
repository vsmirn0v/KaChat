import Foundation

/// Free public CoinGecko REST client for KAS/USD price and price history, used by Portfolio.
/// No API key required. Mirrors the cache-on-failure philosophy used throughout the app's
/// other REST clients (e.g. KNSService): return nil/empty on any failure rather than throwing,
/// so callers can fall back to their own last-known-good state instead of crashing or showing
/// a hard error.
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

    func getCurrentPriceUsd() async -> Double? {
        guard var components = URLComponents(string: baseURL + "/api/v3/simple/price") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "ids", value: "kaspa"),
            URLQueryItem(name: "vs_currencies", value: "usd")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(SimplePriceResponse.self, from: data)
            return decoded.kaspa["usd"]
        } catch {
            return nil
        }
    }

    /// (timestamp, priceUsd) points, oldest first. Empty array on any failure rather than
    /// throwing — callers must not blindly overwrite existing cached history with an empty
    /// result (see PortfolioViewModel.fetchPriceHistory).
    func getPriceHistory(days: Int) async -> [PricePoint] {
        guard var components = URLComponents(string: baseURL + "/api/v3/coins/kaspa/market_chart") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "days", value: String(days))
        ]
        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(MarketChartResponse.self, from: data)
            return decoded.prices.compactMap { point -> PricePoint? in
                guard point.count >= 2 else { return nil }
                return PricePoint(timestamp: Date(timeIntervalSince1970: point[0] / 1000), value: point[1])
            }
        } catch {
            return []
        }
    }
}
