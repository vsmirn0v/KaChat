import Foundation

/// Debounced persistence of read positions. Uses per-device read markers (CDReadMarker) -
/// a schema born for cross-device merging and kept because a model change would migrate every
/// store - written on a stable point: 15s idle timeout OR conversation exit.
///
/// Device-local, like the store it writes to. Read state used to ride CloudKit to the user's
/// other devices; that mirror is gone, and the Nextcloud archive is the only thing that leaves
/// the device.
@MainActor
final class ReadStatusSyncManager: ObservableObject {
    static let shared = ReadStatusSyncManager()

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

    /// Current wallet address
    private var currentWalletAddress: String? {
        WalletManager.shared.currentWallet?.publicAddress
    }

    /// Current device identifier from KeychainService
    private var deviceId: String? {
        KeychainService.shared.currentDeviceId()
    }

    private init() {}

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

        AppLog.log("[ReadStatusSync] Recorded read for %@ (blockTime: %lld), idle flush in %.0fs",
              String(contactAddress.suffix(8)), blockTime, idleInterval)
    }

    /// The freshest read position recorded for a conversation but not yet flushed to Core Data,
    /// if any. `recordRead` only writes here immediately - the actual `CDReadMarker` write is
    /// debounced up to `idleInterval` (15s) - so callers deciding "is this chat fully read"
    /// (e.g. the initial scroll-anchor check) need to consult this in-memory value too, or they
    /// can see a stale pre-read cursor for that whole debounce window.
    func pendingReadCursor(for contactAddress: String) -> (txId: String?, blockTime: Int64)? {
        guard let marker = pendingMarkers[contactAddress] else { return nil }
        return (marker.lastReadTxId, marker.lastReadBlockTime)
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

        AppLog.log("[ReadStatusSync] Flushing all %d pending read markers", pendingMarkers.count)

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

        // Also record the per-device marker
        recordRead(contactAddress: contactAddress, lastReadTxId: lastReadTxId, lastReadBlockTime: lastReadBlockTime)
    }

    /// Awaitable version of `markAsRead` - see `MessageStore.updateReadStatusAndWait`'s doc
    /// comment. `recordRead`'s own per-device marker write stays fire-and-forget (debounced by
    /// design; the local read cursor above is this device's single source of truth for its
    /// badge, and that is the write a force-quit must not lose).
    func markAsReadAndWait(contactAddress: String, lastReadTxId: String?, lastReadBlockTime: UInt64) async {
        let blockTime = Int64(lastReadBlockTime)
        await MessageStore.shared.updateReadStatusAndWait(
            contactAddress: contactAddress,
            lastReadTxId: lastReadTxId,
            lastReadBlockTime: blockTime,
            lastReadAt: Date()
        )
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

    /// Persist a read marker to Core Data
    private func persistReadMarker(_ marker: PendingReadMarker) {
        guard let deviceId = deviceId else {
            AppLog.log("[ReadStatusSync] Cannot persist read marker: no device ID")
            return
        }

        // Upsert to CDReadMarker (monotonic write handled inside)
        MessageStore.shared.upsertReadMarker(
            conversationId: marker.conversationId,
            deviceId: deviceId,
            lastReadTxId: marker.lastReadTxId,
            lastReadBlockTime: marker.lastReadBlockTime
        )

        AppLog.log("[ReadStatusSync] Persisted read marker for %@ device=%@ blockTime=%lld",
              String(marker.conversationId.suffix(8)), String(deviceId.prefix(8)), marker.lastReadBlockTime)
    }
}
