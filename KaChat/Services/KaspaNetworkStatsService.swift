import Foundation

/// Network hashrate, current and historical, from the Kaspa REST API.
///
/// Uses `AppSettings.kaspaRestAPIURL` like every other REST caller in the app, so a user pointed at
/// their own node's API gets their own numbers.
@MainActor
final class KaspaNetworkStatsService: ObservableObject {
    static let shared = KaspaNetworkStatsService()

    /// Hashrate over time, in PH/s, oldest first. Empty until the first successful fetch.
    @Published private(set) var hashrateHistory: [PricePoint] = []
    /// The most recent sample, in PH/s.
    @Published private(set) var currentHashrate: Double?
    /// Current block reward in KAS, for the mining estimate. Kaspa's reward steps down every
    /// month (the chromatic halving), so this is read from the API rather than hardcoded.
    @Published private(set) var blockRewardKas: Double?
    /// What the reward steps down to at the next chromatic halving, and when. Read from the API
    /// rather than derived: the step is a clean 1/2^(1/12), but the DAA score it lands on is not
    /// something a client can date accurately on its own.
    @Published private(set) var nextBlockRewardKas: Double?
    @Published private(set) var nextHalvingDate: Date?
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
            await refreshBlockReward()
            await refreshNextHalving()
        } catch {
            // A chart nobody asked for is not worth an error banner; the card simply stays empty.
            AppLog.log("%@", "[Hashrate] Fetch failed: \(error.localizedDescription)")
        }
    }

    /// The current block reward, for the mining estimate.
    ///
    /// Kaspa's reward is not a fixed number: it steps down every month on the chromatic halving
    /// (a smooth 1/2^(1/12) per month rather than a cliff every four years), so a hardcoded
    /// constant would be wrong within weeks.
    private func refreshBlockReward() async {
        guard var components = URLComponents(string: AppSettings.load().kaspaRestAPIURL) else { return }
        components.path += "/info/blockreward"
        guard let url = components.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(BlockRewardResponse.self, from: data)
            if decoded.blockreward > 0 { blockRewardKas = decoded.blockreward }
        } catch {
            // The chart is still useful without it; the estimate just says it is unavailable.
            AppLog.log("%@", "[Hashrate] Block reward fetch failed: \(error.localizedDescription)")
        }
    }

    private struct BlockRewardResponse: Decodable {
        let blockreward: Double
    }

    /// The next reward step-down and its date.
    ///
    /// Kaspa's emission steps every month, so "next halving" here is the next monthly reduction,
    /// not a four-year event - which is why it is usually only weeks away.
    private func refreshNextHalving() async {
        guard var components = URLComponents(string: AppSettings.load().kaspaRestAPIURL) else { return }
        components.path += "/info/halving"
        guard let url = components.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(HalvingResponse.self, from: data)
            if decoded.nextHalvingAmount > 0 { nextBlockRewardKas = decoded.nextHalvingAmount }
            if decoded.nextHalvingTimestamp > 0 {
                nextHalvingDate = Date(timeIntervalSince1970: decoded.nextHalvingTimestamp)
            }
        } catch {
            // The rest of the screen stands without it; those two rows just stay empty.
            AppLog.log("%@", "[Hashrate] Halving fetch failed: \(error.localizedDescription)")
        }
    }

    private struct HalvingResponse: Decodable {
        let nextHalvingTimestamp: TimeInterval
        let nextHalvingAmount: Double
    }

    /// Blocks per second on mainnet since the Crescendo hardfork (May 2025) took Kaspa from 1 to
    /// 10. Together with the block reward this gives daily emission: at today's ~2.31 KAS reward
    /// that is about 2.0 million KAS a day, which is what the network actually pays out.
    static let blocksPerSecond: Double = 10

    /// Maps the API's kilohashes to PH/s and sorts oldest first.
    ///
    /// Deliberately UNFILTERED. The series looks like it carries wild outliers - days reporting
    /// four times the current hashrate - and an outlier filter was written before the data was
    /// actually checked. It is not noise: the network really did climb to around 1,480 PH/s
    /// across 2024-25 before falling back to roughly 320. Filtering on a multiple of the median
    /// deleted about a quarter of the series and drew a history that never happened.
    static func series(from samples: [HashrateSample]) -> [PricePoint] {
        samples
            .filter { $0.hashrate_kh > 0 }
            .map {
                PricePoint(
                    timestamp: Date(timeIntervalSince1970: TimeInterval($0.timestamp) / 1000),
                    // 1 PH/s = 1e12 kH/s. This divisor was right and the LABEL was wrong: the
                    // series was drawn as EH/s, a thousand times what it is. Checked against both
                    // endpoints - /info/hashrate/history's newest sample and /info/hashrate - and
                    // they agree at ~317 PH/s, i.e. 0.32 EH/s.
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

/// Formats a hashrate given in PH/s, stepping the unit so both the network today (hundreds of
/// PH/s) and a single miner (tens of TH/s) read naturally.
enum HashrateFormat {
    static func display(_ phs: Double) -> String {
        if phs >= 1_000 { return String(format: "%.2f EH/s", phs / 1_000) }
        if phs >= 1 { return String(format: "%.1f PH/s", phs) }
        if phs >= 0.001 { return String(format: "%.1f TH/s", phs * 1_000) }
        return String(format: "%.1f GH/s", phs * 1_000_000)
    }
}
