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
    /// `GRPCStreamConnection.connectionGeneration` of the primary at the moment our
    /// notifyUtxosChanged request was accepted. A stream drop + transparent self-reconnect
    /// (sleep/wake, network blip, `reconnectDisconnected` on foreground) leaves `isConnected`
    /// true and getInfo pings passing while the node-side subscription is GONE - utxosChanged
    /// has no natural heartbeat, so nothing else can tell. The health check compares the live
    /// generation against this and re-sends the subscription when they differ.
    private var primaryConnectionGeneration: Int?

    /// Whether a consumer (e.g. broadcast channel scanning) currently wants block-added
    /// notifications. Piggybacks on the primary UTXO subscription connection rather than
    /// opening a second stream; re-registered automatically on every (re)connect of that
    /// connection, including failover and epoch-change resubscribes.
    private var wantsBlockAdded = false

    /// Last time an actual block-added push notification arrived (regardless of its content).
    /// Kaspa produces blocks roughly once a second, so if `wantsBlockAdded` is true and nothing
    /// has arrived in a while, the node's subscription for it has likely silently expired/dropped
    /// server-side even though the connection itself still answers pings fine (getInfo has
    /// nothing to do with whether push notifications are still flowing) - this is used to detect
    /// that and proactively re-send the subscription request rather than requiring the user to
    /// force-quit the app to recover.
    private var lastBlockAddedNotificationAt: Date?
    private let blockAddedStaleThreshold: TimeInterval = 20

    /// Health check timer
    private var healthCheckTask: Task<Void, Never>?

    /// Consecutive failures on primary
    private var primaryFailures: Int = 0
    private let maxPrimaryFailures = 1  // Immediate failover on first ping failure

    /// Failover in progress
    private var isFailingOver = false

    /// Consecutive failed failover attempts, and when the last one happened - drives backoff so
    /// repeated failures don't re-trigger an immediate retry every healthCheckInterval (15s)
    /// indefinitely. This matters most with a single manually-pinned node (nowhere else to fail
    /// over to, so every attempt just retries the same node) - without it, a node that's
    /// rejecting new streams (e.g. it's hit its own connection-capacity limit) gets hit with a
    /// fresh attempt every 15s forever, independent of and not slowed by the connection-level
    /// backoff in GRPCStreamConnection.scheduleAutoReconnect(). Reset to 0 on success.
    private var failoverAttempts: Int = 0
    private var lastFailoverAttemptAt: Date?

    // MARK: - Configuration

    /// Health check interval (ping every 15s)
    private let healthCheckInterval: TimeInterval = 15

    /// Ping timeout
    private let pingTimeout: TimeInterval = 5.0

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
            AppLog.log("[UtxoSub] Cleaning up previous subscription state before retry")
            await cleanupExistingSubscription()
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

        AppLog.log("[UtxoSub] Trying subscription on %d capable nodes", availableNodes.count)

        // Try each node in sequence until one succeeds
        var lastError: Error?
        for (index, nodeRecord) in availableNodes.enumerated() {
            let endpoint = nodeRecord.endpoint

            AppLog.log("[UtxoSub] Attempt %d/%d: trying %@", index + 1, availableNodes.count, endpoint.key)

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

                AppLog.log("[UtxoSub] Subscribed successfully on %@", endpoint.key)
                return  // Success!

            } catch {
                AppLog.log("[UtxoSub] Subscription failed on %@: %@", endpoint.key, error.localizedDescription)
                lastError = error
                // Continue immediately to next node
            }
        }

        // All nodes failed
        state = .failed
        throw lastError ?? KasiaError.networkError("All capable nodes failed")
    }

    /// Clean up existing subscription without changing state to disconnected
    private func cleanupExistingSubscription() async {
        healthCheckTask?.cancel()
        healthCheckTask = nil

        // Remove notification handler from old connection
        if let conn = primaryConnection, let handlerId = primaryHandlerId {
            await conn.removeNotificationHandler(handlerId)
        }

        // Actually close the old connection(s), not just drop our reference to them - a
        // GRPCStreamConnection has no way to know it's being abandoned here, so it would
        // otherwise keep believing it's "connected" (e.g. right after a WiFi<->cellular switch,
        // before it's independently noticed the old socket is dead) and linger in the shared
        // pool - and the node it was talking to may not release that connection slot until its
        // own timeout eventually kicks in. Awaited (not fire-and-forget) so the immediately
        // following subscribeOn() on this same endpoint can't race a stale in-flight connect.
        if let conn = primaryConnection {
            await conn.disconnect()
        }
        if let conn = standbyConnection, conn !== primaryConnection {
            await conn.disconnect()
        }

        primaryConnection = nil
        standbyConnection = nil
        primaryHandlerId = nil
        primaryConnectionGeneration = nil
        primaryFailures = 0
        failoverAttempts = 0
        lastFailoverAttemptAt = nil
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
        primaryConnectionGeneration = nil
        subscribedAddresses = []
        primaryEndpoint = nil
        standbyEndpoint = nil
        state = .disconnected

        AppLog.log("[UtxoSub] Unsubscribed")
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

    /// Enable or disable block-added notifications on the primary connection.
    /// There is no protocol-level "stop notifying" for block-added, so disabling only
    /// stops us re-registering on future reconnects - the current connection may keep
    /// pushing block notifications, which are simply ignored client-side.
    func setBlockAddedWanted(_ wanted: Bool) async {
        wantsBlockAdded = wanted
        guard wanted, state == .subscribed, let conn = primaryConnection else { return }
        await sendNotifyBlockAdded(on: conn)
    }

    private func sendNotifyBlockAdded(on conn: GRPCStreamConnection) async {
        var msg = Protowire_KaspadMessage()
        msg.notifyBlockAddedRequest = Protowire_NotifyBlockAddedRequestMessage()
        do {
            _ = try await conn.sendRequest(
                msg,
                type: .notifyBlockAdded,
                timeout: OperationClass.subscribeUtxosChanged.timeout
            )
            // Baseline the staleness clock from here, not from the next actual notification -
            // otherwise a node that's simply slow for the first block after subscribing would
            // look "stale" and trigger an immediate, unnecessary re-send.
            lastBlockAddedNotificationAt = Date()
        } catch {
            AppLog.log("[UtxoSub] Failed to register block-added notifications: %@", error.localizedDescription)
        }
    }

    /// Reconnect to lowest latency node if not already connected to it
    func reconnectToBestNodeIfNeeded() async {
        // Act whenever we're not actively mid-attempt - deliberately NOT gated on
        // state == .subscribed only. This is called right after switching/clearing the trusted
        // node (see NodePoolService.setTrustedNodeAddress); if the old pinned node was already
        // broken (state .failed/.disconnected, e.g. it was rejecting connections), gating on
        // .subscribed meant this silently did nothing, leaving the app never subscribed to the
        // new node at all.
        guard state != .connecting, state != .failover else { return }
        guard !subscribedAddresses.isEmpty else { return }

        // Get best nodes
        let eligibleNodes = await selector.eligibleNodes(for: .subscribeUtxosChanged)
        guard let bestNode = eligibleNodes.first else { return }

        // Check if we're already connected to the best node - only meaningful when we're
        // actually subscribed; a stale primaryEndpoint from a broken prior state isn't grounds
        // to skip reconnecting.
        if state == .subscribed, let currentPrimary = primaryEndpoint, currentPrimary.key == bestNode.endpoint.key {
            AppLog.log("[UtxoSub] Already connected to best node: %@", currentPrimary.key)
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

        AppLog.log("[UtxoSub] Pool is healthy - reconnecting to lowest latency node: %@ (%.0fms, was: %@)",
              bestNode.endpoint.key,
              bestLatency,
              currentLatency.map { String(format: "%.0fms", $0) } ?? "none")

        // Resubscribe to best node
        do {
            try await subscribe(addresses: subscribedAddresses)
        } catch {
            AppLog.log("[UtxoSub] Failed to reconnect to best node: %@", error.localizedDescription)
        }
    }

    /// Reconnect to a specific endpoint (triggered by better node detection)
    func reconnectToEndpoint(_ endpoint: Endpoint) async {
        // Only reconnect if currently subscribed
        guard state == .subscribed else { return }
        guard !subscribedAddresses.isEmpty else { return }

        // Check if we're already connected to this endpoint
        if let currentPrimary = primaryEndpoint, currentPrimary.key == endpoint.key {
            AppLog.log("[UtxoSub] Already connected to endpoint: %@", endpoint.key)
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

        AppLog.log("[UtxoSub] Reconnecting to better node: %@ (%.0fms, was: %@)",
              endpoint.key,
              targetLatency,
              currentLatency.map { String(format: "%.0fms", $0) } ?? "none")

        // Resubscribe to target node
        do {
            try await subscribe(addresses: subscribedAddresses)
        } catch {
            AppLog.log("[UtxoSub] Failed to reconnect to better node: %@", error.localizedDescription)
        }
    }

    // MARK: - Internal Subscription

    private func subscribeOn(endpoint: Endpoint, isPrimary: Bool) async throws {
        let conn = await connectionPool.connection(for: endpoint)

        // Connect if needed
        if await !conn.isConnected {
            try await conn.connect()
        }

        // Read the generation BEFORE sending: if the stream flips between the request and the
        // health check, the next tick sees a newer generation and re-arms (never the reverse).
        let generationAtSubscribe = await conn.connectionGeneration

        // Subscribe request
        let subscribeStart = Date()
        try await sendNotifyUtxosChanged(on: conn)

        // An accepted subscription is a full request/response roundtrip - record it so the
        // registry (and the blocked-network detector reading it) sees this success immediately,
        // not only at the next 15s health ping.
        await registry.recordResult(
            endpoint: endpoint,
            epochId: epochMonitor.epochId,
            latencyMs: Date().timeIntervalSince(subscribeStart) * 1000,
            isTimeout: false,
            isError: false
        )

        // Add notification handler to connection
        let handlerId = await conn.addNotificationHandler { [weak self] type, data in
            Task { @MainActor in
                self?.handleNotification(type, data: data)
            }
        }

        if isPrimary {
            primaryConnection = conn
            primaryHandlerId = handlerId
            primaryConnectionGeneration = generationAtSubscribe
            if wantsBlockAdded {
                await sendNotifyBlockAdded(on: conn)
            }
        } else {
            standbyConnection = conn
        }
    }

    /// Send the notifyUtxosChanged request for `subscribedAddresses` on `conn` and validate
    /// the response. Used both for the initial subscribe and for re-arming a subscription the
    /// node silently dropped when the underlying stream reconnected.
    private func sendNotifyUtxosChanged(on conn: GRPCStreamConnection) async throws {
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
    }

    // MARK: - Notification Handling

    private func handleNotification(_ type: KaspaRPCNotification, data: Data) {
        lastNotificationAt = Date()
        if type == .blockAdded {
            lastBlockAddedNotificationAt = Date()
        }

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

            // Feed the success into the registry: the subscription is the app's primary
            // long-lived connection, but its pings previously left no trace there, so the
            // blocked-network detector (which reads registry lastSuccessAt) could see "zero
            // recent successes" while a perfectly healthy subscription was pinging every 15s.
            // Also keeps the primary's health/latency fresh between (slow) profiler probes.
            await registry.recordResult(
                endpoint: endpoint,
                epochId: epochMonitor.epochId,
                latencyMs: latencyMs,
                isTimeout: false,
                isError: false
            )

            AppLog.log("[UtxoSub] Ping OK on %@ (%.0fms)", endpoint.key, latencyMs)

        } catch {
            AppLog.log("[UtxoSub] Ping failed on %@ - triggering immediate failover: %@", endpoint.key, error.localizedDescription)
            await handlePrimaryFailure()
            return
        }

        // A ping that succeeds on a stream that was transparently re-established since we
        // subscribed is the silent-loss case: the node forgot our utxosChanged subscription
        // with the old stream, and this is the ONLY signal we have (no heartbeat exists for
        // utxosChanged). Re-arm it on the same connection before anything else.
        await resubscribeIfPrimaryReconnected(conn: conn, endpoint: endpoint)

        // The ping above only proves the connection still answers requests - it says nothing
        // about whether the node is still actually pushing block-added notifications on it. Kaspa
        // produces a block roughly every second, so total silence for this long while we still
        // want them means that specific subscription silently died server-side; re-register it.
        if wantsBlockAdded {
            let staleness = lastBlockAddedNotificationAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if staleness > blockAddedStaleThreshold {
                AppLog.log("[UtxoSub] Block-added notifications stale (%.0fs) - re-registering", staleness)
                await sendNotifyBlockAdded(on: conn)
            }
        }
    }

    /// Re-arm the utxosChanged subscription if the primary stream was re-established since we
    /// subscribed (see `primaryConnectionGeneration`). Safe to call any time: no-op unless we're
    /// `.subscribed` and the generation moved. Called from the 15s health check and eagerly from
    /// `NodePoolService.reconnectStaleConnections()` on app foreground, so a subscription lost
    /// while backgrounded is restored immediately rather than up to a health tick later.
    func verifyPrimarySubscription() async {
        guard state == .subscribed, let endpoint = primaryEndpoint, let conn = primaryConnection else { return }
        guard await conn.isConnected else { return }
        await resubscribeIfPrimaryReconnected(conn: conn, endpoint: endpoint)
    }

    private func resubscribeIfPrimaryReconnected(conn: GRPCStreamConnection, endpoint: Endpoint) async {
        guard state == .subscribed else { return }
        let liveGeneration = await conn.connectionGeneration
        guard let subscribedGeneration = primaryConnectionGeneration, liveGeneration != subscribedGeneration else {
            return
        }

        AppLog.log("[UtxoSub] Primary %@ reconnected underneath us (gen %d -> %d) - re-sending utxosChanged subscription for %d addresses",
                   endpoint.key, subscribedGeneration, liveGeneration, subscribedAddresses.count)
        do {
            // The notification handler registered in subscribeOn() survives the reconnect (it's
            // keyed on the GRPCStreamConnection, not the stream), so only the request is re-sent.
            try await sendNotifyUtxosChanged(on: conn)
            primaryConnectionGeneration = liveGeneration
            if wantsBlockAdded {
                await sendNotifyBlockAdded(on: conn)
            }
            AppLog.log("[UtxoSub] utxosChanged subscription re-armed on %@", endpoint.key)
            // Anything that confirmed during the dead window never reached us - let ChatService
            // run its catch-up sync (observer of this name; honors push-reliability debounce).
            NotificationCenter.default.post(name: .rpcSubscriptionsRestored, object: nil)
        } catch {
            AppLog.log("[UtxoSub] Re-arming subscription on %@ failed: %@ - failing over", endpoint.key, error.localizedDescription)
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

        // Capped exponential backoff (1, 2, 4, 8, 16, 30, 30...s) between attempts once at
        // least one has already failed - see failoverAttempts' doc comment.
        if failoverAttempts > 0, let lastAttempt = lastFailoverAttemptAt {
            let backoff = min(30.0, pow(2.0, Double(failoverAttempts - 1)))
            guard Date().timeIntervalSince(lastAttempt) >= backoff else { return }
        }
        failoverAttempts += 1
        lastFailoverAttemptAt = Date()

        isFailingOver = true
        state = .failover

        AppLog.log("[UtxoSub] Starting failover from %@", primaryEndpoint?.key ?? "unknown")

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
                failoverAttempts = 0
                isFailingOver = false

                AppLog.log("[UtxoSub] Failover to standby successful: %@", standby.key)
                return

            } catch {
                AppLog.log("[UtxoSub] Standby failover failed: %@", error.localizedDescription)
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
                failoverAttempts = 0
                isFailingOver = false

                AppLog.log("[UtxoSub] Failover to new primary: %@", selection.primary.key)
                return

            } catch {
                AppLog.log("[UtxoSub] New primary failover failed: %@", error.localizedDescription)
            }
        }

        // Complete failure
        state = .failed
        isFailingOver = false
        AppLog.log("[UtxoSub] Failover failed - no working endpoints")
    }

    // MARK: - State Resync

    /// Resync UTXO state after failover
    /// Fetches current UTXOs and compares with cached state
    private func resyncUtxoState() async {
        guard let primary = primaryEndpoint, let conn = primaryConnection else { return }

        AppLog.log("[UtxoSub] Resyncing UTXO state on %@", primary.key)

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
                AppLog.log("[UtxoSub] Resync: invalid response type")
                return
            }

            // Convert to notification format and dispatch
            // This simulates receiving a "full state" notification
            if let data = try? utxoResponse.serializedData() {
                for handler in notificationHandlers.values {
                    handler(.utxosChanged, data)
                }
            }

            AppLog.log("[UtxoSub] Resync complete - %d UTXOs", utxoResponse.entries.count)

        } catch {
            AppLog.log("[UtxoSub] Resync failed: %@", error.localizedDescription)
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
            AppLog.log("[UtxoSub] Standby warmed up: %@", endpoint.key)

        } catch {
            AppLog.log("[UtxoSub] Standby warmup failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Epoch Changes

    private func handleEpochChange() async {
        // Deliberately not gated on state == .subscribed - a WiFi<->cellular switch (or any
        // other path change) can happen while the subscription is already broken for an
        // unrelated reason (e.g. .failed/.disconnected), and that's exactly when resubscribing
        // matters most. Gating on .subscribed only meant a phone that flips networks while
        // already disconnected just stayed disconnected until something else happened to retry.
        guard state != .connecting, state != .failover else { return }
        guard !subscribedAddresses.isEmpty else { return }

        AppLog.log("[UtxoSub] Network epoch changed - resubscribing")

        // Resubscribe to current addresses
        do {
            try await subscribe(addresses: subscribedAddresses)
        } catch {
            AppLog.log("[UtxoSub] Resubscription after epoch change failed: %@", error.localizedDescription)
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
