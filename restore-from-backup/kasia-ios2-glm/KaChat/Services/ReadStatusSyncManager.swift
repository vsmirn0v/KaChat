import Foundation
import CloudKit

/// Manages read status synchronization between devices via CloudKit.
/// Uses per-device read markers (CDReadMarker) to eliminate write conflicts.
/// Implements stable-point debounce: 15s idle timeout OR conversation exit.
@MainActor
final class ReadStatusSyncManager: ObservableObject {
    static let shared = ReadStatusSyncManager()

    private let containerId = "iCloud.com.kachat.app"

    /// Pending read marker for a conversation
    struct PendingReadMarker {
        let conversationId: String
        let lastReadTxId: String?
        let lastReadBlockTime: Int64
        let timestamp: Date
    }

    /// Pending read markers waiting to be flushed, keyed by conversationId (contact address)
    private var pendingMarkers: [String: PendingReadMarker] = [:]

    /// Per-conversation idle timers (15 seconds)
    private var idleTimers: [String: Timer] = [:]

    /// Idle timeout in seconds before flushing a conversation's read marker
    private let idleInterval: TimeInterval = 15.0

    /// Whether CloudKit sync is enabled
    private var isCloudKitEnabled = AppSettings.load().storeMessagesInICloud
    private var settingsObserver: NSObjectProtocol?

    /// Current wallet address (for zone partitioning)
    private var currentWalletAddress: String? {
        WalletManager.shared.currentWallet?.publicAddress
    }

    /// Current device identifier from KeychainService
    private var deviceId: String? {
        KeychainService.shared.currentDeviceId()
    }

    private init() {
        // Observe read status changes from remote (CloudKit)
        NotificationCenter.default.addObserver(
            forName: MessageStore.readStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRemoteReadStatusChange(notification)
            }
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let settings = notification.object as? AppSettings else { return }
            Task { @MainActor [weak self] in
                self?.isCloudKitEnabled = settings.storeMessagesInICloud
            }
        }
    }

    /// Run one-time migration from CDConversation read status to CDReadMarker.
    /// Call this after the store is loaded and wallet is set.
    func runMigrationIfNeeded() {
        guard let deviceId = KeychainService.shared.currentDeviceId() else { return }
        guard MessageStore.shared.isStoreLoaded else { return }
        guard MessageStore.shared.currentWalletAddress != nil else { return }

        Task.detached(priority: .background) {
            MessageStore.shared.migrateToReadMarkersIfNeeded(deviceId: deviceId)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    // MARK: - Public API

    /// Record a read event for a conversation.
    /// This accumulates the read position and resets the idle timer for that conversation.
    /// The actual write happens on idle timeout (15s) or conversation exit.
    /// - Parameters:
    ///   - contactAddress: Contact address identifying the conversation
    ///   - lastReadTxId: txId of the last read message (optional)
    ///   - lastReadBlockTime: blockTime of the last read message
    func recordRead(contactAddress: String, lastReadTxId: String?, lastReadBlockTime: UInt64) {
        let blockTime = Int64(lastReadBlockTime)

        // Check if this is an advancement from current pending marker
        if let existing = pendingMarkers[contactAddress], blockTime <= existing.lastReadBlockTime {
            // Not an advancement, ignore
            return
        }

        // Update pending marker
        pendingMarkers[contactAddress] = PendingReadMarker(
            conversationId: contactAddress,
            lastReadTxId: lastReadTxId,
            lastReadBlockTime: blockTime,
            timestamp: Date()
        )

        // Reset idle timer for this conversation
        idleTimers[contactAddress]?.invalidate()
        idleTimers[contactAddress] = Timer.scheduledTimer(withTimeInterval: idleInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.flushMarker(for: contactAddress)
            }
        }

        NSLog("[ReadStatusSync] Recorded read for %@ (blockTime: %lld), idle flush in %.0fs",
              String(contactAddress.suffix(8)), blockTime, idleInterval)
    }

    /// Called when user leaves a conversation. Immediately flushes pending read marker.
    /// - Parameter contactAddress: Contact address of the conversation being exited
    func userLeftConversation(_ contactAddress: String) {
        // Cancel idle timer
        idleTimers[contactAddress]?.invalidate()
        idleTimers.removeValue(forKey: contactAddress)

        // Flush immediately
        flushMarker(for: contactAddress)
    }

    /// Force flush all pending read markers immediately.
    /// Call this when app is going to background.
    func flushAllPending() {
        guard !pendingMarkers.isEmpty else { return }

        NSLog("[ReadStatusSync] Flushing all %d pending read markers", pendingMarkers.count)

        // Cancel all idle timers
        for timer in idleTimers.values {
            timer.invalidate()
        }
        idleTimers.removeAll()

        // Flush all pending markers
        let markers = pendingMarkers
        pendingMarkers.removeAll()

        for (_, marker) in markers {
            persistReadMarker(marker)
        }
    }

    /// Sync read statuses from CloudKit.
    /// Call this on app launch and when receiving CloudKit change notifications.
    func syncFromCloudKit() async {
        guard isCloudKitEnabled else { return }
        guard currentWalletAddress != nil else {
            NSLog("[ReadStatusSync] No wallet set, skipping CloudKit sync")
            return
        }

        NSLog("[ReadStatusSync] Starting CloudKit read status sync...")

        // Refresh view context to pick up CloudKit changes
        // NSPersistentCloudKitContainer handles the actual sync - we just need to refresh
        MessageStore.shared.refreshFromCloudKit()

        // Fetch all read statuses from local store (which includes CloudKit-synced data)
        let readStatuses = MessageStore.shared.fetchAllReadStatuses()

        NSLog("[ReadStatusSync] Loaded %d read statuses from CloudKit-synced store", readStatuses.count)
    }

    // MARK: - Legacy API (for backwards compatibility during migration)

    /// Legacy method - redirects to new recordRead API.
    /// Kept for backwards compatibility with existing ChatService calls.
    func markAsRead(contactAddress: String, lastReadTxId: String?, lastReadBlockTime: UInt64) {
        // Update local CDConversation immediately (for unread count display)
        let blockTime = Int64(lastReadBlockTime)
        MessageStore.shared.updateReadStatus(
            contactAddress: contactAddress,
            lastReadTxId: lastReadTxId,
            lastReadBlockTime: blockTime,
            lastReadAt: Date()
        )

        // Also record for per-device marker sync
        recordRead(contactAddress: contactAddress, lastReadTxId: lastReadTxId, lastReadBlockTime: lastReadBlockTime)
    }

    /// Legacy method name - kept for backwards compatibility
    func flushPendingUpdates() {
        flushAllPending()
    }

    // MARK: - Private Helpers

    /// Flush a single conversation's read marker
    private func flushMarker(for conversationId: String) {
        guard let marker = pendingMarkers.removeValue(forKey: conversationId) else { return }
        idleTimers.removeValue(forKey: conversationId)
        persistReadMarker(marker)
    }

    /// Persist a read marker to Core Data (which syncs to CloudKit via NSPersistentCloudKitContainer)
    private func persistReadMarker(_ marker: PendingReadMarker) {
        guard let deviceId = deviceId else {
            NSLog("[ReadStatusSync] Cannot persist read marker: no device ID")
            return
        }

        // Upsert to CDReadMarker (monotonic write handled inside)
        MessageStore.shared.upsertReadMarker(
            conversationId: marker.conversationId,
            deviceId: deviceId,
            lastReadTxId: marker.lastReadTxId,
            lastReadBlockTime: marker.lastReadBlockTime
        )

        NSLog("[ReadStatusSync] Persisted read marker for %@ device=%@ blockTime=%lld",
              String(marker.conversationId.suffix(8)), String(deviceId.prefix(8)), marker.lastReadBlockTime)
    }

    /// Handle remote read status change notification
    private func handleRemoteReadStatusChange(_ notification: Notification) {
        guard let conversations = notification.userInfo?["conversations"] as? Set<String> else { return }

        NSLog("[ReadStatusSync] Remote read status changed for %d conversations", conversations.count)

        // Recompute effective read status for each affected conversation
        // The ChatService should listen for this and update unread counts
        for conversationId in conversations {
            if let effective = MessageStore.shared.recomputeEffectiveReadStatus(conversationId: conversationId) {
                NSLog("[ReadStatusSync] Effective read status for %@: blockTime=%lld (%d devices)",
                      String(conversationId.suffix(8)), effective.lastReadBlockTime, effective.deviceCount)
            }
        }
    }
}
