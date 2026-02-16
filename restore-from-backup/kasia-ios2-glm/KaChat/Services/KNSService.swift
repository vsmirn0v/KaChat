import Foundation

/// Kaspa Name Service (KNS) API client for resolving domain names
@MainActor
final class KNSService: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = KNSService()

    /// Cache of domains by address
    @Published private(set) var domainCache: [String: KNSAddressInfo] = [:]

    /// Addresses currently being fetched
    private var pendingFetches: Set<String> = []
    private var lastAttemptAt: [String: Date] = [:]
    private var failureCounts: [String: Int] = [:]

    private let cacheKey = "kachat_kns_domain_cache_v1"
    private let minRefreshInterval: TimeInterval = 10 * 60
    private let maxBackoffInterval: TimeInterval = 6 * 60 * 60
    private let maxConcurrentRefreshes = 4

    private var session: URLSession!

    private override init() {
        super.init()
        loadCache()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - URLSessionTaskDelegate

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // Use full URL with query params
        let fullURL = task.originalRequest?.url?.absoluteString ?? "unknown"
        logMetrics(metrics, endpoint: fullURL, task: task)
    }

    /// Log detailed metrics for a completed request
    nonisolated private func logMetrics(_ metrics: URLSessionTaskMetrics, endpoint: String, task: URLSessionTask) {
        guard let transaction = metrics.transactionMetrics.last else {
            NSLog("[KNS] [%@] No transaction data", endpoint)
            return
        }

        let proto = transaction.networkProtocolName ?? "unknown"
        let isReused = transaction.isReusedConnection
        let remoteAddr = transaction.remoteAddress ?? "unknown"
        let remotePort = transaction.remotePort.map { String($0) } ?? "?"

        var connProto = proto
        if proto.contains("h3") || proto.contains("quic") {
            connProto = "HTTP/3-QUIC-UDP"
        } else if proto.contains("h2") || proto == "http/2" {
            connProto = "HTTP/2-TCP"
        } else if proto.contains("http/1") {
            connProto = "HTTP/1.1-TCP"
        }

        var timings: [String] = []
        if let fetchStart = transaction.fetchStartDate {
            if let domainEnd = transaction.domainLookupEndDate, let domainStart = transaction.domainLookupStartDate {
                let dnsMs = domainEnd.timeIntervalSince(domainStart) * 1000
                if dnsMs > 0 { timings.append(String(format: "dns=%.0fms", dnsMs)) }
            }
            if let connectEnd = transaction.connectEndDate, let connectStart = transaction.connectStartDate {
                let connectMs = connectEnd.timeIntervalSince(connectStart) * 1000
                if connectMs > 0 { timings.append(String(format: "tcp=%.0fms", connectMs)) }
            }
            if let secureEnd = transaction.secureConnectionEndDate, let secureStart = transaction.secureConnectionStartDate {
                let tlsMs = secureEnd.timeIntervalSince(secureStart) * 1000
                if tlsMs > 0 { timings.append(String(format: "tls=%.0fms", tlsMs)) }
            }
            if let requestEnd = transaction.requestEndDate, let requestStart = transaction.requestStartDate {
                let requestMs = requestEnd.timeIntervalSince(requestStart) * 1000
                timings.append(String(format: "send=%.0fms", requestMs))
            }
            if let responseEnd = transaction.responseEndDate, let responseStart = transaction.responseStartDate {
                let responseMs = responseEnd.timeIntervalSince(responseStart) * 1000
                timings.append(String(format: "recv=%.0fms", responseMs))
            }
            if let responseEnd = transaction.responseEndDate {
                let totalMs = responseEnd.timeIntervalSince(fetchStart) * 1000
                timings.append(String(format: "TOTAL=%.0fms", totalMs))
            }
        }

        let connType = isReused ? "REUSED" : "NEW-CONN"
        let timingStr = timings.isEmpty ? "no-timing-data" : timings.joined(separator: " ")

        if let err = task.error {
            NSLog("[KNS] [%@] FAIL | %@ %@ | %@:%@ | %@ | err=%@",
                  endpoint, connProto, connType, remoteAddr, remotePort, timingStr, err.localizedDescription)
        } else {
            NSLog("[KNS] [%@] OK | %@ %@ | %@:%@ | %@",
                  endpoint, connProto, connType, remoteAddr, remotePort, timingStr)
        }
    }

    /// Make a request
    private func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        return try await session.data(from: url)
    }

    /// Get the KNS base URL from settings
    private var baseURL: String {
        AppSettings.load().knsBaseURL
    }

    // MARK: - Public API

    /// Get KNS info for an address (from cache or fetch)
    func getInfo(for address: String, network: NetworkType = .mainnet) async -> KNSAddressInfo? {
        // Return cached if available
        if let cached = domainCache[address] {
            return cached
        }

        // Fetch if not already pending
        guard !pendingFetches.contains(address) else { return nil }

        return await fetchInfo(for: address, network: network)
    }

    /// Fetch KNS info for an address (always fetches fresh data)
    func fetchInfo(for address: String, network: NetworkType = .mainnet) async -> KNSAddressInfo? {
        guard !pendingFetches.contains(address) else { return domainCache[address] }

        lastAttemptAt[address] = Date()
        pendingFetches.insert(address)
        defer { pendingFetches.remove(address) }

        let result = await fetchInfoInternal(for: address, network: network)
        if result.hadError {
            failureCounts[address, default: 0] += 1
        } else {
            failureCounts[address] = 0
        }
        return result.info
    }

    /// Fetch KNS info for multiple addresses
    func fetchInfo(for addresses: [String], network: NetworkType = .mainnet) async {
        await withTaskGroup(of: Void.self) { group in
            for address in addresses {
                group.addTask {
                    _ = await self.fetchInfo(for: address, network: network)
                }
            }
        }
    }

    /// Refresh KNS info for multiple addresses if debounce allows it.
    func refreshIfNeeded(for addresses: [String], network: NetworkType = .mainnet) async {
        let now = Date()
        let eligible = addresses.filter { address in
            guard !pendingFetches.contains(address) else { return false }
            guard let last = lastAttemptAt[address] else { return true }
            let failures = failureCounts[address, default: 0]
            let backoff = min(maxBackoffInterval, minRefreshInterval * pow(2.0, Double(failures)))
            return now.timeIntervalSince(last) >= backoff
        }
        guard !eligible.isEmpty else { return }

        var startIndex = 0
        while startIndex < eligible.count {
            let endIndex = min(startIndex + maxConcurrentRefreshes, eligible.count)
            let slice = eligible[startIndex..<endIndex]
            await withTaskGroup(of: Void.self) { group in
                for address in slice {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        _ = await self.fetchInfo(for: address, network: network)
                    }
                }
            }
            startIndex = endIndex
        }
    }

    /// Clear cache for an address
    func clearCache(for address: String) {
        domainCache.removeValue(forKey: address)
        persistCache()
    }

    /// Clear all cache
    func clearAllCache() {
        domainCache.removeAll()
        persistCache()
    }

    // MARK: - Domain Resolution (Forward Lookup)

    /// Resolve a KNS domain name to a Kaspa address
    /// - Parameters:
    ///   - domain: Domain name (e.g., "vsmirnov" or "vsmirnov.kas")
    ///   - network: Network type (mainnet or testnet) - ignored, uses settings
    /// - Returns: KNSDomainResolution with owner address, or nil if not found
    func resolveDomain(_ domain: String, network: NetworkType = .mainnet) async -> KNSDomainResolution? {
        // Ensure domain has .kas suffix
        let fullDomain = domain.lowercased().hasSuffix(".kas") ? domain.lowercased() : "\(domain.lowercased()).kas"

        // URL encode the domain name
        guard let encodedDomain = fullDomain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        guard var components = URLComponents(string: baseURL) else { return nil }
        components.path += "/\(encodedDomain)/owner"
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await fetchData(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            // 404 means domain not found
            if httpResponse.statusCode == 404 {
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                return nil
            }

            let result = try JSONDecoder().decode(KNSDomainOwnerResponse.self, from: data)
            guard result.success,
                  let ownerData = result.data,
                  let ownerAddress = ownerData.owner,
                  ownerData.asset == fullDomain else {
                return nil
            }

            return KNSDomainResolution(
                domain: fullDomain,
                ownerAddress: ownerAddress,
                inscriptionId: ownerData.id
            )
        } catch {
            NSLog("[KNS] Domain resolution error for %@: %@", domain, error.localizedDescription)
            return nil
        }
    }

    /// Check if a string looks like a KNS domain (not a Kaspa address)
    static func looksLikeDomain(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Not a Kaspa address
        if trimmed.hasPrefix("kaspa:") || trimmed.hasPrefix("kaspatest:") {
            return false
        }
        // Has .kas suffix or is a simple name that could be a domain
        if trimmed.hasSuffix(".kas") {
            return true
        }
        // Simple alphanumeric string (potential domain without suffix)
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy { allowedChars.contains($0) }
    }

    // MARK: - Private API calls

    private func fetchPrimaryNameResult(for address: String, baseURL: String) async -> (domain: String?, hadError: Bool) {
        guard var components = URLComponents(string: baseURL) else { return (nil, true) }
        components.path += "/primary-name/\(address)"
        guard let url = components.url else { return (nil, true) }

        do {
            let (data, response) = try await fetchData(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return (nil, true)
            }

            if httpResponse.statusCode == 404 {
                return (nil, false)
            }

            guard httpResponse.statusCode == 200 else {
                return (nil, true)
            }

            let result = try JSONDecoder().decode(KNSPrimaryNameResponse.self, from: data)
            guard result.success, let domainData = result.data?.domain else {
                return (nil, false)
            }

            return (normalizeDomainName(domainData.fullName), false)
        } catch {
            NSLog("[KNS] Primary name fetch error for %@: %@", address, error.localizedDescription)
            return (nil, true)
        }
    }

    private func fetchAllDomains(for address: String, baseURL: String) async -> (domains: [KNSDomain], hadError: Bool) {
        guard var components = URLComponents(string: baseURL) else { return ([], true) }
        components.path += "/assets"
        components.queryItems = [
            URLQueryItem(name: "owner", value: address),
            URLQueryItem(name: "type", value: "domain"),
            URLQueryItem(name: "pageSize", value: "100")
        ]
        guard let url = components.url else { return ([], true) }

        do {
            let (data, response) = try await fetchData(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return ([], true)
            }

            let result = try JSONDecoder().decode(KNSAssetsResponse.self, from: data)
            guard result.success, let assets = result.data?.assets else {
                return ([], false)
            }

            let domains: [KNSDomain] = assets
                .filter { (asset: KNSAsset) in
                    asset.isDomain && asset.isVerifiedDomain
                }
                .compactMap { (asset: KNSAsset) -> KNSDomain? in
                    guard let fullName = normalizeDomainName(asset.asset) else { return nil }
                    return KNSDomain(
                        fullName: fullName,
                        inscriptionId: asset.assetId,
                        createdAt: SharedFormatting.iso8601.date(from: asset.creationBlockTime ?? "") ?? Date.distantPast,
                        isVerified: asset.isVerifiedDomain,
                        status: asset.status ?? "default"
                    )
                }
                .sorted { (lhs: KNSDomain, rhs: KNSDomain) in
                    lhs.createdAt > rhs.createdAt
                }
            return (domains, false)
        } catch {
            NSLog("[KNS] Assets fetch error for %@: %@", address, error.localizedDescription)
            return ([], true)
        }
    }

    private func fetchInfoInternal(for address: String, network: NetworkType) async -> (info: KNSAddressInfo?, hadError: Bool) {
        let (primaryDomain, primaryError) = await fetchPrimaryNameResult(for: address, baseURL: baseURL)
        let (allDomains, assetsError) = await fetchAllDomains(for: address, baseURL: baseURL)
        let hadError = primaryError || assetsError

        if hadError, let cached = domainCache[address] {
            return (cached, true)
        }

        if allDomains.isEmpty && primaryDomain == nil {
            let info = KNSAddressInfo(address: address, primaryDomain: nil, allDomains: [], fetchedAt: Date())
            updateCache(info, address: address)
            return (info, false)
        }

        let finalPrimary = primaryDomain ?? allDomains.first?.fullName
        let info = KNSAddressInfo(
            address: address,
            primaryDomain: finalPrimary,
            allDomains: allDomains,
            fetchedAt: Date()
        )
        updateCache(info, address: address)
        return (info, false)
    }

    private func updateCache(_ info: KNSAddressInfo, address: String) {
        domainCache[address] = info
        persistCache()
    }

    private func normalizeDomainName(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }

        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query])
        }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        guard !value.isEmpty else { return nil }
        if !value.hasSuffix(".kas") {
            value += ".kas"
        }
        return value
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([String: KNSAddressInfo].self, from: data) else {
            return
        }
        var sanitized: [String: KNSAddressInfo] = [:]
        var didChange = false

        for (address, info) in decoded {
            let primary = normalizeDomainName(info.primaryDomain)
            let domains = info.allDomains.compactMap { domain -> KNSDomain? in
                guard let normalized = normalizeDomainName(domain.fullName) else {
                    return nil
                }
                return KNSDomain(
                    fullName: normalized,
                    inscriptionId: domain.inscriptionId,
                    createdAt: domain.createdAt,
                    isVerified: domain.isVerified,
                    status: domain.status
                )
            }
            let finalPrimary = primary ?? domains.first?.fullName
            let cleaned = KNSAddressInfo(
                address: info.address,
                primaryDomain: finalPrimary,
                allDomains: domains,
                fetchedAt: info.fetchedAt
            )
            sanitized[address] = cleaned
            if cleaned != info {
                didChange = true
            }
        }

        domainCache = sanitized
        if didChange {
            persistCache()
        }
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(domainCache) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

// MARK: - Models

struct KNSAddressInfo: Equatable, Codable {
    let address: String
    let primaryDomain: String?
    let allDomains: [KNSDomain]
    let fetchedAt: Date

    /// Display name - primary domain without .kas suffix, or nil
    var displayName: String? {
        guard let domain = primaryDomain else { return nil }
        if domain.hasSuffix(".kas") {
            return String(domain.dropLast(4))
        }
        return domain
    }
}

struct KNSDomain: Equatable, Codable {
    let fullName: String  // e.g. "vsmirnov.kas"
    let inscriptionId: String
    let createdAt: Date
    let isVerified: Bool
    let status: String

    /// Domain name without .kas suffix
    var name: String {
        if fullName.hasSuffix(".kas") {
            return String(fullName.dropLast(4))
        }
        return fullName
    }
}

/// Result of resolving a KNS domain to an address
struct KNSDomainResolution: Equatable {
    let domain: String        // e.g. "vsmirnov.kas"
    let ownerAddress: String  // Kaspa address
    let inscriptionId: String?
}

// MARK: - API Response Models

private struct KNSDomainOwnerResponse: Codable {
    let success: Bool
    let data: KNSDomainOwnerData?
    let message: String?
    let error: String?
}

private struct KNSDomainOwnerData: Codable {
    let asset: String?
    let owner: String?
    let id: String?
}

private struct KNSPrimaryNameResponse: Codable {
    let success: Bool
    let data: KNSPrimaryNameData?
    let message: String?
    let error: String?
}

private struct KNSPrimaryNameData: Codable {
    let ownerAddress: String?
    let inscriptionId: String?
    let domain: KNSPrimaryNameDomain?
}

private struct KNSPrimaryNameDomain: Codable {
    let name: String?
    let tld: String?
    let fullName: String?
    let isVerified: Bool?
    let status: String?
}

private struct KNSAssetsResponse: Codable {
    let success: Bool
    let data: KNSAssetsData?
    let message: String?
    let error: String?
}

private struct KNSAssetsData: Codable {
    let assets: [KNSAsset]?
    let pagination: KNSPagination?
}

private struct KNSAsset: Codable {
    let id: String?
    let assetId: String
    let mimeType: String?
    let asset: String  // domain name like "vsmirnov.kas"
    let owner: String?
    let creationBlockTime: String?
    let isDomain: Bool
    let isVerifiedDomain: Bool
    let status: String?
    let transactionId: String?
}

private struct KNSPagination: Codable {
    let currentPage: Int?
    let pageSize: Int?
    let totalItems: Int?
    let totalPages: Int?
}
