import Foundation

/// "Has this address ever been used, and when" - for a whole list of addresses in one request.
///
/// Both address scans in the app used to answer that question one address at a time, and both were
/// slow and shallow because of it. Cold Storage probed KNS sequentially for the first 200 indices,
/// at roughly a third of a second each; the spending-address scan walked a gap limit that a run of
/// empty addresses could end early, which is how a funded address at index 291 stayed invisible.
///
/// `POST /addresses/active` on the Kaspa REST API answers the question in bulk, which removes the
/// reason to walk at all: ask about the whole window at once, and only the handful of addresses the
/// chain says were ever touched cost anything further. A balance or a KNS domain cannot exist on an
/// address that has never been touched, so nothing is lost by using it as a pre-filter.
///
/// Measured against api.kaspa.org while building this: a 1000-address window answers in about
/// 0.65 seconds across four requests.
enum AddressActivityService {
    /// Addresses per request, and how many requests to keep in flight.
    ///
    /// From measurement, not taste: 250 addresses answer in ~350ms and 300 in ~315ms, but 500 in a
    /// single body stalls past 25 seconds. The ceiling is real and it is well under 500.
    static let batchSize = 250
    static let concurrency = 2
    /// A stalled request must not hold a scan open indefinitely - the caller has a fallback.
    static let timeout: TimeInterval = 20

    /// The subset of `addresses` the chain has ever seen, mapped to the block time of their last
    /// transaction (0 when the server reports activity without a timestamp).
    ///
    /// Returns nil when the configured REST server does not serve the route, or could not be
    /// reached. That is deliberately distinct from "an empty result": an empty map means every
    /// address is genuinely unused, and nil means we do not know, which is the caller's signal to
    /// fall back rather than to report emptiness it never confirmed.
    static func lastActivity(for addresses: [String]) async -> [String: Int64]? {
        guard !addresses.isEmpty else { return [:] }
        let batches = stride(from: 0, to: addresses.count, by: batchSize).map {
            Array(addresses[$0..<min($0 + batchSize, addresses.count)])
        }

        var merged: [String: Int64] = [:]
        var unavailable = false

        // Two requests in flight at a time, a pair at a time. Simple on purpose: the batch count
        // is single digits, so a hand-rolled sliding window would be machinery for nothing.
        for chunk in stride(from: 0, to: batches.count, by: concurrency) {
            let slice = Array(batches[chunk..<min(chunk + concurrency, batches.count)])
            let results = await withTaskGroup(of: [String: Int64]?.self) { group -> [[String: Int64]?] in
                for batch in slice { group.addTask { await requestBatch(batch) } }
                var collected: [[String: Int64]?] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for result in results {
                guard let result else { unavailable = true; continue }
                merged.merge(result) { current, _ in current }
            }
            // One unreadable batch makes the whole answer untrustworthy: a request that failed is
            // not evidence that its addresses are unused, and reporting them as unused would hide
            // real balances. Stop and let the caller fall back.
            if unavailable { break }
        }

        return unavailable ? nil : merged
    }

    /// Just the set that has ever been used, for callers that do not need the timestamps.
    static func activeAddresses(in addresses: [String]) async -> Set<String>? {
        guard let map = await lastActivity(for: addresses) else { return nil }
        return Set(map.keys)
    }

    // MARK: - Wire

    private static func requestBatch(_ addresses: [String]) async -> [String: Int64]? {
        guard var components = URLComponents(string: AppSettings.load().kaspaRestAPIURL) else { return nil }
        // A trailing slash on a custom URL would otherwise produce "//addresses".
        if components.path.hasSuffix("/") { components.path.removeLast() }
        components.path += "/addresses/active"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONEncoder().encode(RequestBody(addresses: addresses))
        guard request.httpBody != nil else { return nil }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else {
            return nil
        }
        var result: [String: Int64] = [:]
        for row in rows where row.active {
            result[row.address] = row.lastTxBlockTime ?? 0
        }
        return result
    }

    private struct RequestBody: Encodable {
        let addresses: [String]
    }

    private struct Row: Decodable {
        let address: String
        let active: Bool
        let lastTxBlockTime: Int64?
    }
}
