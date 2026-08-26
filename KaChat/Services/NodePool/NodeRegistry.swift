import Foundation

// MARK: - Node Store Protocol

/// Protocol for persisting node records
protocol NodeStore: Sendable {
    func loadAll() throws -> [NodeRecord]
    func saveAll(_ records: [NodeRecord]) throws
}

struct ActivePoolRebalanceResult: Sendable {
    let promoted: Int
    let demoted: Int
    let activeCount: Int
    let eligibleCount: Int
}

struct PrefixPerformanceStats: Sendable {
    let sampleCount: Int
    let p50LatencyMs: Double
    let averageErrorRate: Double
    let averageTcpRttMs: Double?
}

// MARK: - UserDefaults Node Store

/// Simple UserDefaults-based storage for node records
final class UserDefaultsNodeStore: NodeStore, @unchecked Sendable {
    private let key = "com.kachat.nodepool.records"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadAll() throws -> [NodeRecord] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return try JSONDecoder().decode([NodeRecord].self, from: data)
    }

    func saveAll(_ records: [NodeRecord]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: key)
    }
}

// MARK: - Node Registry Actor

/// Thread-safe registry for managing node records
/// Uses actor isolation for safe concurrent access
actor NodeRegistry {
    // MARK: - Properties

    private var records: [String: NodeRecord] = [:]  // key = endpoint.key
    private let store: NodeStore?
    private var isDirty = false
    private var saveTask: Task<Void, Never>?
    /// When set (Kaspium-style fixed-node mode), `upsert` refuses every endpoint except this one.
    private var trustedNodeKey: String?

    // Configuration
    private let maxNodes = 3000
    private let autoSaveInterval: TimeInterval = 30

    // MARK: - Initialization

    init(store: NodeStore? = UserDefaultsNodeStore()) {
        self.store = store
    }

    /// Load records from store
    func load() {
        guard let store = store else { return }
        do {
            let loaded = try store.loadAll()
            records = Dictionary(uniqueKeysWithValues: loaded.map { ($0.endpoint.key, $0) })

            // Quarantine and circuit-breaker verdicts are in-session protection, not a
            // permanent blacklist: persisted across launches they can depopulate the boot race
            // (quickBoot selects by state, and a prior session's failure bursts can leave most
            // records .quarantined/.suspect for up to an hour of wall-clock time). The runtime
            // epoch-change reset clears the same fields, but on a cold launch it races
            // quickBoot's candidate selection nondeterministically - so clear them here,
            // deterministically, before anything selects. updateState() then lifts the records
            // back into .candidate/.verified so every persisted node is raceable at boot.
            var sanitized = 0
            for (key, record) in records {
                var fresh = record
                let wasBlocked = fresh.health.quarantineUntil != nil
                    || fresh.health.circuitBreakerOpenUntil != nil
                    || fresh.health.consecutiveFailures > 0
                fresh.health.quarantineUntil = nil
                fresh.health.circuitBreakerOpenUntil = nil
                fresh.health.circuitBreakerFailures = 0
                fresh.health.consecutiveFailures = 0
                fresh.updateState()
                records[key] = fresh
                if wasBlocked { sanitized += 1 }
            }

            AppLog.log("[NodeRegistry] Loaded %d node records (%d cleared of stale quarantine/failure state)",
                  records.count, sanitized)
        } catch {
            AppLog.log("[NodeRegistry] Failed to load records: %@", error.localizedDescription)
        }
    }

    /// Initialize with seed nodes for the given network
    /// Note: Seeds are now populated via DNS resolution in NodeProfiler.quickBoot()
    func initializeSeeds(for network: NetworkType) {
        AppLog.log("[NodeRegistry] Seed nodes will be populated via DNS resolution")
    }

    // MARK: - CRUD Operations

    /// Get a node record by endpoint
    func get(_ endpoint: Endpoint) -> NodeRecord? {
        records[endpoint.key]
    }

    /// Get a node record by key
    func get(key: String) -> NodeRecord? {
        records[key]
    }

    /// Get all endpoints
    func allEndpoints() -> [Endpoint] {
        records.values.map { $0.endpoint }
    }

    /// Get all records
    func allRecords() -> [NodeRecord] {
        Array(records.values)
    }

    /// Get records filtered by state
    func records(inState state: NodeState) -> [NodeRecord] {
        records.values.filter { $0.state == state }
    }

    /// Get records that can handle an operation
    func records(canHandle op: OperationClass) -> [NodeRecord] {
        records.values.filter { $0.canHandle(op) }
    }

    /// Pins the registry to exactly one node (Kaspium-style fixed-node mode) - clears
    /// every other record and refuses to add any other one until cleared.
    ///
    /// Returns the endpoint that WAS pinned before this call, if any and if it's actually
    /// changing - a `GRPCStreamConnection` has no concept of "trusted" and will otherwise keep
    /// reconnecting to a node that's no longer relevant forever, so the caller needs this to
    /// close that now-orphaned connection (see NodePoolService.setTrustedNodeAddress).
    @discardableResult
    func setTrustedNode(_ endpoint: Endpoint?) -> Endpoint? {
        let previousEndpoint = trustedNodeKey.flatMap { records[$0]?.endpoint }

        guard let endpoint else {
            // Drop the now-stale pinned record too, so it doesn't linger with origin
            // .userAdded (which forces it "active" unconditionally - see
            // NodeRecord.updateState()) even after it's no longer actually pinned.
            if let trustedNodeKey {
                records.removeValue(forKey: trustedNodeKey)
            }
            trustedNodeKey = nil
            // Bring back the pool that existed before pinning (stashed below when the pin was
            // applied) - switching back to Automatic Scan must dial known-good nodes
            // immediately, not restart discovery from an empty registry (which previously left
            // the app with NO nodes at all until the next cold launch, because nothing after
            // this point ever re-resolved DNS seeds).
            let restored = restoreStashedRecords()
            if restored > 0 {
                AppLog.log("[NodeRegistry] Restored %d pre-pin node records for Automatic Scan", restored)
            }
            scheduleSave()
            return previousEndpoint
        }

        guard previousEndpoint?.key != endpoint.key else {
            // Re-pinning the same endpoint - nothing stale to report.
            return nil
        }

        // Entering pinned mode from Automatic Scan: stash the discovered pool before wiping it,
        // so known-good nodes survive the pinned period and can be dialed the instant the user
        // switches back. Not done when moving pin -> pin (the registry only holds the old pinned
        // record then, and overwriting the stash with it would destroy the real pre-pin pool).
        if trustedNodeKey == nil {
            stashRecordsBeforePinning(excluding: endpoint.key)
        }

        trustedNodeKey = endpoint.key
        records = records.filter { $0.key == endpoint.key }
        if records[endpoint.key] == nil {
            records[endpoint.key] = NodeRecord(endpoint: endpoint, origin: .userAdded)
        }
        scheduleSave()
        return previousEndpoint
    }

    /// UserDefaults key holding the pre-pin snapshot of the registry (see setTrustedNode).
    private static let prePinStashKey = "com.kachat.nodepool.records.prepin"

    /// Snapshot every non-pinned record so the discovered pool survives the pinned period.
    private func stashRecordsBeforePinning(excluding pinnedKey: String) {
        let toStash = records.values.filter { $0.endpoint.key != pinnedKey }
        guard !toStash.isEmpty else { return }
        if let data = try? JSONEncoder().encode(Array(toStash)) {
            UserDefaults.standard.set(data, forKey: Self.prePinStashKey)
            AppLog.log("[NodeRegistry] Stashed %d node records before pinning", toStash.count)
        }
    }

    /// Restore the pre-pin snapshot into the live registry (existing keys win). The stash is
    /// consumed: records rejoin the normal lifecycle and are re-persisted with everything else.
    /// Stale entries are harmless - they fail their probes like any other node and get pruned.
    private func restoreStashedRecords() -> Int {
        guard let data = UserDefaults.standard.data(forKey: Self.prePinStashKey),
              let stashed = try? JSONDecoder().decode([NodeRecord].self, from: data) else {
            return 0
        }
        UserDefaults.standard.removeObject(forKey: Self.prePinStashKey)
        var restored = 0
        for record in stashed where records[record.endpoint.key] == nil {
            // Same sanitize as load(): quarantine/circuit verdicts from the stash era are not
            // evidence about the present, and would depopulate the instant-switch race.
            var fresh = record
            fresh.health.quarantineUntil = nil
            fresh.health.circuitBreakerOpenUntil = nil
            fresh.health.circuitBreakerFailures = 0
            fresh.health.consecutiveFailures = 0
            fresh.updateState()
            records[fresh.endpoint.key] = fresh
            restored += 1
        }
        return restored
    }

    /// Insert or update a node record
    func upsert(endpoint: Endpoint, origin: NodeOrigin = .discovered) {
        if let trustedNodeKey, endpoint.key != trustedNodeKey { return }
        if var existing = records[endpoint.key] {
            existing.lastSeenAt = Date()
            records[endpoint.key] = existing
        } else {
            let record = NodeRecord(endpoint: endpoint, origin: origin)
            records[endpoint.key] = record
        }
        scheduleSave()
    }

    /// Update profile for an endpoint
    func updateProfile(_ endpoint: Endpoint, _ mutate: (inout NodeProfile) -> Void) {
        guard var record = records[endpoint.key] else { return }
        mutate(&record.profile)
        record.profile.lastProfiledAt = Date()
        record.updateState()
        records[endpoint.key] = record
        scheduleSave()
    }

    /// Update lightweight profile metadata without affecting profiling timestamps/state transitions.
    func updateProfileMetadata(_ endpoint: Endpoint, _ mutate: (inout NodeProfile) -> Void) {
        guard var record = records[endpoint.key] else { return }
        mutate(&record.profile)
        records[endpoint.key] = record
        scheduleSave()
    }

    /// Record a request result
    func recordResult(
        endpoint: Endpoint,
        epochId: Int,
        latencyMs: Double?,
        isTimeout: Bool,
        isError: Bool
    ) {
        guard var record = records[endpoint.key] else { return }

        if isError || isTimeout {
            record.health.recordFailure(isTimeout: isTimeout, epochId: epochId)
            // A pinned trusted node is always used regardless of health (see
            // NodePoolService.setTrustedNodeAddress / registry.upsert's trusted-only guard) -
            // quarantine is meaningless for it and was previously showing up, and blocking
            // isActiveEligible, after a handful of transient probe failures.
            if endpoint.key == trustedNodeKey {
                record.health.quarantineUntil = nil
            }
        } else if let latencyMs = latencyMs {
            record.health.recordSuccess(latencyMs: latencyMs, epochId: epochId)
        }

        record.updateState()
        records[endpoint.key] = record
        scheduleSave()
    }

    /// Reset epoch-local stats for all nodes (called on network change)
    func resetEpochStats(newEpochId: Int) {
        for key in records.keys {
            records[key]?.health.resetForNewEpoch(newEpochId)
            records[key]?.updateState()
        }
        AppLog.log("[NodeRegistry] Reset epoch stats for %d nodes (epoch: %d)", records.count, newEpochId)
        scheduleSave()
    }

    /// Set node state directly
    func setState(_ endpoint: Endpoint, state: NodeState) {
        guard var record = records[endpoint.key] else { return }
        record.state = state
        records[endpoint.key] = record
        scheduleSave()
    }

    /// Update TCP ping result for a node
    func updateTcpPingResult(
        _ endpoint: Endpoint,
        passed: Bool,
        checkedAt: Date = Date(),
        rttMs: Double? = nil
    ) {
        guard var record = records[endpoint.key] else { return }
        record.health.tcpPingPassed = passed
        record.health.tcpPingCheckedAt = checkedAt
        if let rttMs, rttMs.isFinite, rttMs > 0 {
            record.health.lastTcpRttMs = rttMs
            record.health.tcpConnectRttMs.update(sample: rttMs, alpha: 0.30)
        }
        records[endpoint.key] = record
        // Don't schedule save for TCP ping results - they're ephemeral
    }

    /// Aggregate prefix-level performance for prioritizing new/discovered nodes.
    func prefixPerformanceStats(minSamples: Int = 3) -> [String: PrefixPerformanceStats] {
        var grouped: [String: [(latency: Double, errorRate: Double, tcpRtt: Double?)]] = [:]

        for record in records.values {
            guard let prefix = Self.ipv4Prefix24(record.endpoint.host) else { continue }
            let latency = record.health.latencyMs.value ?? record.health.globalLatencyMs.value
            guard let latency, latency.isFinite, latency > 0 else { continue }
            let errorRate = record.health.errorRate.value ?? record.health.globalErrorRate.value ?? 0.0
            let tcpRtt = record.health.tcpConnectRttMs.value ?? record.health.lastTcpRttMs
            grouped[prefix, default: []].append((latency, errorRate, tcpRtt))
        }

        var result: [String: PrefixPerformanceStats] = [:]
        for (prefix, values) in grouped where values.count >= minSamples {
            let latencies = values.map(\.latency).sorted()
            let p50 = latencies[latencies.count / 2]
            let avgError = values.map(\.errorRate).reduce(0, +) / Double(values.count)

            let tcpSamples = values.compactMap(\.tcpRtt)
            let avgTcp = tcpSamples.isEmpty ? nil : (tcpSamples.reduce(0, +) / Double(tcpSamples.count))

            result[prefix] = PrefixPerformanceStats(
                sampleCount: values.count,
                p50LatencyMs: p50,
                averageErrorRate: avgError,
                averageTcpRttMs: avgTcp
            )
        }
        return result
    }

    /// Remove a node
    func remove(_ endpoint: Endpoint) {
        records.removeValue(forKey: endpoint.key)
        scheduleSave()
    }

    /// Remove nodes that haven't been seen recently (LRU eviction)
    func pruneOldNodes(olderThan threshold: TimeInterval = 7 * 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-threshold)
        var removed = 0

        for (key, record) in records {
            // Don't remove seeds or user-added nodes
            guard record.origin == .discovered else { continue }
            // Don't remove active nodes
            guard record.state != .active else { continue }

            if record.lastSeenAt < cutoff {
                records.removeValue(forKey: key)
                removed += 1
            }
        }

        // Also enforce max size
        if records.count > maxNodes {
            let sortedByLastSeen = records.values
                .filter { $0.origin == .discovered && $0.state != .active }
                .sorted { $0.lastSeenAt < $1.lastSeenAt }

            let toRemove = records.count - maxNodes
            for record in sortedByLastSeen.prefix(toRemove) {
                records.removeValue(forKey: record.endpoint.key)
                removed += 1
            }
        }

        if removed > 0 {
            AppLog.log("[NodeRegistry] Pruned %d old nodes", removed)
            scheduleSave()
        }
    }

    /// Clear all dynamically discovered nodes and optionally reset remaining nodes to fresh state.
    func clearDiscoveredNodes(resetRemaining: Bool = true) {
        let totalBefore = records.count
        records = records.filter { $0.value.origin != .discovered }

        if resetRemaining {
            for key in records.keys {
                var record = records[key]
                record?.state = .candidate
                record?.profile = NodeProfile()
                record?.health = NodeHealth()
                record?.lastSeenAt = Date()
                if let record {
                    records[key] = record
                }
            }
        }

        let removed = totalBefore - records.count
        AppLog.log("[NodeRegistry] Cleared %d discovered nodes (kept: %d)", removed, records.count)
        scheduleSave()
    }

    /// Rebalance active node pool to keep the best latency nodes within a target band.
    /// - Parameters:
    ///   - minActive: Minimum desired active nodes when enough eligible nodes exist
    ///   - maxActive: Maximum active nodes
    ///   - maxReplacementsPerCycle: Maximum active/inactive swaps per rebalance cycle
    ///   - minImprovementRatio: Required relative latency improvement for replacement swaps
    @discardableResult
    func rebalanceActivePool(
        minActive: Int = 8,
        maxActive: Int = 12,
        maxReplacementsPerCycle: Int = 1,
        minImprovementRatio: Double = 0.15
    ) -> ActivePoolRebalanceResult {
        guard minActive > 0, maxActive >= minActive else {
            return ActivePoolRebalanceResult(
                promoted: 0,
                demoted: 0,
                activeCount: records.values.filter { $0.state == .active }.count,
                eligibleCount: 0
            )
        }

        var promoted = 0
        var demoted = 0

        // Refresh state machine decisions first.
        for key in Array(records.keys) {
            guard var record = records[key] else { continue }
            let previous = record.state
            record.updateState()
            if previous == .active && record.state != .active {
                demoted += 1
            }
            records[key] = record
        }

        let compareBetter: (NodeRecord, NodeRecord) -> Bool = { lhs, rhs in
            if lhs.effectiveLatencyMs != rhs.effectiveLatencyMs {
                return lhs.effectiveLatencyMs < rhs.effectiveLatencyMs
            }

            let lhsErr = lhs.health.errorRate.value ?? lhs.health.globalErrorRate.value ?? 0
            let rhsErr = rhs.health.errorRate.value ?? rhs.health.globalErrorRate.value ?? 0
            if lhsErr != rhsErr {
                return lhsErr < rhsErr
            }

            if lhs.health.consecutiveSuccesses != rhs.health.consecutiveSuccesses {
                return lhs.health.consecutiveSuccesses > rhs.health.consecutiveSuccesses
            }

            if lhs.origin != rhs.origin {
                if lhs.origin == .userAdded { return true }
                if rhs.origin == .userAdded { return false }
            }

            return lhs.endpoint.key < rhs.endpoint.key
        }

        let eligible = records.values
            .filter { $0.isActiveEligible }
            .sorted(by: compareBetter)

        let eligibleCount = eligible.count
        let desiredCount: Int
        if eligibleCount < minActive {
            desiredCount = eligibleCount
        } else {
            desiredCount = min(maxActive, eligibleCount)
        }

        // Hard cap active nodes to maxActive by demoting worst active nodes first.
        var activeEligible = records.values
            .filter { $0.state == .active && $0.isActiveEligible }
            .sorted(by: compareBetter)

        if activeEligible.count > maxActive {
            let overflow = activeEligible.count - maxActive
            for record in activeEligible.suffix(overflow) {
                guard var stored = records[record.endpoint.key] else { continue }
                stored.state = .verified
                records[record.endpoint.key] = stored
                demoted += 1
            }

            activeEligible = records.values
                .filter { $0.state == .active && $0.isActiveEligible }
                .sorted(by: compareBetter)
        }

        // Ensure at least desiredCount active nodes by promoting best eligible nodes.
        if activeEligible.count < desiredCount {
            let needed = desiredCount - activeEligible.count
            for record in eligible where needed > promoted {
                guard var stored = records[record.endpoint.key], stored.state != .active else { continue }
                stored.state = .active
                records[record.endpoint.key] = stored
                promoted += 1
            }
        }

        // Keep active count at desiredCount if we still have excess.
        activeEligible = records.values
            .filter { $0.state == .active && $0.isActiveEligible }
            .sorted(by: compareBetter)

        if activeEligible.count > desiredCount {
            let toTrim = activeEligible.count - desiredCount
            for record in activeEligible.suffix(toTrim) {
                guard var stored = records[record.endpoint.key] else { continue }
                stored.state = .verified
                records[record.endpoint.key] = stored
                demoted += 1
            }
        }

        // In-band optimization: replace worst active nodes with clearly better candidates.
        var replacements = 0
        while replacements < maxReplacementsPerCycle {
            let activeNow = records.values
                .filter { $0.state == .active && $0.isActiveEligible }
                .sorted(by: compareBetter)

            guard activeNow.count >= minActive else { break }
            guard let worstActive = activeNow.last else { break }

            let bestInactive = eligible.first {
                guard let stored = records[$0.endpoint.key] else { return false }
                return stored.state != .active
            }

            guard let candidate = bestInactive else { break }
            guard worstActive.effectiveLatencyMs.isFinite, candidate.effectiveLatencyMs.isFinite else { break }
            guard worstActive.effectiveLatencyMs > 0 else { break }

            let improvement = (worstActive.effectiveLatencyMs - candidate.effectiveLatencyMs) / worstActive.effectiveLatencyMs
            guard improvement >= minImprovementRatio else { break }

            if var demotedRecord = records[worstActive.endpoint.key] {
                demotedRecord.state = .verified
                records[worstActive.endpoint.key] = demotedRecord
                demoted += 1
            }

            if var promotedRecord = records[candidate.endpoint.key] {
                promotedRecord.state = .active
                records[candidate.endpoint.key] = promotedRecord
                promoted += 1
            }

            replacements += 1
        }

        let finalActiveCount = records.values.filter { $0.state == .active }.count

        if promoted > 0 || demoted > 0 {
            AppLog.log(
                "[NodeRegistry] Rebalanced active pool: promoted=%d demoted=%d active=%d eligible=%d",
                promoted,
                demoted,
                finalActiveCount,
                eligibleCount
            )
            scheduleSave()
        }

        return ActivePoolRebalanceResult(
            promoted: promoted,
            demoted: demoted,
            activeCount: finalActiveCount,
            eligibleCount: eligibleCount
        )
    }

    // MARK: - Statistics

    /// Count of nodes by state
    func stateCounts() -> [NodeState: Int] {
        var counts: [NodeState: Int] = [:]
        for state in NodeState.allCases {
            counts[state] = 0
        }
        for record in records.values {
            counts[record.state, default: 0] += 1
        }
        return counts
    }

    /// Current pool health
    func poolHealth() -> PoolHealth {
        // A manually-pinned node is meant to always be treated as "it's working" (see
        // NodeRecord.updateState()) - the 5/2/1/0-active-node healthy/degraded/critical/failed
        // thresholds below are tuned for a large auto-discovered pool and would otherwise show
        // "Critical" for a single pinned node that's actually working completely fine.
        if trustedNodeKey != nil {
            return .healthy
        }
        let activeCount = records.values.filter { $0.state == .active }.count
        return PoolHealth(activeCount: activeCount)
    }

    /// Distinct nodes with a recent success/failure, for the blocked-network heuristic
    /// (see NodePoolService.updatePoolStats): many distinct nodes failing with zero successes
    /// while the device is online is the signature of gRPC being blocked wholesale
    /// (firewall/DPI), as opposed to a few individually-bad nodes.
    ///
    /// Only events at or after `anchor` count - the caller anchors this to the most recent
    /// boot / pin-switch / network-epoch change, so failures persisted from a previous launch
    /// or earned on a previous network path can never contribute to a verdict about this one.
    /// Chronic dead-weight candidates (known for over an hour, never once answered - e.g.
    /// seeder entries behind Cloudflare that cannot serve raw gRPC anywhere) are excluded from
    /// the failed count: they fail on every network and are evidence about nothing. Freshly
    /// discovered nodes still count, so a first launch under censorship still trips.
    func connectivitySnapshot(
        since anchor: Date,
        window: TimeInterval = 600
    ) -> (recentFailedNodes: Int, recentSuccessfulNodes: Int, failedKeys: [String]) {
        let now = Date()
        let cutoff = max(anchor, now.addingTimeInterval(-window))
        let chronicCutoff = now.addingTimeInterval(-3600)
        var failedKeys: [String] = []
        var succeeded = 0
        for record in records.values {
            if let successAt = record.health.lastSuccessAt, successAt >= cutoff {
                succeeded += 1
            } else if let failureAt = record.health.lastFailureAt, failureAt >= cutoff {
                let neverSucceeded = record.health.lastSuccessAt == nil
                let knownForever = record.firstSeenAt < chronicCutoff
                if neverSucceeded && knownForever { continue }
                failedKeys.append(record.endpoint.key)
            }
        }
        return (failedKeys.count, succeeded, failedKeys)
    }

    /// Average latency of active nodes
    func averageActiveLatency() -> Double? {
        let activeLatencies = records.values
            .filter { $0.state == .active }
            .compactMap { $0.health.latencyMs.value ?? $0.health.globalLatencyMs.value }

        guard !activeLatencies.isEmpty else { return nil }
        return activeLatencies.reduce(0, +) / Double(activeLatencies.count)
    }

    // MARK: - Persistence

    /// Schedule a save operation (debounced)
    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(autoSaveInterval * 1_000_000_000))
            if !Task.isCancelled {
                self.persistNow()
            }
        }
    }

    /// Force immediate save
    func persistNow() {
        guard isDirty, let store = store else { return }
        do {
            try store.saveAll(Array(records.values))
            isDirty = false
            AppLog.log("[NodeRegistry] Persisted %d node records", records.count)
        } catch {
            AppLog.log("[NodeRegistry] Failed to persist records: %@", error.localizedDescription)
        }
    }

    /// Snapshot of all records (for export/debugging)
    func snapshot() -> [NodeRecord] {
        Array(records.values)
    }
}

private extension NodeRegistry {
    static func ipv4Prefix24(_ host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        guard parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }
}

// MARK: - Migration from GrpcEndpoint

extension NodeRegistry {
    /// Migrate from old GrpcEndpoint format
    func migrateFromOldFormat(_ oldEndpoints: [GrpcEndpoint]) {
        for old in oldEndpoints {
            guard let endpoint = Endpoint(url: old.url) else { continue }

            if records[endpoint.key] == nil {
                var record = NodeRecord(endpoint: endpoint)

                // Map origin
                switch old.origin {
                case .preProvisioned:
                    record.origin = .seed
                case .userAdded:
                    record.origin = .userAdded
                case .dynamic:
                    record.origin = .discovered
                }

                // Map profile
                record.profile.isSynced = true  // Assume was working
                record.profile.isUtxoIndexed = true
                if let latency = old.latencyMs {
                    record.health.globalLatencyMs.update(sample: Double(latency), alpha: 1.0)
                }
                if let daa = old.lastDaaScore {
                    record.profile.virtualDaaScore = daa
                }

                // Map state based on old pool
                switch old.pool {
                case .hot:
                    record.state = .active
                case .warm:
                    record.state = .verified
                case .cold:
                    record.state = old.errorCount > 0 ? .suspect : .profiled
                }

                record.firstSeenAt = old.dateAdded
                record.lastSeenAt = old.lastSuccessDate ?? old.dateAdded

                records[endpoint.key] = record
            }
        }

        AppLog.log("[NodeRegistry] Migrated %d endpoints from old format", oldEndpoints.count)
        scheduleSave()
    }
}
