import Foundation
import Network
import Security

enum KasiaAPIClientError: Error {
    case dpiPaginationExhausted(endpoint: String)
}

final class KasiaAPIClient: NSObject, URLSessionTaskDelegate {
    static let shared = KasiaAPIClient()

    private var session: URLSession!
    private var fallbackSession: URLSession!
    private let sessionLock = NSLock()
    private let requestQueue = IndexerRequestQueue(maxConcurrent: 5)
    private let http1Client = HTTP1Client()
    private let dpiState = DpiModeState()
    private let rootCheckMinInterval: TimeInterval = 20
    @MainActor private(set) var dpiSuspectedSnapshot: Bool = false

    private override init() {
        super.init()
        resetSessions()
        Task { @MainActor in
            NetworkEpochMonitor.shared.onEpochChange { [weak self] _ in
                Task { await self?.resetHTTPModeForNewEpoch() }
            }
        }
    }

    @MainActor var isDpiSuspected: Bool {
        dpiSuspectedSnapshot
    }

    private func resetHTTPModeForNewEpoch() async {
        await dpiState.reset()
        await MainActor.run {
            dpiSuspectedSnapshot = false
        }
    }

    private func currentEpochId() async -> Int {
        await MainActor.run {
            NetworkEpochMonitor.shared.epochId
        }
    }

    private func shouldForceHTTP1() async -> Bool {
        let epochId = await currentEpochId()
        return await dpiState.shouldForceHTTP1(epochId: epochId)
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        #if DEBUG
        // Log metrics immediately when received - use full URL with query params
        let fullURL = task.originalRequest?.url?.absoluteString ?? "unknown"
        logMetrics(metrics, endpoint: fullURL, task: task)
        #else
        // In release builds, log only the path without query params
        let path = task.originalRequest?.url?.path ?? "unknown"
        logMetrics(metrics, endpoint: path, task: task)
        #endif
    }

    /// Log detailed metrics for a completed request
    private func logMetrics(_ metrics: URLSessionTaskMetrics, endpoint: String, task: URLSessionTask) {
        guard let transaction = metrics.transactionMetrics.last else {
            NSLog("[KasiaAPI] [%@] No transaction data", endpoint)
            return
        }

        // Protocol info
        let proto = transaction.networkProtocolName ?? "unknown"
        let isReused = transaction.isReusedConnection
        let isProxyConnection = transaction.isProxyConnection

        // Remote address
        let remoteAddr = transaction.remoteAddress ?? "unknown"
        let remotePort = transaction.remotePort.map { String($0) } ?? "?"

        // Connection type detection
        var connProto = proto
        if proto.contains("h3") || proto.contains("quic") {
            connProto = "HTTP/3-QUIC-UDP"
        } else if proto.contains("h2") || proto == "http/2" {
            connProto = "HTTP/2-TCP"
        } else if proto.contains("http/1") {
            connProto = "HTTP/1.1-TCP"
        }

        // Timing breakdown
        var timings: [String] = []

        if let fetchStart = transaction.fetchStartDate {
            if let domainEnd = transaction.domainLookupEndDate, let domainStart = transaction.domainLookupStartDate {
                let dnsMs = domainEnd.timeIntervalSince(domainStart) * 1000
                if dnsMs > 0 {
                    timings.append(String(format: "dns=%.0fms", dnsMs))
                }
            }

            if let connectEnd = transaction.connectEndDate, let connectStart = transaction.connectStartDate {
                let connectMs = connectEnd.timeIntervalSince(connectStart) * 1000
                if connectMs > 0 {
                    timings.append(String(format: "tcp=%.0fms", connectMs))
                }
            }

            if let secureEnd = transaction.secureConnectionEndDate, let secureStart = transaction.secureConnectionStartDate {
                let tlsMs = secureEnd.timeIntervalSince(secureStart) * 1000
                if tlsMs > 0 {
                    timings.append(String(format: "tls=%.0fms", tlsMs))
                }
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
        let proxyStr = isProxyConnection ? " PROXY" : ""
        let timingStr = timings.isEmpty ? "no-timing-data" : timings.joined(separator: " ")
        let taskError = task.error

        if let err = taskError {
            NSLog("[KasiaAPI] [%@] FAIL | %@ %@%@ | %@:%@ | %@ | err=%@",
                  endpoint, connProto, connType, proxyStr, remoteAddr, remotePort, timingStr, err.localizedDescription)
        } else {
            NSLog("[KasiaAPI] [%@] OK | %@ %@%@ | %@:%@ | %@",
                  endpoint, connProto, connType, proxyStr, remoteAddr, remotePort, timingStr)
        }
    }

    // MARK: - Configuration

    /// Get the indexer base URL from settings
    private var baseURL: String {
        AppSettings.load().indexerURL
    }

    var currentBaseURL: String? {
        return baseURL
    }

    // MARK: - Handshakes

    func getHandshakesBySender(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [HandshakeResponse] {
        try await getPaginated(
            endpoint: "/handshakes/by-sender",
            params: ["address": address],
            limit: limit,
            startBlockTime: blockTime,
            getBlockTime: { $0.blockTime }
        )
    }

    func getHandshakesByReceiver(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [HandshakeResponse] {
        try await getPaginated(
            endpoint: "/handshakes/by-receiver",
            params: ["address": address],
            limit: limit,
            startBlockTime: blockTime,
            getBlockTime: { $0.blockTime }
        )
    }

    // MARK: - Contextual Messages

    func getContextualMessagesBySender(address: String, alias: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [ContextualMessageResponse] {
        let aliasHex = alias.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? ""
        return try await getPaginated(
            endpoint: "/contextual-messages/by-sender",
            params: ["address": address, "alias": aliasHex],
            limit: limit,
            startBlockTime: blockTime,
            getBlockTime: { $0.blockTime }
        )
    }

    // MARK: - Payments

    func getPaymentsBySender(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [PaymentResponse] {
        try await getPaginated(
            endpoint: "/payments/by-sender",
            params: ["address": address],
            limit: limit,
            startBlockTime: blockTime,
            getBlockTime: { $0.blockTime }
        )
    }

    func getPaymentsByReceiver(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [PaymentResponse] {
        try await getPaginated(
            endpoint: "/payments/by-receiver",
            params: ["address": address],
            limit: limit,
            startBlockTime: blockTime,
            getBlockTime: { $0.blockTime }
        )
    }

    /// Fetch a single page of payments by receiver (no pagination).
    func getPaymentsByReceiverOnce(address: String, limit: Int = 50, blockTime: UInt64 = 0) async throws -> [PaymentResponse] {
        let params: [String: String] = [
            "address": address,
            "limit": String(limit),
            "block_time": String(blockTime)
        ]
        return try await get(endpoint: "/payments/by-receiver", params: params)
    }

    // MARK: - Self Stash

    func getSelfStash(owner: String, scope: String, limit: Int = 50) async throws -> [SelfStashResponse] {
        let scopeHex = scope.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? ""
        return try await getPaginated(
            endpoint: "/self-stash/by-owner",
            params: ["owner": owner, "scope": scopeHex],
            limit: limit,
            startBlockTime: 0,
            getBlockTime: { $0.blockTime }
        )
    }

    // MARK: - Metrics

    func getMetrics() async throws -> IndexerMetrics {
        let endpoint = "/metrics"
        return try await get(endpoint: endpoint, params: [:])
    }

    // MARK: - Health Check

    func ping() async -> (isHealthy: Bool, latencyMs: Int?) {
        let startTime = Date()

        do {
            let _ = try await getMetrics()
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            return (true, latency)
        } catch {
            return (false, nil)
        }
    }

    // MARK: - Private Methods

    /// Fetch with automatic pagination - continues fetching until all results are retrieved
    /// - Parameters:
    ///   - endpoint: API endpoint path
    ///   - params: Base query parameters (without limit/block_time)
    ///   - limit: Page size for each request
    ///   - startBlockTime: Starting block_time cursor (0 for all)
    ///   - maxPages: Maximum number of pages to fetch (safety limit)
    ///   - getBlockTime: Closure to extract blockTime from response item
    private func getPaginated<T: Decodable>(
        endpoint: String,
        params: [String: String],
        limit: Int,
        startBlockTime: UInt64,
        maxPages: Int = 20,
        getBlockTime: (T) -> UInt64?
    ) async throws -> [T] {
        var allResults: [T] = []
        var currentBlockTime = startBlockTime
        var pageCount = 0
        let baseLimit = limit
        var currentLimit = baseLimit

        while pageCount < maxPages {
            // Build params with current cursor
            var pageParams = params
            pageParams["limit"] = String(currentLimit)
            pageParams["block_time"] = String(currentBlockTime)

            let results: [T]
            do {
                results = try await get(endpoint: endpoint, params: pageParams)
            } catch {
                if await shouldScaleDownPagination(error) {
                    let nextLimit = nextDpiLimit(after: currentLimit, fallbackBase: baseLimit)
                    if nextLimit < currentLimit {
                        NSLog("[KasiaAPI] DPI pagination: reducing limit from %d to %d for %@", currentLimit, nextLimit, endpoint)
                        currentLimit = nextLimit
                        continue
                    }
                    if currentLimit <= 1 {
                        NSLog("[KasiaAPI] DPI pagination: limit=1 failed for %@", endpoint)
                        throw KasiaAPIClientError.dpiPaginationExhausted(endpoint: endpoint)
                    }
                }
                throw error
            }
            allResults.append(contentsOf: results)

            // If we got fewer results than the limit, we've reached the end
            if results.count < currentLimit {
                break
            }

            // Find the maximum blockTime in results for next page cursor
            let maxBlockTime = results.compactMap { getBlockTime($0) }.max()
            guard let nextBlockTime = maxBlockTime, nextBlockTime > currentBlockTime else {
                // No valid blockTime found or no progress - stop pagination
                break
            }

            currentBlockTime = nextBlockTime
            pageCount += 1

            if pageCount > 1 {
                NSLog("[KasiaAPI] Pagination: fetched page %d for %@, total items: %d, next cursor: %llu",
                      pageCount, endpoint, allResults.count, currentBlockTime)
            }
        }

        if pageCount >= maxPages {
            NSLog("[KasiaAPI] Pagination: reached max pages (%d) for %@, total items: %d",
                  maxPages, endpoint, allResults.count)
        }

        return allResults
    }

    private func nextDpiLimit(after limit: Int, fallbackBase: Int) -> Int {
        if limit > 10 {
            return 10
        }
        switch limit {
        case 10:
            return 5
        case 5:
            return 3
        case 3:
            return 2
        case 2:
            return 1
        default:
            return min(1, fallbackBase)
        }
    }

    private func get<T: Decodable>(endpoint: String, params: [String: String]) async throws -> T {
        var urlComponents = URLComponents(string: baseURL + endpoint)
        urlComponents?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = urlComponents?.url else {
            throw KasiaError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await requestQueue.enqueue { [self] in
            if await shouldForceHTTP1() {
                return try await performHTTP1(url: url)
            }
            do {
                let (data, response) = try await session.data(for: request)
                // Detailed metrics logged by URLSessionTaskDelegate
                return try processResponse(data: data, response: response, url: url)
            } catch {
                if isDpiLikelyError(error) {
                    #if DEBUG
                    NSLog("[KasiaAPI] DPI-like failure on primary; switching to HTTP/1.1 for %@", url.absoluteString)
                    #endif
                    await markHTTP1ForEpoch()
                    return try await performHTTP1(url: url)
                }
                if shouldRetryWithFallback(error) {
                    resetSessions()
                    #if DEBUG
                    NSLog("[KasiaAPI] Primary session failed for %@, retrying with fallback session", url.absoluteString)
                    #endif
                    var fallbackRequest = request
                    fallbackRequest.setValue("close", forHTTPHeaderField: "Connection")
                    do {
                        let (data, response) = try await fallbackSession.data(for: fallbackRequest)
                        return try processResponse(data: data, response: response, url: url)
                    } catch {
                        if await shouldTryHTTP1AfterFailure(url: url, error: error) {
                            #if DEBUG
                            NSLog("[KasiaAPI] Fallback failed; trying HTTP/1.1 for %@", url.absoluteString)
                            #endif
                            let result: T = try await performHTTP1(url: url)
                            await markHTTP1ForEpoch()
                            return result
                        }
                        throw error
                    }
                }
                if await shouldTryHTTP1AfterFailure(url: url, error: error) {
                    #if DEBUG
                    NSLog("[KasiaAPI] Primary failed; trying HTTP/1.1 for %@", url.absoluteString)
                    #endif
                    let result: T = try await performHTTP1(url: url)
                    await markHTTP1ForEpoch()
                    return result
                }
                // Detailed metrics logged by URLSessionTaskDelegate
                throw error
            }
        }
    }

    private func markHTTP1ForEpoch() async {
        let epochId = await currentEpochId()
        await dpiState.markHTTP1(epochId: epochId)
        await MainActor.run {
            dpiSuspectedSnapshot = true
        }
        #if DEBUG
        NSLog("[KasiaAPI] DPI suspected - forcing HTTP/1.1 for epoch %d", epochId)
        #endif
    }

    private func shouldTryHTTP1AfterFailure(url: URL, error: Error) async -> Bool {
        if await shouldForceHTTP1() { return false }
        guard shouldRetryWithFallback(error) else { return false }
        #if DEBUG
        NSLog("[KasiaAPI] Evaluating HTTP/1.1 fallback for %@ (err=%@)", url.absoluteString, error.localizedDescription)
        #endif
        guard isDpiLikelyError(error) else {
            return false
        }

        let rootOk = await checkRootReachable()
        if !rootOk {
            #if DEBUG
            NSLog("[KasiaAPI] HTTP/1.1 root probe failed; staying on HTTP/2 for %@", url.absoluteString)
            #endif
            return false
        }
        #if DEBUG
        NSLog("[KasiaAPI] DPI-like failure; trying HTTP/1.1 for %@", url.absoluteString)
        #endif
        return true
    }

    private func isDpiLikelyError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut:
                return true
            default:
                break
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && (nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorTimedOut)
    }

    private func checkRootReachable() async -> Bool {
        let currentEpoch = await currentEpochId()
        if let cached = await dpiState.cachedRootCheck(epochId: currentEpoch, minInterval: rootCheckMinInterval) {
            return cached
        }

        guard let rootURL = rootURL() else {
            await dpiState.setRootCheck(epochId: currentEpoch, ok: false)
            return false
        }

        do {
            let (_, response) = try await http1Client.get(url: rootURL, timeout: 6)
            let ok = (200...599).contains(response.statusCode)
            await dpiState.setRootCheck(epochId: currentEpoch, ok: ok)
            if ok {
                NSLog("[KasiaAPI] HTTP/1.1 root probe OK: %@", rootURL.absoluteString)
            } else {
                NSLog("[KasiaAPI] HTTP/1.1 root probe status %d: %@",
                      response.statusCode, rootURL.absoluteString)
            }
            return ok
        } catch {
            await dpiState.setRootCheck(epochId: currentEpoch, ok: false)
            NSLog("[KasiaAPI] HTTP/1.1 root probe failed for %@: %@", rootURL.absoluteString, error.localizedDescription)
            return false
        }
    }

    private func rootURL() -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }

    private func performHTTP1<T: Decodable>(url: URL) async throws -> T {
        let start = Date()
        do {
            let (data, response) = try await http1Client.get(url: url, timeout: 10)
            #if DEBUG
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("[KasiaAPI] [%@] OK | HTTP/1.1 | TOTAL=%dms", url.absoluteString, elapsed)
            #endif
            return try processResponse(data: data, response: response, url: url)
        } catch {
            #if DEBUG
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            NSLog("[KasiaAPI] [%@] FAIL | HTTP/1.1 | TOTAL=%dms | err=%@",
                  url.absoluteString, elapsed, error.localizedDescription)
            #endif
            throw error
        }
    }

    private func processResponse<T: Decodable>(data: Data, response: URLResponse, url: URL) throws -> T {

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KasiaError.networkError("Invalid response")
        }

        // Validate Content-Type when present (permissive: missing Content-Type is allowed)
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           !contentType.isEmpty {
            guard contentType.contains("application/json") || contentType.contains("text/json") else {
                throw KasiaError.apiError("Unexpected Content-Type: \(contentType)")
            }
        }

        let status = httpResponse.statusCode

        switch status {
        case 200:
            // Some endpoints may legitimately return an empty body when there are no results
            if data.isEmpty {
                if let emptyArray = ([] as [Any]) as? T {
                    return emptyArray
                }
                throw KasiaError.apiError("Empty response from indexer")
            }

            do {
                let decoder = JSONDecoder()
                return try decoder.decode(T.self, from: data)
            } catch {
                throw KasiaError.apiError("Failed to decode response: \(error.localizedDescription)")
            }

        case 400:
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw KasiaError.apiError(errorResponse.error)
            }
            throw KasiaError.apiError("Bad request")

        case 404:
            throw KasiaError.apiError("Resource not found")
        case 500:
            throw KasiaError.apiError("Server error")
        default:
            throw KasiaError.apiError("HTTP \(status)")
        }
    }

    private func shouldRetryWithFallback(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func shouldScaleDownPagination(_ error: Error) async -> Bool {
        if let http1Error = error as? HTTP1ClientError {
            switch http1Error {
            case .timeout, .invalidResponse:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            guard urlError.code == .timedOut || urlError.code == .networkConnectionLost else { return false }
            return await shouldForceHTTP1()
        }
        if let description = error.localizedDescription as String?,
           description == HTTP1ClientError.timeout.errorDescription ||
            description == HTTP1ClientError.invalidResponse.errorDescription {
            return await shouldForceHTTP1()
        }
        return false
    }

    private func resetSessions() {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        let oldSession = session
        let oldFallback = fallbackSession
        session = makeSession(kind: "primary", configuration: makePrimaryConfig())
        fallbackSession = makeSession(kind: "fallback", configuration: makeFallbackConfig())

        oldSession?.finishTasksAndInvalidate()
        oldFallback?.finishTasksAndInvalidate()
    }

    private func makeSession(kind: String, configuration: URLSessionConfiguration) -> URLSession {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        NSLog("[KasiaAPI] URLSession initialized (%@)", kind)
        return session
    }

    private func makePrimaryConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 5
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Connection": "close", "Accept-Encoding": "identity"]
        return config
    }

    private func makeFallbackConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 5
        config.httpShouldUsePipelining = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Connection": "close", "Accept-Encoding": "identity"]
        return config
    }
}

private enum HTTP1ClientError: LocalizedError {
    case invalidURL
    case invalidResponse
    case timeout
    case unsupportedScheme

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .timeout:
            return "Request timed out"
        case .unsupportedScheme:
            return "Unsupported URL scheme"
        }
    }
}

private actor HTTP1Client {
    private static let maxResponseSize = 10 * 1024 * 1024 // 10MB
    private let queue = DispatchQueue(label: "kasia.http1.client")

    func get(url: URL, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let host = url.host else { throw HTTP1ClientError.invalidURL }
        guard let scheme = url.scheme, scheme == "https" else { throw HTTP1ClientError.unsupportedScheme }
        let port = url.port ?? 443
        guard let portValue = NWEndpoint.Port(rawValue: UInt16(port)) else { throw HTTP1ClientError.invalidURL }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, host)
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: NWEndpoint.Host(host), port: portValue, using: parameters)
        defer { connection.cancel() }

        let response: (Data, HTTPURLResponse) = try await withTimeout(timeout, onTimeout: {
            connection.cancel()
        }) { [self] in
            try await waitUntilReady(connection)
            let requestData = buildRequest(url: url, host: host)
            try await send(connection, data: requestData)
            return try await receiveHTTPResponse(connection, url: url)
        }
        return response
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        let gate = ContinuationGate()
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resumeOnce { continuation.resume() }
                case .failed(let error):
                    gate.resumeOnce { continuation.resume(throwing: error) }
                case .cancelled:
                    gate.resumeOnce { continuation.resume(throwing: HTTP1ClientError.invalidResponse) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveOnce(_ connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private func buildRequest(url: URL, host: String) -> Data {
        let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
        let request = "GET \(path) HTTP/1.1\r\n" +
            "Host: \(host)\r\n" +
            "Connection: close\r\n" +
            "Accept: application/json\r\n" +
            "Accept-Encoding: identity\r\n" +
            "User-Agent: Kasia-iOS\r\n" +
            "\r\n"
        return Data(request.utf8)
    }

    private func receiveHTTPResponse(_ connection: NWConnection, url: URL) async throws -> (Data, HTTPURLResponse) {
        var buffer = Data()
        var headers: [String: String]?
        var bodyStart = 0

        while true {
            let (chunk, isComplete) = try await receiveOnce(connection)
            if let chunk {
                buffer.append(chunk)
            }

            guard buffer.count <= Self.maxResponseSize else {
                throw HTTP1ClientError.invalidResponse
            }

            if headers == nil {
                if let range = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                    bodyStart = range.upperBound
                    headers = parseHeaders(from: buffer[..<range.lowerBound])
                }
            }

            if let headers {
                if let lengthStr = headers["content-length"], let length = Int(lengthStr) {
                    if buffer.count >= bodyStart + length {
                        let full = buffer.prefix(bodyStart + length)
                        return try parseHTTPResponse(data: Data(full), url: url)
                    }
                } else if let transfer = headers["transfer-encoding"], transfer.lowercased().contains("chunked") {
                    if buffer.range(of: Data([0x0D, 0x0A, 0x30, 0x0D, 0x0A, 0x0D, 0x0A]), options: [], in: bodyStart..<buffer.count) != nil {
                        return try parseHTTPResponse(data: buffer, url: url)
                    }
                } else if isComplete {
                    return try parseHTTPResponse(data: buffer, url: url)
                }
            }

            if isComplete, headers != nil {
                return try parseHTTPResponse(data: buffer, url: url)
            }
        }
    }

    private func parseHeaders(from data: Data) -> [String: String] {
        let headerString = String(decoding: data, as: UTF8.self)
        let lines = headerString.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    private func parseHTTPResponse(data: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = data.range(of: separator) else {
            throw HTTP1ClientError.invalidResponse
        }

        let headerData = data[..<headerRange.lowerBound]
        let bodyData = data[headerRange.upperBound...]
        let headerString = String(decoding: headerData, as: UTF8.self)
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw HTTP1ClientError.invalidResponse
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let statusCode = Int(parts[1]) else {
            throw HTTP1ClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let body: Data
        if let transfer = headers["transfer-encoding"], transfer.lowercased().contains("chunked") {
            body = try decodeChunkedBody(Data(bodyData))
        } else if let lengthStr = headers["content-length"], let length = Int(lengthStr) {
            body = Data(bodyData.prefix(length))
        } else {
            body = Data(bodyData)
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!

        return (body, response)
    }

    private func decodeChunkedBody(_ data: Data) throws -> Data {
        var output = Data()
        var offset = 0
        while offset < data.count {
            guard let lineRange = findCRLF(in: data, start: offset) else {
                throw HTTP1ClientError.invalidResponse
            }
            let sizeData = data[offset..<lineRange.lowerBound]
            let sizeString = String(decoding: sizeData, as: UTF8.self).split(separator: ";")[0]
            guard let size = Int(sizeString, radix: 16) else {
                throw HTTP1ClientError.invalidResponse
            }
            let chunkStart = lineRange.upperBound
            if size == 0 {
                break
            }
            let chunkEnd = chunkStart + size
            guard chunkEnd <= data.count else {
                throw HTTP1ClientError.invalidResponse
            }
            output.append(data[chunkStart..<chunkEnd])
            offset = chunkEnd + 2
        }
        return output
    }

    private func findCRLF(in data: Data, start: Int) -> Range<Int>? {
        let crlf = Data([0x0D, 0x0A])
        return data.range(of: crlf, options: [], in: start..<data.count)
    }

    private func withTimeout<T>(
        _ seconds: TimeInterval,
        onTimeout: @escaping () -> Void,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw HTTP1ClientError.timeout
            }
            guard let result = try await group.next() else {
                throw HTTP1ClientError.timeout
            }
            group.cancelAll()
            return result
        }
    }
}

private actor DpiModeState {
    private var forcedHTTP1Epoch: Int?
    private var dpiDetectedEpoch: Int?
    private var lastRootCheck: (epoch: Int, time: Date, ok: Bool)?

    func reset() {
        forcedHTTP1Epoch = nil
        dpiDetectedEpoch = nil
        lastRootCheck = nil
    }

    func shouldForceHTTP1(epochId: Int) -> Bool {
        forcedHTTP1Epoch == epochId
    }

    func markHTTP1(epochId: Int) {
        forcedHTTP1Epoch = epochId
        dpiDetectedEpoch = epochId
    }

    func isDpiSuspected(epochId: Int) -> Bool {
        dpiDetectedEpoch == epochId
    }

    func cachedRootCheck(epochId: Int, minInterval: TimeInterval) -> Bool? {
        guard let last = lastRootCheck, last.epoch == epochId else { return nil }
        // Retry probe on every failure path; only cache positive checks briefly.
        if !last.ok { return nil }
        if Date().timeIntervalSince(last.time) < minInterval {
            return last.ok
        }
        return nil
    }

    func setRootCheck(epochId: Int, ok: Bool) {
        lastRootCheck = (epoch: epochId, time: Date(), ok: ok)
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        action()
    }
}

private actor IndexerRequestQueue {
    private let maxConcurrent: Int
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.permits = max(1, maxConcurrent)
    }

    func enqueue<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        await acquire()
        defer { Task { await release() } }
        return try await operation()
    }

    private func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() async {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            permits = min(permits + 1, maxConcurrent)
        }
    }
}

struct ErrorResponse: Codable {
    let error: String
}
