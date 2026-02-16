import Foundation

// MARK: - Endpoint

/// Represents a Kaspa node endpoint (host:port)
struct Endpoint: Hashable, Codable, Identifiable {
    let host: String
    let port: Int

    var id: String { key }
    var key: String { "\(host):\(port)" }
    var url: String { "grpc://\(host):\(port)" }

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    init?(url: String) {
        // Parse "grpc://host:port" or "host:port"
        var cleanUrl = url
        if cleanUrl.hasPrefix("grpc://") {
            cleanUrl = String(cleanUrl.dropFirst(7))
        }

        guard let lastColon = cleanUrl.lastIndex(of: ":"),
              let port = Int(cleanUrl[cleanUrl.index(after: lastColon)...]) else {
            return nil
        }

        self.host = String(cleanUrl[..<lastColon])
        self.port = port
    }
}

// MARK: - Node State

/// Node lifecycle state machine
enum NodeState: Int, Codable, CaseIterable {
    case candidate = 0      // Discovered but never successfully answered gRPC
    case profiled = 1       // Responded to GetInfo at least once
    case verified = 2       // Network matches AND isSynced=true
    case active = 3         // Currently in top-K for at least one operation class
    case suspect = 4        // Temporary failures; reduced selection probability
    case quarantined = 5    // Repeated failures; skip until quarantineUntil

    var displayName: String {
        switch self {
        case .candidate: return "Candidate"
        case .profiled: return "Profiled"
        case .verified: return "Verified"
        case .active: return "Active"
        case .suspect: return "Suspect"
        case .quarantined: return "Quarantined"
        }
    }
}

// MARK: - Node Origin

/// How the node was discovered
enum NodeOrigin: Int, Codable {
    case seed = 0           // Bundled seed node (Tier-0, discovery only)
    case discovered = 1     // Found via peer discovery
    case userAdded = 2      // Manually added by user

    var displayName: String {
        switch self {
        case .seed: return "Seed"
        case .discovered: return "Discovered"
        case .userAdded: return "Manual"
        }
    }

    /// Seeds should not be used for user traffic unless no alternatives
    var isSeed: Bool { self == .seed }
}

// MARK: - Operation Class

/// Types of operations with different capability requirements
enum OperationClass: CaseIterable {
    case discoveryGetPeerAddresses
    case profileGetInfo
    case profileGetBlockDagInfo
    case profilePeerInfoCheck         // DPI detection check (large payload)
    case getUtxosByAddress
    case subscribeUtxosChanged
    case submitTransaction

    /// Timeout for this operation type
    var timeout: TimeInterval {
        switch self {
        case .discoveryGetPeerAddresses: return 20.0  // Seed nodes may be slow to respond
        case .profileGetInfo: return 5.0              // Quick profiling
        case .profileGetBlockDagInfo: return 5.0      // Quick profiling
        case .profilePeerInfoCheck: return 15.0       // DPI check needs time for large payload
        case .getUtxosByAddress: return 15.0          // User-facing, more patient
        case .subscribeUtxosChanged: return 10.0      // Subscription setup
        case .submitTransaction: return 20.0          // Critical, most patient
        }
    }

    /// Whether this operation requires isSynced=true
    var requiresSynced: Bool {
        switch self {
        case .discoveryGetPeerAddresses, .profileGetInfo, .profileGetBlockDagInfo, .profilePeerInfoCheck:
            return false
        case .getUtxosByAddress, .subscribeUtxosChanged, .submitTransaction:
            return true
        }
    }

    /// Whether this operation requires isUtxoIndexed=true
    var requiresUtxoIndex: Bool {
        switch self {
        case .getUtxosByAddress, .subscribeUtxosChanged:
            return true
        case .discoveryGetPeerAddresses, .profileGetInfo, .profileGetBlockDagInfo, .profilePeerInfoCheck, .submitTransaction:
            return false
        }
    }
}

// MARK: - EWMA (Exponential Weighted Moving Average)

/// Tracks a value with exponential smoothing
struct EWMA: Codable {
    private(set) var value: Double? = nil
    private(set) var sampleCount: Int = 0

    /// Update with a new sample
    /// - Parameters:
    ///   - sample: New measurement
    ///   - alpha: Smoothing factor (0-1). Higher = more weight on recent samples
    mutating func update(sample: Double, alpha: Double) {
        sampleCount += 1
        if let v = value {
            value = alpha * sample + (1 - alpha) * v
        } else {
            value = sample
        }
    }

    /// Reset the EWMA
    mutating func reset() {
        value = nil
        sampleCount = 0
    }

    /// Get value or default
    func valueOr(_ defaultValue: Double) -> Double {
        value ?? defaultValue
    }
}

// MARK: - Node Profile

/// Cached capabilities and network info for a node
struct NodeProfile: Codable {
    // From GetCurrentNetwork / GetBlockDagInfo
    var networkName: String?              // "kaspa-mainnet" or "kaspa-testnet-11"
    var virtualDaaScore: UInt64?          // Current DAA score
    var pruningPointHash: String?         // For consensus validation

    // From GetInfo
    var isSynced: Bool?                   // Node is synced with network
    var isUtxoIndexed: Bool?              // Node has UTXO index enabled
    var serverVersion: String?            // kaspad version
    var mempoolSize: UInt64?              // Number of transactions in mempool

    // DPI / payload check (GetConnectedPeerInfo)
    var peerInfoOk: Bool?                 // Passed connected peer info check
    var peerInfoCheckedAt: Date?          // Last time peer info was checked
    var peerInfoSampleBytes: Int?         // Size of last peer info response (bytes)
    var peerInfoEpochId: Int?             // Epoch when peer info was last checked

    // Network intelligence / geo hints (soft ranking signals)
    var asn: String?
    var countryCode: String?
    var prefix24: String?
    var geoLatitude: Double?
    var geoLongitude: Double?
    var geoDistanceKm: Double?
    var predictedMinRttMs: Double?
    var geoResolvedAt: Date?

    // Timestamps
    var lastProfiledAt: Date?             // When capabilities were last checked
    var profileTTL: TimeInterval = 600    // How long profile is valid (10 min default)

    /// Whether the profile is stale and needs refresh
    var isStale: Bool {
        guard let lastProfiled = lastProfiledAt else { return true }
        return Date().timeIntervalSince(lastProfiled) > profileTTL
    }

    /// Whether node has required capabilities for UTXO operations
    var isUtxoCapable: Bool {
        isSynced == true && isUtxoIndexed == true
    }

    /// Whether node is synced (for tx submission)
    var isSyncedNode: Bool {
        isSynced == true
    }
}

// MARK: - Node Health

/// Health statistics for a node, with epoch-aware fast/slow decay
struct NodeHealth: Codable {
    // Network epoch (changes reset fast stats)
    var epochId: Int = 0

    // Fast stats (epoch-local, alpha=0.25)
    var latencyMs = EWMA()
    var errorRate = EWMA()        // 1 for error, 0 for success
    var timeoutRate = EWMA()      // 1 for timeout, 0 otherwise

    // Slow stats (global, alpha=0.05)
    var globalLatencyMs = EWMA()
    var globalErrorRate = EWMA()

    // Hysteresis counters
    var consecutiveSuccesses: Int = 0
    var consecutiveFailures: Int = 0

    // Quarantine
    var quarantineUntil: Date?

    // Timestamps
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastProbeAt: Date?

    // Circuit breaker state
    var circuitBreakerFailures: Int = 0
    var circuitBreakerOpenUntil: Date?

    // TCP ping check (for candidate prioritization)
    var tcpPingPassed: Bool?
    var tcpPingCheckedAt: Date?
    var tcpConnectRttMs = EWMA()
    var lastTcpRttMs: Double?

    // Custom decoder: decodeIfPresent for all fields so old persisted data
    // missing newer keys (e.g. tcpConnectRttMs) doesn't throw keyNotFound.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        epochId               = try c.decodeIfPresent(Int.self,    forKey: .epochId) ?? 0
        latencyMs             = try c.decodeIfPresent(EWMA.self,   forKey: .latencyMs) ?? EWMA()
        errorRate             = try c.decodeIfPresent(EWMA.self,   forKey: .errorRate) ?? EWMA()
        timeoutRate           = try c.decodeIfPresent(EWMA.self,   forKey: .timeoutRate) ?? EWMA()
        globalLatencyMs       = try c.decodeIfPresent(EWMA.self,   forKey: .globalLatencyMs) ?? EWMA()
        globalErrorRate       = try c.decodeIfPresent(EWMA.self,   forKey: .globalErrorRate) ?? EWMA()
        consecutiveSuccesses  = try c.decodeIfPresent(Int.self,    forKey: .consecutiveSuccesses) ?? 0
        consecutiveFailures   = try c.decodeIfPresent(Int.self,    forKey: .consecutiveFailures) ?? 0
        quarantineUntil       = try c.decodeIfPresent(Date.self,   forKey: .quarantineUntil)
        lastSuccessAt         = try c.decodeIfPresent(Date.self,   forKey: .lastSuccessAt)
        lastFailureAt         = try c.decodeIfPresent(Date.self,   forKey: .lastFailureAt)
        lastProbeAt           = try c.decodeIfPresent(Date.self,   forKey: .lastProbeAt)
        circuitBreakerFailures = try c.decodeIfPresent(Int.self,   forKey: .circuitBreakerFailures) ?? 0
        circuitBreakerOpenUntil = try c.decodeIfPresent(Date.self, forKey: .circuitBreakerOpenUntil)
        tcpPingPassed         = try c.decodeIfPresent(Bool.self,   forKey: .tcpPingPassed)
        tcpPingCheckedAt      = try c.decodeIfPresent(Date.self,   forKey: .tcpPingCheckedAt)
        tcpConnectRttMs       = try c.decodeIfPresent(EWMA.self,   forKey: .tcpConnectRttMs) ?? EWMA()
        lastTcpRttMs          = try c.decodeIfPresent(Double.self, forKey: .lastTcpRttMs)
    }

    init() {}

    /// Whether node is currently quarantined
    var isQuarantined: Bool {
        guard let until = quarantineUntil else { return false }
        return Date() < until
    }

    /// Whether circuit breaker is open (fast-fail)
    var isCircuitOpen: Bool {
        guard let until = circuitBreakerOpenUntil else { return false }
        return Date() < until
    }

    /// Reset fast stats for new epoch
    mutating func resetForNewEpoch(_ newEpochId: Int) {
        epochId = newEpochId
        latencyMs.reset()
        errorRate.reset()
        timeoutRate.reset()
        consecutiveSuccesses = 0
        consecutiveFailures = 0
        quarantineUntil = nil
        circuitBreakerFailures = 0
        circuitBreakerOpenUntil = nil
    }

    /// Record a successful request
    mutating func recordSuccess(latencyMs: Double, epochId: Int) {
        // Check epoch change
        if self.epochId != epochId {
            resetForNewEpoch(epochId)
        }

        // Update latency
        self.latencyMs.update(sample: latencyMs, alpha: 0.25)
        self.globalLatencyMs.update(sample: latencyMs, alpha: 0.05)

        // Update error rates
        self.errorRate.update(sample: 0, alpha: 0.25)
        self.timeoutRate.update(sample: 0, alpha: 0.25)
        self.globalErrorRate.update(sample: 0, alpha: 0.05)

        // Hysteresis
        consecutiveSuccesses += 1
        consecutiveFailures = 0

        // Clear quarantine on success
        quarantineUntil = nil

        // Reset circuit breaker
        circuitBreakerFailures = 0
        circuitBreakerOpenUntil = nil

        lastSuccessAt = Date()
        lastProbeAt = Date()
    }

    /// Record a failed request
    mutating func recordFailure(isTimeout: Bool, epochId: Int) {
        // Check epoch change
        if self.epochId != epochId {
            resetForNewEpoch(epochId)
        }

        // Update error rates
        errorRate.update(sample: 1, alpha: 0.25)
        globalErrorRate.update(sample: 1, alpha: 0.05)
        if isTimeout {
            timeoutRate.update(sample: 1, alpha: 0.25)
        }

        // Hysteresis
        consecutiveSuccesses = 0
        consecutiveFailures += 1

        // Circuit breaker
        circuitBreakerFailures += 1
        if circuitBreakerFailures >= 3 {
            circuitBreakerOpenUntil = Date().addingTimeInterval(30)
        }

        // Quarantine with exponential backoff after 5+ consecutive failures
        if consecutiveFailures >= 5 {
            let baseBackoff = min(3600.0, pow(2.0, Double(consecutiveFailures - 5)) * 15.0)
            let jitter = Double.random(in: 0.0...0.3) * baseBackoff
            quarantineUntil = Date().addingTimeInterval(baseBackoff + jitter)
        }

        lastFailureAt = Date()
        lastProbeAt = Date()
    }
}

// MARK: - Node Record

/// Complete record for a node endpoint
struct NodeRecord: Codable, Identifiable {
    let endpoint: Endpoint
    var origin: NodeOrigin
    var state: NodeState
    var profile: NodeProfile
    var health: NodeHealth

    // Timestamps
    var firstSeenAt: Date
    var lastSeenAt: Date

    var id: String { endpoint.key }

    var effectiveLatencyMs: Double {
        health.latencyMs.value ?? health.globalLatencyMs.value ?? Double.infinity
    }

    var isActiveEligible: Bool {
        profile.lastProfiledAt != nil &&
        profile.isSynced == true &&
        profile.peerInfoOk == true &&
        health.consecutiveSuccesses >= 2 &&
        health.consecutiveFailures < 2 &&
        !health.isQuarantined &&
        !health.isCircuitOpen
    }

    init(endpoint: Endpoint, origin: NodeOrigin = .discovered) {
        self.endpoint = endpoint
        self.origin = origin
        self.state = .candidate
        self.profile = NodeProfile()
        self.health = NodeHealth()
        self.firstSeenAt = Date()
        self.lastSeenAt = Date()
    }

    /// Update state based on profile and health
    mutating func updateState() {
        // Quarantined takes priority
        if health.isQuarantined {
            state = .quarantined
            return
        }

        // Check if we have profile data
        guard profile.lastProfiledAt != nil else {
            state = .candidate
            return
        }

        // Check if synced
        guard profile.isSynced == true else {
            state = .profiled
            return
        }

        // If we have consecutive failures, mark as suspect
        if health.consecutiveFailures >= 2 {
            state = .suspect
            return
        }

        // Verified or better
        // Active state is managed by pool rebalancing.
        if state == .active && isActiveEligible {
            state = .active
        } else {
            state = .verified
        }
    }

    /// Whether this node can handle the given operation
    func canHandle(_ op: OperationClass) -> Bool {
        // Can't use quarantined or circuit-open nodes
        if health.isQuarantined || health.isCircuitOpen {
            return false
        }

        // Seeds can now be used for all operations if they meet capability requirements
        // No longer restricting seeds to just discovery and profiling

        // Check capability requirements
        if op.requiresSynced && profile.isSynced != true {
            return false
        }
        if op.requiresUtxoIndex && profile.isUtxoIndexed != true {
            return false
        }

        return true
    }
}

// MARK: - Network Quality

/// Current network quality tier
enum NetworkQuality: Int, Codable {
    case excellent = 0    // WiFi, unmetered
    case good = 1         // WiFi metered, or strong cellular
    case poor = 2         // Weak cellular, constrained
    case offline = 3

    /// Maximum concurrent probes for this quality
    var maxConcurrentProbes: Int {
        switch self {
        case .excellent: return 30
        case .good: return 20
        case .poor: return 10
        case .offline: return 0
        }
    }

    /// Hedge delay in milliseconds
    var hedgeDelayMs: UInt64 {
        switch self {
        case .excellent: return 3000
        case .good: return 400
        case .poor: return 800
        case .offline: return 0
        }
    }

    /// TCP ping timeout in seconds (for quick reachability check)
    var tcpPingTimeout: TimeInterval {
        switch self {
        case .excellent: return 1.0
        case .good: return 2.0
        case .poor: return 5.0
        case .offline: return 1.0
        }
    }

    /// Maximum candidates to discover per day
    var discoveryBudgetPerDay: Int {
        switch self {
        case .excellent: return 30000
        case .good: return 500
        case .poor: return 200
        case .offline: return 0
        }
    }

    /// Low latency threshold in ms for pool evaluation
    /// Nodes below this threshold are considered "fast" for conservative mode decisions
    var lowLatencyThresholdMs: Double {
        switch self {
        case .excellent: return 120.0  // Strict but globally achievable
        case .good: return 200.0       // Proven reasonable baseline
        case .poor: return 500.0       // Lenient for constrained networks
        case .offline: return 200.0
        }
    }
}

// MARK: - Pool Health

/// Overall health of the node pool
enum PoolHealth: Int {
    case healthy = 0      // >= 5 ACTIVE nodes
    case degraded = 1     // 2-4 ACTIVE nodes
    case critical = 2     // 1 ACTIVE node
    case failed = 3       // 0 ACTIVE nodes

    init(activeCount: Int) {
        switch activeCount {
        case 5...: self = .healthy
        case 2...4: self = .degraded
        case 1: self = .critical
        default: self = .failed
        }
    }

    var shouldTriggerDiscovery: Bool {
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

// MARK: - DNS Seeds

/// DNS seed configuration
struct DNSSeed {
    let hostname: String
    let port: Int
}

/// Pre-provisioned DNS seeds for mainnet (resolve to multiple A records)
let mainnetDNSSeeds: [DNSSeed] = [
    DNSSeed(hostname: "n.seeder1.kaspad.net", port: 16110),
    DNSSeed(hostname: "n.seeder2.kaspad.net", port: 16110),
    DNSSeed(hostname: "n.seeder3.kaspad.net", port: 16110),
    DNSSeed(hostname: "n.seeder4.kaspad.net", port: 16110),
    DNSSeed(hostname: "kaspadns.kaspacalc.net", port: 16110),
    DNSSeed(hostname: "n-mainnet.kaspa.ws", port: 16110),
    DNSSeed(hostname: "kaspa.aspectron.org", port: 16110),
]

/// Pre-provisioned DNS seeds for testnet
let testnetDNSSeeds: [DNSSeed] = [
    DNSSeed(hostname: "seeder1-testnet.kaspad.net", port: 16210),
    DNSSeed(hostname: "seeder2-testnet.kaspad.net", port: 16210),
]
