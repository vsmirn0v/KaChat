> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# POOLS_v2 Improvements & Implementation Plan

## Suggested Improvements to POOLS_v2

### 1. Request ID Matching (Critical Fix)
The current implementation uses FIFO matching which causes "Unexpected response type" errors when responses arrive out of order or notifications mix with responses.

**Improvement**: Use `id` field in `Protowire_KaspadMessage` for request/response correlation:
```swift
// In KaspadMessage, set a unique ID for each request
message.id = nextRequestId
pendingRequests[nextRequestId] = continuation

// In handleResponse, match by ID
if let cont = pendingRequests.removeValue(forKey: response.id) {
    cont.resume(returning: response)
}
```

### 2. Jitter in Quarantine Backoff
Prevent thundering herd when many nodes come out of quarantine simultaneously.

```swift
let baseBackoff = min(3600.0, pow(2.0, Double(consecutiveFailures - 5)) * 15.0)
let jitter = Double.random(in: 0.0...0.3) * baseBackoff
h.quarantineUntil = Date().addingTimeInterval(baseBackoff + jitter)
```

### 3. Per-Operation Timeouts
Different operations need different timeouts:
```swift
enum OperationClass {
    var timeout: TimeInterval {
        switch self {
        case .discoveryGetPeerAddresses: return 2.0  // Fast, can fail
        case .profileGetInfo: return 3.0
        case .getUtxosByAddress: return 10.0  // User-facing, more patient
        case .subscribeUtxosChanged: return 5.0
        case .submitTransaction: return 15.0  // Critical, most patient
        }
    }
}
```

### 4. Circuit Breaker Pattern
Fast-fail when node is known bad, don't wait for timeout:
```swift
struct CircuitBreaker {
    var state: State = .closed
    var failureCount: Int = 0
    var lastFailure: Date?

    enum State { case closed, open, halfOpen }

    mutating func recordFailure() {
        failureCount += 1
        lastFailure = Date()
        if failureCount >= 3 {
            state = .open
        }
    }

    mutating func recordSuccess() {
        state = .closed
        failureCount = 0
    }

    func shouldAttempt() -> Bool {
        switch state {
        case .closed: return true
        case .open:
            // Try again after 30 seconds
            guard let last = lastFailure else { return true }
            if Date().timeIntervalSince(last) > 30 { return true }
            return false
        case .halfOpen: return true
        }
    }
}
```

### 5. Connection Pool Warmup
Pre-establish connections to standby nodes in background:
```swift
func warmupStandbyConnections() async {
    let standbys = await selector.pickBest(for: .getUtxosByAddress, count: 3)
    for ep in standbys.dropFirst() {  // Skip primary
        Task.detached(priority: .background) {
            try? await self.conn(ep).connectIfNeeded()
        }
    }
}
```

### 6. Probe Priority Queue
ACTIVE nodes probed more frequently:
```swift
struct ProbeSchedule {
    var nextProbeTime: Date
    var priority: Int  // 0 = highest (ACTIVE), 3 = lowest (CANDIDATE)

    static func forState(_ state: NodeState) -> TimeInterval {
        switch state {
        case .active: return 120  // 2 min
        case .verified: return 600  // 10 min
        case .profiled: return 1800  // 30 min
        case .candidate: return 3600  // 1 hour
        case .quarantined: return 0  // Use quarantineUntil instead
        }
    }
}
```

### 7. Network Quality Tiers
Beyond WiFi/cellular, detect constrained networks:
```swift
enum NetworkQuality {
    case excellent  // WiFi, unmetered
    case good       // WiFi metered, or strong cellular
    case poor       // Weak cellular, constrained
    case offline

    var maxConcurrentProbes: Int {
        switch self {
        case .excellent: return 10
        case .good: return 4
        case .poor: return 1
        case .offline: return 0
        }
    }

    var hedgeDelayMs: UInt64 {
        switch self {
        case .excellent: return 200
        case .good: return 400
        case .poor: return 800
        case .offline: return 0
        }
    }
}
```

### 8. Request-Level Retry with Backoff
Not just node failover, but retry same node for transient errors:
```swift
func withRetry<T>(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 0.5,
    _ operation: () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 0..<maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            if !isRetryable(error) { throw error }
            let delay = baseDelay * pow(2.0, Double(attempt))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    throw lastError!
}
```

### 9. Median DAA from Multiple Nodes
More robust reference DAA calculation:
```swift
func computeReferenceDaaScore() async -> UInt64? {
    let best = await selector.pickBest(for: .profileGetInfo, count: 5)
    var scores: [UInt64] = []

    await withTaskGroup(of: UInt64?.self) { group in
        for ep in best {
            group.addTask {
                guard let rec = await self.registry.get(ep) else { return nil }
                return rec.profile.virtualDaaScore
            }
        }
        for await score in group {
            if let s = score { scores.append(s) }
        }
    }

    guard scores.count >= 3 else { return nil }
    scores.sort()
    return scores[scores.count / 2]  // Median
}
```

### 10. Graceful Degradation Levels
Define behavior when pool is degraded:
```swift
enum PoolHealth {
    case healthy      // >= 5 ACTIVE nodes
    case degraded     // 2-4 ACTIVE nodes
    case critical     // 1 ACTIVE node
    case failed       // 0 ACTIVE nodes

    var shouldDiscover: Bool {
        self != .healthy
    }

    var probeFrequencyMultiplier: Double {
        switch self {
        case .healthy: return 1.0
        case .degraded: return 2.0
        case .critical: return 4.0
        case .failed: return 8.0
        }
    }
}
```

---

## Implementation Plan

### Phase 1: Core Data Structures (2-3 files)
**Files to create/modify:**
- `KaChat/Models/NodeModels.swift` (NEW)
- `KaChat/Services/NodeRegistry.swift` (NEW)

**Tasks:**
1. Define `Endpoint`, `NodeProfile`, `NodeHealth`, `NodeRecord`, `EWMA` structs
2. Define `NodeState` enum (CANDIDATE, PROFILED, VERIFIED, ACTIVE, SUSPECT, QUARANTINED)
3. Define `OperationClass` enum with timeout/capability requirements
4. Create `NodeRegistry` actor with persistence (UserDefaults initially, can upgrade to SQLite later)
5. Add migration from existing `GrpcEndpoint` to new `NodeRecord`

### Phase 2: Network Epoch Monitor (1 file)
**Files to create:**
- `KaChat/Services/NetworkEpochMonitor.swift` (NEW)

**Tasks:**
1. Implement `NetworkEpochMonitor` with NWPathMonitor
2. Track epochId, networkQuality, isExpensive, isConstrained
3. Notify registry on epoch change to reset fast stats
4. Integrate with existing network monitoring code

### Phase 3: Node Selector & Scoring (1 file)
**Files to create:**
- `KaChat/Services/NodeSelector.swift` (NEW)

**Tasks:**
1. Implement scoring function with latency, reliability, freshness components
2. Implement `pickBest(for:count:)` with capability filtering
3. Add median DAA reference calculation
4. Add hysteresis logic (consecutive success/failure tracking)

### Phase 4: gRPC Stream Connection (major refactor)
**Files to modify:**
- `KaChat/Services/KaspaGRPCClient.swift` (MAJOR REFACTOR)

**Tasks:**
1. Add request ID to all outgoing messages
2. Match responses by ID instead of FIFO
3. Add per-request timeout support
4. Add circuit breaker per connection
5. Improve reconnection logic
6. Add latency measurement per request

### Phase 5: RPC Router with Hedging (1 new file)
**Files to create:**
- `KaChat/Services/KaspaRPCRouter.swift` (NEW)

**Tasks:**
1. Implement connection pool (reuse connections)
2. Implement `hedged()` request pattern
3. Implement operation-specific routing
4. Record results back to registry
5. Implement retry with backoff

### Phase 6: Profiler & Discovery Engines (1 new file)
**Files to create:**
- `KaChat/Services/NodeProfiler.swift` (NEW)

**Tasks:**
1. Implement capability profiling (GetInfo, GetBlockDagInfo)
2. Implement probe scheduling with priority queue
3. Implement budgeted discovery (token bucket)
4. Implement background probe loop

### Phase 7: UTXO Subscription Manager (1 new file)
**Files to create:**
- `KaChat/Services/UtxoSubscriptionManager.swift` (NEW)

**Tasks:**
1. Implement sticky primary + warm standby pattern
2. Implement automatic failover with GetUtxosByAddresses resync
3. Integrate with ChatService

### Phase 8: Integration & Migration
**Files to modify:**
- `KaChat/Services/KaspaRPCManager.swift` (REFACTOR)
- `KaChat/Services/ChatService.swift` (UPDATE)
- `KaChat/Services/WalletManager.swift` (UPDATE)
- Remove or deprecate `GrpcEndpointPoolManager.swift`

**Tasks:**
1. Replace `KaspaRPCManager` facade with new `KaspaRPCRouter`
2. Update `ChatService` to use `UtxoSubscriptionManager`
3. Update `WalletManager` to use new routing
4. Migrate existing pool data to new format
5. Update Settings UI for new pool structure

### Phase 9: Testing & Tuning
**Tasks:**
1. Test network epoch transitions (WiFi ↔ cellular)
2. Test VPN on/off behavior
3. Test node quarantine and recovery
4. Test hedged request performance
5. Tune EWMA alpha values
6. Tune timeout values per operation
7. Test discovery rate limiting

---

## File Structure After Implementation

```
KaChat/
├── Models/
│   └── NodeModels.swift           # Endpoint, NodeProfile, NodeHealth, NodeRecord, EWMA
├── Services/
│   ├── NetworkEpochMonitor.swift  # Network path monitoring, epoch tracking
│   ├── NodeRegistry.swift         # Persistent node storage (actor)
│   ├── NodeSelector.swift         # Scoring, capability filtering, node selection
│   ├── NodeProfiler.swift         # Capability checks, probe scheduling
│   ├── KaspaGRPCClient.swift      # Low-level gRPC stream (refactored)
│   ├── KaspaRPCRouter.swift       # High-level routing, hedging, connection pool
│   ├── UtxoSubscriptionManager.swift  # Sticky subscription with failover
│   └── [deprecated] GrpcEndpointPoolManager.swift
```

---

## Key Differences from Current Implementation

| Aspect | Current (POOLS v1) | New (POOLS v2) |
|--------|-------------------|----------------|
| Pool structure | Hot/Warm/Cold pools | State machine (CANDIDATE→ACTIVE→QUARANTINED) |
| Error handling | Count-based demotion | EWMA + hysteresis |
| Network changes | 5s grace period | Full epoch reset with preserved global stats |
| Connection reuse | New connection per request | Persistent connection pool |
| Request matching | FIFO queue | Request ID correlation |
| Failover | Sequential retry | Hedged parallel requests |
| Discovery | Aggressive parallel | Budgeted token bucket |
| Latency tracking | Point-in-time | EWMA with dual decay rates |
| Subscription | Simple retry | Sticky primary + warm standby |

---

## Estimated Complexity

- **Phase 1-2**: Low complexity, foundational
- **Phase 3**: Medium complexity, scoring logic needs tuning
- **Phase 4**: High complexity, core gRPC refactor
- **Phase 5**: Medium complexity, new patterns
- **Phase 6-7**: Medium complexity, background operations
- **Phase 8**: High complexity, integration touchpoints
- **Phase 9**: Variable, depends on issues found

Total: ~8-10 new/modified files, significant architectural change
