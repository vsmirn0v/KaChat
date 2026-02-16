import Foundation
import Network

/// Node profiler and discovery engine
/// Handles capability checking, periodic probing, and peer discovery
actor NodeProfiler {
    // MARK: - Dependencies

    private let registry: NodeRegistry
    private let connectionPool: GRPCConnectionPool
    private let epochMonitor: NetworkEpochMonitor

    private enum TcpScreenMode: String {
        case off
        case prioritize
        case gate
    }

    private struct TcpScreeningConfig {
        let mode: TcpScreenMode = .prioritize
        let minDiscoverySuccesses = 3
        let batchSize = 10
        let maxPassedNodes = 5
        let interBatchDelayNs: UInt64 = 50_000_000
        let resultTTL: TimeInterval = 15 * 60
        let retryAttempts = 2
        let retryDelayNs: UInt64 = 150_000_000
        let explorationRatio = 0.15
        let minScreenedCandidatesPerCycle = 2
        let maxScreenedCandidatesPerCycle = 12
        let geoRefreshTTL: TimeInterval = 24 * 60 * 60

        func maxConcurrentPings(for quality: NetworkQuality) -> Int {
            switch quality {
            case .excellent: return 5
            case .good: return 3
            case .poor: return 2
            case .offline: return 1
            }
        }

        func stageATimeout(for quality: NetworkQuality) -> TimeInterval {
            switch quality {
            case .excellent: return 0.35
            case .good: return 0.60
            case .poor: return 1.20
            case .offline: return 1.00
            }
        }
    }

    private struct ClientGeoContext: Sendable {
        let ip: String
        let latitude: Double
        let longitude: Double
        let asn: String?
        let countryCode: String?
        let resolvedAt: Date
    }

    private struct CandidateRankingContext: Sendable {
        let prefixStats: [String: PrefixPerformanceStats]
        let fastPrefixes: Set<String>
        let clientGeo: ClientGeoContext?
    }

    private struct CandidateRankingWeights {
        // Base and freshness
        let noTcpFreshPenalty = -6
        let overduePerUnit = 10.0
        let overdueCap = 50

        // TCP signal
        let tcpPassBonus = 30
        let tcpFailPenalty = -20
        let tcpRttMaxBonus = 20
        let tcpRttMaxPenalty = -10
        let tcpRttPivotMs = 180.0
        let tcpRttClampMs = 300.0
        let tcpRttScale = 8.0

        // Prefix historical signal
        let prefixFastBonus = 18
        let prefixMediumBonus = 10
        let prefixSlowPenalty = -10
        let prefixFastLatencyMs = 120.0
        let prefixMediumLatencyMs = 220.0
        let prefixSlowLatencyMs = 420.0
        let prefixLowErrorBonus = 6
        let prefixHighErrorPenalty = -8
        let prefixLowErrorRate = 0.10
        let prefixHighErrorRate = 0.35
        let topPrefixBonus = 8

        // Geo / ASN soft prior
        let predictedRttFastBonus = 8
        let predictedRttSlowPenalty = -6
        let predictedRttFastMs = 50.0
        let predictedRttSlowMs = 180.0
        let shortDistanceBonus = 6
        let longDistancePenalty = -4
        let shortDistanceKm = 2_000.0
        let longDistanceKm = 9_000.0
        let sameAsnBonus = 5
    }

    private struct SearchTelemetry {
        var probeCycles = 0
        var discoveryCycles = 0
        var discoveryCalls = 0
        var discoverySuccesses = 0

        var tcpRuns = 0
        var stageAChecked = 0
        var stageAPassed = 0
        var stageBChecked = 0
        var stageBPassed = 0

        mutating func merge(
            stageAChecked: Int,
            stageAPassed: Int,
            stageBChecked: Int,
            stageBPassed: Int
        ) {
            self.stageAChecked += stageAChecked
            self.stageAPassed += stageAPassed
            self.stageBChecked += stageBChecked
            self.stageBPassed += stageBPassed
        }
    }

    // MARK: - Configuration
    private let tcpScreening = TcpScreeningConfig()
    private let rankingWeights = CandidateRankingWeights()
    private let geoIPDatabase = LocalGeoIPDatabase()
    private var clientGeoContext: ClientGeoContext?
    private var lastClientGeoRefreshAttempt: Date = .distantPast
    private var telemetry = SearchTelemetry()
    private let maxRemoteNodeGeoLookupsPerSession = 12
    private var remoteNodeGeoLookups = 0

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
    private let hardPauseErrorWindow: TimeInterval = 15 * 60
    private let hardPauseCacheTTL: TimeInterval = 10
    private var cachedHardPauseState: (paused: Bool, fastCount: Int, hasErrors: Bool, thresholdMs: Double)?
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
        NSLog(
            "[NodeProfiler] Started for %@ (tcp-screen=%@, explore=%.2f, stageA=%.2fs)",
            network.displayName,
            tcpScreening.mode.rawValue,
            tcpScreening.explorationRatio,
            tcpScreening.stageATimeout(for: .excellent)
        )
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
        telemetry.probeCycles += 1
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

        if telemetry.probeCycles % 20 == 0 {
            logTelemetrySnapshot(reason: "probe")
        }
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
        let rankingContext = await buildCandidateRankingContext(from: allRecords)

        var candidates: [(NodeRecord, Int)] = []  // (record, priority)

        for record in allRecords {
            // Skip quarantined nodes that haven't reached their release time
            if record.health.isQuarantined {
                continue
            }

            // Calculate probe priority
            let priority = await calculateProbePriority(record, now: now, context: rankingContext)
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
        let maxSelection = maxProbes * batchMultiplier
        let sorted = candidates.sorted { $0.1 > $1.1 }

        let deterministicCount = max(1, Int(Double(maxSelection) * (1.0 - tcpScreening.explorationRatio)))
        var selected = Array(sorted.prefix(deterministicCount))
        let remaining = max(0, maxSelection - selected.count)
        if remaining > 0 {
            let tail = Array(sorted.dropFirst(deterministicCount))
            selected.append(contentsOf: tail.shuffled().prefix(remaining))
        }

        let poolHealth = await registry.poolHealth()
        let candidateCap: Int
        switch poolHealth {
        case .healthy:
            candidateCap = tcpScreening.minScreenedCandidatesPerCycle
        case .degraded:
            candidateCap = max(tcpScreening.minScreenedCandidatesPerCycle + 1, maxSelection / 3)
        case .critical, .failed:
            candidateCap = tcpScreening.maxScreenedCandidatesPerCycle
        }

        var result: [NodeRecord] = []
        var candidateCount = 0
        for (record, _) in selected {
            if record.state == .candidate {
                if candidateCount >= candidateCap { continue }
                candidateCount += 1
            }
            result.append(record)
            if result.count >= maxSelection { break }
        }

        return result
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
    private func hardPauseState() async -> (paused: Bool, fastCount: Int, hasErrors: Bool, thresholdMs: Double) {
        let now = Date()
        if let cached = cachedHardPauseState, now.timeIntervalSince(lastHardPauseCheckAt) < hardPauseCacheTTL {
            return cached
        }

        let thresholdMs = await MainActor.run { epochMonitor.networkQuality.lowLatencyThresholdMs }
        let activeNodes = await registry.records(inState: .active)
        let fastNodes = activeNodes.filter { $0.effectiveLatencyMs <= thresholdMs }
        let hasErrors = activeNodes.contains { record in
            if record.health.consecutiveFailures > 0 { return true }
            if let lastFailure = record.health.lastFailureAt,
               now.timeIntervalSince(lastFailure) <= hardPauseErrorWindow {
                return true
            }
            return false
        }

        let paused = fastNodes.count >= hardPauseFastNodeThreshold && !hasErrors
        let state = (paused: paused, fastCount: fastNodes.count, hasErrors: hasErrors, thresholdMs: thresholdMs)
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
            case .verified: return 15       // 15 seconds - promote quickly
            case .profiled: return 120      // 2 minutes - test to verify
            case .candidate: return 240     // 4 minutes - discover new nodes
            case .suspect: return 300       // 5 minutes - try to recover
            case .quarantined: return 0
            }
        }
    }

    /// Calculate probe priority for a node
    private func calculateProbePriority(
        _ record: NodeRecord,
        now: Date,
        context: CandidateRankingContext
    ) async -> Int {
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

        // Optional TCP screening policy for candidate nodes.
        if record.state == .candidate {
            switch tcpScreening.mode {
            case .off:
                break
            case .prioritize, .gate:
                if isTcpPingFresh(record, now: now), let passed = record.health.tcpPingPassed {
                    priority += passed ? rankingWeights.tcpPassBonus : rankingWeights.tcpFailPenalty
                } else {
                    priority += rankingWeights.noTcpFreshPenalty
                }
            }

            if let tcpRtt = record.health.tcpConnectRttMs.value ?? record.health.lastTcpRttMs {
                // Favor lower TCP setup RTT while still giving unknown nodes a chance.
                let rttBonus = Int(
                    (rankingWeights.tcpRttPivotMs - min(rankingWeights.tcpRttClampMs, tcpRtt))
                        / rankingWeights.tcpRttScale
                )
                priority += max(rankingWeights.tcpRttMaxPenalty, min(rankingWeights.tcpRttMaxBonus, rttBonus))
            }

            let prefix = record.profile.prefix24 ?? Self.ipv4Prefix24(record.endpoint.host)
            if let prefix, let stats = context.prefixStats[prefix] {
                if stats.p50LatencyMs <= rankingWeights.prefixFastLatencyMs {
                    priority += rankingWeights.prefixFastBonus
                } else if stats.p50LatencyMs <= rankingWeights.prefixMediumLatencyMs {
                    priority += rankingWeights.prefixMediumBonus
                } else if stats.p50LatencyMs > rankingWeights.prefixSlowLatencyMs {
                    priority += rankingWeights.prefixSlowPenalty
                }

                if stats.averageErrorRate > rankingWeights.prefixHighErrorRate {
                    priority += rankingWeights.prefixHighErrorPenalty
                } else if stats.averageErrorRate < rankingWeights.prefixLowErrorRate {
                    priority += rankingWeights.prefixLowErrorBonus
                }
            }

            if let prefix, context.fastPrefixes.contains(prefix) {
                priority += rankingWeights.topPrefixBonus
            }

            if let predicted = record.profile.predictedMinRttMs {
                if predicted <= rankingWeights.predictedRttFastMs {
                    priority += rankingWeights.predictedRttFastBonus
                } else if predicted >= rankingWeights.predictedRttSlowMs {
                    priority += rankingWeights.predictedRttSlowPenalty
                }
            }

            if let distanceKm = record.profile.geoDistanceKm {
                if distanceKm < rankingWeights.shortDistanceKm {
                    priority += rankingWeights.shortDistanceBonus
                } else if distanceKm > rankingWeights.longDistanceKm {
                    priority += rankingWeights.longDistancePenalty
                }
            }

            if let clientAsn = context.clientGeo?.asn,
               let nodeAsn = record.profile.asn,
               !clientAsn.isEmpty,
               clientAsn == nodeAsn {
                priority += rankingWeights.sameAsnBonus
            }
        }

        // Bonus for being overdue
        let overdueRatio = elapsed / interval
        priority += Int(min(Double(rankingWeights.overdueCap), overdueRatio * rankingWeights.overduePerUnit))

        return priority
    }

    private func buildCandidateRankingContext(from records: [NodeRecord]) async -> CandidateRankingContext {
        let prefixStats = await registry.prefixPerformanceStats(minSamples: 2)
        let fastPrefixes = Set(
            prefixStats
                .sorted { lhs, rhs in
                    if lhs.value.p50LatencyMs != rhs.value.p50LatencyMs {
                        return lhs.value.p50LatencyMs < rhs.value.p50LatencyMs
                    }
                    return lhs.value.averageErrorRate < rhs.value.averageErrorRate
                }
                .prefix(10)
                .map(\.key)
        )

        // Fallback when we have too little prefix history: trust prefixes of top active nodes.
        let fallbackFastPrefixes: Set<String>
        if fastPrefixes.isEmpty {
            fallbackFastPrefixes = Set(
                records
                    .filter { $0.state == .active }
                    .sorted { $0.effectiveLatencyMs < $1.effectiveLatencyMs }
                    .prefix(5)
                    .compactMap { $0.profile.prefix24 ?? Self.ipv4Prefix24($0.endpoint.host) }
            )
        } else {
            fallbackFastPrefixes = fastPrefixes
        }

        let clientGeo = await refreshClientGeoContextIfNeeded()
        return CandidateRankingContext(
            prefixStats: prefixStats,
            fastPrefixes: fallbackFastPrefixes,
            clientGeo: clientGeo
        )
    }

    private func refreshClientGeoContextIfNeeded() async -> ClientGeoContext? {
        let now = Date()
        if let cached = clientGeoContext,
           now.timeIntervalSince(cached.resolvedAt) <= tcpScreening.geoRefreshTTL {
            return cached
        }

        if now.timeIntervalSince(lastClientGeoRefreshAttempt) < 5 * 60 {
            return clientGeoContext
        }
        lastClientGeoRefreshAttempt = now

        guard let ip = await fetchPublicIP() else {
            if clientGeoContext == nil {
                clientGeoContext = await inferClientGeoFromPoolHints()
            }
            return clientGeoContext
        }

        if let localLookup = await geoIPDatabase.lookup(ip: ip) {
            let context = ClientGeoContext(
                ip: ip,
                latitude: localLookup.latitude,
                longitude: localLookup.longitude,
                asn: localLookup.asn,
                countryCode: localLookup.countryCode,
                resolvedAt: Date()
            )
            clientGeoContext = context
            return context
        }

        if let remoteLookup = await fetchRemoteGeoLookup(for: ip) {
            let context = ClientGeoContext(
                ip: ip,
                latitude: remoteLookup.latitude,
                longitude: remoteLookup.longitude,
                asn: remoteLookup.asn,
                countryCode: remoteLookup.countryCode,
                resolvedAt: Date()
            )
            clientGeoContext = context
            return context
        }

        if clientGeoContext == nil {
            clientGeoContext = await inferClientGeoFromPoolHints()
        }
        return clientGeoContext
    }

    private func fetchPublicIP() async -> String? {
        let endpoints = [
            "https://api64.ipify.org?format=json",
            "https://ifconfig.me/ip"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 1.5
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      200..<300 ~= http.statusCode else { continue }

                if endpoint.contains("ipify") {
                    if let payload = try? JSONDecoder().decode(IPifyResponse.self, from: data),
                       Self.isValidIPv4(payload.ip) {
                        return payload.ip
                    }
                } else if let value = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    Self.isValidIPv4(value) {
                    return value
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func fetchRemoteGeoLookup(for ip: String, timeout: TimeInterval = 1.8) async -> GeoIPLookup? {
        guard let url = URL(string: "https://ipapi.co/\(ip)/json/") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode else { return nil }

            let payload = try JSONDecoder().decode(IPApiCoResponse.self, from: data)
            guard let latitude = payload.latitude,
                  let longitude = payload.longitude else { return nil }
            return GeoIPLookup(
                latitude: latitude,
                longitude: longitude,
                countryCode: payload.countryCode,
                asn: payload.asn,
                source: "ipapi-co"
            )
        } catch {
            return nil
        }
    }

    private func inferClientGeoFromPoolHints() async -> ClientGeoContext? {
        let candidates = await registry.records(inState: .active)
            .filter { $0.profile.geoLatitude != nil && $0.profile.geoLongitude != nil }
            .sorted { $0.effectiveLatencyMs < $1.effectiveLatencyMs }
            .prefix(3)

        guard !candidates.isEmpty else { return nil }
        let latitudes = candidates.compactMap(\.profile.geoLatitude)
        let longitudes = candidates.compactMap(\.profile.geoLongitude)
        guard !latitudes.isEmpty, !longitudes.isEmpty else { return nil }

        let latitude = latitudes.reduce(0, +) / Double(latitudes.count)
        let longitude = longitudes.reduce(0, +) / Double(longitudes.count)
        let country = candidates.compactMap(\.profile.countryCode).first
        let asn = candidates.compactMap(\.profile.asn).first

        return ClientGeoContext(
            ip: "pool-hint",
            latitude: latitude,
            longitude: longitude,
            asn: asn,
            countryCode: country,
            resolvedAt: Date()
        )
    }

    /// Probe a single node
    private func probeNode(_ endpoint: Endpoint) async {
        if let record = await registry.get(endpoint) {
            if await shouldProbeCandidate(record) == false {
                return
            }
            if record.profile.prefix24 == nil || record.profile.geoResolvedAt == nil {
                await enrichGeoHintsIfNeeded(for: endpoint)
            }
        }

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
        telemetry.discoveryCycles += 1
        // Hard pause when we already have excellent low-latency, error-free active nodes.
        let hardPause = await hardPauseState()
        if hardPause.paused {
            if lastLoggedHardPause != true {
                NSLog(
                    "[NodeProfiler] Discovery HARD-PAUSED - %d active nodes under %.0fms and no recent errors",
                    hardPause.fastCount,
                    hardPause.thresholdMs
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

        if telemetry.discoveryCycles % 10 == 0 {
            logTelemetrySnapshot(reason: "discovery")
        }
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
                await enrichGeoHintsIfNeeded(for: endpoint)
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
        var attempts = 0
        var discoveryCallsThisRun = 0

        // Get primary endpoint to exclude from discovery
        let primaryKey = await getPrimaryEndpoint?()?.key
        let poolHealth = await registry.poolHealth()
        let networkQuality = await MainActor.run { epochMonitor.networkQuality }

        let targetSuccesses: Int
        switch poolHealth {
        case .healthy: targetSuccesses = 1
        case .degraded: targetSuccesses = 2
        case .critical, .failed: targetSuccesses = 3
        }

        let sourceParallelism: Int
        switch networkQuality {
        case .excellent: sourceParallelism = 3
        case .good: sourceParallelism = 2
        case .poor, .offline: sourceParallelism = 1
        }

        NSLog(
            "[NodeProfiler] Discovery fanout starting: target=%d parallel=%d pool=%d quality=%d",
            targetSuccesses,
            sourceParallelism,
            poolHealth.rawValue,
            networkQuality.rawValue
        )

        while successCount < targetSuccesses && !Task.isCancelled && attempts < 8 {
            // Get available endpoints (not already used, exclude primary subscription endpoint)
            let activeNodes = await registry.records(inState: .active)
            let verifiedNodes = await registry.records(inState: .verified)
            let candidateNodes = (activeNodes + verifiedNodes)
                .filter {
                    !usedEndpoints.contains($0.endpoint.key) &&
                    !$0.health.isQuarantined &&
                    $0.endpoint.key != primaryKey  // Exclude primary subscription endpoint
                }
                .sorted { discoverySourceScore($0) > discoverySourceScore($1) }

            guard !candidateNodes.isEmpty else {
                // No more endpoints available, wait and retry
                if successCount == 0 {
                    // Haven't succeeded once yet, keep trying
                    NSLog("[NodeProfiler] No endpoints available for discovery, waiting...")
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)  // Wait 5 seconds
                    attempts += 1
                    continue
                } else {
                    // Already have some successes, exit
                    break
                }
            }

            let batchCount = min(sourceParallelism, candidateNodes.count)
            let batch = Array(candidateNodes.prefix(batchCount))
            for node in batch {
                usedEndpoints.insert(node.endpoint.key)
            }

            let results = await withTaskGroup(of: (Endpoint, Bool).self, returning: [(Endpoint, Bool)].self) { group in
                for node in batch {
                    group.addTask {
                        let success = await self.discoverFromNode(node.endpoint)
                        return (node.endpoint, success)
                    }
                }

                var aggregated: [(Endpoint, Bool)] = []
                for await result in group {
                    aggregated.append(result)
                }
                return aggregated
            }

            var batchSuccesses = 0
            for (endpoint, success) in results {
                discoveryCallsThisRun += 1
                if success {
                    batchSuccesses += 1
                    successCount += 1
                    NSLog("[NodeProfiler] discovery success %d/%d from %@", successCount, targetSuccesses, endpoint.key)
                    if successCount >= targetSuccesses {
                        break
                    }
                }
            }

            if batchSuccesses == 0 && successCount == 0 {
                // First success not achieved yet, retry with delay.
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            }

            attempts += 1
        }

        telemetry.discoveryCalls += discoveryCallsThisRun
        telemetry.discoverySuccesses += successCount
        if discoveryCallsThisRun > 0 {
            let successRate = (Double(successCount) / Double(discoveryCallsThisRun)) * 100
            NSLog(
                "[NodeProfiler] Discovery efficiency: %d/%d successes (%.0f%%), attempts=%d",
                successCount,
                discoveryCallsThisRun,
                successRate,
                attempts
            )
        }

        if successCount > 0 {
            NSLog("[NodeProfiler] Discovery with retry complete: %d/%d endpoints succeeded", successCount, targetSuccesses)
            // Force immediate save after discovery to persist new nodes
            await registry.persistNow()
        }
    }

    private func discoverySourceScore(_ record: NodeRecord) -> Double {
        var score = 0.0
        if record.state == .active { score += 40 }
        if record.state == .verified { score += 20 }

        let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value ?? 450
        score += max(0, 400 - latency)

        score += Double(record.health.consecutiveSuccesses * 8)
        score -= Double(record.health.consecutiveFailures * 12)

        if record.origin == .userAdded { score += 12 }
        if record.health.tcpPingPassed == true { score += 6 }

        return score
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

    private func enrichGeoHintsIfNeeded(for endpoint: Endpoint) async {
        guard Self.isValidIPv4(endpoint.host) else { return }
        let now = Date()
        let prefix = Self.ipv4Prefix24(endpoint.host)
        let existing = await registry.get(endpoint)

        if let resolvedAt = existing?.profile.geoResolvedAt,
           now.timeIntervalSince(resolvedAt) <= tcpScreening.geoRefreshTTL {
            if existing?.profile.prefix24 == nil, let prefix {
                await registry.updateProfileMetadata(endpoint) { profile in
                    profile.prefix24 = prefix
                }
            }
            return
        }

        var nodeLookup = await geoIPDatabase.lookup(ip: endpoint.host)
        if nodeLookup == nil, remoteNodeGeoLookups < maxRemoteNodeGeoLookupsPerSession {
            if let remote = await fetchRemoteGeoLookup(for: endpoint.host, timeout: 1.2) {
                nodeLookup = remote
                remoteNodeGeoLookups += 1
            }
        }
        let clientGeo = await refreshClientGeoContextIfNeeded()

        let distanceKm: Double?
        if let lookup = nodeLookup, let clientGeo {
            distanceKm = Self.haversineDistanceKm(
                lat1: clientGeo.latitude,
                lon1: clientGeo.longitude,
                lat2: lookup.latitude,
                lon2: lookup.longitude
            )
        } else {
            distanceKm = nil
        }

        await registry.updateProfileMetadata(endpoint) { profile in
            if let prefix {
                profile.prefix24 = prefix
            }

            if let lookup = nodeLookup {
                profile.geoLatitude = lookup.latitude
                profile.geoLongitude = lookup.longitude
                profile.countryCode = lookup.countryCode
                profile.asn = lookup.asn
            }

            if let distanceKm {
                profile.geoDistanceKm = distanceKm
                profile.predictedMinRttMs = Self.predictedMinRttFloorMs(forDistanceKm: distanceKm)
            }

            profile.geoResolvedAt = now
        }
    }

    private static func ipv4Prefix24(_ host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        guard parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private static func haversineDistanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKm = 6_371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusKm * c
    }

    private static func predictedMinRttFloorMs(forDistanceKm distanceKm: Double) -> Double {
        // Soft floor model: fiber RTT ~= distance / 100 km/ms, plus routing overhead.
        8.0 + (distanceKm / 100.0)
    }

    // MARK: - TCP Ping for Candidate Screening

    private func isTcpPingFresh(_ record: NodeRecord, now: Date = Date()) -> Bool {
        guard let checkedAt = record.health.tcpPingCheckedAt else { return false }
        return now.timeIntervalSince(checkedAt) <= tcpScreening.resultTTL
    }

    private func shouldRefreshTcpPing(_ record: NodeRecord, now: Date = Date()) -> Bool {
        guard record.state == .candidate else { return false }
        switch tcpScreening.mode {
        case .off:
            return false
        case .prioritize, .gate:
            guard let checkedAt = record.health.tcpPingCheckedAt else { return true }
            return now.timeIntervalSince(checkedAt) > tcpScreening.resultTTL
        }
    }

    /// Returns true when candidate probing should proceed for current TCP screening mode.
    private func shouldProbeCandidate(_ record: NodeRecord) async -> Bool {
        guard record.state == .candidate else { return true }
        guard tcpScreening.mode != .off else { return true }

        let now = Date()
        let passed: Bool
        if isTcpPingFresh(record, now: now), let cached = record.health.tcpPingPassed {
            passed = cached
        } else {
            let timeout = await MainActor.run { epochMonitor.networkQuality.tcpPingTimeout }
            let measurement = await tcpPingWithRetryMeasured(
                host: record.endpoint.host,
                port: record.endpoint.port,
                timeout: timeout,
                maxAttempts: tcpScreening.retryAttempts,
                retryDelayNs: tcpScreening.retryDelayNs
            )
            passed = measurement.passed
            await registry.updateTcpPingResult(
                record.endpoint,
                passed: passed,
                checkedAt: Date(),
                rttMs: measurement.bestRttMs
            )
        }

        if tcpScreening.mode == .gate && !passed {
            NSLog("[NodeProfiler] TCP gate blocked candidate probe for %@", record.endpoint.key)
            return false
        }
        return true
    }

    /// Check if conditions are met to start TCP ping checks
    private func checkAndStartTcpPingIfReady() async {
        guard tcpScreening.mode != .off else { return }

        // Prerequisites: enough successful discovery calls AND DNS resolve complete
        guard successfulDiscoveryCount >= tcpScreening.minDiscoverySuccesses && dnsResolveComplete else { return }

        // Only run in good/excellent network conditions
        let networkQuality = await MainActor.run { epochMonitor.networkQuality }
        guard networkQuality == .excellent || networkQuality == .good else { return }

        // Only run in aggressive mode (not conservative/paused)
        let mode = await getProbeMode()
        guard !mode.isConservative else { return }

        // Don't start if already running
        guard tcpPingTask == nil || tcpPingTask?.isCancelled == true else { return }

        NSLog("[NodeProfiler] Starting TCP ping check on candidates (mode=%@, quality=%d, aggressive mode, DNS complete)", tcpScreening.mode.rawValue, networkQuality.rawValue)
        startTcpPingBatches()
    }

    /// Start TCP ping checks on candidate nodes in sequential batches
    private func startTcpPingBatches() {
        tcpPingTask?.cancel()
        tcpPingTask = Task {
            await runTcpPingBatches()
        }
    }

    /// Run TCP ping checks on candidate nodes in batches with bounded parallelism.
    /// Stops early after finding enough reachable candidates.
    private func runTcpPingBatches() async {
        guard tcpScreening.mode != .off else { return }
        telemetry.tcpRuns += 1

        // Get candidate nodes that need initial ping or refresh by TTL.
        let now = Date()
        let candidates = await registry.records(inState: .candidate)
            .filter { shouldRefreshTcpPing($0, now: now) }

        guard !candidates.isEmpty else {
            NSLog("[NodeProfiler] No candidates to TCP ping")
            return
        }

        NSLog("[NodeProfiler] TCP ping check: %d candidates to check", candidates.count)

        var checked = 0
        var passed = 0
        var stageAChecked = 0
        var stageAPassed = 0
        var stageBChecked = 0
        var stageBPassed = 0

        // Process in sequential batches
        for batch in stride(from: 0, to: candidates.count, by: tcpScreening.batchSize) {
            guard !Task.isCancelled else { break }

            // Stop if we've found enough reachable nodes
            if passed >= tcpScreening.maxPassedNodes {
                NSLog("[NodeProfiler] TCP ping check stopped: found %d reachable nodes", passed)
                break
            }

            // Re-check conditions before each batch
            let networkQuality = await MainActor.run { epochMonitor.networkQuality }
            guard networkQuality == .excellent || networkQuality == .good else {
                NSLog("[NodeProfiler] TCP ping check stopped: network quality degraded")
                break
            }

            let mode = await getProbeMode()
            if mode.isConservative {
                NSLog("[NodeProfiler] TCP ping check stopped: switched to conservative mode")
                break
            }

            let batchEnd = min(batch + tcpScreening.batchSize, candidates.count)
            let batchCandidates = Array(candidates[batch..<batchEnd])
            let tcpTimeout = networkQuality.tcpPingTimeout
            let batchParallelism = max(1, min(tcpScreening.maxConcurrentPings(for: networkQuality), batchCandidates.count))
            let stageATimeout = tcpScreening.stageATimeout(for: networkQuality)
            let stageAResults = await runTcpStage(
                candidates: batchCandidates,
                timeout: stageATimeout,
                maxAttempts: 1,
                retryDelayNs: 0,
                parallelism: batchParallelism
            )
            stageAChecked += stageAResults.count
            stageAPassed += stageAResults.filter(\.passed).count

            for result in stageAResults {
                checked += 1
                await registry.updateTcpPingResult(
                    result.endpoint,
                    passed: result.passed,
                    checkedAt: Date(),
                    rttMs: result.bestRttMs
                )
            }

            // Stage B: only confirm most promising stage-A survivors.
            let remainingBudget = max(0, tcpScreening.maxPassedNodes - passed)
            let stageBCandidateCap = max(batchParallelism, remainingBudget + 2)
            let stageBCandidates = stageAResults
                .filter { $0.passed }
                .sorted { ($0.bestRttMs ?? Double.infinity) < ($1.bestRttMs ?? Double.infinity) }
                .prefix(stageBCandidateCap)
                .compactMap { result in
                    batchCandidates.first { $0.endpoint.key == result.endpoint.key }
                }

            if !stageBCandidates.isEmpty {
                let stageBResults = await runTcpStage(
                    candidates: Array(stageBCandidates),
                    timeout: tcpTimeout,
                    maxAttempts: tcpScreening.retryAttempts,
                    retryDelayNs: tcpScreening.retryDelayNs,
                    parallelism: batchParallelism
                )
                stageBChecked += stageBResults.count
                stageBPassed += stageBResults.filter(\.passed).count

                for result in stageBResults {
                    await registry.updateTcpPingResult(
                        result.endpoint,
                        passed: result.passed,
                        checkedAt: Date(),
                        rttMs: result.bestRttMs
                    )
                    if result.passed {
                        passed += 1
                    }
                }
            }

            // Small delay between batches to avoid overloading
            try? await Task.sleep(nanoseconds: tcpScreening.interBatchDelayNs)
        }

        telemetry.merge(
            stageAChecked: stageAChecked,
            stageAPassed: stageAPassed,
            stageBChecked: stageBChecked,
            stageBPassed: stageBPassed
        )
        let stageARate = stageAChecked > 0 ? (Double(stageAPassed) / Double(stageAChecked)) * 100 : 0
        let stageBRate = stageBChecked > 0 ? (Double(stageBPassed) / Double(stageBChecked)) * 100 : 0
        NSLog(
            "[NodeProfiler] TCP staged efficiency: A %d/%d (%.0f%%), B %d/%d (%.0f%%)",
            stageAPassed,
            stageAChecked,
            stageARate,
            stageBPassed,
            stageBChecked,
            stageBRate
        )
        NSLog("[NodeProfiler] TCP ping check complete: %d/%d candidates passed", passed, checked)

        if telemetry.tcpRuns % 5 == 0 {
            logTelemetrySnapshot(reason: "tcp")
        }
    }

    private func runTcpStage(
        candidates: [NodeRecord],
        timeout: TimeInterval,
        maxAttempts: Int,
        retryDelayNs: UInt64,
        parallelism: Int
    ) async -> [(endpoint: Endpoint, passed: Bool, bestRttMs: Double?)] {
        guard !candidates.isEmpty else { return [] }

        var results: [(endpoint: Endpoint, passed: Bool, bestRttMs: Double?)] = []
        for chunkStart in stride(from: 0, to: candidates.count, by: parallelism) {
            guard !Task.isCancelled else { break }
            let chunkEnd = min(chunkStart + parallelism, candidates.count)
            let chunk = Array(candidates[chunkStart..<chunkEnd])

            let chunkResults = await withTaskGroup(
                of: (endpoint: Endpoint, passed: Bool, bestRttMs: Double?).self,
                returning: [(endpoint: Endpoint, passed: Bool, bestRttMs: Double?)].self
            ) { group in
                for candidate in chunk {
                    group.addTask {
                        let measurement = await self.tcpPingWithRetryMeasured(
                            host: candidate.endpoint.host,
                            port: candidate.endpoint.port,
                            timeout: timeout,
                            maxAttempts: maxAttempts,
                            retryDelayNs: retryDelayNs
                        )
                        return (candidate.endpoint, measurement.passed, measurement.bestRttMs)
                    }
                }

                var aggregated: [(endpoint: Endpoint, passed: Bool, bestRttMs: Double?)] = []
                for await result in group {
                    aggregated.append(result)
                }
                return aggregated
            }

            results.append(contentsOf: chunkResults)
        }

        return results
    }

    private func tcpPingWithRetry(
        host: String,
        port: Int,
        timeout: TimeInterval,
        maxAttempts: Int,
        retryDelayNs: UInt64
    ) async -> Bool {
        let measured = await tcpPingWithRetryMeasured(
            host: host,
            port: port,
            timeout: timeout,
            maxAttempts: maxAttempts,
            retryDelayNs: retryDelayNs
        )
        return measured.passed
    }

    private func tcpPingWithRetryMeasured(
        host: String,
        port: Int,
        timeout: TimeInterval,
        maxAttempts: Int,
        retryDelayNs: UInt64
    ) async -> (passed: Bool, bestRttMs: Double?) {
        let attempts = max(1, maxAttempts)
        var bestRttMs: Double?
        for attempt in 1...attempts {
            if let rttMs = await tcpPingMeasured(host: host, port: port, timeout: timeout) {
                if let best = bestRttMs {
                    bestRttMs = min(best, rttMs)
                } else {
                    bestRttMs = rttMs
                }
                return (true, bestRttMs)
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: retryDelayNs)
            }
        }
        return (false, bestRttMs)
    }

    /// Quick TCP ping to check if host:port is reachable
    /// Returns connection RTT in milliseconds when succeeded, nil otherwise.
    private func tcpPingMeasured(host: String, port: Int, timeout: TimeInterval) async -> Double? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )

            let queue = DispatchQueue(label: "tcp-ping-\(host):\(port)")
            let gate = ContinuationGate()
            let startedAt = Date()

            // Timeout handler
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                gate.resumeOnce {
                    continuation.resume(returning: nil)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Connection succeeded
                    let rttMs = Date().timeIntervalSince(startedAt) * 1_000
                    connection.cancel()
                    gate.resumeOnce {
                        continuation.resume(returning: rttMs)
                    }

                case .failed, .cancelled:
                    // Connection failed
                    gate.resumeOnce {
                        continuation.resume(returning: nil)
                    }

                case .waiting(let error):
                    // Network path not available
                    if case .posix(let code) = error, code == .ENETUNREACH || code == .EHOSTUNREACH {
                        connection.cancel()
                        gate.resumeOnce {
                            continuation.resume(returning: nil)
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

    private func logTelemetrySnapshot(reason: String) {
        let discoveryRate: Double
        if telemetry.discoveryCalls > 0 {
            discoveryRate = (Double(telemetry.discoverySuccesses) / Double(telemetry.discoveryCalls)) * 100
        } else {
            discoveryRate = 0
        }

        let stageARate: Double
        if telemetry.stageAChecked > 0 {
            stageARate = (Double(telemetry.stageAPassed) / Double(telemetry.stageAChecked)) * 100
        } else {
            stageARate = 0
        }

        let stageBRate: Double
        if telemetry.stageBChecked > 0 {
            stageBRate = (Double(telemetry.stageBPassed) / Double(telemetry.stageBChecked)) * 100
        } else {
            stageBRate = 0
        }

        NSLog(
            "[NodeProfiler] Telemetry[%@]: probeCycles=%d discovery=%d/%d(%.0f%%) tcpA=%d/%d(%.0f%%) tcpB=%d/%d(%.0f%%)",
            reason,
            telemetry.probeCycles,
            telemetry.discoverySuccesses,
            telemetry.discoveryCalls,
            discoveryRate,
            telemetry.stageAPassed,
            telemetry.stageAChecked,
            stageARate,
            telemetry.stageBPassed,
            telemetry.stageBChecked,
            stageBRate
        )
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
                        await enrichGeoHintsIfNeeded(for: endpoint)
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

private struct IPifyResponse: Decodable {
    let ip: String
}

private struct IPApiCoResponse: Decodable {
    let latitude: Double?
    let longitude: Double?
    let countryCode: String?
    let asn: String?

    enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
        case countryCode = "country_code"
        case asn
    }
}

private struct GeoIPLookup: Sendable {
    let latitude: Double
    let longitude: Double
    let countryCode: String?
    let asn: String?
    let source: String
}

private actor LocalGeoIPDatabase {
    private struct JsonEntry: Decodable {
        let startIp: String?
        let endIp: String?
        let cidr: String?
        let latitude: Double?
        let longitude: Double?
        let lat: Double?
        let lon: Double?
        let countryCode: String?
        let countryCodeAlt: String?
        let asn: String?

        enum CodingKeys: String, CodingKey {
            case startIp
            case endIp
            case cidr
            case latitude
            case longitude
            case lat
            case lon
            case countryCode
            case countryCodeAlt = "country_code"
            case asn
        }

        var resolvedLatitude: Double? { latitude ?? lat }
        var resolvedLongitude: Double? { longitude ?? lon }
        var resolvedCountry: String? { countryCode ?? countryCodeAlt }
    }

    private struct RangeEntry {
        let start: UInt32
        let end: UInt32
        let lookup: GeoIPLookup
    }

    private var loaded = false
    private var entries: [RangeEntry] = []

    func lookup(ip: String) async -> GeoIPLookup? {
        await loadIfNeeded()
        guard let target = Self.ipv4ToUInt32(ip), !entries.isEmpty else { return nil }

        var low = 0
        var high = entries.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let entry = entries[mid]
            if target < entry.start {
                high = mid - 1
            } else if target > entry.end {
                low = mid + 1
            } else {
                return entry.lookup
            }
        }

        return nil
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true

        let candidateURLs = [
            Bundle.main.url(forResource: "geoip-lite", withExtension: "json"),
            Bundle.main.url(forResource: "geoip_local", withExtension: "json")
        ].compactMap { $0 }

        guard let url = candidateURLs.first else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([JsonEntry].self, from: data)
            var built: [RangeEntry] = []
            built.reserveCapacity(decoded.count)

            for item in decoded {
                guard let latitude = item.resolvedLatitude,
                      let longitude = item.resolvedLongitude else { continue }

                let range: (UInt32, UInt32)?
                if let startIp = item.startIp, let endIp = item.endIp,
                   let start = Self.ipv4ToUInt32(startIp),
                   let end = Self.ipv4ToUInt32(endIp), start <= end {
                    range = (start, end)
                } else if let cidr = item.cidr {
                    range = Self.cidrToRange(cidr)
                } else {
                    range = nil
                }

                guard let range else { continue }
                built.append(
                    RangeEntry(
                        start: range.0,
                        end: range.1,
                        lookup: GeoIPLookup(
                            latitude: latitude,
                            longitude: longitude,
                            countryCode: item.resolvedCountry,
                            asn: item.asn,
                            source: "local-geo-db"
                        )
                    )
                )
            }

            entries = built.sorted { $0.start < $1.start }
            NSLog("[NodeProfiler] Loaded local GeoIP DB with %d ranges", entries.count)
        } catch {
            NSLog("[NodeProfiler] Failed to load local GeoIP DB: %@", error.localizedDescription)
        }
    }

    private static func cidrToRange(_ cidr: String) -> (UInt32, UInt32)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let ip = ipv4ToUInt32(String(parts[0])),
              let bits = Int(parts[1]),
              bits >= 0, bits <= 32 else {
            return nil
        }

        if bits == 0 {
            return (0, UInt32.max)
        }

        let mask = UInt32.max << UInt32(32 - bits)
        let start = ip & mask
        let end = start | ~mask
        return (start, end)
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var acc: UInt32 = 0
        for part in parts {
            guard let n = UInt32(part), n <= 255 else { return nil }
            acc = (acc << 8) | n
        }
        return acc
    }
}
