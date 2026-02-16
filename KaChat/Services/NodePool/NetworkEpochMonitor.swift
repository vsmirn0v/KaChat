import Foundation
import Network
import Combine

/// Monitors network path changes and manages "epochs" to prevent
/// VPN/WiFi/cellular switches from poisoning node health stats
@MainActor
final class NetworkEpochMonitor: ObservableObject {
    // MARK: - Singleton

    static let shared = NetworkEpochMonitor()

    // MARK: - Published Properties

    @Published private(set) var epochId: Int = 0
    @Published private(set) var networkQuality: NetworkQuality = .good
    @Published private(set) var isOnline: Bool = true
    @Published private(set) var isExpensive: Bool = false
    @Published private(set) var isConstrained: Bool = false

    // MARK: - Private Properties

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.kachat.network.epoch.monitor")
    private var currentPath: NWPath?
    private var lastPathChangeTime: Date?

    // Callbacks for epoch changes
    private var epochChangeCallbacks: [(Int) -> Void] = []

    // Grace period after network change (ignore transient errors)
    private let gracePeriod: TimeInterval = 5.0

    // MARK: - Initialization

    private init() {}

    // MARK: - Lifecycle

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
        NSLog("[NetworkEpoch] Started monitoring")
    }

    func stop() {
        monitor.cancel()
        NSLog("[NetworkEpoch] Stopped monitoring")
    }

    // MARK: - Path Handling

    private func handlePathUpdate(_ path: NWPath) {
        let oldQuality = networkQuality

        // Update basic status
        isOnline = path.status == .satisfied
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        // Detect significant path change
        let isSignificantChange = detectSignificantChange(from: currentPath, to: path)

        if isSignificantChange {
            // Bump epoch
            epochId += 1
            lastPathChangeTime = Date()

            NSLog("[NetworkEpoch] Path changed significantly - new epoch: %d", epochId)
            NSLog("[NetworkEpoch] Status: %@, Expensive: %@, Constrained: %@",
                  isOnline ? "online" : "offline",
                  isExpensive ? "yes" : "no",
                  isConstrained ? "yes" : "no")

            // Notify callbacks
            for callback in epochChangeCallbacks {
                callback(epochId)
            }
        }

        // Update network quality
        networkQuality = determineQuality(path: path)

        if networkQuality != oldQuality {
            NSLog("[NetworkEpoch] Network quality changed: %@ -> %@",
                  String(describing: oldQuality), String(describing: networkQuality))
        }

        currentPath = path
    }

    /// Detect if path change is significant enough to warrant epoch bump
    private func detectSignificantChange(from oldPath: NWPath?, to newPath: NWPath) -> Bool {
        guard let old = oldPath else {
            // First path update
            return true
        }

        // Status change (online <-> offline)
        if old.status != newPath.status {
            return true
        }

        // Interface type change (WiFi <-> Cellular)
        let oldInterfaces = Set(old.availableInterfaces.map { $0.type })
        let newInterfaces = Set(newPath.availableInterfaces.map { $0.type })
        if oldInterfaces != newInterfaces {
            return true
        }

        // Expensive status change (usually VPN toggle)
        if old.isExpensive != newPath.isExpensive {
            return true
        }

        // Constrained status change
        if old.isConstrained != newPath.isConstrained {
            return true
        }

        return false
    }

    /// Determine network quality tier from path
    private func determineQuality(path: NWPath) -> NetworkQuality {
        guard path.status == .satisfied else {
            return .offline
        }

        let interfaces = path.availableInterfaces

        // Check for WiFi
        let hasWifi = interfaces.contains { $0.type == .wifi }
        let hasCellular = interfaces.contains { $0.type == .cellular }

        if hasWifi {
            if path.isExpensive || path.isConstrained {
                return .good  // Metered WiFi
            }
            return .excellent
        }

        if hasCellular {
            if path.isConstrained {
                return .poor  // Low data mode
            }
            return .good
        }

        // Wired or other
        return .excellent
    }

    // MARK: - Public API

    /// Whether we're within the grace period after a network change
    var isWithinGracePeriod: Bool {
        guard let lastChange = lastPathChangeTime else { return false }
        return Date().timeIntervalSince(lastChange) < gracePeriod
    }

    /// Register a callback for epoch changes
    func onEpochChange(_ callback: @escaping (Int) -> Void) {
        epochChangeCallbacks.append(callback)
    }

    /// Get interface description for logging
    var interfaceDescription: String {
        guard let path = currentPath else { return "unknown" }

        let types = path.availableInterfaces.map { interface -> String in
            switch interface.type {
            case .wifi: return "WiFi"
            case .cellular: return "Cellular"
            case .wiredEthernet: return "Ethernet"
            case .loopback: return "Loopback"
            case .other: return "Other"
            @unknown default: return "Unknown"
            }
        }

        return types.joined(separator: ", ")
    }

    /// Current path status for debugging
    var statusDescription: String {
        guard let path = currentPath else { return "No path" }

        var parts: [String] = []
        parts.append(path.status == .satisfied ? "Connected" : "Disconnected")
        parts.append("via \(interfaceDescription)")
        if path.isExpensive { parts.append("(expensive)") }
        if path.isConstrained { parts.append("(constrained)") }
        parts.append("epoch:\(epochId)")

        return parts.joined(separator: " ")
    }
}

// MARK: - Combine Publisher

extension NetworkEpochMonitor {
    /// Publisher for epoch changes
    var epochPublisher: AnyPublisher<Int, Never> {
        $epochId.eraseToAnyPublisher()
    }

    /// Publisher for network quality changes
    var qualityPublisher: AnyPublisher<NetworkQuality, Never> {
        $networkQuality.eraseToAnyPublisher()
    }

    /// Publisher for online status changes
    var onlinePublisher: AnyPublisher<Bool, Never> {
        $isOnline.eraseToAnyPublisher()
    }
}
