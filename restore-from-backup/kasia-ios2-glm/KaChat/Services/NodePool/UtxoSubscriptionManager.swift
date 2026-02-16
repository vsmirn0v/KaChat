import Foundation
import Combine

/// Subscription state
enum SubscriptionState: Equatable {
    case disconnected
    case connecting
    case subscribed
    case failover
    case failed
}

/// Manages UTXO subscriptions with sticky primary + warm standby pattern
/// Provides automatic failover and state resync on reconnection
@MainActor
final class UtxoSubscriptionManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var state: SubscriptionState = .disconnected
    @Published private(set) var primaryEndpoint: Endpoint?
    @Published private(set) var standbyEndpoint: Endpoint?
    @Published private(set) var lastNotificationAt: Date?

    // MARK: - Dependencies

    private let registry: NodeRegistry
    private let selector: NodeSelector
    private let connectionPool: GRPCConnectionPool
    private let epochMonitor: NetworkEpochMonitor

    // MARK: - State

    private var subscribedAddresses: [String] = []
    private var notificationHandlers: [UUID: (KaspaRPCNotification, Data) -> Void] = [:]
    private var primaryConnection: GRPCStreamConnection?
    private var standbyConnection: GRPCStreamConnection?
    private var primaryHandlerId: UUID?

    /// Health check timer
    private var healthCheckTask: Task<Void, Never>?

    /// Consecutive failures on primary
    private var primaryFailures: Int = 0
    private let maxPrimaryFailures = 1  // Immediate failover on first ping failure

    /// Failover in progress
    private var isFailingOver = false

    // MARK: - Configuration

    /// Health check interval (ping every 15s)
    private let healthCheckInterval: TimeInterval = 15

    /// Ping timeout
    private let pingTimeout: TimeInterval = 5.0

    /// Standby warmup interval
    private let standbyWarmupInterval: TimeInterval = 60

    // MARK: - Initialization

    init(
        registry: NodeRegistry,
        selector: NodeSelector,
        connectionPool: GRPCConnectionPool,
        epochMonitor: NetworkEpochMonitor
    ) {
        self.registry = registry
        self.selector = selector
        self.connectionPool = connectionPool
        self.epochMonitor = epochMonitor

        // Subscribe to epoch changes
        epochMonitor.onEpochChange { [weak self] _ in
            Task { @MainActor in
                await self?.handleEpochChange()
            }
        }
    }

    // MARK: - Public API

    /// Subscribe to UTXO changes for addresses
    /// Tries all capable nodes in pool in sequence, throws if all fail
    func subscribe(addresses: [String], excluding: Set<String> = []) async throws {
        guard !addresses.isEmpty else { return }

        // Clean up any existing subscription state before retrying
        if state != .disconnected {
            NSLog("[UtxoSub] Cleaning up previous subscription state before retry")
            cleanupExistingSubscription()
        }

        self.subscribedAddresses = addresses
        state = .connecting

        // Get all capable nodes, sorted by score
        let allCapableNodes = await selector.eligibleNodes(for: .subscribeUtxosChanged)
        let availableNodes = allCapableNodes.filter { !excluding.contains($0.endpoint.key) }

        guard !availableNodes.isEmpty else {
            state = .failed
            if allCapableNodes.isEmpty {
                throw KasiaError.networkError("No capable nodes in pool (need synced + UTXO indexed)")
            } else {
                throw KasiaError.networkError("All \(allCapableNodes.count) capable nodes already tried")
            }
        }

        NSLog("[UtxoSub] Trying subscription on %d capable nodes", availableNodes.count)

        // Try each node in sequence until one succeeds
        var lastError: Error?
        for (index, nodeRecord) in availableNodes.enumerated() {
            let endpoint = nodeRecord.endpoint

            NSLog("[UtxoSub] Attempt %d/%d: trying %@", index + 1, availableNodes.count, endpoint.key)

            do {
                primaryEndpoint = endpoint

                try await subscribeOn(endpoint: endpoint, isPrimary: true)
                state = .subscribed
                primaryFailures = 0

                // Start health monitoring
                startHealthCheck()

                // Select standby from remaining nodes
                let standbyNodes = await selector.pickBest(
                    for: .subscribeUtxosChanged,
                    count: 2,
                    excluding: Set([endpoint.key])
                )
                if standbyNodes.count > 1 {
                    standbyEndpoint = standbyNodes[1]
                    Task {
                        await warmupStandby(standbyNodes[1])
                    }
                }

                NSLog("[UtxoSub] Subscribed successfully on %@", endpoint.key)
                return  // Success!

            } catch {
                NSLog("[UtxoSub] Subscription failed on %@: %@", endpoint.key, error.localizedDescription)
                lastError = error
                // Continue immediately to next node
            }
        }

        // All nodes failed
        state = .failed
        throw lastError ?? KasiaError.networkError("All capable nodes failed")
    }

    /// Clean up existing subscription without changing state to disconnected
    private func cleanupExistingSubscription() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        // Remove notification handler from old connection
        if let conn = primaryConnection, let handlerId = primaryHandlerId {
            Task {
                await conn.removeNotificationHandler(handlerId)
            }
        }

        primaryConnection = nil
        standbyConnection = nil
        primaryHandlerId = nil
        primaryFailures = 0
        isFailingOver = false
    }

    /// Unsubscribe from UTXO changes
    func unsubscribe() {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        // Remove notification handlers from connections
        if let conn = primaryConnection, let handlerId = primaryHandlerId {
            Task {
                await conn.removeNotificationHandler(handlerId)
            }
        }

        primaryConnection = nil
        standbyConnection = nil
        primaryHandlerId = nil
        subscribedAddresses = []
        primaryEndpoint = nil
        standbyEndpoint = nil
        state = .disconnected

        NSLog("[UtxoSub] Unsubscribed")
    }

    /// Add notification handler
    func addNotificationHandler(_ handler: @escaping (KaspaRPCNotification, Data) -> Void) -> UUID {
        let id = UUID()
        notificationHandlers[id] = handler
        return id
    }

    /// Remove notification handler
    func removeNotificationHandler(_ id: UUID) {
        notificationHandlers.removeValue(forKey: id)
    }

    /// Reconnect to lowest latency node if not already connected to it
    func reconnectToBestNodeIfNeeded() async {
        // Only reconnect if currently subscribed
        guard state == .subscribed else { return }
        guard !subscribedAddresses.isEmpty else { return }

        // Get best nodes
        let eligibleNodes = await selector.eligibleNodes(for: .subscribeUtxosChanged)
        guard let bestNode = eligibleNodes.first else { return }

        // Check if we're already connected to the best node
        if let currentPrimary = primaryEndpoint, currentPrimary.key == bestNode.endpoint.key {
            NSLog("[UtxoSub] Already connected to best node: %@", currentPrimary.key)
            return
        }

        // Get latency info for logging
        let bestLatency = bestNode.health.latencyMs.value ?? bestNode.health.globalLatencyMs.value ?? 0
        let currentLatency: Double?
        if let currentPrimary = primaryEndpoint {
            let currentRecord = await registry.get(currentPrimary)
            currentLatency = currentRecord?.health.latencyMs.value ?? currentRecord?.health.globalLatencyMs.value
        } else {
            currentLatency = nil
        }

        NSLog("[UtxoSub] Pool is healthy - reconnecting to lowest latency node: %@ (%.0fms, was: %@)",
              bestNode.endpoint.key,
              bestLatency,
              currentLatency.map { String(format: "%.0fms", $0) } ?? "none")

        // Resubscribe to best node
        do {
            try await subscribe(addresses: subscribedAddresses)
        } catch {
            NSLog("[UtxoSub] Failed to reconnect to best node: %@", error.localizedDescription)
        }
    }

    /// Reconnect to a specific endpoint (triggered by better node detection)
    func reconnectToEndpoint(_ endpoint: Endpoint) async {
        // Only reconnect if currently subscribed
        guard state == .subscribed else { return }
        guard !subscribedAddresses.isEmpty else { return }

        // Check if we're already connected to this endpoint
        if let currentPrimary = primaryEndpoint, currentPrimary.key == endpoint.key {
            NSLog("[UtxoSub] Already connected to endpoint: %@", endpoint.key)
            return
        }

        // Get latency info for logging
        let targetRecord = await registry.get(endpoint)
        let targetLatency = targetRecord?.health.latencyMs.value ?? targetRecord?.health.globalLatencyMs.value ?? 0

        let currentLatency: Double?
        if let currentPrimary = primaryEndpoint {
            let currentRecord = await registry.get(currentPrimary)
            currentLatency = currentRecord?.health.latencyMs.value ?? currentRecord?.health.globalLatencyMs.value
        } else {
            currentLatency = nil
        }

        NSLog("[UtxoSub] Reconnecting to better node: %@ (%.0fms, was: %@)",
              endpoint.key,
              targetLatency,
              currentLatency.map { String(format: "%.0fms", $0) } ?? "none")

        // Resubscribe to target node
        do {
            try await subscribe(addresses: subscribedAddresses)
        } catch {
            NSLog("[UtxoSub] Failed to reconnect to better node: %@", error.localizedDescription)
        }
    }

    // MARK: - Internal Subscription

    private func subscribeOn(endpoint: Endpoint, isPrimary: Bool) async throws {
        let conn = await connectionPool.connection(for: endpoint)

        // Connect if needed
        if await !conn.isConnected {
            try await conn.connect()
        }

        // Subscribe request
        var msg = Protowire_KaspadMessage()
        var req = Protowire_NotifyUtxosChangedRequestMessage()
        req.addresses = subscribedAddresses
        msg.notifyUtxosChangedRequest = req

        let response = try await conn.sendRequest(
            msg,
            type: .notifyUtxosChanged,
            timeout: OperationClass.subscribeUtxosChanged.timeout
        )

        guard case .notifyUtxosChangedResponse(let subResponse) = response.payload else {
            throw KasiaError.networkError("Unexpected response type")
        }

        if subResponse.hasError && !subResponse.error.message.isEmpty {
            throw KasiaError.networkError(subResponse.error.message)
        }

        // Add notification handler to connection
        let handlerId = await conn.addNotificationHandler { [weak self] type, data in
            Task { @MainActor in
                self?.handleNotification(type, data: data)
            }
        }

        if isPrimary {
            primaryConnection = conn
            primaryHandlerId = handlerId
        } else {
            standbyConnection = conn
        }
    }

    // MARK: - Notification Handling

    private func handleNotification(_ type: KaspaRPCNotification, data: Data) {
        lastNotificationAt = Date()

        // Forward to all handlers
        for handler in notificationHandlers.values {
            handler(type, data)
        }
    }

    // MARK: - Health Monitoring

    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))

                if !Task.isCancelled {
                    await checkPrimaryHealth()
                }
            }
        }
    }

    private func checkPrimaryHealth() async {
        guard let endpoint = primaryEndpoint, let conn = primaryConnection else { return }

        // Check if connection is still active
        if await !conn.isConnected {
            await handlePrimaryFailure()
            return
        }

        // Check if circuit breaker is open
        if await conn.isCircuitOpen {
            await handlePrimaryFailure()
            return
        }

        // Send ping (getInfo) request to keep connection alive
        do {
            var msg = Protowire_KaspadMessage()
            msg.getInfoRequest = Protowire_GetInfoRequestMessage()

            let startTime = Date()
            _ = try await conn.sendRequest(msg, type: .getInfo, timeout: pingTimeout)
            let latencyMs = Date().timeIntervalSince(startTime) * 1000

            // Connection is alive
            primaryFailures = 0

            NSLog("[UtxoSub] Ping OK on %@ (%.0fms)", endpoint.key, latencyMs)

        } catch {
            NSLog("[UtxoSub] Ping failed on %@ - triggering immediate failover: %@", endpoint.key, error.localizedDescription)
            await handlePrimaryFailure()
        }
    }

    // MARK: - Failover

    private func handlePrimaryFailure() async {
        primaryFailures += 1

        // Immediate failover on first failure
        if primaryFailures >= maxPrimaryFailures {
            await performFailover()
        }
    }

    private func performFailover() async {
        guard !isFailingOver else { return }
        isFailingOver = true
        state = .failover

        NSLog("[UtxoSub] Starting failover from %@", primaryEndpoint?.key ?? "unknown")

        // Try standby first
        if let standby = standbyEndpoint {
            do {
                try await subscribeOn(endpoint: standby, isPrimary: true)

                // Demote old primary, promote standby
                let oldPrimary = primaryEndpoint
                primaryEndpoint = standby
                standbyEndpoint = oldPrimary  // Can try to recover later

                // Resync state by fetching current UTXOs
                await resyncUtxoState()

                state = .subscribed
                primaryFailures = 0
                isFailingOver = false

                NSLog("[UtxoSub] Failover to standby successful: %@", standby.key)
                return

            } catch {
                NSLog("[UtxoSub] Standby failover failed: %@", error.localizedDescription)
            }
        }

        // Standby failed or not available, pick new endpoints
        if let selection = await selector.pickPrimaryAndStandby(for: .subscribeUtxosChanged) {
            do {
                try await subscribeOn(endpoint: selection.primary, isPrimary: true)
                primaryEndpoint = selection.primary
                standbyEndpoint = selection.standby

                await resyncUtxoState()

                state = .subscribed
                primaryFailures = 0
                isFailingOver = false

                NSLog("[UtxoSub] Failover to new primary: %@", selection.primary.key)
                return

            } catch {
                NSLog("[UtxoSub] New primary failover failed: %@", error.localizedDescription)
            }
        }

        // Complete failure
        state = .failed
        isFailingOver = false
        NSLog("[UtxoSub] Failover failed - no working endpoints")
    }

    // MARK: - State Resync

    /// Resync UTXO state after failover
    /// Fetches current UTXOs and compares with cached state
    private func resyncUtxoState() async {
        guard let primary = primaryEndpoint, let conn = primaryConnection else { return }

        NSLog("[UtxoSub] Resyncing UTXO state on %@", primary.key)

        do {
            // Fetch current UTXOs
            var msg = Protowire_KaspadMessage()
            var req = Protowire_GetUtxosByAddressesRequestMessage()
            req.addresses = subscribedAddresses
            msg.getUtxosByAddressesRequest = req

            let response = try await conn.sendRequest(
                msg,
                type: .getUtxosByAddresses,
                timeout: OperationClass.getUtxosByAddress.timeout
            )

            guard case .getUtxosByAddressesResponse(let utxoResponse) = response.payload else {
                NSLog("[UtxoSub] Resync: invalid response type")
                return
            }

            // Convert to notification format and dispatch
            // This simulates receiving a "full state" notification
            if let data = try? utxoResponse.serializedData() {
                for handler in notificationHandlers.values {
                    handler(.utxosChanged, data)
                }
            }

            NSLog("[UtxoSub] Resync complete - %d UTXOs", utxoResponse.entries.count)

        } catch {
            NSLog("[UtxoSub] Resync failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Standby Warmup

    /// Keep standby connection warm
    private func warmupStandby(_ endpoint: Endpoint) async {
        let conn = await connectionPool.connection(for: endpoint)

        do {
            if await !conn.isConnected {
                try await conn.connect()
            }

            // Verify node is responsive with getInfo
            var msg = Protowire_KaspadMessage()
            msg.getInfoRequest = Protowire_GetInfoRequestMessage()
            _ = try await conn.sendRequest(msg, type: .getInfo, timeout: 5)

            // Explicitly reset circuit breaker after successful warmup
            await conn.resetCircuitBreaker()

            standbyConnection = conn
            NSLog("[UtxoSub] Standby warmed up: %@", endpoint.key)

        } catch {
            NSLog("[UtxoSub] Standby warmup failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Epoch Changes

    private func handleEpochChange() async {
        guard state == .subscribed else { return }

        NSLog("[UtxoSub] Network epoch changed - resubscribing")

        // Resubscribe to current addresses
        do {
            try await subscribe(addresses: subscribedAddresses)
        } catch {
            NSLog("[UtxoSub] Resubscription after epoch change failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Manual Triggers

    /// Force failover to standby (for testing)
    func forceFailover() async {
        await performFailover()
    }

    /// Force resync UTXO state
    func forceResync() async {
        await resyncUtxoState()
    }

    /// Get current status for UI
    var statusDescription: String {
        var parts: [String] = []
        parts.append(String(describing: state))

        if let primary = primaryEndpoint {
            parts.append("primary: \(primary.host)")
        }

        if let standby = standbyEndpoint {
            parts.append("standby: \(standby.host)")
        }

        if let lastNotif = lastNotificationAt {
            let ago = Int(Date().timeIntervalSince(lastNotif))
            parts.append("last notification: \(ago)s ago")
        }

        return parts.joined(separator: ", ")
    }
}
