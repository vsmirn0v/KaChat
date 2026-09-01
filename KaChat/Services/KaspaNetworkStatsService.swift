import Foundation

/// Network hashrate, current and historical, from the Kaspa REST API.
///
/// Uses `AppSettings.kaspaRestAPIURL` like every other REST caller in the app, so a user pointed at
/// their own node's API gets their own numbers.
@MainActor
final class KaspaNetworkStatsService: ObservableObject {
    static let shared = KaspaNetworkStatsService()

    /// Hashrate over time, in EH/s, oldest first. Empty until the first successful fetch.
    @Published private(set) var hashrateHistory: [PricePoint] = []
    /// The most recent sample, in EH/s.
    @Published private(set) var currentHashrate: Double?
    @Published private(set) var isLoading = false

    private var lastFetchedAt: Date?
    /// The series moves slowly - it is a multi-day chart of a quantity that changes by a few
    /// percent a day - so refetching more often than this buys nothing and costs data.
    private let minimumRefetchInterval: TimeInterval = 15 * 60

    private init() {}

    /// One point per day. Finer resolutions exist (down to 15m) but return tens of thousands of
    /// samples for the full chain history, which is a lot of payload for a chart a few hundred
    /// pixels wide.
    private static let resolution = "1d"

    func refreshIfNeeded(force: Bool = false) async {
        if !force, let lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < minimumRefetchInterval {
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard var components = URLComponents(string: AppSettings.load().kaspaRestAPIURL) else { return }
        components.path += "/info/hashrate/history"
        components.queryItems = [URLQueryItem(name: "resolution", value: Self.resolution)]
        guard let url = components.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let samples = try JSONDecoder().decode([HashrateSample].self, from: data)
            let points = Self.series(from: samples)
            guard !points.isEmpty else { return }
            hashrateHistory = points
            currentHashrate = points.last?.value
            lastFetchedAt = Date()
        } catch {
            // A chart nobody asked for is not worth an error banner; the card simply stays empty.
            AppLog.log("%@", "[Hashrate] Fetch failed: \(error.localizedDescription)")
        }
    }

    /// Maps the API's kilohashes to EH/s and sorts oldest first.
    ///
    /// Deliberately UNFILTERED. The series looks like it carries wild outliers - days reporting
    /// four times the current hashrate - and an outlier filter was written before the data was
    /// actually checked. It is not noise: the network really did climb to around 1,480 EH/s
    /// across 2024-25 before falling back to roughly 400. Filtering on a multiple of the median
    /// deleted about a quarter of the series and drew a history that never happened.
    static func series(from samples: [HashrateSample]) -> [PricePoint] {
        // 1 EH/s = 1e12 kH/s.
        samples
            .filter { $0.hashrate_kh > 0 }
            .map {
                PricePoint(
                    timestamp: Date(timeIntervalSince1970: TimeInterval($0.timestamp) / 1000),
                    value: $0.hashrate_kh / 1e12
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// One row of `/info/hashrate/history`. Only the two fields the chart needs are decoded.
    struct HashrateSample: Decodable {
        let timestamp: Int64
        let hashrate_kh: Double
    }
}

/// Formats a hashrate in EH/s, stepping down the units so an early-history value is still legible.
enum HashrateFormat {
    static func display(_ ehs: Double) -> String {
        if ehs >= 1 { return String(format: "%.2f EH/s", ehs) }
        if ehs >= 0.001 { return String(format: "%.1f PH/s", ehs * 1_000) }
        return String(format: "%.1f TH/s", ehs * 1_000_000)
    }
}
