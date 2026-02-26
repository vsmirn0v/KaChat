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

    /// Make a request with a configured URLRequest.
    private func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        return try await session.data(for: request)
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

    /// Normalize user input to a KNS label (without `.kas`) for inscription.
    /// Returns nil when value is empty or has unsupported characters.
    func normalizeDomainLabel(_ raw: String) -> String? {
        var value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }
        if value.hasSuffix(".kas") {
            value = String(value.dropLast(4))
        }
        guard !value.isEmpty else { return nil }
        guard !value.hasPrefix("-"), !value.hasSuffix("-") else { return nil }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return value
    }

    /// Fetch KNS inscription fee tiers in KAS units.
    /// Tier keys: 1...5 where 5 means "5+ chars".
    func fetchInscribeFeeTiers() async throws -> [Int: Decimal] {
        guard var components = URLComponents(string: baseURL) else {
            throw KasiaError.networkError("Invalid KNS base URL")
        }
        components.path += "/fee"
        guard let url = components.url else {
            throw KasiaError.networkError("Invalid KNS fee URL")
        }

        let (data, response) = try await fetchData(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw KasiaError.networkError("No HTTP response from KNS fee endpoint")
        }
        guard http.statusCode == 200 else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw KasiaError.networkError("KNS fee fetch failed (\(http.statusCode)): \(responseText)")
        }

        let decoded = try JSONDecoder().decode(KNSInscribeFeeResponse.self, from: data)
        guard decoded.success else {
            throw KasiaError.apiError(decoded.error ?? decoded.message ?? "KNS fee fetch failed")
        }
        guard let rawFeeMap = decoded.data?.fee, !rawFeeMap.isEmpty else {
            throw KasiaError.apiError("KNS fee response is missing tier data")
        }

        var mapped: [Int: Decimal] = [:]
        for (key, value) in rawFeeMap {
            guard let tier = Int(key), tier > 0 else { continue }
            mapped[tier] = value
        }
        guard !mapped.isEmpty else {
            throw KasiaError.apiError("KNS fee response has invalid tier data")
        }
        return mapped
    }

    /// Check whether a domain is available for inscription.
    /// - Parameters:
    ///   - address: wallet address used by KNS backend checks
    ///   - domainName: full domain (with or without `.kas`)
    func checkDomainAvailability(
        address: String,
        domainName: String
    ) async throws -> KNSDomainAvailability {
        guard let normalized = normalizeDomainName(domainName) else {
            throw KasiaError.apiError("Invalid domain name")
        }

        guard var components = URLComponents(string: baseURL) else {
            throw KasiaError.networkError("Invalid KNS base URL")
        }
        components.path += "/domains/check"
        guard let url = components.url else {
            throw KasiaError.networkError("Invalid KNS domain check URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            KNSDomainCheckRequest(
                address: address,
                domainNames: [normalized]
            )
        )

        let (data, response) = try await fetchData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KasiaError.networkError("No HTTP response from KNS domain check endpoint")
        }
        guard http.statusCode == 200 else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw KasiaError.networkError("KNS domain check failed (\(http.statusCode)): \(responseText)")
        }

        let decoded = try JSONDecoder().decode(KNSDomainCheckResponse.self, from: data)
        guard decoded.success else {
            throw KasiaError.apiError(decoded.error ?? decoded.message ?? "KNS domain check failed")
        }
        guard let domains = decoded.data?.domains, !domains.isEmpty else {
            throw KasiaError.apiError("KNS domain check response is empty")
        }
        let matched = domains.first(where: { $0.domain.lowercased() == normalized }) ?? domains[0]
        return KNSDomainAvailability(
            domain: matched.domain.lowercased(),
            available: matched.available,
            isReservedDomain: matched.isReservedDomain
        )
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

    /// Resolve domain full name from domain asset id.
    func resolveDomainName(assetId: String) async -> String? {
        let trimmedAssetId = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAssetId.isEmpty else { return nil }

        for info in domainCache.values {
            if let matched = info.allDomains.first(where: { $0.inscriptionId == trimmedAssetId }) {
                return matched.fullName
            }
        }

        let (profileData, _) = await fetchDomainProfileResult(
            assetId: trimmedAssetId,
            baseURL: baseURL,
            keys: nil
        )
        guard let profileData,
              let fullName = profileData.fullName else {
            return nil
        }
        return normalizeDomainName(fullName)
    }

    // MARK: - Phase 2 Write Primitives

    /// Build canonical `addProfile` inscription operation payload.
    func buildAddProfilePayload(
        assetId: String,
        key: KNSProfileFieldKey,
        value: String
    ) -> KNSAddProfilePayload {
        KNSAddProfilePayload(
            op: "addProfile",
            id: assetId,
            key: key.rawValue,
            value: value
        )
    }

    /// Build canonical `transfer` payload for domain asset transfer.
    func buildTransferDomainPayload(
        assetId: String,
        toAddress: String
    ) -> KNSTransferDomainPayload {
        KNSTransferDomainPayload(
            op: "transfer",
            p: "domain",
            id: assetId,
            to: toAddress
        )
    }

    /// Build the message string that must be signed for image upload authorization.
    func buildImageUploadSigningMessage(
        assetId: String,
        uploadType: KNSProfileImageUploadType
    ) throws -> String {
        let trimmedAssetId = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAssetId.isEmpty else {
            throw KasiaError.apiError("Missing KNS asset id")
        }
        // Match app.knsdomains.org payload bytes exactly.
        return #"{"assetId":"\#(trimmedAssetId)","uploadType":"\#(uploadType.rawValue)"}"#
    }

    /// Build the message string that must be signed to set domain as primary.
    func buildPrimaryNameSigningMessage(
        domainId: String,
        timestampMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) throws -> String {
        let trimmedDomainId = domainId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomainId.isEmpty else {
            throw KasiaError.apiError("Missing KNS domain id")
        }
        // Match app.knsdomains.org payload bytes exactly.
        return #"{"domainId":"\#(trimmedDomainId)","timestamp":\#(timestampMs)}"#
    }

    /// Set primary KNS domain for the signed wallet.
    @discardableResult
    func setPrimaryDomain(
        signMessage: String,
        signature: String
    ) async throws -> Bool {
        let trimmedSignMessage = signMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSignMessage.isEmpty else {
            throw KasiaError.apiError("Missing signed message payload")
        }
        let trimmedSignature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSignature.isEmpty else {
            throw KasiaError.apiError("Missing signature")
        }

        guard var components = URLComponents(string: baseURL) else {
            throw KasiaError.networkError("Invalid KNS base URL")
        }
        components.path += "/domain/primary-name"
        guard let url = components.url else {
            throw KasiaError.networkError("Invalid KNS primary domain URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            KNSSetPrimaryNameRequest(
                signMessage: trimmedSignMessage,
                signature: trimmedSignature
            )
        )

        let (data, response) = try await fetchData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KasiaError.networkError("No HTTP response from KNS primary domain endpoint")
        }
        guard http.statusCode == 200 else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw KasiaError.networkError("KNS set primary failed (\(http.statusCode)): \(responseText)")
        }

        let decoded = try JSONDecoder().decode(KNSBasicAPIResponse.self, from: data)
        guard decoded.success else {
            throw KasiaError.apiError(decoded.error ?? decoded.message ?? "KNS set primary failed")
        }
        return true
    }

    /// Upload avatar/banner image to KNS storage.
    /// Returns image URL that should be written on-chain via `addProfile` (`avatarUrl`/`bannerUrl`).
    func uploadProfileImage(
        assetId: String,
        uploadType: KNSProfileImageUploadType,
        imageData: Data,
        mimeType: String,
        signMessage: String,
        signature: String
    ) async throws -> String {
        guard !assetId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KasiaError.apiError("Missing KNS asset id")
        }
        guard !signMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KasiaError.apiError("Missing signed message payload")
        }
        guard !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KasiaError.apiError("Missing signature")
        }
        guard !imageData.isEmpty else {
            throw KasiaError.apiError("Image data is empty")
        }

        guard var components = URLComponents(string: baseURL) else {
            throw KasiaError.networkError("Invalid KNS base URL")
        }
        components.path += "/upload/image"
        guard let url = components.url else {
            throw KasiaError.networkError("Invalid KNS upload URL")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendMultipartField("signMessage", value: signMessage, boundary: boundary, body: &body)
        appendMultipartField("signature", value: signature, boundary: boundary, body: &body)

        let fileExt = fileExtension(for: mimeType)
        let fileName = "\(uploadType.rawValue)-\(assetId).\(fileExt)"
        appendMultipartFile(
            "image",
            fileName: fileName,
            mimeType: mimeType,
            data: imageData,
            boundary: boundary,
            body: &body
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())
        request.httpBody = body

        let (data, response) = try await fetchData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KasiaError.networkError("No HTTP response from KNS upload")
        }
        guard http.statusCode == 200 else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw KasiaError.networkError("KNS upload failed (\(http.statusCode)): \(responseText)")
        }

        let decoded = try JSONDecoder().decode(KNSImageUploadResponse.self, from: data)
        guard decoded.success else {
            throw KasiaError.apiError(decoded.error ?? decoded.message ?? "KNS upload failed")
        }
        guard let imageURL = decoded.data?.resolvedImageURL,
              !imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KasiaError.apiError("KNS upload response missing image URL")
        }
        return imageURL
    }

    /// Poll profile endpoint until the specific field value matches expected value.
    func pollProfileField(
        assetId: String,
        key: KNSProfileFieldKey,
        expectedValue: String,
        timeout: TimeInterval = 60,
        pollInterval: TimeInterval = 2
    ) async -> Bool {
        let expected = expectedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectsClear = expected.isEmpty
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let (profileData, _) = await fetchDomainProfileResult(
                assetId: assetId,
                baseURL: baseURL,
                keys: [key.rawValue]
            )
            if let profile = profileData?.profile?.toModel() {
                let current = profile.value(for: key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if expectsClear {
                    if current.isEmpty {
                        return true
                    }
                } else if current == expected {
                    return true
                }
            }
            let nanos = UInt64(max(0.1, pollInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }

        return false
    }

    /// Verify field update by polling indexer and patch local cache on success.
    @discardableResult
    func verifyAndApplyProfileField(
        address: String,
        assetId: String,
        domainName: String?,
        key: KNSProfileFieldKey,
        expectedValue: String,
        timeout: TimeInterval = 60
    ) async -> Bool {
        let verified = await pollProfileField(
            assetId: assetId,
            key: key,
            expectedValue: expectedValue,
            timeout: timeout
        )
        guard verified else { return false }

        applyProfileFieldToCache(
            address: address,
            assetId: assetId,
            domainName: domainName,
            key: key,
            value: expectedValue
        )
        return true
    }

    /// Patch a single KNS profile field in local cache.
    func applyProfileFieldToCache(
        address: String,
        assetId: String,
        domainName: String?,
        key: KNSProfileFieldKey,
        value: String
    ) {
        let normalized = normalizeProfileFieldValue(value)

        let existing = profileCache[address]
        let updatedProfile = (existing?.profile ?? KNSDomainProfile.empty)
            .withValue(normalized, for: key)
            .sanitized()

        let info = KNSAddressProfileInfo(
            address: address,
            domainName: domainName ?? existing?.domainName,
            assetId: assetId,
            profile: updatedProfile,
            fetchedAt: Date()
        )
        updateProfileCache(info, address: address)
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

    private func fetchPrimaryNameResult(
        for address: String,
        baseURL: String
    ) async -> (domain: String?, inscriptionId: String?, hadError: Bool) {
        guard var components = URLComponents(string: baseURL) else { return (nil, nil, true) }
        components.path += "/primary-name/\(address)"
        guard let url = components.url else { return (nil, nil, true) }

        do {
            let (data, response) = try await fetchData(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                return (nil, nil, true)
            }

            if httpResponse.statusCode == 404 {
                return (nil, nil, false)
            }

            guard httpResponse.statusCode == 200 else {
                return (nil, nil, true)
            }

            let result = try JSONDecoder().decode(KNSPrimaryNameResponse.self, from: data)
            guard result.success, let domainData = result.data?.domain else {
                return (nil, nil, false)
            }

            let normalizedDomain = normalizeDomainName(domainData.fullName)
            let inscriptionId = result.data?.inscriptionId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (normalizedDomain, inscriptionId?.isEmpty == false ? inscriptionId : nil, false)
        } catch {
            NSLog("[KNS] Primary name fetch error for %@: %@", address, error.localizedDescription)
            return (nil, nil, true)
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
        let (primaryDomain, primaryInscriptionId, primaryError) = await fetchPrimaryNameResult(
            for: address,
            baseURL: baseURL
        )
        let (allDomains, assetsError) = await fetchAllDomains(for: address, baseURL: baseURL)
        let hadError = primaryError || assetsError

        if hadError, let cached = domainCache[address] {
            return (cached, true)
        }

        if allDomains.isEmpty && primaryDomain == nil {
            let info = KNSAddressInfo(
                address: address,
                primaryDomain: nil,
                primaryInscriptionId: nil,
                allDomains: [],
                fetchedAt: Date()
            )
            updateCache(info, address: address)
            return (info, false)
        }

        let finalPrimary = primaryDomain ?? allDomains.first?.fullName
        var finalPrimaryInscriptionId = primaryInscriptionId
        if finalPrimaryInscriptionId == nil, let finalPrimary {
            finalPrimaryInscriptionId = allDomains.first(where: { $0.fullName == finalPrimary })?.inscriptionId
        }
        let info = KNSAddressInfo(
            address: address,
            primaryDomain: finalPrimary,
            primaryInscriptionId: finalPrimaryInscriptionId,
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
        let selectedProfileTarget: (assetId: String, domainName: String?)? = {
            guard let domainInfo else { return nil }
            if let primaryAssetId = domainInfo.primaryInscriptionId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !primaryAssetId.isEmpty {
                if let matched = domainInfo.allDomains.first(where: { $0.inscriptionId == primaryAssetId }) {
                    return (matched.inscriptionId, matched.fullName)
                }
                return (primaryAssetId, domainInfo.primaryDomain)
            }
            if let primary = domainInfo.primaryDomain,
               let matched = domainInfo.allDomains.first(where: { $0.fullName == primary }) {
                return (matched.inscriptionId, matched.fullName)
            }
            if let first = domainInfo.allDomains.first {
                return (first.inscriptionId, first.fullName)
            }
            return nil
        }()

        guard let selectedProfileTarget else {
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
            assetId: selectedProfileTarget.assetId,
            baseURL: baseURL
        )

        if profileError, let cached = profileCache[address] {
            return (cached, true)
        }

        let profile = profileData?.profile?.toModel()
        let info = KNSAddressProfileInfo(
            address: address,
            domainName: profileData?.fullName ?? selectedProfileTarget.domainName,
            assetId: selectedProfileTarget.assetId,
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

    private func normalizeProfileFieldValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func appendMultipartField(_ name: String, value: String, boundary: String, body: inout Data) {
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(value)\r\n".data(using: .utf8) ?? Data())
    }

    private func appendMultipartFile(
        _ name: String,
        fileName: String,
        mimeType: String,
        data: Data,
        boundary: String,
        body: inout Data
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8) ?? Data())
        body.append(data)
        body.append("\r\n".data(using: .utf8) ?? Data())
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "bin"
        }
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
            let primaryInscriptionId = info.primaryInscriptionId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
            var finalPrimaryInscriptionId = primaryInscriptionId?.isEmpty == false ? primaryInscriptionId : nil
            if finalPrimaryInscriptionId == nil, let finalPrimary {
                finalPrimaryInscriptionId = domains.first(where: { $0.fullName == finalPrimary })?.inscriptionId
            }
            let cleaned = KNSAddressInfo(
                address: info.address,
                primaryDomain: finalPrimary,
                primaryInscriptionId: finalPrimaryInscriptionId,
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

@MainActor
final class KNSProfileWriteService: ObservableObject {
    static let shared = KNSProfileWriteService()

    @Published private(set) var inFlightOperation: KNSProfileUpdateOperation?

    private let knsService = KNSService.shared
    private let nodePool = NodePoolService.shared

    private init() {}

    private func log(_ message: String) {
        NSLog("[KNS_WRITE] %@", message)
    }

    private func diagnosticError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = [
            "type=\(String(describing: type(of: error)))",
            "message=\(error.localizedDescription)",
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]

        if let reason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if let suggestion = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String, !suggestion.isEmpty {
            parts.append("suggestion=\(suggestion)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)#\(underlying.code):\(underlying.localizedDescription)")
        }

        return parts.joined(separator: " | ")
    }

    /// Submit KNS `addProfile` commit-reveal transaction pair and verify indexing.
    @discardableResult
    func submitAddProfile(
        assetId: String,
        key: KNSProfileFieldKey,
        value: String,
        domainName: String? = nil
    ) async throws -> KNSCommitRevealResult {
        let trimmedAssetId = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAssetId.isEmpty else {
            throw KasiaError.apiError("Missing KNS asset id")
        }
        guard inFlightOperation == nil else {
            throw KasiaError.apiError("Another KNS profile update is already running")
        }

        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        var operation = KNSProfileUpdateOperation(
            id: UUID(),
            address: wallet.publicAddress,
            assetId: trimmedAssetId,
            fieldKey: key,
            value: value,
            status: .queued,
            commitTxId: nil,
            revealTxId: nil,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        inFlightOperation = operation

        do {
            log("START field=\(key.rawValue) valueLen=\(trimmedValue.count) asset=\(trimmedAssetId)")
            operation.status = .submittingCommit
            operation.updatedAt = Date()
            inFlightOperation = operation

            let addProfilePayload = knsService.buildAddProfilePayload(
                assetId: trimmedAssetId,
                key: key,
                value: trimmedValue
            )
            let payloadJSON = try JSONEncoder().encode(addProfilePayload)
            log("PAYLOAD field=\(key.rawValue) jsonBytes=\(payloadJSON.count)")

            let fetchedUtxos = try await nodePool.getUtxosByAddresses([wallet.publicAddress])
            let utxos = fetchedUtxos.filter { !$0.isCoinbase && $0.blockDaaScore > 0 }
            let totalSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
            log("UTXO field=\(key.rawValue) total=\(fetchedUtxos.count) spendable=\(utxos.count) sumSompi=\(totalSompi)")
            guard !utxos.isEmpty else {
                throw KasiaError.networkError("No spendable UTXOs available for KNS update")
            }

            let (commitTx, commitContext) = try KasiaTransactionBuilder.buildKNSAddProfileCommitTx(
                from: wallet.publicAddress,
                senderPrivateKey: privateKey,
                payloadJSON: payloadJSON,
                utxos: utxos
            )
            log("COMMIT_BUILT field=\(key.rawValue) commitAmount=\(commitContext.commitAmountSompi) revealAmount=\(commitContext.revealAmountSompi)")
            let (commitTxId, _) = try await nodePool.submitTransaction(commitTx, allowOrphan: false)
            log("COMMIT_SUBMITTED field=\(key.rawValue) txId=\(commitTxId)")
            ChatService.shared.registerSuppressedPaymentTxIds(
                [commitTxId],
                reason: "kns-profile-commit"
            )

            operation.commitTxId = commitTxId
            operation.status = .submittingReveal
            operation.updatedAt = Date()
            inFlightOperation = operation

            let revealTx = try KasiaTransactionBuilder.buildKNSAddProfileRevealTx(
                walletAddress: wallet.publicAddress,
                senderPrivateKey: privateKey,
                commitTxId: commitTxId,
                commitContext: commitContext,
                revealTargetAddress: wallet.publicAddress
            )
            let (revealTxId, _) = try await submitRevealWithFallback(revealTx)
            log("REVEAL_SUBMITTED field=\(key.rawValue) txId=\(revealTxId)")
            ChatService.shared.registerSuppressedPaymentTxIds(
                [commitTxId, revealTxId],
                reason: "kns-profile-reveal"
            )

            operation.revealTxId = revealTxId
            operation.status = .verifying
            operation.updatedAt = Date()
            inFlightOperation = operation

            let verified = await knsService.verifyAndApplyProfileField(
                address: wallet.publicAddress,
                assetId: trimmedAssetId,
                domainName: domainName,
                key: key,
                expectedValue: trimmedValue,
                timeout: 90
            )
            guard verified else {
                log("VERIFY_TIMEOUT field=\(key.rawValue) commitTx=\(commitTxId) revealTx=\(revealTxId)")
                throw KasiaError.apiError("KNS profile update was submitted but verification timed out")
            }

            operation.status = .success
            operation.updatedAt = Date()
            inFlightOperation = nil
            log("SUCCESS field=\(key.rawValue) commitTx=\(commitTxId) revealTx=\(revealTxId)")

            return KNSCommitRevealResult(commitTxId: commitTxId, revealTxId: revealTxId)
        } catch {
            let details = diagnosticError(error)
            operation.status = .failed
            operation.errorMessage = details
            operation.updatedAt = Date()
            inFlightOperation = nil
            log("FAIL field=\(key.rawValue) \(details)")
            throw error
        }
    }

    private func submitRevealWithFallback(_ revealTx: KaspaRpcTransaction) async throws -> (txId: String, endpoint: String) {
        do {
            return try await nodePool.submitTransaction(revealTx, allowOrphan: false)
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("orphan") {
                log("REVEAL_RETRY allowOrphan=true reason=\(error.localizedDescription)")
                return try await nodePool.submitTransaction(revealTx, allowOrphan: true)
            }
            throw error
        }
    }
}

@MainActor
final class KNSDomainInscribeService: ObservableObject {
    static let shared = KNSDomainInscribeService()

    @Published private(set) var isSubmitting = false

    private let knsService = KNSService.shared
    private let nodePool = NodePoolService.shared
    private let walletManager = WalletManager.shared

    private static let mainnetRevenueAddress = "kaspa:qyp4nvaq3pdq7609z09fvdgwtc9c7rg07fuw5zgeee7xpr085de59eseqfcmynn"

    private init() {}

    private func log(_ message: String) {
        NSLog("[KNS_INSCRIBE] %@", message)
    }

    @discardableResult
    func inscribeDomain(label rawLabel: String) async throws -> KNSDomainInscribeResult {
        guard !isSubmitting else {
            throw KasiaError.apiError("Another KNS domain inscription is already running")
        }
        guard let wallet = walletManager.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = walletManager.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }
        guard let label = knsService.normalizeDomainLabel(rawLabel) else {
            throw KasiaError.apiError("Invalid domain label")
        }

        let fullDomain = "\(label).kas"
        log("START domain=\(fullDomain) address=\(wallet.publicAddress)")
        isSubmitting = true
        defer { isSubmitting = false }

        let availability = try await knsService.checkDomainAvailability(
            address: wallet.publicAddress,
            domainName: fullDomain
        )
        guard availability.available else {
            throw KasiaError.apiError("Domain \(fullDomain) is not available")
        }

        let feeTiers = try await knsService.fetchInscribeFeeTiers()
        let revealKas = try revealAmountKas(label: label, isReservedDomain: availability.isReservedDomain, feeTiers: feeTiers)
        let commitKas = commitAmountKas(for: revealKas)
        let revealSompi = try kasToSompi(revealKas)
        let commitSompi = try kasToSompi(commitKas)
        log("AMOUNTS domain=\(fullDomain) revealKas=\(revealKas) commitKas=\(commitKas) revealSompi=\(revealSompi) commitSompi=\(commitSompi)")

        let payload = KNSCreateDomainPayload(op: "create", p: "domain", v: label)
        let payloadJSON = try JSONEncoder().encode(payload)

        let fetchedUtxos = try await nodePool.getUtxosByAddresses([wallet.publicAddress])
        let utxos = fetchedUtxos.filter { !$0.isCoinbase && $0.blockDaaScore > 0 }
        guard !utxos.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs available for KNS inscription")
        }
        log("UTXO domain=\(fullDomain) total=\(fetchedUtxos.count) spendable=\(utxos.count)")

        let (commitTx, commitContext) = try KasiaTransactionBuilder.buildKNSAddProfileCommitTx(
            from: wallet.publicAddress,
            senderPrivateKey: privateKey,
            payloadJSON: payloadJSON,
            utxos: utxos,
            title: "kns",
            commitAmountSompi: commitSompi,
            revealAmountSompi: revealSompi
        )
        let (commitTxId, _) = try await nodePool.submitTransaction(commitTx, allowOrphan: false)
        log("COMMIT_SUBMITTED domain=\(fullDomain) txId=\(commitTxId)")
        ChatService.shared.registerSuppressedPaymentTxIds(
            [commitTxId],
            reason: "kns-inscribe-commit"
        )

        let revealTarget = try revealTargetAddress(
            walletAddress: wallet.publicAddress,
            isReservedDomain: availability.isReservedDomain
        )
        let revealTx = try KasiaTransactionBuilder.buildKNSAddProfileRevealTx(
            walletAddress: wallet.publicAddress,
            senderPrivateKey: privateKey,
            commitTxId: commitTxId,
            commitContext: commitContext,
            revealTargetAddress: revealTarget
        )
        let (revealTxId, _) = try await submitRevealWithFallback(revealTx)
        log("REVEAL_SUBMITTED domain=\(fullDomain) txId=\(revealTxId)")
        ChatService.shared.registerSuppressedPaymentTxIds(
            [commitTxId, revealTxId],
            reason: "kns-inscribe-reveal"
        )

        let verified = await verifyDomainOwnership(
            fullDomain: fullDomain,
            expectedOwnerAddress: wallet.publicAddress
        )
        log("VERIFY domain=\(fullDomain) verified=\(verified)")

        _ = await knsService.fetchInfo(for: wallet.publicAddress)
        _ = await knsService.fetchProfile(for: wallet.publicAddress)

        return KNSDomainInscribeResult(
            domain: fullDomain,
            isReservedDomain: availability.isReservedDomain,
            serviceFeeSompi: revealSompi,
            commitTxId: commitTxId,
            revealTxId: revealTxId,
            verified: verified
        )
    }

    private func revealTargetAddress(walletAddress: String, isReservedDomain: Bool) throws -> String {
        if isReservedDomain {
            return walletAddress
        }
        switch AppSettings.load().networkType {
        case .mainnet:
            return Self.mainnetRevenueAddress
        case .testnet:
            throw KasiaError.apiError("KNS domain inscription revenue address is not configured for testnet")
        }
    }

    private func revealAmountKas(
        label: String,
        isReservedDomain: Bool,
        feeTiers: [Int: Decimal]
    ) throws -> Decimal {
        if isReservedDomain {
            return 0
        }
        let tier = min(max(label.count, 1), 5)
        if let fee = feeTiers[tier] ?? feeTiers[5] {
            return fee
        }
        throw KasiaError.apiError("KNS fee tier data is missing")
    }

    private func commitAmountKas(for revealKas: Decimal) -> Decimal {
        if revealKas <= 1 {
            return 2
        }
        let value = NSDecimalNumber(decimal: revealKas).doubleValue * 1.05
        return Decimal(Int(round(value)))
    }

    private func kasToSompi(_ kas: Decimal) throws -> UInt64 {
        guard kas >= 0 else {
            throw KasiaError.apiError("Negative KAS amount is invalid")
        }
        let scaled = NSDecimalNumber(decimal: kas).multiplying(by: NSDecimalNumber(value: 100_000_000))
        let rounded = scaled.rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: true,
                raiseOnUnderflow: true,
                raiseOnDivideByZero: true
            )
        )
        if rounded == .notANumber {
            throw KasiaError.apiError("Failed to convert KAS amount to sompi")
        }
        let asInt64 = rounded.int64Value
        guard asInt64 >= 0 else {
            throw KasiaError.apiError("Negative sompi amount is invalid")
        }
        return UInt64(asInt64)
    }

    private func submitRevealWithFallback(_ revealTx: KaspaRpcTransaction) async throws -> (txId: String, endpoint: String) {
        do {
            return try await nodePool.submitTransaction(revealTx, allowOrphan: false)
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("orphan") {
                log("REVEAL_RETRY allowOrphan=true reason=\(error.localizedDescription)")
                return try await nodePool.submitTransaction(revealTx, allowOrphan: true)
            }
            throw error
        }
    }

    private func verifyDomainOwnership(
        fullDomain: String,
        expectedOwnerAddress: String,
        timeout: TimeInterval = 90,
        pollInterval: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let resolution = await knsService.resolveDomain(fullDomain),
               resolution.ownerAddress == expectedOwnerAddress {
                return true
            }
            let nanos = UInt64(max(0.1, pollInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        return false
    }
}

@MainActor
final class KNSDomainTransferService: ObservableObject {
    static let shared = KNSDomainTransferService()

    @Published private(set) var isSubmitting = false

    private let knsService = KNSService.shared
    private let nodePool = NodePoolService.shared
    private let walletManager = WalletManager.shared

    private init() {}

    private func log(_ message: String) {
        NSLog("[KNS_TRANSFER] %@", message)
    }

    @discardableResult
    func transferDomain(
        domain fullDomain: String,
        assetId rawAssetId: String,
        to rawRecipient: String
    ) async throws -> KNSDomainTransferResult {
        guard !isSubmitting else {
            throw KasiaError.apiError("Another KNS domain transfer is already running")
        }
        guard let wallet = walletManager.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = walletManager.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }

        let assetId = rawAssetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !assetId.isEmpty else {
            throw KasiaError.apiError("Missing domain asset id")
        }

        let domain = fullDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else {
            throw KasiaError.apiError("Missing domain name")
        }

        let recipientAddress = try await resolveRecipientAddress(
            rawRecipient,
            walletAddress: wallet.publicAddress
        )

        log("START domain=\(domain) asset=\(assetId) from=\(wallet.publicAddress) to=\(recipientAddress)")
        isSubmitting = true
        defer { isSubmitting = false }

        if let resolution = await knsService.resolveDomain(domain),
           resolution.ownerAddress.lowercased() != wallet.publicAddress.lowercased() {
            throw KasiaError.apiError("Domain is not owned by current wallet")
        }

        let payload = knsService.buildTransferDomainPayload(
            assetId: assetId,
            toAddress: recipientAddress
        )
        let payloadJSON = try JSONEncoder().encode(payload)
        log("PAYLOAD domain=\(domain) jsonBytes=\(payloadJSON.count)")

        let fetchedUtxos = try await nodePool.getUtxosByAddresses([wallet.publicAddress])
        let utxos = fetchedUtxos.filter { !$0.isCoinbase && $0.blockDaaScore > 0 }
        guard !utxos.isEmpty else {
            throw KasiaError.networkError("No spendable UTXOs available for KNS transfer")
        }
        log("UTXO domain=\(domain) total=\(fetchedUtxos.count) spendable=\(utxos.count)")

        // KNS web app submits transfers with tx.amount=0, which maps to 2 KAS commit funding.
        let revealSompi: UInt64 = 0
        let commitSompi: UInt64 = 200_000_000
        log("AMOUNTS domain=\(domain) revealSompi=\(revealSompi) commitSompi=\(commitSompi)")

        let (commitTx, commitContext) = try KasiaTransactionBuilder.buildKNSAddProfileCommitTx(
            from: wallet.publicAddress,
            senderPrivateKey: privateKey,
            payloadJSON: payloadJSON,
            utxos: utxos,
            title: "kns",
            commitAmountSompi: commitSompi,
            revealAmountSompi: revealSompi
        )
        let (commitTxId, _) = try await nodePool.submitTransaction(commitTx, allowOrphan: false)
        log("COMMIT_SUBMITTED domain=\(domain) txId=\(commitTxId)")
        ChatService.shared.registerSuppressedPaymentTxIds(
            [commitTxId],
            reason: "kns-transfer-commit"
        )

        let revealTx = try KasiaTransactionBuilder.buildKNSAddProfileRevealTx(
            walletAddress: wallet.publicAddress,
            senderPrivateKey: privateKey,
            commitTxId: commitTxId,
            commitContext: commitContext,
            revealTargetAddress: wallet.publicAddress
        )
        let (revealTxId, _) = try await submitRevealWithFallback(revealTx)
        log("REVEAL_SUBMITTED domain=\(domain) txId=\(revealTxId)")
        ChatService.shared.registerSuppressedPaymentTxIds(
            [commitTxId, revealTxId],
            reason: "kns-transfer-reveal"
        )
        ChatService.shared.registerKNSTransferChatHint(
            txId: revealTxId,
            domainName: domain,
            domainId: assetId,
            counterpartyAddress: recipientAddress,
            isOutgoing: true
        )

        let verified = await verifyDomainOwnership(
            fullDomain: domain,
            expectedOwnerAddress: recipientAddress
        )
        log("VERIFY domain=\(domain) verified=\(verified)")

        _ = await knsService.fetchInfo(for: wallet.publicAddress)
        _ = await knsService.fetchProfile(for: wallet.publicAddress)
        _ = await knsService.fetchInfo(for: recipientAddress)

        return KNSDomainTransferResult(
            domain: domain,
            recipientAddress: recipientAddress,
            commitTxId: commitTxId,
            revealTxId: revealTxId,
            verified: verified
        )
    }

    private func resolveRecipientAddress(
        _ raw: String,
        walletAddress: String
    ) async throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.apiError("Recipient address is required")
        }

        let resolvedAddress: String
        if trimmed.lowercased().hasSuffix(".kas") {
            guard let resolution = await knsService.resolveDomain(trimmed) else {
                throw KasiaError.apiError("Could not resolve recipient KNS domain")
            }
            resolvedAddress = resolution.ownerAddress
        } else {
            resolvedAddress = trimmed
        }

        guard KaspaAddress.isValid(resolvedAddress) else {
            throw KasiaError.apiError("Recipient address is invalid")
        }
        guard let recipient = KaspaAddress(address: resolvedAddress),
              let wallet = KaspaAddress(address: walletAddress) else {
            throw KasiaError.apiError("Recipient address is invalid")
        }
        guard recipient.hrp == wallet.hrp else {
            throw KasiaError.apiError("Recipient address network does not match current wallet")
        }
        guard resolvedAddress.lowercased() != walletAddress.lowercased() else {
            throw KasiaError.apiError("Recipient address must be different from your wallet")
        }
        return resolvedAddress
    }

    private func submitRevealWithFallback(_ revealTx: KaspaRpcTransaction) async throws -> (txId: String, endpoint: String) {
        do {
            return try await nodePool.submitTransaction(revealTx, allowOrphan: false)
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("orphan") {
                log("REVEAL_RETRY allowOrphan=true reason=\(error.localizedDescription)")
                return try await nodePool.submitTransaction(revealTx, allowOrphan: true)
            }
            throw error
        }
    }

    private func verifyDomainOwnership(
        fullDomain: String,
        expectedOwnerAddress: String,
        timeout: TimeInterval = 90,
        pollInterval: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let resolution = await knsService.resolveDomain(fullDomain),
               resolution.ownerAddress.lowercased() == expectedOwnerAddress.lowercased() {
                return true
            }
            let nanos = UInt64(max(0.1, pollInterval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
        return false
    }
}

// MARK: - Models

struct KNSAddressInfo: Equatable, Codable {
    let address: String
    let primaryDomain: String?
    let primaryInscriptionId: String?
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

    static var empty: KNSDomainProfile {
        KNSDomainProfile(
            avatarUrl: nil,
            redirectUrl: nil,
            bio: nil,
            x: nil,
            website: nil,
            telegram: nil,
            discord: nil,
            contactEmail: nil,
            bannerUrl: nil,
            github: nil
        )
    }

    func value(for key: KNSProfileFieldKey) -> String? {
        switch key {
        case .redirectUrl: return redirectUrl
        case .avatarUrl: return avatarUrl
        case .bannerUrl: return bannerUrl
        case .bio: return bio
        case .x: return x
        case .website: return website
        case .telegram: return telegram
        case .discord: return discord
        case .contactEmail: return contactEmail
        case .github: return github
        }
    }

    func withValue(_ value: String?, for key: KNSProfileFieldKey) -> KNSDomainProfile {
        switch key {
        case .redirectUrl:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: value,
                bio: bio,
                x: x,
                website: website,
                telegram: telegram,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: github
            )
        case .avatarUrl:
            return KNSDomainProfile(
                avatarUrl: value,
                redirectUrl: redirectUrl,
                bio: bio,
                x: x,
                website: website,
                telegram: telegram,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: github
            )
        case .bannerUrl:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: bio,
                x: x,
                website: website,
                telegram: telegram,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: value,
                github: github
            )
        case .bio:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: value,
                x: x,
                website: website,
                telegram: telegram,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: github
            )
        case .x:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: bio,
                x: value,
                website: website,
                telegram: telegram,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: github
            )
        case .website:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: bio,
                x: x,
                website: value,
                telegram: telegram,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: github
            )
        case .telegram:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: bio,
                x: x,
                website: website,
                telegram: value,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: github
            )
        case .discord:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: bio,
                x: x,
                website: website,
                telegram: telegram,
                discord: value,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: github
            )
        case .contactEmail:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: bio,
                x: x,
                website: website,
                telegram: telegram,
                discord: discord,
                contactEmail: value,
                bannerUrl: bannerUrl,
                github: github
            )
        case .github:
            return KNSDomainProfile(
                avatarUrl: avatarUrl,
                redirectUrl: redirectUrl,
                bio: bio,
                x: x,
                website: website,
                telegram: telegram,
                discord: discord,
                contactEmail: contactEmail,
                bannerUrl: bannerUrl,
                github: value
            )
        }
    }
}

enum KNSProfileFieldKey: String, CaseIterable, Codable {
    case redirectUrl
    case avatarUrl
    case bannerUrl
    case bio
    case x
    case website
    case telegram
    case discord
    case contactEmail
    case github

    var displayName: String {
        switch self {
        case .redirectUrl: return String(localized: "Redirect")
        case .avatarUrl: return String(localized: "Avatar")
        case .bannerUrl: return String(localized: "Banner")
        case .bio: return String(localized: "Bio")
        case .x: return String(localized: "X")
        case .website: return String(localized: "Website")
        case .telegram: return String(localized: "Telegram")
        case .discord: return String(localized: "Discord")
        case .contactEmail: return String(localized: "Email")
        case .github: return String(localized: "GitHub")
        }
    }
}

enum KNSProfileImageUploadType: String, Codable {
    case avatar
    case banner
}

enum KNSProfileUpdateStatus: String, Codable {
    case queued
    case signing
    case uploading
    case submittingCommit
    case submittingReveal
    case verifying
    case success
    case failed
}

struct KNSProfileUpdateOperation: Identifiable, Equatable, Codable {
    let id: UUID
    let address: String
    let assetId: String
    let fieldKey: KNSProfileFieldKey
    let value: String
    var status: KNSProfileUpdateStatus
    var commitTxId: String?
    var revealTxId: String?
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date
}

struct KNSCommitRevealResult: Equatable, Codable {
    let commitTxId: String
    let revealTxId: String
}

struct KNSDomainAvailability: Equatable, Codable {
    let domain: String
    let available: Bool
    let isReservedDomain: Bool
}

struct KNSDomainInscribeResult: Equatable, Codable {
    let domain: String
    let isReservedDomain: Bool
    let serviceFeeSompi: UInt64
    let commitTxId: String
    let revealTxId: String
    let verified: Bool
}

struct KNSCreateDomainPayload: Equatable, Codable {
    let op: String
    let p: String
    let v: String
}

struct KNSTransferDomainPayload: Equatable, Codable {
    let op: String
    let p: String
    let id: String
    let to: String
}

struct KNSDomainTransferResult: Equatable, Codable {
    let domain: String
    let recipientAddress: String
    let commitTxId: String
    let revealTxId: String
    let verified: Bool
}

struct KNSAddProfilePayload: Equatable, Codable {
    let op: String
    let id: String
    let key: String
    let value: String
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

private struct KNSInscribeFeeResponse: Codable {
    let success: Bool
    let data: KNSInscribeFeeData?
    let message: String?
    let error: String?
}

private struct KNSInscribeFeeData: Codable {
    let fee: [String: Decimal]?
}

private struct KNSDomainCheckRequest: Codable {
    let address: String
    let domainNames: [String]
}

private struct KNSSetPrimaryNameRequest: Codable {
    let signMessage: String
    let signature: String
}

private struct KNSDomainCheckResponse: Codable {
    let success: Bool
    let data: KNSDomainCheckData?
    let message: String?
    let error: String?
}

private struct KNSDomainCheckData: Codable {
    let domains: [KNSDomainCheckEntry]?
}

private struct KNSDomainCheckEntry: Codable {
    let domain: String
    let available: Bool
    let isReservedDomain: Bool
}

private struct KNSPrimaryNameResponse: Codable {
    let success: Bool
    let data: KNSPrimaryNameData?
    let message: String?
    let error: String?
}

private struct KNSBasicAPIResponse: Codable {
    let success: Bool
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

private struct KNSImageUploadResponse: Codable {
    let success: Bool
    let data: KNSImageUploadDataContainer?
    let message: String?
    let error: String?
}

private struct KNSImageUploadDataContainer: Codable {
    let imageUrl: String?
    let data: KNSImageUploadData?

    var resolvedImageURL: String? {
        imageUrl ?? data?.imageUrl
    }
}

private struct KNSImageUploadData: Codable {
    let imageUrl: String?
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
