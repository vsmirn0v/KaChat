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
            NSLog("[NodeRegistry] Loaded %d node records", records.count)
        } catch {
            NSLog("[NodeRegistry] Failed to load records: %@", error.localizedDescription)
        }
    }

    /// Initialize with seed nodes for the given network
    /// Note: Seeds are now populated via DNS resolution in NodeProfiler.quickBoot()
    func initializeSeeds(for network: NetworkType) {
        NSLog("[NodeRegistry] Seed nodes will be populated via DNS resolution")
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

    /// Insert or update a node record
    func upsert(endpoint: Endpoint, origin: NodeOrigin = .discovered) {
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
        NSLog("[NodeRegistry] Reset epoch stats for %d nodes (epoch: %d)", records.count, newEpochId)
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
    func updateTcpPingResult(_ endpoint: Endpoint, passed: Bool) {
        guard var record = records[endpoint.key] else { return }
        record.health.tcpPingPassed = passed
        records[endpoint.key] = record
        // Don't schedule save for TCP ping results - they're ephemeral
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
            NSLog("[NodeRegistry] Pruned %d old nodes", removed)
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
        NSLog("[NodeRegistry] Cleared %d discovered nodes (kept: %d)", removed, records.count)
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
            NSLog(
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
        let activeCount = records.values.filter { $0.state == .active }.count
        return PoolHealth(activeCount: activeCount)
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
            NSLog("[NodeRegistry] Persisted %d node records", records.count)
        } catch {
            NSLog("[NodeRegistry] Failed to persist records: %@", error.localizedDescription)
        }
    }

    /// Snapshot of all records (for export/debugging)
    func snapshot() -> [NodeRecord] {
        Array(records.values)
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

        NSLog("[NodeRegistry] Migrated %d endpoints from old format", oldEndpoints.count)
        scheduleSave()
    }
}
