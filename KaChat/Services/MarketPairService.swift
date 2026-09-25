import Foundation

/// USD price history for the things a chart can be measured against besides a currency:
/// Vanguard's S&P 500 ETF, gold and silver. Yahoo Finance's chart endpoint, keyless, the way
/// CoinGecko is for KAS. Empty on any failure, like the other price clients - the chart then
/// keeps whatever it had.
///
/// KAS against one of these is KAS/USD over the pair's USD price at the same moment. The pair
/// only trades market hours, so between sessions its last close stands - a weekend line
/// against VOO is KAS's own move, which is the honest reading.
final class MarketPairService: Sendable {
    static let shared = MarketPairService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"]
        session = URLSession(configuration: config)
    }

    private struct ChartResponse: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
        }
        struct Result: Decodable {
            struct Meta: Decodable { let regularMarketPrice: Double? }
            struct Indicators: Decodable {
                struct Quote: Decodable { let close: [Double?]? }
                let quote: [Quote]
            }
            let meta: Meta
            let timestamp: [Int]?
            let indicators: Indicators
        }
        let chart: Chart
    }

    /// The pair's USD prices covering a chart base range (see `PortfolioViewModel.baseDays`),
    /// oldest first, and its latest price. A base of one day comes as five days of 5-minute
    /// points so a KAS point on a weekend still has a close before it to stand on.
    func history(_ pair: ChartPair, baseDays: Int) async -> (points: [PricePoint], latest: Double?) {
        guard let symbol = pair.yahooSymbol else { return ([], nil) }
        let (range, interval): (String, String)
        switch baseDays {
        case 0: (range, interval) = ("max", "1d")
        case ...1: (range, interval) = ("5d", "5m")
        case ...90: (range, interval) = ("3mo", "1h")
        default: (range, interval) = ("2y", "1d")
        }
        guard var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)") else { return ([], nil) }
        components.queryItems = [
            URLQueryItem(name: "range", value: range),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "includePrePost", value: "false")
        ]
        guard let url = components.url else { return ([], nil) }
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { return ([], nil) }
                if http.statusCode == 200 {
                    let decoded = try JSONDecoder().decode(ChartResponse.self, from: data)
                    guard let result = decoded.chart.result?.first else { return ([], nil) }
                    let stamps = result.timestamp ?? []
                    let closes = result.indicators.quote.first?.close ?? []
                    var points: [PricePoint] = []
                    points.reserveCapacity(stamps.count)
                    for (index, stamp) in stamps.enumerated() where index < closes.count {
                        guard let close = closes[index], close > 0 else { continue }
                        points.append(PricePoint(timestamp: Date(timeIntervalSince1970: TimeInterval(stamp)), value: close))
                    }
                    return (points, result.meta.regularMarketPrice ?? points.last?.value)
                }
                guard attempt == 0, http.statusCode == 429 || http.statusCode >= 500 else { return ([], nil) }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return ([], nil)
            }
        }
        return ([], nil)
    }

    /// KAS priced in the pair: each KAS/USD point over the pair's last price at or before it.
    /// KAS points from before the pair's first price are dropped rather than guessed.
    static func divide(_ kas: [PricePoint], by pair: [PricePoint]) -> [PricePoint] {
        guard !pair.isEmpty else { return [] }
        var result: [PricePoint] = []
        result.reserveCapacity(kas.count)
        var index = 0
        for point in kas {
            while index + 1 < pair.count, pair[index + 1].timestamp <= point.timestamp { index += 1 }
            guard pair[index].timestamp <= point.timestamp, pair[index].value > 0 else { continue }
            result.append(PricePoint(timestamp: point.timestamp, value: point.value / pair[index].value))
        }
        return result
    }
}
