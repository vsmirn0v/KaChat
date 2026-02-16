import Foundation
import Combine

/// High-level RPC router that implements hedged requests and automatic failover
/// Uses NodeSelector for endpoint selection and GRPCConnectionPool for connections
@MainActor
final class KaspaRPCRouter: ObservableObject {
    // MARK: - Singleton

    static let shared = KaspaRPCRouter()

    // MARK: - Published Properties

    @Published private(set) var isConnected = false
    @Published private(set) var activeEndpoint: Endpoint?
    @Published private(set) var connectionError: String?

    // MARK: - Dependencies

    private let registry: NodeRegistry
    private let selector: NodeSelector
    private let epochMonitor: NetworkEpochMonitor
    private let connectionPool: GRPCConnectionPool

    // MARK: - Configuration

    /// Maximum number of hedged requests
    private let maxHedgedRequests = 3

    /// Delay before sending hedge request (based on network quality)
    private var hedgeDelay: UInt64 {
        epochMonitor.networkQuality.hedgeDelayMs * 1_000_000  // Convert to nanoseconds
    }

    // MARK: - Notification Handlers

    private var notificationHandlers: [UUID: (KaspaRPCNotification, Data) -> Void] = [:]

    // MARK: - Initialization

    private init() {
        self.registry = NodeRegistry()
        self.epochMonitor = NetworkEpochMonitor.shared
        self.selector = NodeSelector(registry: registry, epochMonitor: epochMonitor)
        self.connectionPool = GRPCConnectionPool()

        // Subscribe to epoch changes
        epochMonitor.onEpochChange { [weak self] newEpochId in
            Task { @MainActor in
                await self?.handleEpochChange(newEpochId)
            }
        }
    }

    // MARK: - Lifecycle

    /// Initialize the router for a network
    func initialize(network: NetworkType) async {
        // Load persisted records
        await registry.load()

        // Initialize seed nodes
        await registry.initializeSeeds(for: network)

        // Start epoch monitoring
        epochMonitor.start()

        NSLog("[RPCRouter] Initialized for %@", network.displayName)
    }

    /// Shutdown the router
    func shutdown() async {
        epochMonitor.stop()
        await connectionPool.disconnectAll()
        await registry.persistNow()
        NSLog("[RPCRouter] Shutdown complete")
    }

    // MARK: - Epoch Handling

    private func handleEpochChange(_ newEpochId: Int) async {
        NSLog("[RPCRouter] Epoch changed to %d - resetting connection stats", newEpochId)

        // Reset epoch stats in registry
        await registry.resetEpochStats(newEpochId: newEpochId)

        // Reset health metrics on all connections
        for conn in await connectionPool.allConnections() {
            await conn.resetHealthMetrics()
        }
    }

    // MARK: - Simple Request (Single Node)

    /// Send a simple request to the best available node
    private func sendSimple<T>(
        op: OperationClass,
        build: () -> Protowire_KaspadMessage,
        type: KaspaRequestType,
        parse: (Protowire_KaspadMessage) throws -> T
    ) async throws -> T {
        // Refresh reference DAA if needed
        if await selector.needsReferenceRefresh {
            await selector.updateReferenceDaaScore()
        }

        let endpoints = await selector.pickBest(for: op, count: 3)
        guard !endpoints.isEmpty else {
            throw KasiaError.networkError("No suitable endpoints available")
        }

        var lastError: Error?
        var excludedEndpoints: Set<String> = []

        for endpoint in endpoints {
            guard !excludedEndpoints.contains(endpoint.key) else { continue }

            do {
                let result = try await sendToEndpoint(
                    endpoint: endpoint,
                    message: build(),
                    type: type,
                    timeout: op.timeout,
                    parse: parse
                )
                return result
            } catch {
                lastError = error
                excludedEndpoints.insert(endpoint.key)
                NSLog("[RPCRouter] Request failed on %@: %@", endpoint.key, error.localizedDescription)
            }
        }

        throw lastError ?? KasiaError.networkError("All endpoints failed")
    }

    /// Send request to a specific endpoint
    private func sendToEndpoint<T>(
        endpoint: Endpoint,
        message: Protowire_KaspadMessage,
        type: KaspaRequestType,
        timeout: TimeInterval,
        parse: (Protowire_KaspadMessage) throws -> T
    ) async throws -> T {
        let conn = await connectionPool.connection(for: endpoint)

        // Connect if needed
        if await !conn.isConnected {
            try await conn.connect()
        }

        let startTime = Date()

        do {
            let response = try await conn.sendRequest(message, type: type, timeout: timeout)
            let latencyMs = Date().timeIntervalSince(startTime) * 1000

            // Record success
            await registry.recordResult(
                endpoint: endpoint,
                epochId: epochMonitor.epochId,
                latencyMs: latencyMs,
                isTimeout: false,
                isError: false
            )

            // Update active endpoint
            activeEndpoint = endpoint
            isConnected = true
            connectionError = nil

            return try parse(response)

        } catch {
            let isTimeout = error.localizedDescription.contains("timeout")

            // Record failure
            await registry.recordResult(
                endpoint: endpoint,
                epochId: epochMonitor.epochId,
                latencyMs: nil,
                isTimeout: isTimeout,
                isError: true
            )

            throw error
        }
    }

    // MARK: - Hedged Request (Multiple Nodes in Parallel)

    /// Send a hedged request to multiple nodes with staggered timing
    /// Returns the first successful response
    private func sendHedged<T>(
        op: OperationClass,
        build: () -> Protowire_KaspadMessage,
        type: KaspaRequestType,
        parse: @escaping (Protowire_KaspadMessage) throws -> T
    ) async throws -> T {
        let endpoints = await selector.pickBest(for: op, count: maxHedgedRequests)
        guard !endpoints.isEmpty else {
            throw KasiaError.networkError("No suitable endpoints available")
        }

        // Build message once outside the task group to avoid closure escaping issues
        let message = build()

        // Use TaskGroup with first-success semantics
        let value = await withTaskGroup(of: T?.self, returning: T?.self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                // Add hedge delay for non-primary requests
                let delay = index == 0 ? 0 : hedgeDelay * UInt64(index)

                group.addTask {
                    do {
                        if delay > 0 {
                            try await Task.sleep(nanoseconds: delay)
                        }

                        // Check if already cancelled (another request succeeded)
                        if Task.isCancelled {
                            return nil
                        }

                        return try await self.sendToEndpoint(
                            endpoint: endpoint,
                            message: message,
                            type: type,
                            timeout: op.timeout,
                            parse: parse
                        )
                    } catch {
                        return nil
                    }
                }
            }

            while let result = await group.next() {
                if let value = result {
                    group.cancelAll()
                    return value
                }
            }

            return nil
        }

        guard let value else {
            throw KasiaError.networkError("All hedged requests failed")
        }
        return value
    }

    // MARK: - Public RPC Methods

    /// Get node info
    func getInfo() async throws -> NodeInfo {
        try await sendSimple(
            op: .profileGetInfo,
            build: {
                var msg = Protowire_KaspadMessage()
                msg.getInfoRequest = Protowire_GetInfoRequestMessage()
                return msg
            },
            type: .getInfo
        ) { response in
            guard case .getInfoResponse(let info) = response.payload else {
                throw KasiaError.networkError("Unexpected response type")
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

    /// Get UTXOs by addresses (hedged for responsiveness)
    func getUtxosByAddresses(_ addresses: [String]) async throws -> [UTXO] {
        try await sendHedged(
            op: .getUtxosByAddress,
            build: {
                var msg = Protowire_KaspadMessage()
                var req = Protowire_GetUtxosByAddressesRequestMessage()
                req.addresses = addresses
                msg.getUtxosByAddressesRequest = req
                return msg
            },
            type: .getUtxosByAddresses
        ) { response in
            guard case .getUtxosByAddressesResponse(let utxoResponse) = response.payload else {
                throw KasiaError.networkError("Unexpected response type")
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
    }

    /// Submit transaction (broadcast to multiple nodes for reliability)
    func submitTransaction(_ transaction: KaspaRpcTransaction, allowOrphan: Bool = false) async throws -> String {
        // For tx submission, we broadcast to multiple nodes but only need one success
        try await sendHedged(
            op: .submitTransaction,
            build: {
                var msg = Protowire_KaspadMessage()
                var req = Protowire_SubmitTransactionRequestMessage()
                req.transaction = transaction.toProtobuf()
                req.allowOrphan = allowOrphan
                msg.submitTransactionRequest = req
                return msg
            },
            type: .submitTransaction
        ) { response in
            guard case .submitTransactionResponse(let txResponse) = response.payload else {
                throw KasiaError.networkError("Unexpected response type")
            }
            if txResponse.hasError && !txResponse.error.message.isEmpty {
                throw KasiaError.networkError(txResponse.error.message)
            }
            return txResponse.transactionID
        }
    }

    /// Get connected peer addresses for discovery
    func getPeerAddresses() async throws -> [String] {
        try await sendSimple(
            op: .discoveryGetPeerAddresses,
            build: {
                var msg = Protowire_KaspadMessage()
                msg.getConnectedPeerInfoRequest = Protowire_GetConnectedPeerInfoRequestMessage()
                return msg
            },
            type: .getConnectedPeerInfo
        ) { response in
            guard case .getConnectedPeerInfoResponse(let peerResponse) = response.payload else {
                throw KasiaError.networkError("Unexpected response type")
            }
            if peerResponse.hasError && !peerResponse.error.message.isEmpty {
                throw KasiaError.networkError(peerResponse.error.message)
            }
            return peerResponse.infos.map { $0.address }
        }
    }

    /// Get block DAG info for profiling
    func getBlockDagInfo() async throws -> BlockDagInfo {
        try await sendSimple(
            op: .profileGetBlockDagInfo,
            build: {
                var msg = Protowire_KaspadMessage()
                msg.getBlockDagInfoRequest = Protowire_GetBlockDagInfoRequestMessage()
                return msg
            },
            type: .getBlockDagInfo
        ) { response in
            guard case .getBlockDagInfoResponse(let dagInfo) = response.payload else {
                throw KasiaError.networkError("Unexpected response type")
            }
            if dagInfo.hasError && !dagInfo.error.message.isEmpty {
                throw KasiaError.networkError(dagInfo.error.message)
            }
            return BlockDagInfo(
                networkName: dagInfo.networkName,
                virtualDaaScore: dagInfo.virtualDaaScore,
                pruningPointHash: dagInfo.pruningPointHash
            )
        }
    }

    // MARK: - Notifications

    /// Add notification handler
    func addNotificationHandler(_ handler: @escaping (KaspaRPCNotification, Data) -> Void) -> UUID {
        let id = UUID()
        notificationHandlers[id] = handler
        return id
    }

    /// Remove notification handler
    func removeNotificationHandler(_ id: UUID?) {
        guard let id = id else { return }
        notificationHandlers.removeValue(forKey: id)
    }

    // MARK: - Subscription (handled by UtxoSubscriptionManager)

    /// Subscribe to UTXO changes on a specific endpoint
    /// Returns true if subscription succeeded
    func subscribeUtxosChanged(addresses: [String], on endpoint: Endpoint) async throws -> Bool {
        let conn = await connectionPool.connection(for: endpoint)

        if await !conn.isConnected {
            try await conn.connect()
        }

        var msg = Protowire_KaspadMessage()
        var req = Protowire_NotifyUtxosChangedRequestMessage()
        req.addresses = addresses
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

        // Add notification handlers to connection
        for (_, handler) in notificationHandlers {
            _ = await conn.addNotificationHandler(handler)
        }

        return true
    }

    // MARK: - Registry Access

    /// Get all node records (for UI)
    func allNodeRecords() async -> [NodeRecord] {
        await registry.allRecords()
    }

    /// Get state counts (for UI)
    func nodeStateCounts() async -> [NodeState: Int] {
        await registry.stateCounts()
    }

    /// Get pool health
    func poolHealth() async -> PoolHealth {
        await registry.poolHealth()
    }

    /// Add endpoint manually
    func addEndpoint(_ endpoint: Endpoint) async {
        await registry.upsert(endpoint: endpoint, origin: .userAdded)
    }

    /// Remove endpoint
    func removeEndpoint(_ endpoint: Endpoint) async {
        await registry.remove(endpoint)
        await connectionPool.removeConnection(for: endpoint)
    }
}

// MARK: - BlockDagInfo

/// Block DAG information from node
struct BlockDagInfo {
    let networkName: String
    let virtualDaaScore: UInt64
    let pruningPointHash: String
}
