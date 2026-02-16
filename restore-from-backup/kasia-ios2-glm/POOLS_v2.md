Below is a “mobile-first, hostile-network-tolerant” node pooling architecture for an iOS Swift messenger that talks to **Kaspa gRPC endpoints (plaintext)**, discovers nodes starting from **6–8 seeds**, profiles nodes (**`isSynced`, `isUtxoIndexed`, network/mainnet vs testnet**), and does **latency + error-rate load balancing** without accidentally throwing away good nodes when the user’s network/VPN changes.

I’ll assume:

* gRPC default port **16110** (mainnet), P2P is **16111**. ([docs.kas.fyi][1])
* Wallet-style calls need a node that is **synced** and has **UTXO index** enabled (so `GetInfo` includes `isSynced` / `isUtxoIndexed`). ([Kaspa WIKI][2])
* Mainnet is currently **10 blocks/sec** (Crescendo activated May 5, 2025). ([Kaspa][3])
* DAA score definition / reorg reality: DAA score is a DAG metric (not “height”), and small reorgs can happen near the tips. ([Kaspa][4])
* api.kaspa.org exposes network/blockdag info endpoints (useful as a public reference, but don’t treat it as a trust anchor). ([api.kaspa.org][5])

---

## 1) High-level architecture (layers)

### A. Data layer (persistent “node registry”)

Store a `NodeRecord` per endpoint (host:port), persisted across launches (SQLite/CoreData):

* **Identity**: host, port, firstSeen, lastSeen
* **Profile** (TTL cached): networkName / currentNetwork, `isSynced`, `isUtxoIndexed`, version, lastVirtualDaaScore, lastPruningPointHash/virtual parents (if you read them)
* **Health** (EWMA + hysteresis):

  * `latencyEWMA_ms`, `timeoutRateEWMA`, `rpcErrorRateEWMA`
  * `consecutiveFailures`, `consecutiveSuccesses`
  * `quarantineUntil`, `cooldownBackoff`
* **Network-epoch binding**:

  * health stats keyed by `networkEpochId` (resets when cellular↔wifi / VPN / path changes)

### B. Engines

1. **DiscoveryEngine**

* Input: 6–8 seed nodes.
* Output: growing set of candidate endpoints.
* Strategy: seeds are *discovery-only* (low priority for user traffic).

2. **ProfilerEngine**

* Cheap capability checks:

  * `GetInfo` ⇒ `isSynced`, `isUtxoIndexed` ([Kaspa WIKI][2])
  * `GetCurrentNetwork` or `GetBlockDagInfo` ⇒ networkName + virtualDaaScore-ish sanity (depending on your proto)
* Cache profile for e.g. 10–30 minutes unless failure.

3. **HealthEngine**

* Periodic lightweight probes (deadline-based):

  * probe **only a small rotating subset** to save mobile data/battery
  * use adaptive timeouts and “hedged probes” (below)

4. **ScoreEngine + NodeSelector**

* Multi-armed bandit-ish routing (exploit good nodes, explore a few new ones).
* Produces ranked sets per *required capability*.

5. **RPCRouter**

* For each operation type (subscribe UTXO, get UTXOs, submit tx, get peers), picks node(s) with correct profile/score and runs fallback logic.

---

## 2) Node lifecycle (state machine)

**NEW → CANDIDATE → PROFILED → VERIFIED → ACTIVE → (SUSPECT/QUARANTINED) → ACTIVE…**

* **CANDIDATE**: discovered but never successfully answered gRPC.
* **PROFILED**: responded to `GetInfo` at least once; you know `isSynced`, `isUtxoIndexed`.
* **VERIFIED**: network matches desired (mainnet/testnet) AND `isSynced=true`. (UTXO calls additionally require `isUtxoIndexed=true`.) ([Kaspa WIKI][2])
* **ACTIVE**: currently in top-K for at least one operation class.
* **SUSPECT**: temporary failures; don’t discard, just reduce selection probability.
* **QUARANTINED**: repeated failures; skip until `quarantineUntil` but re-test eventually (so “good nodes” come back after a network/VPN wobble).

Key rule: **never delete nodes because of transient network issues**; only increase cooldown and reduce score.

---

## 3) Discovery that doesn’t burn mobile data

### Problem: `getPeerAddresses` gives you *P2P peers*, not guaranteed public gRPC endpoints

P2P port is typically **16111**; gRPC is **16110**. ([docs.kas.fyi][1])
So treat peer discovery as: “new IPs to try on gRPC port”, not “guaranteed endpoints”.

### Discovery strategy

* **Cold start**:

  * probe seeds for `getPeerAddresses` with *short deadlines* (e.g. 700–1200ms)
  * accept partial results; don’t block app startup on discovery
* **Candidate generation**:

  * from each P2P address, create `host:16110` candidate
  * dedupe aggressively (IP + /24 bucketing helps avoid scanning a single hoster)
* **Budgeted crawl**:

  * Token bucket: e.g. **max 20 new candidates/day** on cellular, **200/day** on Wi-Fi
  * Keep a long tail list, but only **profile** a few per hour

Seeds “must be essential but not affect app functionality”:

* Mark seed nodes as **Tier-0 (Discovery)**.
* Never use Tier-0 nodes for wallet-critical calls unless you have no verified alternatives.

---

## 4) Capability checks: minimal and cheap

### Required capabilities by feature

* **Subscribe UTXO changes / GetUtxosByAddresses**
  Require: `isUtxoIndexed=true` AND `isSynced=true` ([Kaspa WIKI][2])
* **SubmitTransaction**
  Require: `isSynced=true` (UTXO index not needed to accept a tx, but you want synced nodes for propagation)
* **GetPeerAddresses**
  Any node that responds (no utxoindex requirement)

Also remember: enabling UTXO index is a node startup option (`--utxoindex`). ([kaspa.aspectron.org][6])

---

## 5) Health + scoring that survives VPN switches & bad cellular moments

### A. Use “network epochs”

Maintain a `networkEpochId` that increments when:

* NWPathMonitor reports path change (wifi↔cellular, expensive constrained, interface change)
* VPN toggles (often appears as interface/path change)

For each node keep:

* **global reputation** (slow-decay)
* **epoch-local health** (fast-decay)

Selection uses mostly epoch-local health; if epoch-local is scarce, fall back to global.

### B. Use hysteresis & “grace”

Don’t mark a node “bad” on a single timeout.

* Promote to ACTIVE after **2–3 successes**
* Demote to SUSPECT after **2 consecutive failures** *or* timeoutRateEWMA crosses threshold
* Quarantine only after **N failures** (e.g. 5–8) with exponential backoff

### C. Adaptive timeouts

For probes:

* start with **tight** deadlines (e.g. 600–1200ms on Wi-Fi, 1200–2200ms on cellular)
* if node is historically good, allow a bit more slack (to avoid false negatives on a temporary cellular dip)

### D. Hedged requests (mobile-friendly)

For user-facing operations (not background probes):

* send to **best node**
* if no response by `p95_latency(best)+δ` (e.g. 300ms), also send to **second-best**
* take first success, cancel the other call

This is *huge* for perceived responsiveness on flaky mobile links.

---

## 6) Connection pooling with grpc-swift (plaintext)

### Recommended channel model

* Keep **2–3 “hot” channels** to top ACTIVE nodes (reused for most unary calls).
* Keep **1 dedicated streaming channel** for the UTXO subscription (sticky node).
* Optionally keep **1 “exploration” channel** that rotates through candidates (low rate).

Why: gRPC handshakes and HTTP/2 setup cost are non-trivial on mobile; channel reuse saves battery and time.

### Sticky subscription with graceful failover

UTXO subscription is special (long-lived stream):

* pick the best **UTXO-capable** node as **primary**
* maintain a **warm standby** node (profiled + recently healthy)
* on stream failure:

  1. immediately switch to standby and resubscribe
  2. call `GetUtxosByAddresses` to resync wallet state (because you may miss deltas during reconnection)

---

## 7) Should you filter by `virtualDaaScore`?

### Yes — but only as a **secondary** signal

Primary gating should be `isSynced`. ([Kaspa WIKI][2])
`virtualDaaScore` is still useful for:

* catching nodes that claim “synced” but are lagging or on the wrong fork
* choosing between several “synced” nodes (prefer the freshest)

DAA score is not a simple “height”; it’s a merged-blocks measure, and reorgs near the tips are a real thing. ([Kaspa][4])

### How to get a reference score

Best approach (no central trust):

* Query **3–5 of your best nodes**, take the **median** as your reference.
* Accept nodes within a delta window from that median.

You can also use **api.kaspa.org** as a *convenience reference* (it exposes network/blockdag info endpoints). ([api.kaspa.org][5])
But don’t hard-depend on it: if it’s down or slow, your app should keep working.

### What delta window to use?

Because mainnet is **10 blocks/sec** now ([Kaspa][3]) and DAA score grows with block production (by definition it tracks merged blocks), don’t use an absolute “difference of 3”. Use a **time-based** window:

* e.g. “node must be within ~3–10 seconds worth of DAA progression of the reference”
* widen the window on cellular / during network turbulence (again: avoid false negatives)

---

## 8) Routing policies per operation (what to actually do)

### GetUtxosByAddresses / SubscribeUtxosChanged

* only nodes with: `isUtxoIndexed && isSynced && correct network`
* pick **1 primary + 1 standby**
* prefer low latency, low timeout EWMA

### SubmitTransaction

* pick top 2–3 **synced** nodes
* **broadcast** (parallel submit) to reduce “my chosen node is slow” failures
* mark success per node independently (helps score engine)

### Discovery: GetPeerAddresses

* run on:

  * seeds (Tier-0) and
  * 1–2 good nodes (Tier-1)
* low frequency, strict timeouts, budgeted

---

## 9) “Are we on the proper Kaspa network?” (security sanity)

Because endpoints are plaintext, you can’t authenticate the server via TLS. So you validate *consensus view* instead:

* Ensure network name/mainnet vs testnet matches what you want (and is consistent across multiple nodes).
* Compare “tip fingerprints” across several nodes (virtual parents / pruning point / DAA score range). If one node disagrees wildly, drop it.

This also helps against eclipse-ish situations where one bad node gives you a weird view.

---

## 10) Practical numbers that work on mobile

* Maintain:

  * **ACTIVE**: 5–10 nodes
  * **VERIFIED** cache: 50–150 nodes
  * **CANDIDATES** stored: up to 1000+ (but *not actively probed*)
* Probe concurrency (kept low to avoid overwhelming system network stack):

  * Wi-Fi (excellent): 5 concurrent probes
  * Wi-Fi (metered) / Cellular: 2–3 concurrent probes
* TCP ping pre-filter:

  * Candidate nodes get a quick TCP ping (2s timeout) before gRPC probe
  * Unreachable candidates are marked failed without creating gRPC connections
  * Reduces resource usage and speeds up pool building
* Probe scheduling:

  * ACTIVE nodes: every 2–5 minutes (light probe)
  * VERIFIED but inactive: every 30–120 minutes
  * FAILED nodes: exponential backoff up to days

---

# EXAMPLE IMPLEMENTATION

Awesome — let’s turn this into a concrete, Swift-first design you can drop into your app and iterate on.

Below is an **actor-based node pool** that:

* discovers endpoints from **6–8 seeds** via `getPeerAddresses`
* profiles nodes via **`GetInfo` + `GetBlockDagInfo` + `GetCurrentNetwork`**
* tracks **latency + error/timeout EWMAs** with **network “epochs”** (so a VPN switch doesn’t poison your pool)
* selects best nodes per operation (**UTXO subscribe, getUTXOs, submitTx, discovery**) with **hedged requests**
* keeps seeds **essential but non-blocking**
* uses **virtualDaaScore** as a *secondary* freshness signal (median-of-nodes reference; optional api.kaspa.org fallback)

Everything below assumes your protos match what you uploaded (`protowire.RPC/MessageStream`, `KaspadRequest/KaspadResponse`, `GetInfo`, `GetBlockDagInfo`, `NotifyUtxosChanged`, `GetUtxosByAddresses`, `SubmitTransaction`, `GetPeerAddresses`).

---

## 0) Core ideas in one glance

* **One `MessageStream` per endpoint**, multiplex requests by `id`.
* Maintain **two reputations** per node:

  * **epoch-local** (fast decay) — “how it behaves on *this* network path”
  * **global** (slow decay) — “long-term quality”
* **Never permanently drop** nodes due to mobile flakiness:

  * quarantine with backoff
  * periodically re-test
* **Sticky subscription**:

  * 1 primary UTXO-capable node + 1 warm standby
  * re-subscribe + `GetUtxosByAddresses` on failover

---

## 1) Models (endpoints, capabilities, health)

```swift
import Foundation

struct Endpoint: Hashable, Codable {
    let host: String
    let port: Int
    var key: String { "\(host):\(port)" }
}

enum OperationClass {
    case discoveryGetPeerAddresses
    case profileGetInfo
    case profileGetBlockDagInfo
    case getUtxosByAddress
    case subscribeUtxosChanged
    case submitTransaction
}

struct NodeProfile: Codable {
    var currentNetwork: String?          // from GetCurrentNetworkResponse.currentNetwork
    var networkName: String?             // from GetBlockDagInfoResponse.networkName
    var virtualDaaScore: UInt64?         // from GetBlockDagInfoResponse.virtualDaaScore
    var pruningPointHash: String?        // from GetBlockDagInfoResponse.pruningPointHash

    var isSynced: Bool?                  // from GetInfoResponse.isSynced
    var isUtxoIndexed: Bool?             // from GetInfoResponse.isUtxoIndexed
    var serverVersion: String?           // from GetInfoResponse.serverVersion

    var updatedAt: Date = .init()
}

struct EWMA: Codable {
    private(set) var value: Double? = nil

    mutating func update(sample: Double, alpha: Double) {
        if let v = value { value = alpha * sample + (1 - alpha) * v }
        else { value = sample }
    }
}

struct NodeHealth: Codable {
    // “Epoch” is your current network path identity (wifi/cell/vpn). Changes reset fast stats.
    var epochId: Int = 0

    // Fast stats (epoch-local)
    var latencyMs = EWMA()
    var errorRate = EWMA()      // 1 for error, 0 for success
    var timeoutRate = EWMA()    // 1 for timeout, 0 otherwise

    // Slow stats (global-ish)
    var globalErrorRate = EWMA()
    var globalLatencyMs = EWMA()

    var consecutiveFailures: Int = 0
    var quarantineUntil: Date? = nil
    var lastSuccessAt: Date? = nil
    var lastFailureAt: Date? = nil
}

struct NodeRecord: Codable {
    let endpoint: Endpoint
    var profile = NodeProfile()
    var health = NodeHealth()

    var firstSeenAt: Date = .init()
    var lastSeenAt: Date = .init()
}
```

---

## 2) Network epoch monitor (prevents “VPN switch poisoned my pool”)

```swift
import Network

final class NetworkEpochMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.epoch.monitor")
    private(set) var epochId: Int = 0
    private(set) var currentPath: NWPath?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Bump epoch on meaningful path changes
            if self.currentPath?.status != path.status ||
               self.currentPath?.availableInterfaces != path.availableInterfaces ||
               self.currentPath?.isExpensive != path.isExpensive ||
               self.currentPath?.isConstrained != path.isConstrained {
                self.epochId += 1
            }
            self.currentPath = path
        }
        monitor.start(queue: queue)
    }
}
```

---

## 3) Node registry (actor) + persistence hook

You can back this with SQLite/CoreData; here it’s an in-memory + “optional store” pattern.

```swift
protocol NodeStore {
    func loadAll() throws -> [NodeRecord]
    func saveAll(_ records: [NodeRecord]) throws
}

actor NodeRegistry {
    private var records: [Endpoint: NodeRecord] = [:]
    private let store: NodeStore?

    init(store: NodeStore? = nil) {
        self.store = store
        if let store, let loaded = try? store.loadAll() {
            self.records = Dictionary(uniqueKeysWithValues: loaded.map { ($0.endpoint, $0) })
        }
    }

    func upsert(endpoint: Endpoint) {
        if records[endpoint] == nil {
            records[endpoint] = NodeRecord(endpoint: endpoint)
        } else {
            records[endpoint]?.lastSeenAt = .init()
        }
    }

    func get(_ endpoint: Endpoint) -> NodeRecord? { records[endpoint] }

    func allEndpoints() -> [Endpoint] { Array(records.keys) }

    func updateProfile(_ endpoint: Endpoint, _ mutate: (inout NodeProfile) -> Void) {
        guard records[endpoint] != nil else { return }
        mutate(&records[endpoint]!.profile)
        records[endpoint]!.profile.updatedAt = .init()
    }

    func recordResult(
        endpoint: Endpoint,
        epochId: Int,
        latencyMs: Double?,
        isTimeout: Bool,
        isError: Bool
    ) {
        guard records[endpoint] != nil else { return }
        var h = records[endpoint]!.health

        // Reset fast stats if epoch changed
        if h.epochId != epochId {
            h.epochId = epochId
            h.latencyMs = EWMA()
            h.errorRate = EWMA()
            h.timeoutRate = EWMA()
            h.consecutiveFailures = 0
            h.quarantineUntil = nil
        }

        if let latencyMs {
            h.latencyMs.update(sample: latencyMs, alpha: 0.25)
            h.globalLatencyMs.update(sample: latencyMs, alpha: 0.05)
        }

        h.errorRate.update(sample: isError ? 1 : 0, alpha: 0.25)
        h.timeoutRate.update(sample: isTimeout ? 1 : 0, alpha: 0.25)
        h.globalErrorRate.update(sample: isError ? 1 : 0, alpha: 0.05)

        if isError || isTimeout {
            h.consecutiveFailures += 1
            h.lastFailureAt = .init()
            // Quarantine with exponential backoff after a few consecutive failures
            if h.consecutiveFailures >= 5 {
                let backoffSec = min(3600.0, pow(2.0, Double(h.consecutiveFailures - 5)) * 15.0)
                h.quarantineUntil = Date().addingTimeInterval(backoffSec)
            }
        } else {
            h.consecutiveFailures = 0
            h.lastSuccessAt = .init()
            h.quarantineUntil = nil
        }

        records[endpoint]!.health = h
    }

    func snapshot() -> [NodeRecord] { Array(records.values) }

    func persist() {
        guard let store else { return }
        try? store.saveAll(Array(records.values))
    }
}
```

---

## 4) Scoring + selection (capabilities-aware, mobile-safe)

Key: **don’t hard-drop** nodes; just reduce selection probability.

```swift
actor NodeSelector {
    private let registry: NodeRegistry
    private let epoch: NetworkEpochMonitor

    // Optional “freshness reference” (median DAA across good nodes)
    private var referenceDaaScore: UInt64?

    init(registry: NodeRegistry, epoch: NetworkEpochMonitor) {
        self.registry = registry
        self.epoch = epoch
    }

    func updateReferenceDaaScore(_ v: UInt64?) { referenceDaaScore = v }

    func pickBest(for op: OperationClass, count: Int = 1) async -> [Endpoint] {
        let now = Date()
        let nodes = await registry.snapshot()

        let filtered = nodes.filter { rec in
            // quarantine
            if let until = rec.health.quarantineUntil, until > now { return false }

            // capability gating
            switch op {
            case .getUtxosByAddress, .subscribeUtxosChanged:
                return rec.profile.isSynced == true && rec.profile.isUtxoIndexed == true
            case .submitTransaction:
                return rec.profile.isSynced == true
            case .discoveryGetPeerAddresses:
                return true
            case .profileGetInfo, .profileGetBlockDagInfo:
                return true
            }
        }

        let scored: [(Endpoint, Double)] = filtered.map { rec in
            (rec.endpoint, score(rec, for: op))
        }
        .sorted(by: { $0.1 > $1.1 })

        return Array(scored.prefix(count).map(\.0))
    }

    private func score(_ rec: NodeRecord, for op: OperationClass) -> Double {
        // Latency: lower is better
        let lat = rec.health.latencyMs.value ?? rec.health.globalLatencyMs.value ?? 9999
        let latencyScore = -log(max(1, lat)) // log-scale

        // Errors/timeouts: lower is better
        let err = rec.health.errorRate.value ?? rec.health.globalErrorRate.value ?? 0.25
        let timeout = rec.health.timeoutRate.value ?? 0.10
        let reliabilityScore = -(2.0 * err + 3.0 * timeout)

        // Freshness: only as a soft bonus/penalty, never a hard gate
        var freshnessScore = 0.0
        if let ref = referenceDaaScore, let daa = rec.profile.virtualDaaScore {
            let diff = Double(Int64(ref) - Int64(daa))
            // Penalize being behind; cap so it doesn’t nuke a node on brief reorgs
            freshnessScore = -min(5.0, max(0.0, diff / 200.0))
        }

        // Seeds should not dominate; mark them elsewhere and apply a slight penalty if needed.
        return 3.0 * reliabilityScore + 1.0 * latencyScore + 0.5 * freshnessScore
    }
}
```

---

## 5) The Kaspa gRPC “MessageStream” client (multiplex requests + notifications)

This is the key piece: one stream, many requests, match by `id`, plus notification fanout.

> grpc-swift API differs a bit by version, so treat this as the *structure*. You’ll map the “send”/“receive loop” to your generated stubs.

```swift
import GRPC
import NIO

// Replace these with your generated SwiftProtobuf types:
typealias KaspadRequest = Protowire_KaspadRequest
typealias KaspadResponse = Protowire_KaspadResponse

actor KaspadStreamConnection {
    private let endpoint: Endpoint
    private let group: EventLoopGroup

    private var channel: GRPCChannel?
    private var client: Protowire_RPCClient? // generated by protoc-gen-grpc-swift
    private var call: BidirectionalStreamingCall<KaspadRequest, KaspadResponse>?

    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<KaspadResponse, Error>] = [:]

    // Notifications
    private var utxoSubs: [UUID: (Protowire_UtxosChangedNotificationMessage) -> Void] = [:]

    init(endpoint: Endpoint, group: EventLoopGroup) {
        self.endpoint = endpoint
        self.group = group
    }

    func connectIfNeeded() throws {
        if call != nil { return }

        let channel = try GRPCChannelPool.with(
            target: .host(endpoint.host, port: endpoint.port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        )

        self.channel = channel
        self.client = Protowire_RPCClient(channel: channel)

        // Create the long-lived stream
        self.call = client!.messageStream { [weak self] response in
            // This callback is on NIO threads; hop into actor
            Task { await self?.handleIncoming(response) }
        }
    }

    private func handleIncoming(_ response: KaspadResponse) {
        // 1) If response matches a pending request id, resume it
        if let cont = pending.removeValue(forKey: response.id) {
            cont.resume(returning: response)
            return
        }

        // 2) Otherwise, treat as notification (UTXO changes, etc.)
        if case .utxosChangedNotification(let n)? = response.payload {
            for handler in utxoSubs.values { handler(n) }
        }
    }

    func request(_ build: (UInt64) -> KaspadRequest) async throws -> KaspadResponse {
        try connectIfNeeded()
        guard let call else { throw NSError(domain: "kaspa", code: -1) }

        let id = nextID
        nextID &+= 1
        let req = build(id)

        let start = DispatchTime.now()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<KaspadResponse, Error>) in
            pending[id] = cont
            call.sendMessage(req, promise: nil) // NIO promise optional; errors come via call status
        }
        // latency measurement is done outside; return response
    }

    func subscribeUtxosChanged(
        addresses: [String],
        onEvent: @escaping (Protowire_UtxosChangedNotificationMessage) -> Void
    ) async throws -> UUID {
        let token = UUID()
        utxoSubs[token] = onEvent

        _ = try await request { id in
            var req = KaspadRequest()
            req.id = id
            var n = Protowire_NotifyUtxosChangedRequestMessage()
            n.addresses = addresses
            n.command = .notifyStart
            req.notifyUtxosChangedRequest = n
            return req
        }
        return token
    }

    func unsubscribeUtxosChanged(token: UUID, addresses: [String]) async throws {
        utxoSubs.removeValue(forKey: token)

        _ = try await request { id in
            var req = KaspadRequest()
            req.id = id
            var n = Protowire_NotifyUtxosChangedRequestMessage()
            n.addresses = addresses
            n.command = .notifyStop
            req.notifyUtxosChangedRequest = n
            return req
        }
    }
}
```

**Two important practical notes:**

1. you’ll want a **reconnect** path when the stream fails (recreate channel + call, fail pending continuations, then retry via router).
2. for “unary-like” requests over a bidi stream, always set a **deadline** in call options if your grpc-swift version supports it.

---

## 6) Router: hedged requests + per-operation node selection

```swift
actor KaspaRPCRouter {
    private let registry: NodeRegistry
    private let selector: NodeSelector
    private let epoch: NetworkEpochMonitor
    private let group: EventLoopGroup

    private var connections: [Endpoint: KaspadStreamConnection] = [:]

    init(registry: NodeRegistry, selector: NodeSelector, epoch: NetworkEpochMonitor, group: EventLoopGroup) {
        self.registry = registry
        self.selector = selector
        self.epoch = epoch
        self.group = group
    }

    private func conn(_ ep: Endpoint) -> KaspadStreamConnection {
        if let c = connections[ep] { return c }
        let c = KaspadStreamConnection(endpoint: ep, group: group)
        connections[ep] = c
        return c
    }

    /// “Hedged” request: try best node; if slow, race a 2nd node.
    func hedged<T>(
        op: OperationClass,
        hedgeDelayMs: UInt64,
        _ body: @escaping (KaspadStreamConnection) async throws -> (T, Double) // result + latencyMs
    ) async throws -> T {
        let eps = await selector.pickBest(for: op, count: 2)
        guard let primary = eps.first else { throw NSError(domain: "kaspa", code: -2) }

        let epochId = epoch.epochId

        async let primaryTask: T = {
            do {
                let (res, lat) = try await body(conn(primary))
                await registry.recordResult(endpoint: primary, epochId: epochId, latencyMs: lat, isTimeout: false, isError: false)
                return res
            } catch {
                await registry.recordResult(endpoint: primary, epochId: epochId, latencyMs: nil, isTimeout: isTimeout(error), isError: true)
                throw error
            }
        }()

        // Hedge with 2nd node if primary is slow
        if eps.count >= 2 {
            let backup = eps[1]
            async let backupTask: T = {
                try await Task.sleep(nanoseconds: hedgeDelayMs * 1_000_000)
                do {
                    let (res, lat) = try await body(conn(backup))
                    await registry.recordResult(endpoint: backup, epochId: epochId, latencyMs: lat, isTimeout: false, isError: false)
                    return res
                } catch {
                    await registry.recordResult(endpoint: backup, epochId: epochId, latencyMs: nil, isTimeout: isTimeout(error), isError: true)
                    throw error
                }
            }()

            return try await race(primaryTask, backupTask)
        }

        return try await primaryTask
    }

    private func race<T>(_ a: T, _ b: T) async throws -> T {
        // Minimal “race”: prefer whichever completes first
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await a }
            g.addTask { try await b }
            let first = try await g.next()!
            g.cancelAll()
            return first
        }
    }

    private func isTimeout(_ error: Error) -> Bool {
        // Map grpc-swift status / NIO timeout errors as you see fit
        return false
    }
}
```

You’ll use `hedged(op: .getUtxosByAddress, ...)` for user-facing wallet actions; for background discovery/probes, don’t hedge (save battery/data).

---

## 7) Concrete RPC wrappers (GetInfo, GetBlockDagInfo, etc.)

Here’s what a “unary” call looks like over the stream (you measure latency on the client side):

```swift
extension KaspadStreamConnection {
    func getInfo() async throws -> (Protowire_GetInfoResponseMessage, Double) {
        let t0 = DispatchTime.now()
        let resp = try await request { id in
            var r = KaspadRequest()
            r.id = id
            r.getInfoRequest = Protowire_GetInfoRequestMessage() // empty
            return r
        }
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
        return (resp.getInfoResponse, dt)
    }

    func getBlockDagInfo() async throws -> (Protowire_GetBlockDagInfoResponseMessage, Double) {
        let t0 = DispatchTime.now()
        let resp = try await request { id in
            var r = KaspadRequest()
            r.id = id
            r.getBlockDagInfoRequest = Protowire_GetBlockDagInfoRequestMessage() // empty
            return r
        }
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
        return (resp.getBlockDagInfoResponse, dt)
    }

    func getPeerAddresses() async throws -> (Protowire_GetPeerAddressesResponseMessage, Double) {
        let t0 = DispatchTime.now()
        let resp = try await request { id in
            var r = KaspadRequest()
            r.id = id
            r.getPeerAddressesRequest = Protowire_GetPeerAddressesRequestMessage() // empty
            return r
        }
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000.0
        return (resp.getPeerAddressesResponse, dt)
    }
}
```

---

## 8) Profiling loop (capabilities + network + freshness)

```swift
actor ProfilerEngine {
    private let registry: NodeRegistry
    private let router: KaspaRPCRouter
    private let epoch: NetworkEpochMonitor

    init(registry: NodeRegistry, router: KaspaRPCRouter, epoch: NetworkEpochMonitor) {
        self.registry = registry
        self.router = router
        self.epoch = epoch
    }

    func profile(endpoint: Endpoint) async {
        // Use tight deadlines and no hedging; this is background work.
        // If it fails, it’ll be retried later with backoff.
    }

    func profileTopCandidates() async {
        // pick a small rotating set: e.g. 2–3 on cellular, 5–10 on wifi
    }
}
```

(Implementation detail: you’ll call `getInfo` and `getBlockDagInfo`, update `NodeProfile` in `registry`.)

---

## 9) Discovery (seeds are essential but never blocking)

* Seeds are only used to **bootstrap discovery**.
* If seeds are slow, discovery just yields fewer candidates — app still works with existing verified nodes.

Pseudo-flow:

1. pick 1–2 seeds
2. `getPeerAddresses`
3. parse addresses → infer gRPC endpoints (`host:16110`)
4. `registry.upsert` for each candidate
5. later, profiler will validate them

---

## 10) UTXO subscription: sticky primary + standby

```swift
actor UtxoSubscriptionManager {
    private let selector: NodeSelector
    private let router: KaspaRPCRouter

    private var activeEndpoint: Endpoint?
    private var activeToken: UUID?

    func start(address: String, onChange: @escaping (Protowire_UtxosChangedNotificationMessage) -> Void) async throws {
        let best = await selector.pickBest(for: .subscribeUtxosChanged, count: 2)
        guard let primary = best.first else { throw NSError(domain: "kaspa", code: -10) }

        // connect + subscribe on primary
        let conn = await router /* internal */ // you can expose a method to get connection
        // (or route subscribe via router)

        // If stream drops, resubscribe on standby and then call GetUtxosByAddresses to resync.
    }
}
```

This is where you’ll implement the “do not lose events” pattern:

* on subscription start/failover:

  * subscribe
  * immediately `GetUtxosByAddresses` to rebuild local UTXO set

---

## 11) virtualDaaScore filtering: how to do it safely

**Yes, use it — but only as a soft signal.** In the code above it’s a *bounded penalty*, not a hard drop.

**Reference score**:

* compute `median(virtualDaaScore)` across 3–5 of your best synced nodes
* if you have *no* good nodes yet, you *can* optionally query api.kaspa.org as a bootstrap reference, but don't hard-depend on it.

---

## 12) Implementation-Specific Features (Kasia iOS)

### Dynamic Probe Modes

The profiler automatically switches between aggressive and conservative modes based on pool health:

**Aggressive Mode** (pool is building):
- Probe loop interval: 10 seconds
- Batch multiplier: maxProbes × 5
- Probe intervals: active=60s, verified=15s, profiled=2min, candidate=4min

**Conservative Mode** (pool is healthy):
- Probe loop interval: 60 seconds
- Batch multiplier: maxProbes × 1
- Probe intervals: active=2min, verified=10min, profiled=30min, candidate=60min

**Mode triggers:**
- Conservative: 5+ active nodes AND at least one with latency <200ms
- Aggressive: otherwise

### Discovery Pause

Discovery and candidate probing pause completely when pool is healthy enough:

**Pause criteria (either):**
- 5+ nodes with latency ≤200ms
- 15+ total active nodes

**What pauses:**
- Peer discovery (`getPeerAddresses` calls)
- Candidate node probing

**What continues:**
- Active node health checks (every 2 min)
- Verified/profiled/suspect node probing (conservative intervals)

### UTXO Subscription Keepalive

The UTXO subscription channel sends a keepalive ping every 30 seconds:

```swift
// In UtxoSubscriptionManager.checkPrimaryHealth()
var msg = Protowire_KaspadMessage()
msg.getInfoRequest = Protowire_GetInfoRequestMessage()
_ = try await conn.sendRequest(msg, type: .getInfo, timeout: 10.0)
```

This ensures:
- Connection stays alive through NAT/firewall timeouts
- Early detection of dead connections
- Latency monitoring for the subscription channel

### Subscription Restart Sync

When UTXO subscription is restarted (after failure, reconnect, or failover), the app automatically syncs messages and payments to catch anything missed during downtime:

```swift
// In ChatService.setupUtxoSubscription()
if isRestart {
    NSLog("[ChatService] Subscription restarted - syncing to catch missed messages/payments")
    Task {
        await self.fetchNewMessages()
    }
}
```

This covers:
- Subscription retry after failure
- Reconnection to a different node
- Failover scenarios
- Manual reconnect

### DNS Seed Resolution

DNS seeds are resolved using `getaddrinfo()` to get all A records (not just the first one):

```swift
// In NodeProfiler.resolveDNSSeed()
var hints = addrinfo()
hints.ai_family = AF_INET  // IPv4 only
hints.ai_socktype = SOCK_STREAM
let status = getaddrinfo(seed.hostname, String(seed.port), &hints, &result)
// Iterate through all results...
```

This ensures we discover all available seed IPs, not just one.

### Peer Discovery Optimizations

**Single Success Target:**
- `discoverWithRetry()` uses `targetSuccesses = 1` (previously 3)
- Reduces network calls - only one successful `getPeerAddresses` needed per discovery cycle
- Reduces discovery overhead on mobile networks

**Primary Endpoint Exclusion:**
- Discovery calls exclude the primary subscription endpoint
- Prevents disrupting the active UTXO subscription channel
- Subscription channel is dedicated and sticky

```swift
// In NodeProfiler.discoverWithRetry()
let primarySubscriptionEndpoint = await subscriptionManager?.getPrimaryEndpoint()
let discoveryNodes = activeNodes.filter { $0 != primarySubscriptionEndpoint }
```

### Memory Management

The pool system includes automatic maintenance to prevent memory growth:

**Maintenance Loop** (runs every 2 minutes):

1. **Node Registry Pruning** (`NodeRegistry.pruneOldNodes()`):
   - Removes nodes not seen in 7 days
   - Preserves seed and user-added nodes
   - Preserves active nodes regardless of age
   - Enforces `maxNodes = 1000` limit via LRU eviction

2. **Connection Pool Cleanup** (`GRPCConnectionPool.pruneIdleConnections()`):
   - Removes disconnected connections idle for >2 minutes
   - Tracks `lastActivityAt` timestamp per connection
   - Preserves connected and recently-used connections
   - Lightweight cleanup - only closes channels (no EventLoopGroup shutdown per connection)

3. **Connection Pool Limits**:
   - Maximum 50 connections in the pool (`maxTotalConnections`)
   - When limit reached, `evictOldestDisconnected()` removes oldest disconnected connection
   - Prevents unbounded connection accumulation

**Channel Close Protocol:**
- Channels must be properly awaited on close to prevent memory leaks
- `GRPCStreamConnection.disconnect()` is async and awaits channel close
- Error paths properly close channels via `_ = try? await ch.close().get()`
- Background Task used for channel close when sync disconnect needed

**ClientConnection vs GRPCChannelPool:**
- Uses `ClientConnection.insecure()` instead of `GRPCChannelPool.with()`
- `GRPCChannelPool` has internal retain cycles (`connectivityDelegate -> CYCLE BACK`)
- These internal `ConnectionManager`/`ConnectionPool` objects never get released
- `ClientConnection` is simpler, creates single connection without pooling overhead

**Shared EventLoopGroup:**
- All gRPC connections share a single `EventLoopGroup` (2 threads)
- Owned by `GRPCConnectionPool`, not individual connections
- Eliminates per-connection thread creation/destruction overhead
- Prevents resource exhaustion when pruning many connections
- Only shut down when the entire pool is deallocated

**Why this matters:**
- Without pruning, node records grow unbounded (3000+ discovered nodes)
- Without connection cleanup, GRPCStreamConnection objects accumulate
- Without proper channel close, ConnectionManager instances leak
- All contribute to memory growth from ~50MB to 100MB+ over hours

```swift
// In NodeProfiler.runMaintenanceCycle()
await registry.pruneOldNodes(olderThan: 7 * 24 * 3600)  // 7 days
await connectionPool.pruneIdleConnections(maxAge: 2 * 60)  // 2 minutes

// Monitoring
NSLog("[NodeProfiler] Maintenance cycle complete, connections: %d", await connectionPool.connectionCount())
```
