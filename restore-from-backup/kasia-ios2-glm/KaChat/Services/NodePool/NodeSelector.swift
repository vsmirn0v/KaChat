import Foundation

/// Selects best nodes for operations based on scoring and capability filtering
actor NodeSelector {
    // MARK: - Dependencies

    private let registry: NodeRegistry
    private let epochMonitor: NetworkEpochMonitor

    // MARK: - State

    /// Reference DAA score (median of good nodes)
    private var referenceDaaScore: UInt64?

    /// Last time reference was updated
    private var referenceUpdatedAt: Date?

    // MARK: - Configuration

    /// How often to refresh the reference DAA score
    private let referenceRefreshInterval: TimeInterval = 300  // 5 minutes

    /// DAA delta window (in "seconds worth" of blocks at 10 bps)
    private let daaDeltaWindow: UInt64 = 100  // ~10 seconds worth

    // MARK: - Initialization

    init(registry: NodeRegistry, epochMonitor: NetworkEpochMonitor) {
        self.registry = registry
        self.epochMonitor = epochMonitor
    }

    // MARK: - Reference DAA Score

    /// Update reference DAA score from current good nodes
    func updateReferenceDaaScore() async {
        let nodes = await registry.allRecords()

        // Get DAA scores from active/verified nodes that are synced
        let scores = nodes
            .filter { $0.state == .active || $0.state == .verified }
            .filter { $0.profile.isSynced == true }
            .compactMap { $0.profile.virtualDaaScore }
            .sorted()

        guard scores.count >= 3 else {
            // Not enough nodes for reliable median
            return
        }

        // Use median
        referenceDaaScore = scores[scores.count / 2]
        referenceUpdatedAt = Date()

        NSLog("[NodeSelector] Updated reference DAA: %llu (from %d nodes)",
              referenceDaaScore ?? 0, scores.count)
    }

    /// Set reference DAA from external source (e.g., api.kaspa.org)
    func setReferenceDaaScore(_ score: UInt64) {
        referenceDaaScore = score
        referenceUpdatedAt = Date()
        NSLog("[NodeSelector] Set external reference DAA: %llu", score)
    }

    /// Whether reference needs refresh
    var needsReferenceRefresh: Bool {
        guard let updatedAt = referenceUpdatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > referenceRefreshInterval
    }

    // MARK: - Node Selection

    /// Pick the best nodes for an operation
    /// - Parameters:
    ///   - op: The operation type
    ///   - count: Number of nodes to return
    ///   - excluding: Endpoints to exclude (e.g., recently failed)
    /// - Returns: Array of best endpoints, sorted by score (best first)
    func pickBest(
        for op: OperationClass,
        count: Int = 1,
        excluding: Set<String> = []
    ) async -> [Endpoint] {
        let nodes = await registry.allRecords()

        // Filter by capability and exclusions
        let eligible = nodes.filter { record in
            // Not excluded
            guard !excluding.contains(record.endpoint.key) else { return false }

            // Can handle this operation
            return record.canHandle(op)
        }

        // Score and sort
        let scored: [(Endpoint, Double)] = eligible.map { record in
            (record.endpoint, score(record, for: op))
        }
        .sorted { $0.1 > $1.1 }  // Higher score = better

        // Return top N
        return Array(scored.prefix(count).map(\.0))
    }

    /// Pick best nodes, preferring non-seed nodes but falling back to seeds if needed
    func pickBestWithSeedFallback(
        for op: OperationClass,
        count: Int = 1,
        excluding: Set<String> = []
    ) async -> [Endpoint] {
        let nodes = await registry.allRecords()

        // Filter and score all nodes equally (no special treatment for seeds)
        let scored: [(Endpoint, Double)] = nodes
            .filter { !excluding.contains($0.endpoint.key) && $0.canHandle(op) }
            .map { record in
                (record.endpoint, score(record, for: op))
            }
            .sorted { $0.1 > $1.1 }

        return Array(scored.prefix(count).map(\.0))
    }

    // MARK: - Scoring

    /// Calculate score for a node
    /// Higher score = better node
    private func score(_ record: NodeRecord, for op: OperationClass) -> Double {
        var score = 0.0

        // 1. Latency score (log scale, lower is better)
        let latency = record.health.latencyMs.value
            ?? record.health.globalLatencyMs.value
            ?? 9999.0
        let latencyScore = -log(max(1, latency))  // Negative because lower latency is better
        score += latencyScore

        // 2. Reliability score (error/timeout rates, lower is better)
        let errorRate = record.health.errorRate.value
            ?? record.health.globalErrorRate.value
            ?? 0.25
        let timeoutRate = record.health.timeoutRate.value ?? 0.10
        let reliabilityScore = -(2.0 * errorRate + 3.0 * timeoutRate)
        score += 3.0 * reliabilityScore  // Weight reliability heavily

        // 3. State bonus
        switch record.state {
        case .active:
            score += 2.0
        case .verified:
            score += 1.0
        case .profiled:
            score += 0.0
        case .candidate:
            score -= 1.0
        case .suspect:
            score -= 3.0
        case .quarantined:
            score -= 10.0  // Should be filtered out anyway
        }

        // 4. Freshness score (DAA delta, only as soft signal)
        if let ref = referenceDaaScore, let daa = record.profile.virtualDaaScore {
            let diff = Int64(ref) - Int64(daa)
            if diff > 0 {
                // Node is behind
                let penalty = min(5.0, Double(diff) / Double(daaDeltaWindow))
                score -= 0.5 * penalty
            } else if diff < -Int64(daaDeltaWindow * 10) {
                // Node claims to be way ahead - suspicious
                score -= 2.0
            }
        }

        // 5. Consecutive success bonus (hysteresis)
        if record.health.consecutiveSuccesses >= 5 {
            score += 1.0
        } else if record.health.consecutiveSuccesses >= 2 {
            score += 0.5
        }

        // 6. Seeds are now treated as regular nodes (no penalty)
        // They're resolved from DNS and can handle all operations

        // 7. User-added bonus (user trusts these)
        if record.origin == .userAdded {
            score += 1.0
        }

        return score
    }

    // MARK: - Utility

    /// Get nodes eligible for a specific operation (for UI display)
    func eligibleNodes(for op: OperationClass) async -> [NodeRecord] {
        let nodes = await registry.allRecords()
        return nodes.filter { $0.canHandle(op) }
            .sorted { score($0, for: op) > score($1, for: op) }
    }

    /// Get nodes by state (for debugging/UI)
    func nodesByState() async -> [NodeState: [NodeRecord]] {
        let nodes = await registry.allRecords()
        var result: [NodeState: [NodeRecord]] = [:]

        for state in NodeState.allCases {
            result[state] = nodes.filter { $0.state == state }
        }

        return result
    }
}

// MARK: - Convenience Extensions

extension NodeSelector {
    /// Pick a single best node for an operation
    func pickOne(for op: OperationClass, excluding: Set<String> = []) async -> Endpoint? {
        let results = await pickBest(for: op, count: 1, excluding: excluding)
        return results.first
    }

    /// Pick primary and standby nodes for subscription
    func pickPrimaryAndStandby(for op: OperationClass) async -> (primary: Endpoint, standby: Endpoint?)? {
        let results = await pickBest(for: op, count: 2)
        guard let primary = results.first else { return nil }
        let standby = results.count > 1 ? results[1] : nil
        return (primary, standby)
    }

    /// Pick nodes for broadcast (e.g., submit tx to multiple nodes)
    func pickForBroadcast(count: Int = 3) async -> [Endpoint] {
        await pickBest(for: .submitTransaction, count: count)
    }
}
