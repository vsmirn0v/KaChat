import Foundation
import Network

/// Node profiler and discovery engine
/// Handles capability checking, periodic probing, and peer discovery
actor NodeProfiler {
    // MARK: - Dependencies

    private let registry: NodeRegistry
    private let connectionPool: GRPCConnectionPool
    private let epochMonitor: NetworkEpochMonitor

    // MARK: - Configuration

    /// Maximum concurrent probes
    private func getMaxConcurrentProbes() async -> Int {
        let configured = await MainActor.run { epochMonitor.networkQuality.maxConcurrentProbes }
#if targetEnvironment(macCatalyst)
        return max(1, min(3, configured / 2))
#else
        return configured
#endif
    }

    /// Discovery budget (token bucket)
    private var discoveryTokens: Int = 3000
    private var lastTokenRefill: Date = Date()
    private let tokensPerHour: Int = 800

    /// Active pool rebalance policy
    private let minActiveNodes = 8
    private let maxActiveNodes = 12
    private let maxReplacementsPerCycle = 1
    private let minReplacementImprovementRatio = 0.15

    /// Healthy-pool discovery behavior
    private let healthyDiscoveryInterval: TimeInterval = 30 * 60
    private var lastHealthyDiscoveryAt: Date = .distantPast

    /// Hard-pause discovery policy
    private let hardPauseFastNodeThreshold = 5
    private let hardPauseLatencyMs: Double = 50
    private let hardPauseErrorWindow: TimeInterval = 15 * 60
    private let hardPauseCacheTTL: TimeInterval = 10
    private var cachedHardPauseState: (paused: Bool, fastCount: Int, hasErrors: Bool)?
    private var lastHardPauseCheckAt: Date = .distantPast

    /// Current probe task
    private var probeLoopTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var dnsRefreshTask: Task<Void, Never>?

    /// Network type for filtering
    private var networkType: NetworkType = .mainnet

    /// Last DNS resolution time
    private var lastDNSRefresh: Date = Date.distantPast

    /// Tracks successful discovery calls (for TCP ping prerequisite)
    private var successfulDiscoveryCount: Int = 0

    /// Whether DNS resolution is complete (for TCP ping prerequisite)
    private var dnsResolveComplete: Bool = false

    /// TCP ping batch task
    private var tcpPingTask: Task<Void, Never>?

    // MARK: - Better Node Detection

    /// Callback to get current primary endpoint
    private var getPrimaryEndpoint: (() async -> Endpoint?)?

    /// Callback to trigger reconnection to a better node
    private var onBetterNodeDetected: ((Endpoint) async -> Void)?

    /// Candidate better node (70% lower latency than current primary)
    private var candidateBetterNode: Endpoint?

    /// Consecutive probe cycles where the same node was significantly better
    private var candidateConsecutiveCount: Int = 0

    /// Required consecutive probes before triggering reconnect
    private let requiredConsecutiveProbes = 2

    /// Latency improvement threshold (0.3 = 70% lower latency, i.e., new latency is 30% of old)
    private let latencyImprovementThreshold = 0.3

    // MARK: - Initialization

    init(registry: NodeRegistry, connectionPool: GRPCConnectionPool, epochMonitor: NetworkEpochMonitor) {
        self.registry = registry
        self.connectionPool = connectionPool
        self.epochMonitor = epochMonitor
    }

    /// Set callbacks for better node detection
    func setBetterNodeCallbacks(
        getPrimaryEndpoint: @escaping () async -> Endpoint?,
        onBetterNodeDetected: @escaping (Endpoint) async -> Void
    ) {
        self.getPrimaryEndpoint = getPrimaryEndpoint
        self.onBetterNodeDetected = onBetterNodeDetected
    }

    // MARK: - Lifecycle

    private var maintenanceTask: Task<Void, Never>?

    /// Start the profiler
    func start(network: NetworkType) {
        self.networkType = network
        startProbeLoop()
        startDiscoveryLoop()
        startMaintenanceLoop()
        NSLog("[NodeProfiler] Started for %@", network.displayName)
    }

    /// Stop the profiler
    func stop() {
        probeLoopTask?.cancel()
        probeLoopTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        dnsRefreshTask?.cancel()
        dnsRefreshTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        tcpPingTask?.cancel()
        tcpPingTask = nil
        NSLog("[NodeProfiler] Stopped")
    }

    // MARK: - Maintenance Loop

    /// Start background maintenance loop for cleanup tasks
    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task {
            // Initial delay before first maintenance
#if targetEnvironment(macCatalyst)
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)  // 1.5 minutes
#else
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)  // 1 minute
#endif

            while !Task.isCancelled {
                await runMaintenanceCycle()

                // Run maintenance less frequently on macCatalyst to reduce CPU.
#if targetEnvironment(macCatalyst)
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
#else
                try? await Task.sleep(nanoseconds: 2 * 60 * 1_000_000_000)
#endif
            }
        }
    }

    /// Run maintenance tasks: prune old nodes, cleanup idle connections
    private func runMaintenanceCycle() async {
        // Prune nodes not seen in 7 days (except seeds and user-added)
        await registry.pruneOldNodes(olderThan: 7 * 24 * 3600)

        // Cleanup idle/disconnected connections (less aggressive on macCatalyst).
#if targetEnvironment(macCatalyst)
        await connectionPool.pruneIdleConnections(maxAge: 5 * 60)
#else
        await connectionPool.pruneIdleConnections(maxAge: 2 * 60)
#endif

        NSLog("[NodeProfiler] Maintenance cycle complete, connections: %d", await connectionPool.connectionCount())
    }

    // MARK: - Probe Loop

    /// Start background probe loop
    private func startProbeLoop() {
        probeLoopTask?.cancel()
        probeLoopTask = Task {
            while !Task.isCancelled {
                await runProbeCycle()

                // Wait before next cycle
                // In conservative mode, use 60s base interval
                // In aggressive mode, use 10s base interval (adjusted by pool health)
                let mode = await getProbeMode()
                let baseInterval: Double
#if targetEnvironment(macCatalyst)
                baseInterval = mode.isConservative ? 120.0 : 30.0
#else
                baseInterval = mode.isConservative ? 60.0 : 10.0
#endif
                let poolHealth = await registry.poolHealth()
                let interval = baseInterval / poolHealth.probeFrequencyMultiplier
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Run a single probe cycle
    private func runProbeCycle() async {
        // Get nodes that need probing
        let nodesToProbe = await selectNodesForProbing()

        guard !nodesToProbe.isEmpty else { return }

        NSLog("[NodeProfiler] Probing %d nodes", nodesToProbe.count)

        // Probe in parallel with concurrency limit
        let maxProbes = await getMaxConcurrentProbes()
        await withTaskGroup(of: Void.self) { group in
            var activeProbes = 0

            for record in nodesToProbe {
                // Respect concurrency limit
                if activeProbes >= maxProbes {
                    _ = await group.next()
                    activeProbes -= 1
                }

                group.addTask {
                    await self.probeNode(record.endpoint)
                }
                activeProbes += 1
            }

            // Wait for remaining probes
            for await _ in group {}
        }

        await rebalanceActivePool(reason: "probe-cycle")

        // Check for significantly better nodes after probing
        await checkForBetterNode()
    }

    /// Check if there's a node with 70% lower latency than current primary
    /// Triggers reconnect if same better node is detected for 2 consecutive probes
    private func checkForBetterNode() async {
        // Need callbacks to be set
        guard let getPrimary = getPrimaryEndpoint,
              let onBetterNode = onBetterNodeDetected else { return }

        // Get current primary endpoint
        guard let primaryEndpoint = await getPrimary() else { return }

        // Get current primary's latency
        guard let primaryRecord = await registry.get(primaryEndpoint),
              let primaryLatency = primaryRecord.health.latencyMs.value ?? primaryRecord.health.globalLatencyMs.value else {
            return
        }

        // Find best active node by latency
        let activeRecords = await registry.records(inState: .active)
        let sortedByLatency = activeRecords
            .compactMap { record -> (NodeRecord, Double)? in
                guard let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value else {
                    return nil
                }
                return (record, latency)
            }
            .sorted { $0.1 < $1.1 }

        guard let (bestRecord, bestLatency) = sortedByLatency.first else { return }

        // Skip if best node is already the primary
        guard bestRecord.endpoint.key != primaryEndpoint.key else {
            // Reset candidate tracking since we're already on the best node
            if candidateBetterNode != nil {
                candidateBetterNode = nil
                candidateConsecutiveCount = 0
            }
            return
        }

        // Check if best node has 70% lower latency (i.e., bestLatency <= primaryLatency * 0.3)
        let threshold = primaryLatency * latencyImprovementThreshold
        guard bestLatency <= threshold else {
            // No significantly better node found - reset tracking
            if candidateBetterNode != nil {
                candidateBetterNode = nil
                candidateConsecutiveCount = 0
            }
            return
        }

        // Found a significantly better node
        if candidateBetterNode?.key == bestRecord.endpoint.key {
            // Same node as before - increment counter
            candidateConsecutiveCount += 1
            NSLog("[NodeProfiler] Better node %@ confirmed (%d/%d): %.0fms vs %.0fms (%.0f%% improvement)",
                  bestRecord.endpoint.key, candidateConsecutiveCount, requiredConsecutiveProbes,
                  bestLatency, primaryLatency, (1 - bestLatency / primaryLatency) * 100)

            if candidateConsecutiveCount >= requiredConsecutiveProbes {
                // Trigger reconnection
                NSLog("[NodeProfiler] Triggering reconnect to better node %@ (%.0fms vs %.0fms)",
                      bestRecord.endpoint.key, bestLatency, primaryLatency)
                candidateBetterNode = nil
                candidateConsecutiveCount = 0
                await onBetterNode(bestRecord.endpoint)
            }
        } else {
            // Different node - start new tracking
            candidateBetterNode = bestRecord.endpoint
            candidateConsecutiveCount = 1
            NSLog("[NodeProfiler] New candidate better node: %@ (%.0fms vs %.0fms, %.0f%% improvement)",
                  bestRecord.endpoint.key, bestLatency, primaryLatency, (1 - bestLatency / primaryLatency) * 100)
        }
    }

    /// Select nodes that need probing
    private func selectNodesForProbing() async -> [NodeRecord] {
        let allRecords = await registry.allRecords()
        let now = Date()

        var candidates: [(NodeRecord, Int)] = []  // (record, priority)

        for record in allRecords {
            // Skip quarantined nodes that haven't reached their release time
            if record.health.isQuarantined {
                continue
            }

            // Calculate probe priority
            let priority = await calculateProbePriority(record, now: now)
            if priority > 0 {
                candidates.append((record, priority))
            }
        }

        // Sort by priority (higher first) and take top N
        // In conservative mode, use smaller batch (maxProbes * 1)
        // In aggressive mode, use larger batch (maxProbes * 5)
        let maxProbes = await getMaxConcurrentProbes()
        let mode = await getProbeMode()
        let batchMultiplier: Int
#if targetEnvironment(macCatalyst)
        batchMultiplier = mode.isConservative ? 1 : 2
#else
        batchMultiplier = mode.isConservative ? 1 : 5
#endif
        return candidates
            .sorted { $0.1 > $1.1 }
            .prefix(maxProbes * batchMultiplier)
            .map { $0.0 }
    }

    /// Get dynamic probe interval based on pool health and node state
    /// Returns probe mode info including conservative flag and pool stats
    private var lastLoggedProbeMode: String?
    private var cachedProbeMode: (isConservative: Bool, activeCount: Int, minLatency: Double, lowLatencyCount: Int)? = nil
    private var lastProbeModeCheck: Date = .distantPast

    private func getProbeMode() async -> (isConservative: Bool, activeCount: Int, minLatency: Double, lowLatencyCount: Int) {
        // Cache probe mode for 10 seconds to avoid recalculating for each node
        let now = Date()
        if let cached = cachedProbeMode, now.timeIntervalSince(lastProbeModeCheck) < 10 {
            return cached
        }

        // Get dynamic low-latency threshold based on network quality
        let lowLatencyThreshold = await MainActor.run { epochMonitor.networkQuality.lowLatencyThresholdMs }

        let records = await registry.allRecords()
        let activeNodes = records.filter { $0.state == .active }
        let activeCount = activeNodes.count

        // Count nodes with latency <= threshold (dynamic based on network quality)
        let lowLatencyNodes = activeNodes.filter { record in
            if let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value {
                return latency <= lowLatencyThreshold
            }
            return false
        }
        let lowLatencyCount = lowLatencyNodes.count

        guard activeCount >= 5 else {
            let result = (isConservative: false, activeCount: activeCount, minLatency: 999.0, lowLatencyCount: lowLatencyCount)
            cachedProbeMode = result
            lastProbeModeCheck = now
            if lastLoggedProbeMode != "aggressive" {
                NSLog("[NodeProfiler] Probe mode: AGGRESSIVE - only %d active nodes (threshold: %.0fms)", activeCount, lowLatencyThreshold)
                lastLoggedProbeMode = "aggressive"
            }
            return result
        }

        let minLatency = activeNodes.compactMap { $0.health.latencyMs.value ?? $0.health.globalLatencyMs.value }.min() ?? 999.0
        let hasLowLatencyNode = minLatency < lowLatencyThreshold

        if hasLowLatencyNode {
            let result = (isConservative: true, activeCount: activeCount, minLatency: minLatency, lowLatencyCount: lowLatencyCount)
            cachedProbeMode = result
            lastProbeModeCheck = now
            if lastLoggedProbeMode != "conservative" {
                NSLog("[NodeProfiler] Probe mode: CONSERVATIVE - %d active nodes (%d low-latency <%.0fms), min latency: %.0fms",
                      activeCount, lowLatencyCount, lowLatencyThreshold, minLatency)
                lastLoggedProbeMode = "conservative"
            }
            return result
        } else {
            let result = (isConservative: false, activeCount: activeCount, minLatency: minLatency, lowLatencyCount: lowLatencyCount)
            cachedProbeMode = result
            lastProbeModeCheck = now
            if lastLoggedProbeMode != "aggressive-nolatency" {
                NSLog("[NodeProfiler] Probe mode: AGGRESSIVE - %d active nodes but no low-latency node <%.0fms (min: %.0fms)",
                      activeCount, lowLatencyThreshold, minLatency)
                lastLoggedProbeMode = "aggressive-nolatency"
            }
            return result
        }
    }

    /// Evaluate hard-pause state for discovery and candidate probing.
    /// Hard-pause when we have enough ultra-low-latency active nodes and no logged errors.
    private func hardPauseState() async -> (paused: Bool, fastCount: Int, hasErrors: Bool) {
        let now = Date()
        if let cached = cachedHardPauseState, now.timeIntervalSince(lastHardPauseCheckAt) < hardPauseCacheTTL {
            return cached
        }

        let activeNodes = await registry.records(inState: .active)
        let fastNodes = activeNodes.filter { $0.effectiveLatencyMs < hardPauseLatencyMs }
        let hasErrors = activeNodes.contains { record in
            if record.health.consecutiveFailures > 0 { return true }
            if let lastFailure = record.health.lastFailureAt,
               now.timeIntervalSince(lastFailure) <= hardPauseErrorWindow {
                return true
            }
            return false
        }

        let paused = fastNodes.count >= hardPauseFastNodeThreshold && !hasErrors
        let state = (paused: paused, fastCount: fastNodes.count, hasErrors: hasErrors)
        cachedHardPauseState = state
        lastHardPauseCheckAt = now
        return state
    }

    /// Get dynamic probe interval for a specific node state
    private func getDynamicProbeInterval(for state: NodeState) async -> TimeInterval {
        let mode = await getProbeMode()

        if mode.isConservative {
            // Conservative mode: slow down all probing significantly
            switch state {
            case .active: return 120        // 2 minutes - keep active nodes fresh
            case .verified: return 600      // 10 minutes - no need to re-verify often
            case .profiled: return 1800     // 30 minutes - slow search for more profiled
            case .candidate: return 3600    // 60 minutes - very slow discovery
            case .suspect: return 600       // 10 minutes - try to recover
            case .quarantined: return 0     // Use quarantineUntil instead
            }
        } else {
            // Aggressive mode: fast probing for pool building
            switch state {
            case .active: return 60         // 1 minute - verify active nodes
            case .verified: return 15       // 1 minute - promote quickly
            case .profiled: return 120      // 2 minutes - test to verify
            case .candidate: return 240     // 4 minutes - discover new nodes
            case .suspect: return 300       // 5 minutes - try to recover
            case .quarantined: return 0
            }
        }
    }

    /// Calculate probe priority for a node
    private func calculateProbePriority(_ record: NodeRecord, now: Date) async -> Int {
        // Skip candidate probing only during hard-pause mode.
        if record.state == .candidate {
            let hardPause = await hardPauseState()
            if hardPause.paused {
                return 0
            }
        }

        let lastProbe = record.health.lastProbeAt ?? record.firstSeenAt

        // Use dynamic interval for all states based on pool health
        let interval = await getDynamicProbeInterval(for: record.state)

        let elapsed = now.timeIntervalSince(lastProbe)

        if elapsed < interval {
            return 0  // Not due for probe yet
        }

        // Priority based on state and overdue time
        var priority = 0

        switch record.state {
        case .active: priority = 100
        case .verified: priority = 80
        case .suspect: priority = 70  // Try to recover soon
        case .profiled: priority = 50
        case .candidate: priority = 30
        case .quarantined: priority = 0
        }

        // Bonus for seed nodes (DNS-resolved) - probe them first
        if record.origin == .seed {
            priority += 20
        }

        // Extra bonus for user-added nodes (user trusts them)
        if record.origin == .userAdded {
            priority += 30
        }

        // Bonus for candidates that passed TCP ping (reachable, prioritize for profiling)
        if record.state == .candidate && record.health.tcpPingPassed == true {
            priority += 25
        }

        // Bonus for being overdue
        let overdueRatio = elapsed / interval
        priority += Int(min(50, overdueRatio * 10))

        return priority
    }

    /// Probe a single node
    private func probeNode(_ endpoint: Endpoint) async {
        // NOTE: TCP ping pre-filter disabled - NWConnection may interfere with URLSession
        // via shared Network framework state. If needed, re-enable after investigating
        // the URLSession timeout issue.

        let conn = await connectionPool.connection(for: endpoint)
        let startTime = Date()

        do {
            // Connect if needed
            if await !conn.isConnected {
                try await conn.connect()
            }

            // Get node info
            var infoMsg = Protowire_KaspadMessage()
            infoMsg.getInfoRequest = Protowire_GetInfoRequestMessage()

            let infoResponse = try await conn.sendRequest(
                infoMsg,
                type: .getInfo,
                timeout: OperationClass.profileGetInfo.timeout
            )

            guard case .getInfoResponse(let info) = infoResponse.payload else {
                throw KasiaError.networkError("Invalid response")
            }

            let latencyMs = Date().timeIntervalSince(startTime) * 1000

            // Get block DAG info for DAA score
            var dagMsg = Protowire_KaspadMessage()
            dagMsg.getBlockDagInfoRequest = Protowire_GetBlockDagInfoRequestMessage()

            let dagResponse = try await conn.sendRequest(
                dagMsg,
                type: .getBlockDagInfo,
                timeout: OperationClass.profileGetBlockDagInfo.timeout
            )

            var virtualDaaScore: UInt64?
            var networkName: String?

            if case .getBlockDagInfoResponse(let dagInfo) = dagResponse.payload {
                virtualDaaScore = dagInfo.virtualDaaScore
                networkName = dagInfo.networkName
            }

            // Update profile with basic info
            await registry.updateProfile(endpoint) { profile in
                profile.isSynced = info.isSynced
                profile.isUtxoIndexed = info.isUtxoIndexed
                profile.serverVersion = info.serverVersion
                profile.mempoolSize = info.mempoolSize
                profile.virtualDaaScore = virtualDaaScore
                profile.networkName = networkName
            }

            // DPI check: Request connected peer info (10-20KB payload)
            // This detects DPI-blocked nodes where large transfers fail
            // Only run once per epoch to avoid redundant checks
            let currentEpochId = await MainActor.run { epochMonitor.epochId }
            let existingRecord = await registry.get(endpoint)
            let alreadyCheckedInEpoch = existingRecord?.profile.peerInfoEpochId == currentEpochId

            // Skip check if already performed in this epoch
            if !alreadyCheckedInEpoch {
                var peerInfoOk = false
                var peerInfoBytes = 0

                do {
                    var peerMsg = Protowire_KaspadMessage()
                    peerMsg.getConnectedPeerInfoRequest = Protowire_GetConnectedPeerInfoRequestMessage()

                    let peerResponse = try await conn.sendRequest(
                        peerMsg,
                        type: .getConnectedPeerInfo,
                        timeout: OperationClass.profilePeerInfoCheck.timeout
                    )

                    if case .getConnectedPeerInfoResponse(let peerInfo) = peerResponse.payload {
                        // Measure response size by serializing back to bytes
                        if let serialized = try? peerInfo.serializedData() {
                            peerInfoBytes = serialized.count
                        }
                        peerInfoOk = true
                        NSLog("[NodeProfiler] Peer info check passed for %@ (%d bytes, %d peers)",
                              endpoint.key, peerInfoBytes, peerInfo.infos.count)
                    }
                } catch {
                    NSLog("[NodeProfiler] Peer info check failed for %@ (possible DPI block): %@",
                          endpoint.key, error.localizedDescription)
                }

                // Update profile with peer info check result
                await registry.updateProfile(endpoint) { profile in
                    profile.peerInfoOk = peerInfoOk
                    profile.peerInfoCheckedAt = Date()
                    profile.peerInfoSampleBytes = peerInfoBytes
                    profile.peerInfoEpochId = currentEpochId
                }
            }

            // Record success
            await registry.recordResult(
                endpoint: endpoint,
                epochId: await MainActor.run { epochMonitor.epochId },
                latencyMs: latencyMs,
                isTimeout: false,
                isError: false
            )

        } catch {
            // Record failure
            let isTimeout = error.localizedDescription.contains("timeout")
            await registry.recordResult(
                endpoint: endpoint,
                epochId: await MainActor.run { epochMonitor.epochId },
                latencyMs: nil,
                isTimeout: isTimeout,
                isError: true
            )

            // Suppressed: too noisy during node churn
        }
    }

    // MARK: - Discovery

    /// Start discovery loop
    private func startDiscoveryLoop() {
        discoveryTask?.cancel()
        discoveryTask = Task {
            while !Task.isCancelled {
                await runDiscoveryCycle()

                // Run discovery less often on macCatalyst to reduce background load.
#if targetEnvironment(macCatalyst)
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
#else
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
#endif
            }
        }
    }

    /// Track last logged hard-pause state
    private var lastLoggedHardPause: Bool?

    /// Run a discovery cycle
    private func runDiscoveryCycle() async {
        // Hard pause when we already have excellent low-latency, error-free active nodes.
        let hardPause = await hardPauseState()
        if hardPause.paused {
            if lastLoggedHardPause != true {
                NSLog(
                    "[NodeProfiler] Discovery HARD-PAUSED - %d active nodes under %.0fms and no recent errors",
                    hardPause.fastCount,
                    hardPauseLatencyMs
                )
                lastLoggedHardPause = true
            }
            return
        }

        if lastLoggedHardPause == true {
            let mode = await getProbeMode()
            NSLog(
                "[NodeProfiler] Discovery RESUMED - active=%d low-latency=%d errors=%d",
                mode.activeCount,
                mode.lowLatencyCount,
                hardPause.hasErrors ? 1 : 0
            )
            lastLoggedHardPause = false
        }

        // Refill discovery tokens.
        refillDiscoveryTokens()
        guard discoveryTokens > 0 else {
            NSLog("[NodeProfiler] Discovery budget exhausted")
            return
        }

        // Aggressive discovery when pool is not healthy.
        let poolHealth = await registry.poolHealth()
        if poolHealth.shouldTriggerDiscovery {
            await discoverWithRetry()
            await rebalanceActivePool(reason: "discovery-cycle")
            return
        }

        // Healthy pool: keep low-rate background search for better nodes.
        let now = Date()
        guard now.timeIntervalSince(lastHealthyDiscoveryAt) >= healthyDiscoveryInterval else {
            return
        }

        lastHealthyDiscoveryAt = now
        NSLog("[NodeProfiler] Healthy pool - running slow background discovery")
        await discoverWithRetry()
        await rebalanceActivePool(reason: "healthy-discovery")
    }

    private func rebalanceActivePool(reason: String) async {
        let result = await registry.rebalanceActivePool(
            minActive: minActiveNodes,
            maxActive: maxActiveNodes,
            maxReplacementsPerCycle: maxReplacementsPerCycle,
            minImprovementRatio: minReplacementImprovementRatio
        )

        if result.promoted > 0 || result.demoted > 0 {
            NSLog(
                "[NodeProfiler] Rebalance (%@): active=%d eligible=%d +%d/-%d",
                reason,
                result.activeCount,
                result.eligibleCount,
                result.promoted,
                result.demoted
            )
        }
    }

    /// Discover peers from a specific node (returns true on success)
    private func discoverFromNode(_ endpoint: Endpoint) async -> Bool {
        let conn = await connectionPool.connection(for: endpoint)

        do {
            if await !conn.isConnected {
                try await conn.connect()
            }

            // Request connected peer info (higher quality discovery)
            var msg = Protowire_KaspadMessage()
            msg.getConnectedPeerInfoRequest = Protowire_GetConnectedPeerInfoRequestMessage()

            let response = try await conn.sendRequest(
                msg,
                type: .getConnectedPeerInfo,
                timeout: OperationClass.discoveryGetPeerAddresses.timeout
            )

            guard case .getConnectedPeerInfoResponse(let peerResponse) = response.payload else {
                return false
            }

            // Process discovered addresses
            var discovered = 0
            for info in peerResponse.infos {
                // Parse address (format: "host:port" or "[ipv6]:port")
                guard let endpoint = parseAddress(info.address) else { continue }

                // Check if already known
                if await registry.get(endpoint) != nil { continue }

                // Budget check
                guard discoveryTokens > 0 else { break }
                discoveryTokens -= 1

                // Add to registry
                await registry.upsert(endpoint: endpoint, origin: .discovered)
                discovered += 1
            }

            if discovered > 0 {
                NSLog("[NodeProfiler] Discovered %d new peers from %@", discovered, endpoint.key)
            }

            // Track successful discovery
            successfulDiscoveryCount += 1
            NSLog("[NodeProfiler] getConnectedPeerInfo succeeded (%d total successful)", successfulDiscoveryCount)

            // Check if we should start TCP ping checks
            await checkAndStartTcpPingIfReady()

            return true

        } catch {
            NSLog("[NodeProfiler] Discovery failed from %@: %@", endpoint.key, error.localizedDescription)
            return false
        }
    }

    /// Retry discovery until success (single call)
    /// Excludes the primary subscription endpoint to avoid disrupting active connections
    private func discoverWithRetry() async {
        var usedEndpoints: Set<String> = []
        var successCount = 0
        let targetSuccesses = 1

        // Get primary endpoint to exclude from discovery
        let primaryKey = await getPrimaryEndpoint?()?.key

        while successCount < targetSuccesses && !Task.isCancelled {
            // Get available endpoints (not already used, exclude primary subscription endpoint)
            let activeNodes = await registry.records(inState: .active)
            let verifiedNodes = await registry.records(inState: .verified)
            let candidateNodes = (activeNodes + verifiedNodes)
                .filter {
                    !usedEndpoints.contains($0.endpoint.key) &&
                    !$0.health.isQuarantined &&
                    $0.endpoint.key != primaryKey  // Exclude primary subscription endpoint
                }

            guard let node = candidateNodes.first else {
                // No more endpoints available, wait and retry
                if successCount == 0 {
                    // Haven't succeeded once yet, keep trying
                    NSLog("[NodeProfiler] No endpoints available for discovery, waiting...")
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)  // Wait 5 seconds
                    continue
                } else {
                    // Already have some successes, exit
                    break
                }
            }

            usedEndpoints.insert(node.endpoint.key)
            let success = await discoverFromNode(node.endpoint)

            if success {
                successCount += 1
                NSLog("[NodeProfiler] discovery success %d/%d from %@", successCount, targetSuccesses, node.endpoint.key)
            } else if successCount == 0 {
                // First success not achieved yet, retry with delay
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)  // Wait 2 seconds before retry
            }
        }

        if successCount > 0 {
            NSLog("[NodeProfiler] Discovery with retry complete: %d/%d endpoints succeeded", successCount, targetSuccesses)
            // Force immediate save after discovery to persist new nodes
            await registry.persistNow()
        }
    }

    /// Allowed gRPC ports for discovered peers (mainnet + testnet)
    private static let allowedGrpcPorts: Set<Int> = [15110, 15111, 16110, 16111, 15210, 15211, 16210, 16211]

    /// Parse an address string to Endpoint
    /// - Converts IPv4-mapped IPv6 addresses (::ffff:x.x.x.x) to IPv4
    /// - Filters out pure IPv6 addresses
    /// - Filters out private/local IP addresses
    /// - Filters out non-standard ports
    /// - Subtracts 1 from port (P2P port → gRPC port)
    private func parseAddress(_ addr: String) -> Endpoint? {
        var host: String
        var port: Int

        // Handle IPv6 format: [::ffff:1.2.3.4]:16111 or [::1]:16111
        if addr.hasPrefix("[") {
            guard let closeBracket = addr.firstIndex(of: "]"),
                  let colonAfterBracket = addr[closeBracket...].firstIndex(of: ":"),
                  colonAfterBracket > closeBracket else {
                return nil
            }

            let ipv6Host = String(addr[addr.index(after: addr.startIndex)..<closeBracket])
            let portStr = String(addr[addr.index(after: colonAfterBracket)...])
            guard let parsedPort = Int(portStr) else { return nil }

            // Check for IPv4-mapped IPv6 address (::ffff:x.x.x.x)
            let ipv4MappedPrefix = "::ffff:"
            if ipv6Host.lowercased().hasPrefix(ipv4MappedPrefix) {
                // Extract the IPv4 part
                host = String(ipv6Host.dropFirst(ipv4MappedPrefix.count))
            } else {
                // Pure IPv6 address - filter out
                return nil
            }

            port = parsedPort
        } else {
            // Handle IPv4 format: 1.2.3.4:16111
            guard let lastColon = addr.lastIndex(of: ":") else { return nil }
            host = String(addr[..<lastColon])
            let portStr = String(addr[addr.index(after: lastColon)...])
            guard let parsedPort = Int(portStr) else { return nil }
            port = parsedPort
        }

        // Validate IPv4 format
        guard Self.isValidIPv4(host) else { return nil }

        // Filter out private/local IP addresses
        guard !isPrivateIP(host) else { return nil }

        // Subtract 1 from port (P2P port → gRPC port)
        // e.g., 16111 → 16110, 16211 → 16210
        let grpcPort = port - 1

        // Filter out non-standard ports (only allow known Kaspa gRPC ports)
        guard Self.allowedGrpcPorts.contains(grpcPort) else { return nil }

        return Endpoint(host: host, port: grpcPort)
    }

    /// Check if string is a valid IPv4 address
    private static func isValidIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }

        for part in parts {
            guard let num = Int(part), num >= 0 && num <= 255 else {
                return false
            }
        }
        return true
    }

    /// Check if IP address is private/local (should be filtered out)
    private func isPrivateIP(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }  // Invalid = filter out

        let a = parts[0]
        let b = parts[1]

        // 10.0.0.0/8 - Private
        if a == 10 { return true }

        // 172.16.0.0/12 - Private (172.16.x.x - 172.31.x.x)
        if a == 172 && b >= 16 && b <= 31 { return true }

        // 192.168.0.0/16 - Private
        if a == 192 && b == 168 { return true }

        // 127.0.0.0/8 - Loopback
        if a == 127 { return true }

        // 169.254.0.0/16 - Link-local
        if a == 169 && b == 254 { return true }

        // 0.0.0.0/8 - Current network
        if a == 0 { return true }

        // 100.64.0.0/10 - Carrier-grade NAT
        if a == 100 && b >= 64 && b <= 127 { return true }

        return false
    }

    // MARK: - TCP Ping for Candidate Prioritization

    /// Check if conditions are met to start TCP ping checks
    private func checkAndStartTcpPingIfReady() async {
        // Prerequisites: 3+ successful discovery calls AND DNS resolve complete
        guard successfulDiscoveryCount >= 3 && dnsResolveComplete else { return }

        // Only run in excellent network conditions
        let networkQuality = await MainActor.run { epochMonitor.networkQuality }
        guard networkQuality == .excellent else { return }

        // Only run in aggressive mode (not conservative/paused)
        let mode = await getProbeMode()
        guard !mode.isConservative else { return }

        // Don't start if already running
        guard tcpPingTask == nil || tcpPingTask?.isCancelled == true else { return }

        NSLog("[NodeProfiler] Starting TCP ping check on candidates (excellent network, aggressive mode, 3+ discovery, DNS complete)")
        startTcpPingBatches()
    }

    /// Start TCP ping checks on candidate nodes in sequential batches
    private func startTcpPingBatches() {
        tcpPingTask?.cancel()
        tcpPingTask = Task {
            await runTcpPingBatches()
        }
    }

    /// Run TCP ping checks on candidate nodes in sequential batches of 10
    /// Stops early after finding 5 nodes that pass the check
    private func runTcpPingBatches() async {
        let batchSize = 10
        let tcpTimeout: TimeInterval = 0.1  // 100ms
        let maxPassedNodes = 5  // Stop after finding this many reachable nodes

        // Get candidate nodes that haven't been TCP pinged yet
        let candidates = await registry.records(inState: .candidate)
            .filter { $0.health.tcpPingPassed == nil }  // Only check nodes not yet tested

        guard !candidates.isEmpty else {
            NSLog("[NodeProfiler] No candidates to TCP ping")
            return
        }

        NSLog("[NodeProfiler] TCP ping check: %d candidates to check", candidates.count)

        var checked = 0
        var passed = 0

        // Process in sequential batches
        for batch in stride(from: 0, to: candidates.count, by: batchSize) {
            guard !Task.isCancelled else { break }

            // Stop if we've found enough reachable nodes
            if passed >= maxPassedNodes {
                NSLog("[NodeProfiler] TCP ping check stopped: found %d reachable nodes", passed)
                break
            }

            // Re-check conditions before each batch
            let networkQuality = await MainActor.run { epochMonitor.networkQuality }
            guard networkQuality == .excellent else {
                NSLog("[NodeProfiler] TCP ping check stopped: network quality no longer excellent")
                break
            }

            let mode = await getProbeMode()
            if mode.isConservative {
                NSLog("[NodeProfiler] TCP ping check stopped: switched to conservative mode")
                break
            }

            let batchEnd = min(batch + batchSize, candidates.count)
            let batchCandidates = Array(candidates[batch..<batchEnd])

            // Run batch sequentially (not parallel) to avoid network congestion
            for candidate in batchCandidates {
                guard !Task.isCancelled else { break }

                // Stop if we've found enough reachable nodes
                if passed >= maxPassedNodes {
                    break
                }

                let success = await tcpPing(
                    host: candidate.endpoint.host,
                    port: candidate.endpoint.port,
                    timeout: tcpTimeout
                )

                // Update node health with TCP ping result
                await registry.updateTcpPingResult(candidate.endpoint, passed: success)

                checked += 1
                if success {
                    passed += 1
                }
            }

            // Small delay between batches to avoid overloading
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms between batches
        }

        NSLog("[NodeProfiler] TCP ping check complete: %d/%d candidates passed", passed, checked)
    }

    /// Quick TCP ping to check if host:port is reachable
    /// Returns true if connection succeeds within timeout, false otherwise
    private func tcpPing(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )

            let queue = DispatchQueue(label: "tcp-ping-\(host):\(port)")
            let gate = ContinuationGate()

            // Timeout handler
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                gate.resumeOnce {
                    continuation.resume(returning: false)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Connection succeeded
                    connection.cancel()
                    gate.resumeOnce {
                        continuation.resume(returning: true)
                    }

                case .failed, .cancelled:
                    // Connection failed
                    gate.resumeOnce {
                        continuation.resume(returning: false)
                    }

                case .waiting(let error):
                    // Network path not available
                    if case .posix(let code) = error, code == .ENETUNREACH || code == .EHOSTUNREACH {
                        connection.cancel()
                        gate.resumeOnce {
                            continuation.resume(returning: false)
                        }
                    }

                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    /// Refill discovery tokens based on elapsed time
    private func refillDiscoveryTokens() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTokenRefill)
        let tokensToAdd = Int(elapsed / 3600.0) * tokensPerHour

        if tokensToAdd > 0 {
            discoveryTokens = min(discoveryTokens + tokensToAdd, tokensPerHour * 24)
            lastTokenRefill = now
        }
    }

    // MARK: - Manual Triggers

    /// Force immediate probe of all nodes
    func forceProbeAll() async {
        NSLog("[NodeProfiler] Force probing all nodes")
        await runProbeCycle()
    }

    /// Force immediate discovery
    func forceDiscovery() async {
        NSLog("[NodeProfiler] Force discovery")
        await runDiscoveryCycle()
    }

    /// Profile a specific endpoint
    func profileEndpoint(_ endpoint: Endpoint) async {
        await probeNode(endpoint)
    }

    // MARK: - DNS Resolution

    /// Resolve DNS seed to all A records using getaddrinfo
    private func resolveDNSSeed(_ seed: DNSSeed) async -> [Endpoint] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET  // IPv4 only
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP

                var result: UnsafeMutablePointer<addrinfo>?

                let status = getaddrinfo(seed.hostname, String(seed.port), &hints, &result)

                guard status == 0, let addrList = result else {
                    if status != 0 {
                        NSLog("[NodeProfiler] DNS resolution failed for %@: %@",
                              seed.hostname, String(cString: gai_strerror(status)))
                    }
                    continuation.resume(returning: [])
                    return
                }

                defer { freeaddrinfo(addrList) }

                var endpoints: [Endpoint] = []
                var current: UnsafeMutablePointer<addrinfo>? = addrList

                // Iterate through all resolved addresses
                while let currentPtr = current {
                    current = currentPtr.pointee.ai_next

                    guard let addr = currentPtr.pointee.ai_addr else { continue }

                    // Convert sockaddr to IP string
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        addr,
                        socklen_t(currentPtr.pointee.ai_addrlen),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )

                    if result == 0 {
                        let ipString = String(cString: hostname)
                        if Self.isValidIPv4(ipString) {
                            endpoints.append(Endpoint(host: ipString, port: seed.port))
                        }
                    }
                }

                continuation.resume(returning: endpoints)
            }
        }
    }

    /// Refresh DNS seeds and populate registry with resolved IPs
    private func refreshDNSSeeds() async {
        let seeds = networkType == .mainnet ? mainnetDNSSeeds : testnetDNSSeeds

        NSLog("[NodeProfiler] Resolving %d DNS seeds...", seeds.count)

        var totalResolved = 0

        // Resolve seeds in parallel for speed
        await withTaskGroup(of: (String, [Endpoint]).self) { group in
            for seed in seeds {
                group.addTask {
                    let endpoints = await self.resolveDNSSeed(seed)
                    return (seed.hostname, endpoints)
                }
            }

            for await (hostname, endpoints) in group {
                for endpoint in endpoints {
                    // Check if already in registry
                    if await registry.get(endpoint) == nil {
                        await registry.upsert(endpoint: endpoint, origin: .seed)
                        totalResolved += 1
                    }
                }

                if !endpoints.isEmpty {
                    NSLog("[NodeProfiler] DNS seed %@ resolved to %d IPs", hostname, endpoints.count)
                }
            }
        }

        if totalResolved > 0 {
            NSLog("[NodeProfiler] Added %d new nodes from DNS resolution", totalResolved)
            // Force immediate save after DNS discovery
            await registry.persistNow()
        }

        lastDNSRefresh = Date()
        dnsResolveComplete = true

        // Check if we should start TCP ping checks now
        await checkAndStartTcpPingIfReady()
    }

    /// Start periodic DNS refresh (every 1 hour)
    private func startDNSRefreshLoop() async {
        dnsRefreshTask?.cancel()
        dnsRefreshTask = Task {
            while !Task.isCancelled {
                // Wait 1 hour between refreshes
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)

                if !Task.isCancelled {
                    await self.refreshDNSSeeds()
                }
            }
        }
    }

    // MARK: - Quick Boot

    /// Quick boot sequence:
    /// 1. Check if we have persisted active nodes - if yes, use them directly
    /// 2. If no active nodes, resolve DNS seeds and probe them
    /// 3. Call discovery to find more nodes
    /// Returns as soon as we have at least one active node
    func quickBoot() async {
        // Step 1: Check if we already have active nodes from persistence
        let persistedActive = await registry.records(inState: .active)
        let persistedVerified = await registry.records(inState: .verified)

        if !persistedActive.isEmpty {
            NSLog("[NodeProfiler] Quick boot: found %d persisted active nodes, skipping DNS resolution", persistedActive.count)

            // Verify one of the persisted nodes is still working
            if let node = persistedActive.first {
                await probeNode(node.endpoint)
                let stillActive = await registry.stateCounts()[.active] ?? 0
                if stillActive > 0 {
                    NSLog("[NodeProfiler] Quick boot: persisted node verified, starting peer discovery")
                    _ = await discoverFromNode(node.endpoint)
                    await rebalanceActivePool(reason: "quick-boot-persisted-active")

                    // Start DNS refresh loop in background for pool expansion
                    Task { [weak self] in
                        await self?.startDNSRefreshLoop()
                    }
                    return
                }
            }
        } else if !persistedVerified.isEmpty {
            NSLog("[NodeProfiler] Quick boot: found %d persisted verified nodes, probing...", persistedVerified.count)

            // Try to promote verified nodes to active
            for node in persistedVerified.prefix(5) {
                await probeNode(node.endpoint)
                let activeCount = await registry.stateCounts()[.active] ?? 0
                if activeCount > 0 {
                    NSLog("[NodeProfiler] Quick boot: verified node promoted to active")
                    _ = await discoverFromNode(node.endpoint)
                    await rebalanceActivePool(reason: "quick-boot-persisted-verified")

                    Task { [weak self] in
                        await self?.startDNSRefreshLoop()
                    }
                    return
                }
            }
        }

        // No persisted nodes worked - fall back to DNS resolution
        NSLog("[NodeProfiler] Quick boot: no valid persisted nodes, starting DNS resolution")

        // Run DNS resolution in background
        Task { [weak self] in
            guard let self = self else { return }
            await self.refreshDNSSeeds()
            await self.startDNSRefreshLoop()
            NSLog("[NodeProfiler] DNS resolution complete, continuing in background")
        }

        // Probe resolved seed nodes, return as soon as we have one active
        let maxProbes = await getMaxConcurrentProbes()

        // Poll for seeds as they're being resolved
        var attemptCount = 0
        while attemptCount < 5 {  // Try for up to 5 seconds
            let seeds = await registry.records(inState: .candidate)
                .filter { $0.origin == .seed }

            if !seeds.isEmpty {
                NSLog("[NodeProfiler] Found %d resolved seeds, starting probes", seeds.count)

                var foundActive = false
                await withTaskGroup(of: Void.self) { group in
                    var activeProbes = 0

                    for seed in seeds.prefix(20) {
                        // Check if we have an active node
                        let activeCount = await registry.stateCounts()[.active] ?? 0
                        if activeCount > 0 {
                            NSLog("[NodeProfiler] Quick boot complete - found active node")
                            foundActive = true
                            return
                        }

                        // Respect concurrency limit
                        if activeProbes >= maxProbes {
                            _ = await group.next()
                            activeProbes -= 1

                            // Check again after each probe completes
                            let activeCount = await registry.stateCounts()[.active] ?? 0
                            if activeCount > 0 {
                                NSLog("[NodeProfiler] Quick boot complete - found active node")
                                foundActive = true
                                return
                            }
                        }

                        group.addTask {
                            await self.probeNode(seed.endpoint)
                        }
                        activeProbes += 1
                    }

                    // Wait for all probes
                    for await _ in group {
                        let activeCount = await registry.stateCounts()[.active] ?? 0
                        if activeCount > 0 {
                            NSLog("[NodeProfiler] Quick boot complete - found active node")
                            foundActive = true
                            return
                        }
                    }
                }

                // If we found an active node, discover peers immediately
                if foundActive {
                    let activeNodes = await registry.records(inState: .active)
                    if let node = activeNodes.first {
                        NSLog("[NodeProfiler] Quick boot: calling discovery for peer discovery")
                        _ = await discoverFromNode(node.endpoint)
                    }
                    await rebalanceActivePool(reason: "quick-boot-seed-probes")
                    return
                }

                // If we probed seeds, break the retry loop
                break
            }

            // Wait a bit for DNS resolution
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            attemptCount += 1
        }

        NSLog("[NodeProfiler] Quick boot finished initial probes")

        // Continue peer discovery in background
        Task.detached { [weak self] in
            guard let self = self else { return }

            // Wait for at least one active node
            for _ in 0..<30 {
                let activeCount = await self.registry.stateCounts()[.active] ?? 0
                if activeCount > 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            // Discover peers from any working node
            let activeNodes = await self.registry.records(inState: .active)
            let verifiedNodes = await self.registry.records(inState: .verified)
            if let workingNode = activeNodes.first ?? verifiedNodes.first {
                NSLog("[NodeProfiler] Calling discovery from %@", workingNode.endpoint.key)
                _ = await self.discoverFromNode(workingNode.endpoint)
            }

            // Probe discovered candidates with concurrency control
            let candidates = await self.registry.records(inState: .candidate)
                .filter { $0.origin == .discovered }
                .prefix(50)

            if !candidates.isEmpty {
                NSLog("[NodeProfiler] Probing %d discovered candidates", candidates.count)
            }

            let maxProbes = await self.getMaxConcurrentProbes()
            await withTaskGroup(of: Void.self) { group in
                var activeProbes = 0

                for candidate in candidates {
                    if activeProbes >= maxProbes {
                        _ = await group.next()
                        activeProbes -= 1
                    }

                    group.addTask {
                        await self.probeNode(candidate.endpoint)
                    }
                    activeProbes += 1
                }

                for await _ in group {}
            }

            await self.rebalanceActivePool(reason: "quick-boot-background")

            NSLog("[NodeProfiler] Background peer discovery complete")
        }
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
