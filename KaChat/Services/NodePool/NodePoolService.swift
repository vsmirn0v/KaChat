import Foundation
import Combine

/// Unified node pool service that integrates all POOLS_v2 components
/// This is the main entry point for the node pool system
@MainActor
final class NodePoolService: ObservableObject {
    // MARK: - Singleton

    static let shared = NodePoolService()

    // MARK: - Published Properties

    @Published private(set) var isReady = false
    @Published private(set) var poolHealth: PoolHealth = .failed
    @Published private(set) var networkQuality: NetworkQuality = .good
    @Published private(set) var activeNodeCount: Int = 0

    // Subscription state
    @Published private(set) var subscriptionState: SubscriptionState = .disconnected
    @Published private(set) var primaryEndpoint: Endpoint?

    // Pool counts by state (for UI)
    @Published private(set) var activeCount: Int = 0
    @Published private(set) var verifiedCount: Int = 0
    @Published private(set) var profiledCount: Int = 0
    @Published private(set) var candidateCount: Int = 0
    @Published private(set) var suspectCount: Int = 0
    @Published private(set) var quarantinedCount: Int = 0

    // Connection status (for UI)
    @Published private(set) var lastPingLatencyMs: Int?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var connectionError: String?

    // MARK: - Components

    let registry: NodeRegistry
    private let epochMonitor: NetworkEpochMonitor
    private let selector: NodeSelector
    private let connectionPool: GRPCConnectionPool
    private var profiler: NodeProfiler?
    private var subscriptionManager: UtxoSubscriptionManager?

    // MARK: - State

    private(set) var networkType: NetworkType = .mainnet
    private var isInitialized = false
    private var isInitializing = false
    private var quickBootTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var statsUpdateTask: Task<Void, Never>?
    private var previousPoolHealth: PoolHealth?

    // MARK: - Initialization

    private init() {
        self.registry = NodeRegistry()
        self.epochMonitor = NetworkEpochMonitor.shared
        self.connectionPool = GRPCConnectionPool()
        self.selector = NodeSelector(registry: registry, epochMonitor: epochMonitor)

        setupBindings()
    }

    private func setupBindings() {
        // Bind network quality
        epochMonitor.$networkQuality
            .receive(on: DispatchQueue.main)
            .assign(to: &$networkQuality)

        // Bind subscription state when manager is created

        // Reset per-node health stats (latency EWMA, error rates) on a network path change
        // (WiFi<->cellular, VPN toggle) - a node's observed latency/error history from the old
        // path is meaningless on the new one and would otherwise bias selection with stale data.
        // The only other place this was wired up (KaspaRPCRouter) is dead code that's never
        // instantiated, so this was never actually happening.
        epochMonitor.onEpochChange { [weak self] newEpochId in
            Task {
                await self?.registry.resetEpochStats(newEpochId: newEpochId)
            }
        }
    }

    // MARK: - Lifecycle

    /// Initialize the node pool for a network
    func initialize(network: NetworkType) async {
        // Already fully initialized - nothing to do
        if isInitialized {
            AppLog.log("[NodePool] Already initialized")
            return
        }

        // Initialization already in progress - wait for quickBoot to complete
        if isInitializing {
            AppLog.log("[NodePool] Initialization already in progress, waiting for quickBoot...")
            // Wait for the existing quickBoot task if available
            if let bootTask = quickBootTask {
                await bootTask.value
            }
            // Wait until initialization completes
            while isInitializing && !isInitialized {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
            AppLog.log("[NodePool] Existing initialization complete, ready")
            return
        }

        isInitializing = true
        self.networkType = network
        AppLog.log("[NodePool] Initializing for %@", network.displayName)

        // Load persisted records FIRST
        await registry.load()

        // Initialize seed nodes
        await registry.initializeSeeds(for: network)

        // Migrate from old format if needed
        await migrateFromOldFormat()

        // Apply a pinned trusted node (Kaspium-style fixed-node mode) before any
        // discovery/quickBoot work starts, so nothing else gets a chance to upsert.
        let trustedAddress = AppSettings.load().trustedNodeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trustedEndpoint = trustedAddress.isEmpty ? nil : Endpoint(url: trustedAddress)
        if let trustedEndpoint {
            await registry.setTrustedNode(trustedEndpoint)
        }

        // Check if we have cached active nodes - if yes, we can be ready immediately.
        // Computed AFTER setTrustedNode above (not before): setTrustedNode discards every
        // record but the pinned one, so counting active nodes from the pre-pin registry
        // could see leftover discovered/seed nodes from a prior normal-discovery session and
        // wrongly conclude the pool was already healthy - skipping the trusted node's own
        // direct-probe path below even though the pinned node itself had never been probed,
        // which left it stuck showing "candidate" forever (quickBoot() never reaches
        // .userAdded-origin nodes - see the branch below).
        let cachedActiveCount = await registry.stateCounts()[.active] ?? 0
        let hasCachedActiveNodes = cachedActiveCount > 0

        if hasCachedActiveNodes {
            AppLog.log("[NodePool] Found %d cached active nodes - ready for immediate connection", cachedActiveCount)
        }

        // Create profiler
        profiler = NodeProfiler(
            registry: registry,
            connectionPool: connectionPool,
            epochMonitor: epochMonitor
        )

        // Set up better node detection callbacks
        await profiler?.setBetterNodeCallbacks(
            getPrimaryEndpoint: { [weak self] in
                await MainActor.run { self?.primaryEndpoint }
            },
            onBetterNodeDetected: { [weak self] betterEndpoint in
                await self?.handleBetterNodeDetected(betterEndpoint)
            }
        )

        // Create subscription manager
        subscriptionManager = UtxoSubscriptionManager(
            registry: registry,
            selector: selector,
            connectionPool: connectionPool,
            epochMonitor: epochMonitor
        )

        // Bind subscription manager state
        subscriptionManager?.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$subscriptionState)

        subscriptionManager?.$primaryEndpoint
            .receive(on: DispatchQueue.main)
            .assign(to: &$primaryEndpoint)

        // Start epoch monitoring
        epochMonitor.start()

        // Start profiler
        await profiler?.start(network: network)

        // If we have cached active nodes, mark as ready BEFORE quickBoot
        // This allows subscription to start immediately
        if hasCachedActiveNodes {
            isInitialized = true
            isInitializing = false
            isReady = true
            activeNodeCount = cachedActiveCount
            await updatePoolStats()
            AppLog.log("[NodePool] Ready with cached nodes - quickBoot will run in background")

            // Run quickBoot in background to refresh/expand pool
            quickBootTask = Task {
                await self.profiler?.quickBoot()
                await self.updatePoolStats()
                AppLog.log("[NodePool] Background quickBoot complete")
            }
        } else if let trustedEndpoint {
            // Trusted mode with no cached active state (first pin, or a fresh install
            // already defaulted to one): quickBoot()'s discovery loops only ever consider
            // .seed/.discovered origin candidates, and registry.upsert() rejects every
            // endpoint but this one while pinned, so quickBoot would find nothing and just
            // burn several seconds polling for seeds that can never arrive. Probe the
            // pinned node directly instead, bypassing the priority/interval gate that
            // selectNodesForProbing() uses to throttle a large discovery pool (which would
            // otherwise leave a freshly-added node sitting in .candidate for minutes) -
            // twice, so it clears the two-consecutive-success bar rebalanceActivePool()
            // requires before promoting anything out of .candidate.
            AppLog.log("[NodePool] Trusted node pinned - probing directly instead of quickBoot")
            await profiler?.profileEndpoint(trustedEndpoint)
            await profiler?.profileEndpoint(trustedEndpoint)
            await registry.rebalanceActivePool()
            await updatePoolStats()
            isInitialized = true
            isInitializing = false
            isReady = true
        } else {
            // No cached nodes - must wait for quickBoot
            AppLog.log("[NodePool] No cached active nodes - waiting for quickBoot")

            // Store the quickBoot task so other callers can wait on it
            quickBootTask = Task {
                await self.profiler?.quickBoot()
            }
            await quickBootTask?.value
            await updatePoolStats()
            isInitialized = true
            isInitializing = false
            isReady = true
        }

        // Start periodic stats update
        startPeriodicStatsUpdate()

        AppLog.log("[NodePool] Initialization complete")
    }

    /// Shutdown the node pool
    func shutdown() async {
        guard isInitialized || isInitializing else { return }

        AppLog.log("[NodePool] Shutting down")

        // Cancel any in-progress quickBoot
        quickBootTask?.cancel()
        quickBootTask = nil

        // Stop periodic stats update
        statsUpdateTask?.cancel()
        statsUpdateTask = nil

        // Stop profiler
        await profiler?.stop()

        // Unsubscribe
        subscriptionManager?.unsubscribe()

        // Stop epoch monitoring
        epochMonitor.stop()

        // Disconnect all connections
        await connectionPool.disconnectAll()

        // Persist registry
        await registry.persistNow()

        isInitialized = false
        isInitializing = false
        isReady = false

        AppLog.log("[NodePool] Shutdown complete")
    }

    /// True while discovery/probe loops are paused via `pauseDiscovery()` (e.g. off the chat tab).
    private(set) var isDiscoveryPaused = false

    /// Pauses the node discovery/probe loops (the aggressive background scanning), the periodic
    /// stats loop, and any in-flight quickBoot - WITHOUT tearing the pool down. The registry, the
    /// cached active nodes, the connection pool, the epoch monitor and any live UTXO subscription
    /// all stay intact, so on-demand work (sending, balance refresh, transaction history) and
    /// message/balance delivery keep working; only the background scanning stops. Idempotent.
    /// Used to stop scanning while the user is away from the chat tab. Contrast with `shutdown()`,
    /// which is the destructive all-or-nothing teardown.
    func pauseDiscovery() async {
        guard isInitialized, !isDiscoveryPaused else { return }
        isDiscoveryPaused = true
        quickBootTask?.cancel()
        quickBootTask = nil
        statsUpdateTask?.cancel()
        statsUpdateTask = nil
        await profiler?.stop()
        AppLog.log("[NodePool] Discovery paused (pool + subscription kept alive)")
    }

    /// Resumes the loops paused by `pauseDiscovery()`. Mirrors `initialize`'s cached-nodes path:
    /// restarts the profiler loops + stats loop and kicks a background quickBoot to restore
    /// DNS/peer discovery (which `profiler.stop()` cancelled). No-op if not initialized or not paused.
    func resumeDiscovery() async {
        guard isInitialized, isDiscoveryPaused else { return }
        isDiscoveryPaused = false
        await profiler?.start(network: networkType)
        startPeriodicStatsUpdate()
        quickBootTask?.cancel()
        quickBootTask = Task {
            await self.profiler?.quickBoot()
            await self.updatePoolStats()
        }
        AppLog.log("[NodePool] Discovery resumed")
    }

    /// Start node discovery early (before wallet is created/imported)
    /// This pre-warms the node pool so it's ready when the user finishes onboarding
    func startEarlyDiscovery(network: NetworkType = .mainnet) async {
        // Initialize if not already done
        if !isInitialized {
            await initialize(network: network)
        }

        AppLog.log("[NodePool] Starting early discovery warmup")

        // Do a test getInfo call to verify connectivity and trigger activity
        Task {
            do {
                // Try to get info from the network as a warmup
                let info = try await self.getInfo()
                AppLog.log("[NodePool] Early discovery warmup successful - network: %@, synced: %d",
                      info.serverVersion, info.isSynced)
            } catch {
                AppLog.log("[NodePool] Early discovery warmup failed: %@", error.localizedDescription)
                // Continue anyway - probing will happen in background
            }
        }
    }

    // MARK: - RPC Operations

    /// Get node info
    func getInfo() async throws -> NodeInfo {
        try await executeWithFailover(op: .profileGetInfo) { conn in
            var msg = Protowire_KaspadMessage()
            msg.getInfoRequest = Protowire_GetInfoRequestMessage()

            let response = try await conn.sendRequest(msg, type: .getInfo, timeout: 5.0)

            guard case .getInfoResponse(let info) = response.payload else {
                throw KasiaError.networkError("Unexpected response")
            }

            if info.hasError && !info.error.message.isEmpty {
                throw KasiaError.networkError(info.error.message)
            }

            return NodeInfo(
                p2pId: info.p2PID,
                mempoolSize: info.mempoolSize,
                serverVersion: info.serverVersion,
                isUtxoIndexed: info.isUtxoIndexed,
                isSynced: info.isSynced,
                hasNotifyCommand: true,
                hasMessageId: true
            )
        }
    }

    /// Get UTXOs by addresses
    /// Uses ordered failover: active nodes by lowest latency first, then selector fallback.
    func getUtxosByAddresses(_ addresses: [String]) async throws -> [UTXO] {
        let op: OperationClass = .getUtxosByAddress
        let activeCandidates = await registry.records(inState: .active)
            .filter { $0.canHandle(op) }
            .sorted {
                let lhs = $0.health.latencyMs.value ?? $0.health.globalLatencyMs.value ?? Double.infinity
                let rhs = $1.health.latencyMs.value ?? $1.health.globalLatencyMs.value ?? Double.infinity
                return lhs < rhs
            }
            .map(\.endpoint)

        var orderedEndpoints = activeCandidates
        if orderedEndpoints.isEmpty {
            orderedEndpoints = await selector.pickBest(for: op, count: 5)
        }

        let excluded = Set(orderedEndpoints.map(\.key))
        let fallbackEndpoints = await selector.pickBest(for: op, count: 5, excluding: excluded)
        orderedEndpoints.append(contentsOf: fallbackEndpoints)

        var attempted = Set<String>()
        var lastError: Error?

        for endpoint in orderedEndpoints where attempted.insert(endpoint.key).inserted {
            let conn = await connectionPool.connection(for: endpoint)

            do {
                if await !conn.isConnected {
                    try await conn.connect()
                }

                let startTime = Date()
                let utxos = try await requestUtxosByAddresses(addresses, from: conn)
                let latencyMs = Date().timeIntervalSince(startTime) * 1000

                await registry.recordResult(
                    endpoint: endpoint,
                    epochId: epochMonitor.epochId,
                    latencyMs: latencyMs,
                    isTimeout: false,
                    isError: false
                )

                await updatePoolStats()
                return utxos
            } catch {
                let isTimeout = error.localizedDescription.lowercased().contains("timeout")
                await registry.recordResult(
                    endpoint: endpoint,
                    epochId: epochMonitor.epochId,
                    latencyMs: nil,
                    isTimeout: isTimeout,
                    isError: true
                )
                lastError = error
                AppLog.log("[NodePool] getUtxosByAddresses failed on %@: %@ (trying next node)",
                      endpoint.key, error.localizedDescription)
            }
        }

        await updatePoolStats()
        throw lastError ?? KasiaError.networkError("All endpoints failed")
    }

    /// Submit transaction (broadcast to multiple nodes)
    func submitTransaction(_ transaction: KaspaRpcTransaction, allowOrphan: Bool = false) async throws -> (txId: String, endpoint: String) {
        try await executeHedged(op: .submitTransaction) { conn in
            var msg = Protowire_KaspadMessage()
            var req = Protowire_SubmitTransactionRequestMessage()
            req.transaction = transaction.toProtobuf()
            req.allowOrphan = allowOrphan
            msg.submitTransactionRequest = req

            let response = try await conn.sendRequest(msg, type: .submitTransaction, timeout: 15.0)

            guard case .submitTransactionResponse(let txResponse) = response.payload else {
                throw KasiaError.networkError("Unexpected response")
            }

            if txResponse.hasError && !txResponse.error.message.isEmpty {
                throw KasiaError.networkError(txResponse.error.message)
            }

            return (txId: txResponse.transactionID, endpoint: conn.endpoint.key)
        }
    }

    /// Get mempool entry for a transaction (returns nil if not in mempool)
    /// Queries top 10 active nodes by latency in parallel with single immediate attempt
    /// - Parameters:
    ///   - txId: Transaction ID to look up
    ///   - attempt: Optional attempt number for logging (tracks how many times this was called)
    func getMempoolEntry(txId: String, attempt: Int = 0) async -> MempoolEntryResult? {
        // Get active nodes sorted by latency, limited to top 10
        let activeRecords = await registry.records(inState: .active)
        let sortedRecords = activeRecords.sorted { a, b in
            let aLatency = a.health.latencyMs.value ?? a.health.globalLatencyMs.value ?? Double.infinity
            let bLatency = b.health.latencyMs.value ?? b.health.globalLatencyMs.value ?? Double.infinity
            return aLatency < bLatency
        }
        let primaryKey = primaryEndpoint?.key
        let filteredRecords = sortedRecords.filter { $0.endpoint.key != primaryKey }
        var endpoints = filteredRecords.prefix(3).map { $0.endpoint }
        if endpoints.isEmpty {
            endpoints = sortedRecords.prefix(3).map { $0.endpoint }
        }

        guard !endpoints.isEmpty else {
            return nil
        }

        // Query endpoints in parallel with single immediate attempt
        return await withTaskGroup(of: (MempoolEntryResult?, Endpoint)?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    let result = await self.queryMempoolEntrySingle(txId: txId, endpoint: endpoint)
                    return (result, endpoint)
                }
            }

            // Return first non-nil result
            for await tuple in group {
                if let (entry, endpoint) = tuple, let entry = entry {
                    group.cancelAll()
                    AppLog.log("[NodePool] getMempoolEntry: FOUND %@ in mempool on attempt %d from %@ (payload: %d chars, outputs: %d, fee: %llu)",
                          String(txId.prefix(12)), attempt, endpoint.key, entry.payload.count, entry.outputs.count, entry.fee)
                    return entry
                }
            }

            return nil
        }
    }

    /// Single mempool entry query (internal helper)
    private func queryMempoolEntrySingle(txId: String, endpoint: Endpoint) async -> MempoolEntryResult? {
        let conn = await connectionPool.connection(for: endpoint)

        do {
            if await !conn.isConnected {
                try await conn.connect()
            }
        } catch {
            return nil
        }

        return await queryMempoolEntryFromConnection(txId: txId, conn: conn)
    }

    /// Query mempool entry from an established connection (internal helper)
    private func queryMempoolEntryFromConnection(txId: String, conn: GRPCStreamConnection) async -> MempoolEntryResult? {
        do {
            var msg = Protowire_KaspadMessage()
            var req = Protowire_GetMempoolEntryRequestMessage()
            req.txID = txId
            req.includeOrphanPool = true
            req.filterTransactionPool = false
            msg.getMempoolEntryRequest = req

            let response = try await conn.sendRequest(msg, type: .getMempoolEntry, timeout: 2.0)

            guard case .getMempoolEntryResponse(let mempoolResponse) = response.payload else {
                return nil
            }

            // Check for error (tx not in mempool)
            if mempoolResponse.hasError && !mempoolResponse.error.message.isEmpty {
                return nil
            }

            guard mempoolResponse.hasEntry else {
                return nil
            }

            let entry = mempoolResponse.entry
            guard entry.hasTransaction else {
                return nil
            }

            let tx = entry.transaction

            // Extract inputs (outpoints only; address resolution happens elsewhere)
            var inputs: [(txId: String, index: UInt32)] = []
            for input in tx.inputs {
                if input.hasPreviousOutpoint {
                    inputs.append((txId: input.previousOutpoint.transactionID, index: input.previousOutpoint.index))
                }
            }

            // Extract outputs
            var outputs: [(address: String, amount: UInt64)] = []
            for output in tx.outputs {
                if output.hasVerboseData && !output.verboseData.scriptPublicKeyAddress.isEmpty {
                    outputs.append((address: output.verboseData.scriptPublicKeyAddress, amount: output.amount))
                }
            }

            return MempoolEntryResult(
                txId: txId,
                sender: nil,
                inputs: inputs,
                outputs: outputs,
                payload: tx.payload,
                fee: entry.fee,
                isOrphan: entry.isOrphan
            )
        } catch {
            return nil
        }
    }

    private func requestUtxosByAddresses(_ addresses: [String], from conn: GRPCStreamConnection) async throws -> [UTXO] {
        var msg = Protowire_KaspadMessage()
        var req = Protowire_GetUtxosByAddressesRequestMessage()
        req.addresses = addresses
        msg.getUtxosByAddressesRequest = req

        let response = try await conn.sendRequest(
            msg,
            type: .getUtxosByAddresses,
            timeout: OperationClass.getUtxosByAddress.timeout
        )

        guard case .getUtxosByAddressesResponse(let utxoResponse) = response.payload else {
            throw KasiaError.networkError("Unexpected response")
        }

        if utxoResponse.hasError && !utxoResponse.error.message.isEmpty {
            throw KasiaError.networkError(utxoResponse.error.message)
        }

        return utxoResponse.entries.compactMap { entry -> UTXO? in
            guard entry.hasUtxoEntry, entry.hasOutpoint else { return nil }

            let utxoEntry = entry.utxoEntry
            let outpoint = entry.outpoint
            let scriptHex = utxoEntry.scriptPublicKey.scriptPublicKey
            let scriptData = Data(hexString: scriptHex) ?? Data()

            return UTXO(
                address: entry.address,
                outpoint: UTXO.Outpoint(
                    transactionId: outpoint.transactionID,
                    index: UInt32(outpoint.index)
                ),
                amount: utxoEntry.amount,
                scriptPublicKey: scriptData,
                blockDaaScore: utxoEntry.blockDaaScore,
                isCoinbase: utxoEntry.isCoinbase
            )
        }
    }

    // MARK: - Subscriptions

    /// Subscribe to UTXO changes
    func subscribeUtxosChanged(addresses: [String]) async throws {
        guard let manager = subscriptionManager else {
            throw KasiaError.networkError("Subscription manager not initialized")
        }
        try await manager.subscribe(addresses: addresses)
    }

    /// Unsubscribe from UTXO changes
    func unsubscribeUtxosChanged() {
        subscriptionManager?.unsubscribe()
    }

    /// Subscribe to block-added notifications (piggybacks on the primary UTXO connection).
    /// Used by broadcast channel scanning; reference-counted by the caller.
    func subscribeBlockAdded() async {
        await subscriptionManager?.setBlockAddedWanted(true)
    }

    /// Stop wanting block-added notifications (see UtxoSubscriptionManager for caveats).
    func unsubscribeBlockAdded() async {
        await subscriptionManager?.setBlockAddedWanted(false)
    }

    /// Add notification handler
    func addNotificationHandler(_ handler: @escaping (KaspaRPCNotification, Data) -> Void) -> UUID {
        subscriptionManager?.addNotificationHandler(handler) ?? UUID()
    }

    /// Remove notification handler
    func removeNotificationHandler(_ id: UUID) {
        subscriptionManager?.removeNotificationHandler(id)
    }

    // MARK: - Request Execution

    /// Execute a request with automatic failover
    /// Prioritizes already-connected endpoints
    private func executeWithFailover<T>(
        op: OperationClass,
        _ execute: (GRPCStreamConnection) async throws -> T
    ) async throws -> T {
        let endpoints = await selector.pickBest(for: op, count: 5)

        guard !endpoints.isEmpty else {
            throw KasiaError.networkError("No suitable endpoints")
        }

        // Get currently connected endpoints and sort them first
        let connectedKeys = await connectionPool.connectedEndpoints()
        let sortedEndpoints = endpoints.sorted { a, b in
            let aConnected = connectedKeys.contains(a.key)
            let bConnected = connectedKeys.contains(b.key)
            if aConnected != bConnected {
                return aConnected
            }
            return false
        }

        var lastError: Error?

        for endpoint in sortedEndpoints.prefix(3) {
            let conn = await connectionPool.connection(for: endpoint)

            do {
                if await !conn.isConnected {
                    try await conn.connect()
                }

                let startTime = Date()
                let result = try await execute(conn)
                let latencyMs = Date().timeIntervalSince(startTime) * 1000

                // Record success
                await registry.recordResult(
                    endpoint: endpoint,
                    epochId: epochMonitor.epochId,
                    latencyMs: latencyMs,
                    isTimeout: false,
                    isError: false
                )

                await updatePoolStats()
                return result

            } catch {
                let isTimeout = error.localizedDescription.contains("timeout")
                await registry.recordResult(
                    endpoint: endpoint,
                    epochId: epochMonitor.epochId,
                    latencyMs: nil,
                    isTimeout: isTimeout,
                    isError: true
                )
                lastError = error
                AppLog.log("[NodePool] Request failed on %@: %@", endpoint.key, error.localizedDescription)
            }
        }

        await updatePoolStats()
        throw lastError ?? KasiaError.networkError("All endpoints failed")
    }

    /// Execute a hedged request to multiple nodes
    /// Prioritizes already-connected endpoints to avoid slow connection establishment
    private func executeHedged<T>(
        op: OperationClass,
        _ execute: @escaping (GRPCStreamConnection) async throws -> T
    ) async throws -> T {
        let endpoints = await selector.pickBest(for: op, count: 5)  // Get more candidates

        guard !endpoints.isEmpty else {
            throw KasiaError.networkError("No suitable endpoints")
        }

        // Get currently connected endpoints
        let connectedKeys = await connectionPool.connectedEndpoints()

        // Sort: connected endpoints first, then others
        let sortedEndpoints = endpoints.sorted { a, b in
            let aConnected = connectedKeys.contains(a.key)
            let bConnected = connectedKeys.contains(b.key)
            if aConnected != bConnected {
                return aConnected  // Connected first
            }
            return false  // Keep original order from selector
        }

        // Take top 3 after sorting
        let selectedEndpoints = Array(sortedEndpoints.prefix(3))

        let hedgeDelay = epochMonitor.networkQuality.hedgeDelayMs * 1_000_000

        let value = await withTaskGroup(of: Result<T, Error>.self, returning: Result<T, Error>.self) { group in
            for (index, endpoint) in selectedEndpoints.enumerated() {
                // Connected endpoints get no delay, unconnected get longer delays
                let isConnected = connectedKeys.contains(endpoint.key)
                let delay: UInt64
                if isConnected {
                    delay = index == 0 ? 0 : hedgeDelay * UInt64(index)
                } else {
                    // Unconnected endpoints get extra delay since connection takes time
                    delay = hedgeDelay * UInt64(index + 1)
                }

                group.addTask {
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }

                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }

                    let conn = await self.connectionPool.connection(for: endpoint)

                    do {
                        if await !conn.isConnected {
                            try await conn.connect()
                        }

                        let startTime = Date()
                        let result = try await execute(conn)
                        let latencyMs = Date().timeIntervalSince(startTime) * 1000

                        await self.registry.recordResult(
                            endpoint: endpoint,
                            epochId: await MainActor.run { self.epochMonitor.epochId },
                            latencyMs: latencyMs,
                            isTimeout: false,
                            isError: false
                        )

                        return .success(result)
                    } catch {
                        let isTimeout = error.localizedDescription.lowercased().contains("timeout")
                        await self.registry.recordResult(
                            endpoint: endpoint,
                            epochId: await MainActor.run { self.epochMonitor.epochId },
                            latencyMs: nil,
                            isTimeout: isTimeout,
                            isError: true
                        )
                        AppLog.log("[NodePool] Hedged request failed on %@: %@", endpoint.key, error.localizedDescription)
                        return .failure(error)
                    }
                }
            }

            // Every node can reject a genuinely invalid transaction (bad fee, bad signature,
            // mass over the limit) just as consistently as they'd all fail to connect - losing
            // that real per-node error behind a generic "All hedged requests failed" made both
            // cases look identical and impossible to tell apart from the error alone. Surface
            // whichever real error came back last instead.
            var lastError: Error = KasiaError.networkError("All hedged requests failed")
            while let outcome = await group.next() {
                switch outcome {
                case .success(let value):
                    group.cancelAll()
                    return .success(value)
                case .failure(let error):
                    lastError = error
                }
            }

            return .failure(lastError)
        }

        await updatePoolStats()
        switch value {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Pool Stats

    private func updatePoolStats() async {
        let health = await registry.poolHealth()
        let counts = await registry.stateCounts()

        // Detect pool health transition to healthy
        let wasNonHealthy = previousPoolHealth != nil && previousPoolHealth != .healthy
        let isNowHealthy = health == .healthy

        let newActiveNodeCount = counts[.active] ?? 0

        // Update individual state counts
        let newActive = counts[.active] ?? 0
        let newVerified = counts[.verified] ?? 0
        let newProfiled = counts[.profiled] ?? 0
        let newCandidate = counts[.candidate] ?? 0
        let newSuspect = counts[.suspect] ?? 0
        let newQuarantined = counts[.quarantined] ?? 0

        // Update latency from primary connection
        var newLatency: Int?
        if let primary = primaryEndpoint {
            let record = await registry.get(primary)
            if let latency = record?.health.latencyMs.value ?? record?.health.globalLatencyMs.value {
                newLatency = Int(latency)
            }
        }

        // Avoid unnecessary @Published writes to reduce UI re-render churn.
        if poolHealth != health { poolHealth = health }
        if activeNodeCount != newActiveNodeCount { activeNodeCount = newActiveNodeCount }
        if activeCount != newActive { activeCount = newActive }
        if verifiedCount != newVerified { verifiedCount = newVerified }
        if profiledCount != newProfiled { profiledCount = newProfiled }
        if candidateCount != newCandidate { candidateCount = newCandidate }
        if suspectCount != newSuspect { suspectCount = newSuspect }
        if quarantinedCount != newQuarantined { quarantinedCount = newQuarantined }
        if lastPingLatencyMs != newLatency { lastPingLatencyMs = newLatency }

        // If pool just became healthy, check if we should reconnect to lowest latency node
        if wasNonHealthy && isNowHealthy {
            await reconnectToBestNodeIfNeeded()
        }

        previousPoolHealth = health
    }

    /// Reconnect to best node when pool becomes healthy
    private func reconnectToBestNodeIfNeeded() async {
        guard let subManager = subscriptionManager else { return }

        AppLog.log("[NodePool] Pool became healthy - checking if reconnect needed")
        await subManager.reconnectToBestNodeIfNeeded()
    }

    /// Handle detection of a significantly better node (70% lower latency for 2 consecutive probes)
    private func handleBetterNodeDetected(_ betterEndpoint: Endpoint) async {
        guard let subManager = subscriptionManager else { return }

        AppLog.log("[NodePool] Better node detected: %@ - triggering reconnect", betterEndpoint.key)
        await subManager.reconnectToEndpoint(betterEndpoint)
    }

    /// Start periodic stats update task
    private func startPeriodicStatsUpdate() {
        statsUpdateTask?.cancel()
        statsUpdateTask = Task {
            while !Task.isCancelled {
                // Update less frequently on macCatalyst to reduce UI churn.
#if targetEnvironment(macCatalyst)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
#else
                try? await Task.sleep(nanoseconds: 5_000_000_000)
#endif

                if !Task.isCancelled {
                    await updatePoolStats()
                }
            }
        }
    }

    // MARK: - Pool Refresh

    /// Refresh the pool (probe all nodes and discover new ones)
    func refreshPool() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        AppLog.log("[NodePool] Starting pool refresh")

        await profiler?.forceProbeAll()
        await profiler?.forceDiscovery()
        await updatePoolStats()

        lastRefreshDate = Date()
        isRefreshing = false
        AppLog.log("[NodePool] Pool refresh complete")
    }

    /// Reconnect any currently-tracked connection that's dead right now - cheap, non-disruptive
    /// alternative to `refreshPool()`/`clearConnectionPool()` meant to be called every time the app
    /// returns to the foreground (see `KaChatApp.handleScenePhaseChange`), since a batch of
    /// connections can die silently while backgrounded/asleep and otherwise only get reconnected
    /// lazily, one at a time, whenever something happens to pick that exact endpoint for a request.
    func reconnectStaleConnections() async {
        await connectionPool.reconnectDisconnected()
    }

    /// Clear discovered nodes and restart pool discovery/connection.
    func clearConnectionPool() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        AppLog.log("[NodePool] Clearing connection pool")

        // Stop active subscription and connections.
        subscriptionManager?.unsubscribe()
        await connectionPool.disconnectAll()

        // Clear discovered nodes and reset remaining records.
        await registry.clearDiscoveredNodes(resetRemaining: true)
        await updatePoolStats()

        // Restart profiler and quick boot discovery.
        await profiler?.stop()
        await profiler?.start(network: networkType)
        await profiler?.quickBoot()
        await updatePoolStats()

        isRefreshing = false
        AppLog.log("[NodePool] Connection pool cleared and restarted")
    }

    // MARK: - Connection (Compatibility)

    /// Connect to the network (initializes pool if needed)
    func connect(network: NetworkType, requireUtxoIndex: Bool = true) async throws {
        if !isInitialized {
            await initialize(network: network)
        } else if network != networkType {
            // Network changed, reinitialize
            await shutdown()
            await initialize(network: network)
        }

        // Check if we already have active nodes (from cache or quickBoot)
        await updatePoolStats()
        if activeCount > 0 {
            AppLog.log("[NodePool] Connect: already have %d active nodes", activeCount)
            connectionError = nil
            return
        }

        // Wait for pool to get at least one active node (up to 10 seconds)
        // This only happens on first launch with no cached nodes
        AppLog.log("[NodePool] Connect: no active nodes yet, waiting...")
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await updatePoolStats()
            if activeCount > 0 {
                AppLog.log("[NodePool] Connect: found %d active nodes", activeCount)
                break
            }
        }

        if activeCount == 0 {
            connectionError = "No active nodes available"
            throw KasiaError.networkError("No active nodes available")
        }

        connectionError = nil
    }

    /// Disconnect (for compatibility)
    func disconnect() {
        subscriptionManager?.unsubscribe()
    }

    // MARK: - Migration

    private func migrateFromOldFormat() async {
        // Check if we have old format data to migrate
        let settings = AppSettings.load()
        guard !settings.grpcEndpointPool.isEmpty else { return }

        // Convert old GrpcEndpoint to NodeRecord
        await registry.migrateFromOldFormat(settings.grpcEndpointPool)

        AppLog.log("[NodePool] Migrated %d endpoints from old format", settings.grpcEndpointPool.count)
    }

    // MARK: - UI/Debug Support

    /// Get all node records for UI display
    func allNodeRecords() async -> [NodeRecord] {
        await registry.allRecords()
    }

    /// Get node counts by state
    func nodeStateCounts() async -> [NodeState: Int] {
        await registry.stateCounts()
    }

    /// Force probe all nodes
    func forceProbeAll() async {
        await profiler?.forceProbeAll()
        await updatePoolStats()
    }

    /// Force discovery
    func forceDiscovery() async {
        await profiler?.forceDiscovery()
        await updatePoolStats()
    }

    /// Add endpoint manually
    /// Probes immediately and promotes to active if eligible (isSynced + isUtxoIndexed)
    func addEndpoint(_ endpoint: Endpoint) async {
        await registry.upsert(endpoint: endpoint, origin: .userAdded)

        AppLog.log("[NodePool] Probing user-added endpoint: %@", endpoint.key)

        // First probe - gets node to verified state
        await profiler?.profileEndpoint(endpoint)

        // Check if node is eligible for active status
        guard let record = await registry.get(endpoint) else {
            AppLog.log("[NodePool] Failed to probe user-added endpoint: %@", endpoint.key)
            await updatePoolStats()
            return
        }

        // If node is synced and has UTXO index, probe again to promote to active
        if record.profile.isSynced == true && record.profile.isUtxoIndexed == true {
            AppLog.log("[NodePool] User-added endpoint %@ is eligible, probing again to promote to active", endpoint.key)
            await profiler?.profileEndpoint(endpoint)

            // Verify promotion
            if let updatedRecord = await registry.get(endpoint) {
                AppLog.log("[NodePool] User-added endpoint %@ state: %@ (consecutiveSuccesses: %d)",
                      endpoint.key, updatedRecord.state.displayName, updatedRecord.health.consecutiveSuccesses)
            }
        } else {
            AppLog.log("[NodePool] User-added endpoint %@ not eligible: isSynced=%@, isUtxoIndexed=%@",
                  endpoint.key,
                  record.profile.isSynced == true ? "true" : "false",
                  record.profile.isUtxoIndexed == true ? "true" : "false")
        }

        _ = await registry.rebalanceActivePool(
            minActive: 8,
            maxActive: 12,
            maxReplacementsPerCycle: 1,
            minImprovementRatio: 0.15
        )

        await updatePoolStats()
    }

    /// Remove endpoint
    func removeEndpoint(_ endpoint: Endpoint) async {
        await registry.remove(endpoint)
        await connectionPool.removeConnection(for: endpoint)
        await updatePoolStats()
    }

    /// Network status description
    var networkStatusDescription: String {
        var parts: [String] = []
        parts.append("Health: \(poolHealth)")
        parts.append("Active: \(activeNodeCount)")
        parts.append("Network: \(networkQuality)")

        if let primary = primaryEndpoint {
            parts.append("Primary: \(primary.host)")
        }

        return parts.joined(separator: " | ")
    }
}

// MARK: - Compatibility Layer

extension NodePoolService {
    /// Check if connected (for compatibility with old KaspaRPCClient API)
    var isConnected: Bool {
        poolHealth != .failed && activeNodeCount > 0
    }

    /// Current URL (for compatibility)
    var connectedNodeURL: String? {
        primaryEndpoint?.url
    }

    /// Active protocol string (for UI)
    var activeProtocol: String { "gRPC" }

    /// Active transport security description (for UI)
    var activeProtocolSecurity: String {
        if let endpoint = primaryEndpoint,
           endpoint.url.lowercased().hasPrefix("grpcs://") {
            return "secure"
        }
        return "plaintext"
    }

    /// Check if subscribed to UTXOs
    var isSubscribedToUtxos: Bool {
        subscriptionState == .subscribed
    }

    /// Total node count
    var totalNodeCount: Int {
        activeCount + verifiedCount + profiledCount + candidateCount + suspectCount + quarantinedCount
    }

    /// Average latency of active nodes
    func averageActiveLatency() async -> Int? {
        guard let avg = await registry.averageActiveLatency() else { return nil }
        return Int(avg)
    }

    /// Get nodes by state for UI display
    func nodesByState(_ state: NodeState) async -> [NodeRecord] {
        await registry.records(inState: state)
    }

    /// Add endpoint by URL string (for UI)
    func addEndpoint(url: String) async {
        guard let endpoint = Endpoint(url: url) else { return }
        await addEndpoint(endpoint)
    }

    /// Remove endpoint by URL string (for UI)
    func removeEndpoint(url: String) async {
        guard let endpoint = Endpoint(url: url) else { return }
        await removeEndpoint(endpoint)
    }

    /// Pin the pool to exactly one node (Kaspium-style fixed-node mode), or clear the pin
    /// and resume normal discovery when `address` is empty/blank.
    func setTrustedNodeAddress(_ address: String?) async {
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var staleEndpoint: Endpoint?
        if trimmed.isEmpty {
            staleEndpoint = await registry.setTrustedNode(nil)
            await updatePoolStats()
            await forceProbeAll()
        } else if let endpoint = Endpoint(url: trimmed) {
            staleEndpoint = await registry.setTrustedNode(endpoint)
            await updatePoolStats()
            // Probe directly rather than forceProbeAll()/selectNodesForProbing() - that
            // path gates a freshly-added node on a several-minute cold-start interval meant
            // to throttle probing across a large discovery pool, which would leave this
            // one just-pinned node stuck in .candidate. Twice, so it clears the
            // two-consecutive-success bar rebalanceActivePool() requires before promoting
            // anything out of .candidate.
            await profiler?.profileEndpoint(endpoint)
            await profiler?.profileEndpoint(endpoint)
            await registry.rebalanceActivePool()
            await updatePoolStats()
        }

        // A GRPCStreamConnection has no idea it's no longer trusted/relevant and will otherwise
        // keep reconnecting to it forever in the background, completely independently of
        // whatever we do next - this is what was causing a node to keep seeing repeated
        // connection attempts (and "resource exhausted" rejections) minutes after being
        // cleared/switched away from in Settings.
        if let staleEndpoint {
            await connectionPool.removeConnection(for: staleEndpoint)
        }

        // A subscription already open on a now-unpinned node won't notice on its own - its
        // health ping would keep succeeding against a perfectly reachable node that just
        // isn't the trusted one anymore, so force it to re-evaluate against the pinned registry.
        await subscriptionManager?.reconnectToBestNodeIfNeeded()
    }
}
