import Foundation
import GRPC
import NIO
import SwiftProtobuf

// MARK: - Request Type for Matching

/// Enumeration of request types we send to Kaspa nodes
enum KaspaRequestType: Hashable {
    case getInfo
    case getUtxosByAddresses
    case submitTransaction
    case notifyUtxosChanged
    case getPeerAddresses
    case getConnectedPeerInfo
    case getBlockDagInfo
    case getCurrentNetwork
    case getMempoolEntry

    /// The expected response type for this request
    var responseCase: String {
        switch self {
        case .getInfo: return "getInfoResponse"
        case .getUtxosByAddresses: return "getUtxosByAddressesResponse"
        case .submitTransaction: return "submitTransactionResponse"
        case .notifyUtxosChanged: return "notifyUtxosChangedResponse"
        case .getPeerAddresses: return "getPeerAddressesResponse"
        case .getConnectedPeerInfo: return "getConnectedPeerInfoResponse"
        case .getBlockDagInfo: return "getBlockDagInfoResponse"
        case .getCurrentNetwork: return "getCurrentNetworkResponse"
        case .getMempoolEntry: return "getMempoolEntryResponse"
        }
    }
}

// MARK: - Pending Request

/// A pending request waiting for response
struct PendingRequest {
    let id: UInt64
    let type: KaspaRequestType
    let continuation: CheckedContinuation<Protowire_KaspadMessage, Error>
    let sentAt: Date
    let timeout: TimeInterval
    let timeoutTask: Task<Void, Never>

    var isExpired: Bool {
        Date().timeIntervalSince(sentAt) > timeout
    }
}

// MARK: - Connection State

/// Connection state machine
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var isUsable: Bool {
        self == .connected
    }
}

// MARK: - Circuit Breaker

/// Circuit breaker for fast-failing when connection is known bad
struct CircuitBreaker {
    enum State { case closed, open, halfOpen }

    private(set) var state: State = .closed
    private(set) var failureCount: Int = 0
    private(set) var lastFailure: Date?
    private let threshold: Int
    private let resetTimeout: TimeInterval

    init(threshold: Int = 3, resetTimeout: TimeInterval = 30) {
        self.threshold = threshold
        self.resetTimeout = resetTimeout
    }

    mutating func recordFailure() {
        failureCount += 1
        lastFailure = Date()
        if failureCount >= threshold {
            state = .open
        }
    }

    mutating func recordSuccess() {
        state = .closed
        failureCount = 0
        lastFailure = nil
    }

    mutating func checkState() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            guard let last = lastFailure else {
                state = .halfOpen
                return true
            }
            if Date().timeIntervalSince(last) > resetTimeout {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }

    mutating func reset() {
        state = .closed
        failureCount = 0
        lastFailure = nil
    }
}

// MARK: - gRPC Stream Connection

/// Actor that manages a single gRPC stream connection to a Kaspa node
/// Handles request/response matching, timeouts, and circuit breaker pattern
actor GRPCStreamConnection {
    // MARK: - Types

    typealias NotificationHandler = (KaspaRPCNotification, Data) -> Void

    // MARK: - Properties

    let endpoint: Endpoint
    /// Shared EventLoopGroup - owned by GRPCConnectionPool, not by this connection
    private let sharedGroup: EventLoopGroup
    private var channel: GRPCChannel?
    private var stream: BidirectionalStreamingCall<Protowire_KaspadMessage, Protowire_KaspadMessage>?

    private var state: ConnectionState = .disconnected
    private var circuitBreaker = CircuitBreaker()

    /// Pending requests keyed by request ID
    private var pendingRequests: [UInt64: PendingRequest] = [:]

    /// Request ID counter
    private var requestIdCounter: UInt64 = 0

    /// Queue of pending requests per type (for response matching)
    private var requestQueues: [KaspaRequestType: [UInt64]] = [:]

    /// Notification handlers
    private var notificationHandlers: [UUID: NotificationHandler] = [:]

    /// Latency EWMA (for health tracking)
    private var latencyEwma = EWMA()

    /// Consecutive successes/failures
    private var consecutiveSuccesses: Int = 0
    private var consecutiveFailures: Int = 0

    /// Recently timed-out request types (to silently ignore late responses)
    private var recentlyTimedOutTypes: Set<KaspaRequestType> = []

    /// Connection timestamp
    private var connectedAt: Date?

    /// Last activity timestamp (for idle connection pruning)
    private(set) var lastActivityAt: Date = Date()

    // MARK: - Initialization

    init(endpoint: Endpoint, eventLoopGroup: EventLoopGroup) {
        self.endpoint = endpoint
        self.sharedGroup = eventLoopGroup
    }

    // Note: No deinit cleanup needed - EventLoopGroup is owned by GRPCConnectionPool

    // MARK: - Connection State

    var isConnected: Bool {
        state == .connected
    }

    var connectionDuration: TimeInterval? {
        guard let connected = connectedAt else { return nil }
        return Date().timeIntervalSince(connected)
    }

    var averageLatencyMs: Double? {
        latencyEwma.value
    }

    var isCircuitOpen: Bool {
        !circuitBreaker.checkState()
    }

    // MARK: - Connection Lifecycle

    /// Connection timeout in seconds
    private let connectionTimeout: TimeInterval = 3.0

    /// Connect to the endpoint with timeout
    func connect() async throws {
        guard state == .disconnected else {
            if state == .connected { return }
            throw KasiaError.networkError("Connection in progress")
        }

        state = .connecting

        // Use a task with timeout for the connection
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.connectionTimeout * 1_000_000_000))
                    throw KasiaError.networkError("Connection timeout")
                }

                // Actual connection task
                group.addTask {
                    try await self.performConnect()
                }

                // Wait for first to complete (success or timeout)
                try await group.next()
                group.cancelAll()
            }

            state = .connected
            connectedAt = Date()
            lastActivityAt = Date()
            circuitBreaker.reset()

            // Suppress noisy connection logs

        } catch {
            state = .disconnected
            circuitBreaker.recordFailure()
            // Clean up partial connection state (channel only - group is shared)
            stream?.sendEnd(promise: nil)
            stream = nil
            // Properly close the channel and wait for completion to prevent leaks
            if let ch = channel {
                _ = try? await ch.close().get()
            }
            channel = nil
            throw error
        }
    }

    /// Internal connection logic (separated for timeout handling)
    private func performConnect() async throws {
        // Use ClientConnection instead of GRPCChannelPool to avoid retain cycle memory leaks
        // GRPCChannelPool.with() creates internal ConnectionManager/ConnectionPool objects
        // that have retain cycles (connectivityDelegate -> CYCLE BACK) and never get released
        let channel = ClientConnection.insecure(group: sharedGroup)
            .connect(host: endpoint.host, port: endpoint.port)
        self.channel = channel

        // Create RPC client
        let client = Protowire_RPCNIOClient(channel: channel)

        // Start bidirectional stream with response handler
        let stream = client.messageStream { [weak self] response in
            Task {
                await self?.handleResponse(response)
            }
        }
        self.stream = stream

        // Monitor stream status to detect when server closes connection
        stream.status.whenComplete { [weak self] result in
            Task {
                await self?.handleStreamClosed(result: result)
            }
        }
    }

    /// Handle stream being closed (by server or error)
    private func handleStreamClosed(result: Result<GRPCStatus, Error>) {
        // Only process if we think we're connected
        guard state == .connected else { return }

        switch result {
        case .success(let status):
            if status.code != .ok {
                NSLog("[GRPCStream] Stream closed on %@ with status: %@",
                      endpoint.key, status.code.description)
            }
        case .failure(let error):
            NSLog("[GRPCStream] Stream failed on %@: %@",
                  endpoint.key, error.localizedDescription)
        }

        // Only mark as disconnected, but don't cancel pending requests
        // They will timeout naturally if no response arrives
        state = .disconnected
        connectedAt = nil
        stream = nil
    }

    /// Disconnect from the endpoint
    func disconnect() async {
        guard state != .disconnected else { return }

        // Cancel all pending requests
        for (_, pending) in pendingRequests {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: KasiaError.networkError("Connection closed"))
        }
        pendingRequests.removeAll()
        requestQueues.removeAll()

        // Close stream and channel (group is shared, don't shut it down)
        stream?.sendEnd(promise: nil)
        stream = nil

        // Properly close the channel and wait for completion to prevent leaks
        if let ch = channel {
            _ = try? await ch.close().get()
        }
        channel = nil

        state = .disconnected
        connectedAt = nil

        NSLog("[GRPCStream] Disconnected from %@", endpoint.key)
    }

    /// Check if connection should be attempted (circuit breaker)
    func shouldAttempt() -> Bool {
        circuitBreaker.checkState()
    }

    // MARK: - Request/Response

    /// Send a request and wait for response with timeout
    func sendRequest(
        _ message: Protowire_KaspadMessage,
        type: KaspaRequestType,
        timeout: TimeInterval
    ) async throws -> Protowire_KaspadMessage {
        // Check connection first
        guard let stream = stream, state == .connected else {
            // Only check circuit breaker if not connected
            guard circuitBreaker.checkState() else {
                throw KasiaError.networkError("Circuit breaker open for \(endpoint.key)")
            }
            throw KasiaError.networkError("Not connected to \(endpoint.key)")
        }

        // If we're connected but circuit breaker is open, reset it
        // A live connection is evidence the node is responsive
        if !circuitBreaker.checkState() {
            circuitBreaker.reset()
            NSLog("[GRPCStream] Reset circuit breaker for live connection %@", endpoint.key)
        }

        // Generate request ID
        requestIdCounter += 1
        let requestId = requestIdCounter

        let startTime = Date()

        return try await withCheckedThrowingContinuation { continuation in
            // Create timeout task
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled {
                    self.handleTimeout(requestId: requestId)
                }
            }

            // Store pending request
            let pending = PendingRequest(
                id: requestId,
                type: type,
                continuation: continuation,
                sentAt: startTime,
                timeout: timeout,
                timeoutTask: timeoutTask
            )
            pendingRequests[requestId] = pending

            // Add to type queue
            if requestQueues[type] == nil {
                requestQueues[type] = []
            }
            requestQueues[type]?.append(requestId)

            // Send message
            let promise = stream.eventLoop.makePromise(of: Void.self)
            stream.sendMessage(message, promise: promise)

            promise.futureResult.whenFailure { [weak self] error in
                Task {
                    await self?.handleSendFailure(requestId: requestId, error: error)
                }
            }
        }
    }

    /// Handle incoming response
    private func handleResponse(_ message: Protowire_KaspadMessage) {
        // Check for notifications first
        if let payload = message.payload {
            switch payload {
            case .utxosChangedNotification(let notification):
                handleNotification(.utxosChanged, notification)
                return

            // All other notification types
            case .blockAddedNotification,
                 .virtualSelectedParentChainChangedNotification,
                 .finalityConflictNotification,
                 .finalityConflictResolvedNotification,
                 .virtualSelectedParentBlueScoreChangedNotification,
                 .pruningPointUtxosetOverrideNotification,
                 .virtualDaaScoreChangedNotification,
                 .newBlockTemplateNotification:
                return

            default:
                break
            }
        }

        // Determine response type and find matching request
        let responseType = determineResponseType(message)
        guard let type = responseType,
              let queue = requestQueues[type],
              let requestId = queue.first else {
            // Even if we can't match the response, it's evidence the node is responsive
            // Reset circuit breaker for late/unmatched responses
            if let knownType = responseType {
                circuitBreaker.recordSuccess()

                // Silently ignore late responses for recently timed-out requests
                if !recentlyTimedOutTypes.contains(knownType) {
                    // Unexpected unmatched response - log for debugging
                    NSLog("[GRPCStream] Unmatched response on %@: %@", endpoint.key, String(describing: knownType))
                }
            }
            return
        }

        // Remove from queue
        requestQueues[type]?.removeFirst()
        if requestQueues[type]?.isEmpty == true {
            requestQueues.removeValue(forKey: type)
        }

        // Get pending request
        guard let pending = pendingRequests.removeValue(forKey: requestId) else {
            return
        }

        // Cancel timeout task
        pending.timeoutTask.cancel()

        // Calculate latency
        let latencyMs = Date().timeIntervalSince(pending.sentAt) * 1000
        latencyEwma.update(sample: latencyMs, alpha: 0.25)

        // Record success
        consecutiveSuccesses += 1
        consecutiveFailures = 0
        circuitBreaker.recordSuccess()
        lastActivityAt = Date()

        // Resume continuation
        pending.continuation.resume(returning: message)
    }

    /// Handle request timeout
    private func handleTimeout(requestId: UInt64) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else {
            return
        }

        // Remove from type queue
        if var queue = requestQueues[pending.type] {
            queue.removeAll { $0 == requestId }
            if queue.isEmpty {
                requestQueues.removeValue(forKey: pending.type)
            } else {
                requestQueues[pending.type] = queue
            }
        }

        // Track this type as recently timed out (to silently ignore late responses)
        recentlyTimedOutTypes.insert(pending.type)

        // Clear the timeout tracking after a delay
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds
            recentlyTimedOutTypes.remove(pending.type)
        }

        // Record failure
        consecutiveSuccesses = 0
        consecutiveFailures += 1
        circuitBreaker.recordFailure()

        pending.continuation.resume(throwing: KasiaError.networkError("Request timeout"))

        NSLog("[GRPCStream] Request timeout on %@ (type: %@)",
              endpoint.key, String(describing: pending.type))
    }

    /// Handle send failure
    private func handleSendFailure(requestId: UInt64, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestId) else {
            return
        }

        pending.timeoutTask.cancel()

        // Remove from type queue
        if var queue = requestQueues[pending.type] {
            queue.removeAll { $0 == requestId }
            if queue.isEmpty {
                requestQueues.removeValue(forKey: pending.type)
            } else {
                requestQueues[pending.type] = queue
            }
        }

        // Record failure
        consecutiveSuccesses = 0
        consecutiveFailures += 1
        circuitBreaker.recordFailure()

        // Check if the error indicates the stream is dead (AlreadyComplete, closed, etc.)
        // If so, mark connection as disconnected to force reconnection on retry
        let errorDesc = String(describing: error).lowercased()
        if errorDesc.contains("alreadycomplete") ||
           errorDesc.contains("already complete") ||
           errorDesc.contains("connection closed") ||
           errorDesc.contains("stream closed") {
            NSLog("[GRPCStream] Stream dead on %@ - marking disconnected: %@",
                  endpoint.key, error.localizedDescription)
            markDisconnected()
        }

        pending.continuation.resume(throwing: error)
    }

    /// Mark connection as disconnected and clean up stream resources
    private func markDisconnected() {
        state = .disconnected
        connectedAt = nil

        // Clean up stale stream
        stream?.sendEnd(promise: nil)
        stream = nil

        // Close channel in background to prevent leaks
        if let ch = channel {
            Task {
                _ = try? await ch.close().get()
            }
        }
        channel = nil

        // Cancel any remaining pending requests
        for (_, pending) in pendingRequests {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: KasiaError.networkError("Connection lost"))
        }
        pendingRequests.removeAll()
        requestQueues.removeAll()
    }

    /// Determine the request type from a response message
    private func determineResponseType(_ message: Protowire_KaspadMessage) -> KaspaRequestType? {
        guard let payload = message.payload else { return nil }

        switch payload {
        case .getInfoResponse:
            return .getInfo
        case .getUtxosByAddressesResponse:
            return .getUtxosByAddresses
        case .submitTransactionResponse:
            return .submitTransaction
        case .notifyUtxosChangedResponse:
            return .notifyUtxosChanged
        case .getPeerAddressesResponse:
            return .getPeerAddresses
        case .getConnectedPeerInfoResponse:
            return .getConnectedPeerInfo
        case .getBlockDagInfoResponse:
            return .getBlockDagInfo
        case .getCurrentNetworkResponse:
            return .getCurrentNetwork
        case .getMempoolEntryResponse:
            return .getMempoolEntry
        default:
            return nil
        }
    }

    // MARK: - Notifications

    /// Handle a notification message
    private func handleNotification(_ type: KaspaRPCNotification, _ message: SwiftProtobuf.Message) {
        guard let data = try? message.serializedData() else { return }

        for handler in notificationHandlers.values {
            handler(type, data)
        }
    }

    /// Add notification handler
    func addNotificationHandler(_ handler: @escaping NotificationHandler) -> UUID {
        let id = UUID()
        notificationHandlers[id] = handler
        return id
    }

    /// Remove notification handler
    func removeNotificationHandler(_ id: UUID) {
        notificationHandlers.removeValue(forKey: id)
    }

    // MARK: - Health Metrics

    /// Get current health metrics
    func getHealthMetrics() -> (latencyMs: Double?, consecutiveSuccesses: Int, consecutiveFailures: Int) {
        (latencyEwma.value, consecutiveSuccesses, consecutiveFailures)
    }

    /// Reset health metrics (e.g., on epoch change)
    func resetHealthMetrics() {
        latencyEwma.reset()
        consecutiveSuccesses = 0
        consecutiveFailures = 0
    }

    /// Reset the circuit breaker (call after confirmed successful communication)
    func resetCircuitBreaker() {
        circuitBreaker.reset()
    }

    /// Check circuit breaker state without mutating
    var circuitBreakerState: CircuitBreaker.State {
        circuitBreaker.state
    }
}

// MARK: - Connection Pool

/// Pool of gRPC connections for reuse
/// Uses a shared EventLoopGroup for all connections to avoid resource exhaustion
actor GRPCConnectionPool {
    private var connections: [String: GRPCStreamConnection] = [:]
    private var maxConnectionsPerEndpoint = 1

    /// Maximum total connections to prevent memory exhaustion
    private let maxTotalConnections = 50

    /// Shared EventLoopGroup for all connections
    /// Using a shared group is much more efficient than one per connection
    private let sharedEventLoopGroup: EventLoopGroup

    init() {
        // Create shared event loop group with reasonable thread count
        // On mobile, 2-4 threads is usually sufficient
        self.sharedEventLoopGroup = PlatformSupport.makeEventLoopGroup(loopCount: 2)
        NSLog("[GRPCPool] Initialized with shared EventLoopGroup")
    }

    deinit {
        // Shutdown on background queue to avoid blocking
        let group = sharedEventLoopGroup
        DispatchQueue.global(qos: .utility).async {
            try? group.syncShutdownGracefully()
            NSLog("[GRPCPool] Shared EventLoopGroup shut down")
        }
    }

    /// Get or create a connection for an endpoint
    func connection(for endpoint: Endpoint) async -> GRPCStreamConnection {
        if let existing = connections[endpoint.key] {
            return existing
        }

        // Evict oldest disconnected connections if at capacity
        if connections.count >= maxTotalConnections {
            await evictOldestDisconnected()
        }

        let conn = GRPCStreamConnection(endpoint: endpoint, eventLoopGroup: sharedEventLoopGroup)
        connections[endpoint.key] = conn
        return conn
    }

    /// Evict the oldest disconnected connection to make room
    private func evictOldestDisconnected() async {
        var oldest: (key: String, lastActivity: Date)? = nil

        for (key, conn) in connections {
            // Skip connected connections
            if await conn.isConnected { continue }

            let lastActivity = await conn.lastActivityAt
            if oldest == nil || lastActivity < oldest!.lastActivity {
                oldest = (key, lastActivity)
            }
        }

        if let key = oldest?.key {
            if let conn = connections.removeValue(forKey: key) {
                await conn.disconnect()
                NSLog("[GRPCPool] Evicted oldest disconnected connection: %@", key)
            }
        }
    }

    /// Remove a connection
    func removeConnection(for endpoint: Endpoint) async {
        if let conn = connections.removeValue(forKey: endpoint.key) {
            await conn.disconnect()
        }
    }

    /// Disconnect all connections
    func disconnectAll() async {
        for conn in connections.values {
            await conn.disconnect()
        }
        connections.removeAll()
    }

    /// Get all active connections
    func allConnections() -> [GRPCStreamConnection] {
        Array(connections.values)
    }

    /// Get current connection count
    func connectionCount() -> Int {
        connections.count
    }

    /// Check if endpoint has an established connection
    func hasActiveConnection(for endpoint: Endpoint) async -> Bool {
        guard let conn = connections[endpoint.key] else { return false }
        return await conn.isConnected
    }

    /// Get endpoints with active connections
    func connectedEndpoints() async -> Set<String> {
        var connected: Set<String> = []
        for (key, conn) in connections {
            if await conn.isConnected {
                connected.insert(key)
            }
        }
        return connected
    }

    /// Prune idle/disconnected connections to free memory
    /// Keeps connections that are still connected or were recently used
    func pruneIdleConnections(maxAge: TimeInterval) async {
        var pruned = 0
        let now = Date()

        for (key, conn) in connections {
            // Keep connected connections
            if await conn.isConnected {
                continue
            }

            // Keep recently active connections (might reconnect soon)
            let lastActivity = await conn.lastActivityAt
            if now.timeIntervalSince(lastActivity) < maxAge {
                continue
            }

            // Disconnect and remove idle connections
            await conn.disconnect()
            connections.removeValue(forKey: key)
            pruned += 1
        }

        if pruned > 0 {
            NSLog("[GRPCPool] Pruned %d idle connections, %d remaining", pruned, connections.count)
        }
    }
}
