import Foundation

/// Kaspa Name Service (KNS) API client for resolving domain names
@MainActor
final class KNSService: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = KNSService()

    /// Cache of domains by address
    @Published private(set) var domainCache: [String: KNSAddressInfo] = [:]
    /// Cache of selected KNS profiles by address (primary domain if available)
    @Published private(set) var profileCache: [String: KNSAddressProfileInfo] = [:]

    /// Addresses currently being fetched
    private var pendingFetches: Set<String> = []
    private var pendingProfileFetches: Set<String> = []
    private var lastAttemptAt: [String: Date] = [:]
    private var lastProfileAttemptAt: [String: Date] = [:]
    private var failureCounts: [String: Int] = [:]
    private var profileFailureCounts: [String: Int] = [:]

    private let cacheKey = "kachat_kns_domain_cache_v1"
    private let profileCacheKey = "kachat_kns_profile_cache_v1"
    private let minRefreshInterval: TimeInterval = 10 * 60
    private let maxBackoffInterval: TimeInterval = 6 * 60 * 60
    private let maxConcurrentRefreshes = 4
    private let maxConcurrentProfileRefreshes = 3

    private var session: URLSession!

    private override init() {
        super.init()
        loadCache()
        loadProfileCache()
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
        profileCache.removeValue(forKey: address)
        persistCache()
        persistProfileCache()
    }

    /// Clear all cache
    func clearAllCache() {
        domainCache.removeAll()
        profileCache.removeAll()
        persistCache()
        persistProfileCache()
    }

    /// Get cached/fetched KNS profile for an address.
    func getProfile(for address: String, network: NetworkType = .mainnet) async -> KNSAddressProfileInfo? {
        if let cached = profileCache[address] {
            return cached
        }
        guard !pendingProfileFetches.contains(address) else { return nil }
        return await fetchProfile(for: address, network: network)
    }

    /// Fetch KNS profile for an address.
    func fetchProfile(for address: String, network: NetworkType = .mainnet) async -> KNSAddressProfileInfo? {
        guard !pendingProfileFetches.contains(address) else { return profileCache[address] }

        lastProfileAttemptAt[address] = Date()
        pendingProfileFetches.insert(address)
        defer { pendingProfileFetches.remove(address) }

        let result = await fetchProfileInternal(for: address, network: network)
        if result.hadError {
            profileFailureCounts[address, default: 0] += 1
        } else {
            profileFailureCounts[address] = 0
        }
        return result.info
    }

    /// Refresh KNS profiles for multiple addresses if debounce allows it.
    func refreshProfilesIfNeeded(for addresses: [String], network: NetworkType = .mainnet) async {
        let now = Date()
        let eligible = addresses.filter { address in
            guard !pendingProfileFetches.contains(address) else { return false }
            guard let last = lastProfileAttemptAt[address] else { return true }
            let failures = profileFailureCounts[address, default: 0]
            let backoff = min(maxBackoffInterval, minRefreshInterval * pow(2.0, Double(failures)))
            return now.timeIntervalSince(last) >= backoff
        }
        guard !eligible.isEmpty else { return }

        var startIndex = 0
        while startIndex < eligible.count {
            let endIndex = min(startIndex + maxConcurrentProfileRefreshes, eligible.count)
            let slice = eligible[startIndex..<endIndex]
            await withTaskGroup(of: Void.self) { group in
                for address in slice {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        _ = await self.fetchProfile(for: address, network: network)
                    }
                }
            }
            startIndex = endIndex
        }
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

    private func fetchDomainProfileResult(
        assetId: String,
        baseURL: String,
        keys: [String]? = nil
    ) async -> (profileData: KNSDomainProfileData?, hadError: Bool) {
        guard var components = URLComponents(string: baseURL) else { return (nil, true) }
        components.path += "/domain/\(assetId)/profile"
        if let keys, !keys.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "keys", value: keys.joined(separator: ","))
            ]
        }
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

            let result = try JSONDecoder().decode(KNSDomainProfileResponse.self, from: data)
            guard result.success else {
                return (nil, false)
            }
            return (result.data, false)
        } catch {
            NSLog("[KNS] Domain profile fetch error for %@: %@", assetId, error.localizedDescription)
            return (nil, true)
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

    private func fetchProfileInternal(for address: String, network: NetworkType) async -> (info: KNSAddressProfileInfo?, hadError: Bool) {
        var domainInfo = domainCache[address]
        if domainInfo == nil {
            domainInfo = await fetchInfo(for: address, network: network)
        }
        let selectedDomain: KNSDomain? = {
            guard let domainInfo else { return nil }
            if let primary = domainInfo.primaryDomain {
                if let matched = domainInfo.allDomains.first(where: { $0.fullName == primary }) {
                    return matched
                }
            }
            return domainInfo.allDomains.first
        }()

        guard let selectedDomain else {
            let info = KNSAddressProfileInfo(
                address: address,
                domainName: nil,
                assetId: nil,
                profile: nil,
                fetchedAt: Date()
            )
            updateProfileCache(info, address: address)
            return (info, false)
        }

        let (profileData, profileError) = await fetchDomainProfileResult(
            assetId: selectedDomain.inscriptionId,
            baseURL: baseURL
        )

        if profileError, let cached = profileCache[address] {
            return (cached, true)
        }

        let profile = profileData?.profile?.toModel()
        let info = KNSAddressProfileInfo(
            address: address,
            domainName: profileData?.fullName ?? selectedDomain.fullName,
            assetId: selectedDomain.inscriptionId,
            profile: profile,
            fetchedAt: Date()
        )
        updateProfileCache(info, address: address)
        return (info, false)
    }

    private func updateProfileCache(_ info: KNSAddressProfileInfo, address: String) {
        profileCache[address] = info
        persistProfileCache()
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

    private func loadProfileCache() {
        guard let data = UserDefaults.standard.data(forKey: profileCacheKey),
              let decoded = try? JSONDecoder().decode([String: KNSAddressProfileInfo].self, from: data) else {
            return
        }

        var sanitized: [String: KNSAddressProfileInfo] = [:]
        for (address, info) in decoded {
            sanitized[address] = info.sanitized()
        }
        profileCache = sanitized
    }

    private func persistProfileCache() {
        guard let data = try? JSONEncoder().encode(profileCache) else { return }
        UserDefaults.standard.set(data, forKey: profileCacheKey)
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

struct KNSAddressProfileInfo: Equatable, Codable {
    let address: String
    let domainName: String?
    let assetId: String?
    let profile: KNSDomainProfile?
    let fetchedAt: Date

    var avatarURL: String? {
        profile?.avatarUrl
    }

    fileprivate func sanitized() -> KNSAddressProfileInfo {
        KNSAddressProfileInfo(
            address: address,
            domainName: domainName?.trimmingCharacters(in: .whitespacesAndNewlines),
            assetId: assetId?.trimmingCharacters(in: .whitespacesAndNewlines),
            profile: profile?.sanitized(),
            fetchedAt: fetchedAt
        )
    }
}

struct KNSDomainProfile: Equatable, Codable {
    let avatarUrl: String?
    let redirectUrl: String?
    let bio: String?
    let x: String?
    let website: String?
    let telegram: String?
    let discord: String?
    let contactEmail: String?
    let bannerUrl: String?
    let github: String?

    var hasAnyField: Bool {
        [avatarUrl, redirectUrl, bio, x, website, telegram, discord, contactEmail, bannerUrl, github]
            .contains { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    fileprivate func sanitized() -> KNSDomainProfile {
        KNSDomainProfile(
            avatarUrl: sanitizeValue(avatarUrl),
            redirectUrl: sanitizeValue(redirectUrl),
            bio: sanitizeValue(bio),
            x: sanitizeValue(x),
            website: sanitizeValue(website),
            telegram: sanitizeValue(telegram),
            discord: sanitizeValue(discord),
            contactEmail: sanitizeValue(contactEmail),
            bannerUrl: sanitizeValue(bannerUrl),
            github: sanitizeValue(github)
        )
    }

    private func sanitizeValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

private struct KNSDomainProfileResponse: Codable {
    let success: Bool
    let data: KNSDomainProfileData?
    let message: String?
    let error: String?
}

private struct KNSDomainProfileData: Codable {
    let assetId: String?
    let owner: String?
    let name: String?
    let tld: String?
    let profile: KNSDomainProfilePayload?

    var fullName: String? {
        guard let name, !name.isEmpty else { return nil }
        guard let tld, !tld.isEmpty else { return name }
        return "\(name).\(tld)".lowercased()
    }
}

private struct KNSDomainProfilePayload: Codable {
    let avatarUrl: String?
    let redirectUrl: String?
    let bio: String?
    let x: String?
    let website: String?
    let telegram: String?
    let discord: String?
    let contactEmail: String?
    let bannerUrl: String?
    let github: String?

    func toModel() -> KNSDomainProfile {
        KNSDomainProfile(
            avatarUrl: avatarUrl,
            redirectUrl: redirectUrl,
            bio: bio,
            x: x,
            website: website,
            telegram: telegram,
            discord: discord,
            contactEmail: contactEmail,
            bannerUrl: bannerUrl,
            github: github
        ).sanitized()
    }
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
