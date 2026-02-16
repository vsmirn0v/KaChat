With your numbers (**>100 conversations/account, ~10 active/day, ~3 devices**) the *raw volume* of read-sync is small. The throttling risk comes from **bursts + conflicts**, especially when you update the *same mutable record* frequently while Apple is also syncing your message history through `NSPersistentCloudKitContainer`.

CloudKit can throttle when it “deems necessary” and you’re expected to honor the retry interval (`retryAfterSeconds` / `CKErrorRetryAfterKey`). ([Apple Developer][1])

Below is how your current design affects throttling, and what I’d change given your constraints (Core Data + `NSPersistentCloudKitContainer`, segmented archives, eventual OK).

---

## How Option A will behave in practice

### 1) Conflicts create extra traffic

`ConversationState` is a **hot, mutable** record per conversation. With 3 devices, you’ll occasionally have overlapping updates (device A marks read, device B also marks read or comes online and flushes). That yields `serverRecordChanged`, which forces extra fetch/merge/retry cycles (and often happens in bursts). That’s *much* more throttle-prone than the “writes/day” suggests.

### 2) 2-second debounce still produces “scroll spikes”

If the user bounces through 8–15 chats quickly, your 2s debounce can still flush **many conversation updates at once**.

That’s not huge, but it stacks with:

* your history segments syncing
* other metadata sync
* app foreground/background flushes

Throttling is mainly about **short-term request rate**, not daily totals. ([Apple Developer][1])

### 3) “Fetch all states on notification” amplifies bursts

CloudKit notifications can be coalesced; treat them as **hints**, not “one notification per change.” ([Apple Developer][2])
If every hint triggers “fetch all `ConversationState` records”, you create redundant reads right when the system is busiest.

---

## What I recommend for your exact usage: Option B, synced via Core Data (not manual CK ops)

### Why Option B is better for throttling

Per-device `ReadMarker` records eliminate write conflicts entirely:

* each device only writes `read.<conversationId>.<deviceId>`
* no `serverRecordChanged` loop
* no read-modify-write requirement to “merge server into client”

Record count is fine: **100 conv × 3 devices = 300 tiny records/account**.

### Implement it the Core Data way (since you already use `NSPersistentCloudKitContainer`)

Don’t do `CKRecord` fetch/save for read markers. Model them as Core Data entities, let mirroring handle it, and listen for remote changes.

Apple’s docs emphasize enabling remote change notifications with `NSPersistentStoreRemoteChangeNotificationPostOptionKey` and then consuming only relevant store changes. ([Apple Developer][3])

---

## Proposed schema (fits segmented archive + multi-account)

Assuming you keep **one persistent store per app-account** (best for account switching), each store maps to its own CloudKit record zone. That keeps change tokens, subscriptions, and throttling/backoff isolated *per account*.

### Entity: `CDReadMarker` (synced)

Unique constraint: `(conversationId, deviceId)`

| field             |        type | notes                          |
| ----------------- | ----------: | ------------------------------ |
| conversationId    |      String | indexed                        |
| deviceId          |      String | stable per install             |
| lastReadTxId      | String/Data | optional                       |
| lastReadBlockTime |       Int64 | **single source of truth**     |
| updatedAt         |        Date | optional; mostly for debugging |

**Write rule (monotonic):** only update if `newBlockTime > existingBlockTime`.

### Entity: `CDConversation` (local + synced or local only)

| field                      |        type | notes                        |
| -------------------------- | ----------: | ---------------------------- |
| conversationId             |      String | unique                       |
| effectiveLastReadBlockTime |       Int64 | derived (max across markers) |
| effectiveLastReadTxId      | String/Data | derived                      |
| unreadCountCache           |       Int32 | optional cache               |

You can keep the derived fields **local-only** if you want to avoid syncing them.

---

## Sync algorithm that minimizes throttling

### Writes: “stable point” instead of 2-second debounce

Replace the “flush 2s after last event” with:

**Upload a marker only when:**

1. user leaves the conversation screen, OR
2. app goes background, OR
3. user stays idle in that conversation for ~15–30 seconds

And still apply the monotonic check (`blockTime` must advance).

With ~10 active conversations/day, that becomes roughly:

* **~10 marker updates/day/device** (≈30/day/account across 3 devices)
  This is tiny.

### Reads: no “fetch all records” loop

Since you’re using `NSPersistentCloudKitContainer`, you should:

* enable remote change notifications (`NSPersistentStoreRemoteChangeNotificationPostOptionKey`) ([Apple Developer][3])
* when you get `.NSPersistentStoreRemoteChange`, process **persistent history / relevant changes**, then refresh UI

This is the “delta” pattern Apple documents for Core Data + CloudKit sync. ([Apple Developer][3])

### Notifications: treat as hints

If you add subscriptions for read markers, treat pushes as “wake up and process deltas”, not “fetch everything”. Notifications can be coalesced/dropped. ([Apple Developer][2])

---

## Throttling handling: what you must do (even if rare)

Even with the improved algorithm, you’ll still occasionally hit throttles (e.g., new device restores lots of segments + markers).

* On CloudKit errors like “rate limited”, honor the provided retry interval. ([Apple Developer][1])
* With `NSPersistentCloudKitContainer`, follow Apple’s debugging/sync technotes to surface and interpret sync events and throttles. ([Apple Developer][4])

(Practically: implement a per-account “Cloud sync paused until X” gate so your UI doesn’t keep triggering background saves that immediately fail.)

---

## Keep read-sync records small

CloudKit record fields have a **1 MB max (assets excluded)**; keep mutable records tiny anyway. ([Apple Developer][5])
Don’t sync `unreadCount` (you already planned not to). Compute from `effectiveLastReadBlockTime` + locally present message metadata.

---

## What I would change in your current implementation

### Keep from Option A

* last-read-wins by `lastReadBlockTime` (monotonic is good)
* computed unread count
* “flush on background”

### Change

1. **Switch to Option B** (per-device markers) to eliminate conflicts.
2. **Increase debounce window** (15–30s idle) + “flush on conversation exit”.
3. **Don’t “fetch all ConversationState”** on every hint—let Core Data mirroring + remote change notifications drive it. ([Apple Developer][3])

---

## Quick reality check with your load

* 10 active conversations/day × 3 devices → ~30 marker writes/day/account
* message history segments: likely a few segment records/day (depending on your segmentation)
* this is *very* unlikely to throttle under normal usage **if you avoid spikes and conflicts**.

If you want, tell me how you currently structure “one store per account vs one store for all accounts”, and I’ll adapt the exact Core Data model + store/zone setup (including how to pause syncing for inactive accounts so switching accounts doesn’t multiply CloudKit activity).

[1]: https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles?utm_source=chatgpt.com "TN3162: Understanding CloudKit throttles"
[2]: https://developer.apple.com/library/archive/qa/qa1917/_index.html?utm_source=chatgpt.com "Debugging issues with CloudKit subscriptions"
[3]: https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes?utm_source=chatgpt.com "Consuming relevant store changes"
[4]: https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer?utm_source=chatgpt.com "TN3163: Understanding the synchronization of ..."
[5]: https://developer.apple.com/documentation/cloudkit/ckrecord?utm_source=chatgpt.com "CKRecord | Apple Developer Documentation"

---

# Detailed Implementation Plan: Option B with Stable-Point Debounce

---

## Critical Architecture Note: CloudKit Zones

### Current Implementation Issue

The current code in `MessageStore.swift` attempts to create per-wallet CloudKit zones:

```swift
let zoneName = zoneNameForWallet(walletAddress)  // "wallet-<hash>"
let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
createZoneIfNeeded(zoneID: zoneID)  // Creates the zone manually
```

**However, this does NOT work as intended.** `NSPersistentCloudKitContainer` automatically manages its own zone named `com.apple.coredata.cloudkit.zone` and **ignores manually created zones**. There is no API to specify a custom zone name in `NSPersistentCloudKitContainerOptions`.

Sources:
- [NSPersistentCloudKitContainer | Apple Developer Documentation](https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer)
- [General Findings About NSPersistentCloudKitContainer](https://crunchybagel.com/nspersistentcloudkitcontainer/)

### What This Means

| Aspect | What Code Suggests | What Actually Happens |
|--------|-------------------|----------------------|
| **Local storage** | Separate SQLite per wallet ✓ | Works correctly |
| **CloudKit zone** | Separate zone per wallet | **All wallets share one zone** |
| **Data isolation** | Complete per-wallet | **CloudKit data is mixed** |

### Solutions

#### Option 1: Accept Shared Zone (Recommended Short-Term)

Keep `walletAddress` on ALL synced entities to filter data:

```swift
// CDMessage, CDConversation, CDReadMarker all need walletAddress
request.predicate = NSPredicate(format: "walletAddress == %@", currentWalletAddress)
```

**Pros:** Works with current NSPersistentCloudKitContainer
**Cons:** All wallet data syncs to all devices (filtered locally), slight privacy concern

#### Option 2: Separate Configurations (Better Isolation)

Use Core Data configurations - each configuration gets its own CloudKit zone:

```swift
// In Core Data model, create configurations: "Wallet1", "Wallet2", etc.
let description = NSPersistentStoreDescription(url: storeURL)
description.configuration = "Wallet_\(walletHash)"  // Each config = separate zone
```

**Pros:** True zone isolation
**Cons:** Complex model management, may hit zone limits

#### Option 3: CKSyncEngine (iOS 17+, Best Long-Term)

Replace NSPersistentCloudKitContainer with `CKSyncEngine` for full control:

```swift
let engine = CKSyncEngine(configuration: config)
// Full control over zones, records, conflict resolution
```

**Pros:** Complete control, per-wallet zones, better performance
**Cons:** iOS 17+ only, significant refactor, manual sync logic

### Recommendation for CLOUDKIT_IMPROVEMENT_v2

Given this constraint, the document below assumes **Option 1 (shared zone with walletAddress filtering)** for backward compatibility. This means:

1. **Keep `walletAddress` on `CDReadMarker`** (contrary to earlier "remove it" advice)
2. **All predicates must filter by walletAddress**
3. **Store-per-wallet provides local isolation only**

If true CloudKit isolation is needed later, migrate to Option 2 or 3.

---

## Phase 1: Core Data Schema Migration

### New Entity: `CDReadMarker`

Add to `MessageStore.makeModel()`:

> **Architecture Note:** Due to the CloudKit zone limitation (see above), all wallets share the same
> CloudKit zone (`com.apple.coredata.cloudkit.zone`). Therefore, `walletAddress` IS required on
> `CDReadMarker` to filter data per wallet. The separate SQLite files provide local isolation,
> but CloudKit sync requires the walletAddress field for filtering.

```swift
let readMarkerEntity = NSEntityDescription()
readMarkerEntity.name = CDReadMarker.entityName
readMarkerEntity.managedObjectClassName = NSStringFromClass(CDReadMarker.self)

readMarkerEntity.properties = [
    makeAttribute(name: "conversationId", type: .stringAttributeType, optional: false, defaultValue: ""),
    makeAttribute(name: "deviceId", type: .stringAttributeType, optional: false, defaultValue: ""),
    makeAttribute(name: "lastReadTxId", type: .stringAttributeType, optional: true),
    makeAttribute(name: "lastReadBlockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
    makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true),
    // REQUIRED: walletAddress for filtering in shared CloudKit zone
    makeAttribute(name: "walletAddress", type: .stringAttributeType, optional: false, defaultValue: "")
]

// IMPORTANT: Use uniquenessConstraints, NOT NSFetchIndexDescription!
// NSFetchIndexDescription creates an INDEX (for speed), not a UNIQUENESS CONSTRAINT.
// Include walletAddress in constraint since zone is shared across wallets
readMarkerEntity.uniquenessConstraints = [["walletAddress", "conversationId", "deviceId"]]

// Optional: Add index for faster lookups (separate from uniqueness)
let conversationIndex = NSFetchIndexDescription(name: "byWalletConversation",
    elements: [
        NSFetchIndexElementDescription(property: readMarkerEntity.propertiesByName["walletAddress"]!,
                                       collationType: .binary),
        NSFetchIndexElementDescription(property: readMarkerEntity.propertiesByName["conversationId"]!,
                                       collationType: .binary)
    ])
readMarkerEntity.indexes = [conversationIndex]

model.entities = [messageEntity, conversationEntity, readMarkerEntity]
```

### Managed Object Class

```swift
@objc(CDReadMarker)
final class CDReadMarker: NSManagedObject {
    static let entityName = "CDReadMarker"

    @NSManaged var conversationId: String
    @NSManaged var deviceId: String
    @NSManaged var lastReadTxId: String?
    @NSManaged var lastReadBlockTime: Int64
    @NSManaged var updatedAt: Date?
    // REQUIRED: walletAddress for filtering in shared CloudKit zone
    @NSManaged var walletAddress: String
}
```

### Update `CDConversation` - Derived Fields Strategy

The `effectiveLastReadBlockTime` (max across all device markers) needs careful handling:

**Option 1: Transient (Recommended)**
Make it transient so it's computed in-memory, never persisted or synced:

```swift
// In makeModel(), for conversationEntity:
let effectiveReadAttr = makeAttribute(name: "effectiveLastReadBlockTime",
                                      type: .integer64AttributeType, optional: false, defaultValue: 0)
effectiveReadAttr.isTransient = true  // NOT persisted, NOT synced

let unreadCacheAttr = makeAttribute(name: "unreadCountCache",
                                    type: .integer32AttributeType, optional: false, defaultValue: 0)
unreadCacheAttr.isTransient = true  // Computed on demand
```

**Option 2: Persisted but Accepted (Simpler)**
Keep it persisted - it's tiny and syncing it is harmless. Other devices will just overwrite with their own computed value.

```swift
// In CDConversation:
@NSManaged var effectiveLastReadBlockTime: Int64  // Max across all device markers (may sync, that's OK)
@NSManaged var unreadCountCache: Int32            // Computed cache
```

> **Recommendation:** Use Option 2 for simplicity. The field is ~8 bytes and syncing it has no negative effect - each device computes its own value anyway.

---

## Phase 2: Stable-Point Debounce Algorithm

Replace the 2-second timer debounce with a "stable point" approach that only syncs when the user is done reading.

### ReadStatusSyncManager v2

```swift
@MainActor
final class ReadStatusSyncManager: ObservableObject {
    static let shared = ReadStatusSyncManager()

    /// Device ID (stable per install, derived from Secure Enclave)
    private lazy var deviceId: String = {
        KeychainService.shared.deviceIdentifier() ?? UUID().uuidString
    }()

    /// Pending read status per conversation (not yet flushed)
    private var pendingMarkers: [String: PendingReadMarker] = [:]

    /// Idle timer per conversation (flush after 15s of no activity)
    private var idleTimers: [String: Timer] = [:]

    /// Idle threshold before flushing (seconds)
    private let idleThreshold: TimeInterval = 15.0

    // MARK: - Public API

    /// Called when user scrolls/views messages in a conversation.
    /// Accumulates read position but doesn't sync immediately.
    func recordRead(conversationId: String, contactAddress: String, txId: String, blockTime: UInt64) {
        let blockTime64 = Int64(blockTime)

        // Only track if this advances the read position
        if let existing = pendingMarkers[conversationId], existing.blockTime >= blockTime64 {
            return
        }

        pendingMarkers[conversationId] = PendingReadMarker(
            contactAddress: contactAddress,
            txId: txId,
            blockTime: blockTime64,
            recordedAt: Date()
        )

        // Reset idle timer for this conversation
        resetIdleTimer(for: conversationId)
    }

    /// Called when user exits a conversation. Flushes immediately.
    func userLeftConversation(_ conversationId: String) {
        idleTimers[conversationId]?.invalidate()
        idleTimers.removeValue(forKey: conversationId)

        if let pending = pendingMarkers.removeValue(forKey: conversationId) {
            flushMarker(conversationId: conversationId, marker: pending)
        }
    }

    /// Called when app goes to background. Flushes all pending.
    func flushAllPending() {
        // Cancel all timers
        for (_, timer) in idleTimers {
            timer.invalidate()
        }
        idleTimers.removeAll()

        // Flush all pending markers
        let allPending = pendingMarkers
        pendingMarkers.removeAll()

        for (conversationId, marker) in allPending {
            flushMarker(conversationId: conversationId, marker: marker)
        }

        NSLog("[ReadStatusSync] Flushed %d pending markers on background", allPending.count)
    }

    // MARK: - Private

    private func resetIdleTimer(for conversationId: String) {
        idleTimers[conversationId]?.invalidate()
        idleTimers[conversationId] = Timer.scheduledTimer(withTimeInterval: idleThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.idleTimerFired(conversationId: conversationId)
            }
        }
    }

    private func idleTimerFired(conversationId: String) {
        idleTimers.removeValue(forKey: conversationId)

        if let pending = pendingMarkers.removeValue(forKey: conversationId) {
            NSLog("[ReadStatusSync] Idle timeout, flushing marker for %@", String(conversationId.suffix(8)))
            flushMarker(conversationId: conversationId, marker: pending)
        }
    }

    private func flushMarker(conversationId: String, marker: PendingReadMarker) {
        // Write to Core Data (NSPersistentCloudKitContainer will sync)
        MessageStore.shared.upsertReadMarker(
            conversationId: conversationId,
            deviceId: deviceId,
            lastReadTxId: marker.txId,
            lastReadBlockTime: marker.blockTime
        )

        // Also update the conversation's local unread cache
        MessageStore.shared.recomputeEffectiveReadStatus(conversationId: conversationId)
    }
}

struct PendingReadMarker {
    let contactAddress: String
    let txId: String
    let blockTime: Int64
    let recordedAt: Date
}
```

---

## Phase 3: MessageStore Read Marker Methods

### Upsert Read Marker (Monotonic)

> **Note:** `walletAddress` IS required because CloudKit uses a shared zone across all wallets.

```swift
extension MessageStore {
    /// Upserts a read marker for a specific device. Only updates if blockTime advances.
    func upsertReadMarker(conversationId: String, deviceId: String, lastReadTxId: String?, lastReadBlockTime: Int64) {
        guard ensureStoreLoaded() else { return }
        guard let walletAddress = currentWalletAddress else {
            NSLog("[MessageStore] Cannot upsert read marker: no wallet set")
            return
        }

        let context = container.newBackgroundContext()
        // Use NSMergeByPropertyObjectTrumpMergePolicy for uniqueness constraint handling
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.perform {
            let marker = self.fetchOrCreateReadMarker(
                walletAddress: walletAddress,
                conversationId: conversationId,
                deviceId: deviceId,
                in: context
            )

            // Monotonic: only update if new blockTime is greater
            guard lastReadBlockTime > marker.lastReadBlockTime else {
                NSLog("[MessageStore] Skipping marker update: existing=%lld >= new=%lld",
                      marker.lastReadBlockTime, lastReadBlockTime)
                return
            }

            marker.lastReadTxId = lastReadTxId
            marker.lastReadBlockTime = lastReadBlockTime
            marker.updatedAt = Date()

            do {
                try context.save()
                NSLog("[MessageStore] Updated read marker: wallet=%@, conv=%@, device=%@, blockTime=%lld",
                      String(walletAddress.suffix(8)), String(conversationId.suffix(8)),
                      String(deviceId.suffix(8)), lastReadBlockTime)
            } catch {
                NSLog("[MessageStore] Failed to save read marker: \(error)")
            }
        }
    }

    private func fetchOrCreateReadMarker(walletAddress: String, conversationId: String, deviceId: String, in context: NSManagedObjectContext) -> CDReadMarker {
        let request = NSFetchRequest<CDReadMarker>(entityName: CDReadMarker.entityName)
        // MUST filter by walletAddress - shared CloudKit zone contains all wallets' data
        request.predicate = NSPredicate(
            format: "walletAddress == %@ AND conversationId == %@ AND deviceId == %@",
            walletAddress, conversationId, deviceId
        )
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            return existing
        }

        let marker = CDReadMarker(context: context)
        marker.walletAddress = walletAddress
        marker.conversationId = conversationId
        marker.deviceId = deviceId
        marker.lastReadBlockTime = 0
        return marker
    }
}
```

### Compute Effective Read Status (Max Across Devices)

> **Note:** `walletAddress` filtering IS required - shared CloudKit zone contains all wallets' data.

```swift
extension MessageStore {
    /// Recomputes the effective read status by finding max(lastReadBlockTime) across all device markers.
    /// Call this when:
    /// - Local marker is updated
    /// - Remote marker change is detected via persistent history
    func recomputeEffectiveReadStatus(conversationId: String) {
        guard ensureStoreLoaded() else { return }
        guard let walletAddress = currentWalletAddress else {
            NSLog("[MessageStore] Cannot recompute read status: no wallet set")
            return
        }

        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.perform {
            // Fetch all markers for this conversation (from all devices, THIS wallet only)
            let markerRequest = NSFetchRequest<CDReadMarker>(entityName: CDReadMarker.entityName)
            markerRequest.predicate = NSPredicate(
                format: "walletAddress == %@ AND conversationId == %@",
                walletAddress, conversationId
            )

            do {
                let markers = try context.fetch(markerRequest)

                // Find the max blockTime across all devices (the "furthest read" position)
                let effectiveBlockTime = markers.map { $0.lastReadBlockTime }.max() ?? 0
                let effectiveTxId = markers.first(where: { $0.lastReadBlockTime == effectiveBlockTime })?.lastReadTxId

                // Update the conversation's effective read status
                // Note: conversationId is typically the contact address
                let convRequest = NSFetchRequest<CDConversation>(entityName: CDConversation.entityName)
                convRequest.predicate = NSPredicate(format: "contactAddress == %@", conversationId)
                convRequest.fetchLimit = 1

                if let conv = try context.fetch(convRequest).first {
                    let oldBlockTime = conv.effectiveLastReadBlockTime
                    guard effectiveBlockTime != oldBlockTime else {
                        // No change needed
                        return
                    }

                    conv.effectiveLastReadBlockTime = effectiveBlockTime
                    conv.updatedAt = Date()

                    // Recompute unread count from messages
                    let unreadCount = self.computeUnreadCount(
                        contactAddress: conv.contactAddress,
                        lastReadBlockTime: effectiveBlockTime,
                        in: context
                    )
                    conv.unreadCountCache = Int32(unreadCount)

                    try context.save()
                    NSLog("[MessageStore] Updated effective read: conv=%@, blockTime=%lld→%lld, unread=%d",
                          String(conversationId.suffix(8)), oldBlockTime, effectiveBlockTime, unreadCount)

                    // Notify UI on main thread
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .readStatusDidChange,
                                                       object: nil,
                                                       userInfo: ["conversationId": conversationId])
                    }
                }
            } catch {
                NSLog("[MessageStore] Failed to recompute effective read status: \(error)")
            }
        }
    }

    private func computeUnreadCount(contactAddress: String, lastReadBlockTime: Int64, in context: NSManagedObjectContext) -> Int {
        let request = NSFetchRequest<CDMessage>(entityName: CDMessage.entityName)
        request.predicate = NSPredicate(format: "contactAddress == %@ AND isOutgoing == NO AND blockTime > %lld",
                                       contactAddress, lastReadBlockTime)

        do {
            return try context.count(for: request)
        } catch {
            return 0
        }
    }
}
```

---

## Phase 4: Remote Change Processing (Delta Pattern)

> **Prerequisites:** Ensure persistent history tracking is enabled in store description:
> ```swift
> description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
> description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
> ```

### Observe Remote Changes Efficiently

```swift
extension MessageStore {
    /// Process remote changes using persistent history (delta pattern).
    /// Call this when receiving .NSPersistentStoreRemoteChange notification.
    ///
    /// Reference: https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes
    func processRemoteChanges() {
        guard ensureStoreLoaded() else { return }

        var conversationsToRecompute: Set<String> = []

        let context = container.newBackgroundContext()
        context.performAndWait {
            // Fetch persistent history since last processed token
            let token = self.lastHistoryToken
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
            request.resultType = .transactionsAndChanges

            guard let result = try? context.execute(request) as? NSPersistentHistoryResult,
                  let transactions = result.result as? [NSPersistentHistoryTransaction] else {
                NSLog("[MessageStore] No history transactions to process")
                return
            }

            NSLog("[MessageStore] Processing %d history transactions", transactions.count)

            for transaction in transactions {
                guard let changes = transaction.changes else { continue }

                for change in changes {
                    // Check if this is a CDReadMarker change (insert or update)
                    guard change.changedObjectID.entity.name == CDReadMarker.entityName else {
                        continue
                    }

                    // Skip deletes - nothing to recompute
                    guard change.changeType != .delete else { continue }

                    // SAFE PATTERN: Don't assume existingObject works.
                    // Extract conversationId from the change if possible, or fetch it.
                    do {
                        // Try to load the object - it might have been deleted or not yet materialized
                        if let marker = try? context.existingObject(with: change.changedObjectID) as? CDReadMarker {
                            conversationsToRecompute.insert(marker.conversationId)
                        } else {
                            // Object not available - this can happen if it was deleted
                            // after the history was recorded. Log and continue.
                            NSLog("[MessageStore] Could not load marker for change, skipping")
                        }
                    }
                }
            }

            // Update last processed token AFTER successful processing
            if let lastToken = transactions.last?.token {
                self.lastHistoryToken = lastToken
            }
        }

        // ACTUALLY RECOMPUTE - this was missing in the original!
        // Do this outside performAndWait to avoid blocking
        guard !conversationsToRecompute.isEmpty else { return }

        NSLog("[MessageStore] Recomputing read status for %d conversations", conversationsToRecompute.count)

        // Batch recomputes to avoid thundering herd
        // Only recompute immediately for a small number; queue the rest
        let immediateLimit = 5
        let immediate = Array(conversationsToRecompute.prefix(immediateLimit))
        let deferred = Array(conversationsToRecompute.dropFirst(immediateLimit))

        for conversationId in immediate {
            recomputeEffectiveReadStatus(conversationId: conversationId)
        }

        // Queue deferred recomputes with slight delay to spread load
        if !deferred.isEmpty {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                for conversationId in deferred {
                    self?.recomputeEffectiveReadStatus(conversationId: conversationId)
                }
            }
        }
    }

    // MARK: - History Token Storage

    /// Unique key for this store's history token.
    /// Uses the store URL hash to ensure tokens don't cross-contaminate when switching wallets.
    private var historyTokenKey: String {
        guard let storeURL = container.persistentStoreCoordinator.persistentStores.first?.url else {
            return "lastHistoryToken_default"
        }
        // Use store URL hash for unique key per store
        let hash = storeURL.absoluteString.hashValue
        return "lastHistoryToken_\(hash)"
    }

    /// Last processed persistent history token (stored in UserDefaults, keyed per-store)
    private var lastHistoryToken: NSPersistentHistoryToken? {
        get {
            guard let data = UserDefaults.standard.data(forKey: historyTokenKey),
                  let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data) else {
                return nil
            }
            return token
        }
        set {
            if let token = newValue,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: historyTokenKey)
            } else if newValue == nil {
                UserDefaults.standard.removeObject(forKey: historyTokenKey)
            }
        }
    }

    /// Purge old history transactions to prevent unbounded growth.
    /// Call periodically (e.g., on app launch or after processing).
    func purgeOldHistory(olderThan days: Int = 7) {
        guard ensureStoreLoaded() else { return }

        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86400))
        let context = container.newBackgroundContext()

        context.perform {
            let request = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff)
            do {
                try context.execute(request)
                NSLog("[MessageStore] Purged history older than %d days", days)
            } catch {
                NSLog("[MessageStore] Failed to purge history: \(error)")
            }
        }
    }
}

extension Notification.Name {
    static let readStatusDidChange = Notification.Name("readStatusDidChange")
}
```

---

## Phase 5: ChatService Integration

### Update `enterConversation` / `leaveConversation`

```swift
extension ChatService {
    func enterConversation(for address: String) {
        activeConversationAddress = address
        NSLog("[ChatService] Entered conversation for %@", String(address.suffix(12)))

        // Find the conversation and track the current read position
        if let conversation = conversations.first(where: { $0.contact.address == address }),
           let lastIncoming = conversation.messages.filter({ !$0.isOutgoing }).max(by: { $0.blockTime < $1.blockTime }) {
            // Record initial read position (will be flushed on exit or idle)
            ReadStatusSyncManager.shared.recordRead(
                conversationId: address,
                contactAddress: address,
                txId: lastIncoming.txId,
                blockTime: lastIncoming.blockTime
            )
        }
    }

    func leaveConversation() {
        if let address = activeConversationAddress {
            // Flush read status for this conversation
            ReadStatusSyncManager.shared.userLeftConversation(address)

            // Update local unread count immediately
            if let index = conversations.firstIndex(where: { $0.contact.address == address }) {
                updateConversation(at: index) { updated in
                    updated.unreadCount = 0
                }
            }
        }
        activeConversationAddress = nil
        NSLog("[ChatService] Left conversation")
    }

    /// Called when user scrolls to see new messages while in conversation
    func userViewedMessage(_ message: ChatMessage, in conversation: Conversation) {
        guard !message.isOutgoing else { return }

        ReadStatusSyncManager.shared.recordRead(
            conversationId: conversation.contact.address,
            contactAddress: conversation.contact.address,
            txId: message.txId,
            blockTime: message.blockTime
        )
    }
}
```

### Update `markConversationAsRead`

```swift
func markConversationAsRead(_ conversation: Conversation) {
    if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
        // Find the latest incoming message
        let lastIncoming = conversation.messages
            .filter { !$0.isOutgoing }
            .max(by: { $0.blockTime < $1.blockTime })

        updateConversation(at: index) { updated in
            updated.unreadCount = 0
        }

        // Record read status (will be flushed via stable-point debounce)
        if let lastMsg = lastIncoming {
            ReadStatusSyncManager.shared.recordRead(
                conversationId: conversation.contact.address,
                contactAddress: conversation.contact.address,
                txId: lastMsg.txId,
                blockTime: lastMsg.blockTime
            )
        }
    }
}
```

---

## Phase 6: App Lifecycle Hooks

### KaChatApp.swift

```swift
private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
    switch newPhase {
    case .background:
        // ... existing code ...

        // Flush all pending read markers before backgrounding
        ReadStatusSyncManager.shared.flushAllPending()

        // Checkpoint WAL
        MessageStore.shared.checkpointWAL()

    case .active:
        // ... existing code ...

        // Process any remote read marker changes
        Task {
            let settings = AppSettings.load()
            if settings.storeMessagesInICloud {
                MessageStore.shared.refreshFromCloudKit()
                try? await Task.sleep(nanoseconds: 500_000_000)

                // Process remote changes (including read markers from other devices)
                MessageStore.shared.processRemoteChanges()

                ChatService.shared.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
            }
            await ChatService.shared.fetchNewMessages()
        }

    // ...
    }
}
```

---

## Phase 7: Device Lifecycle Considerations

### Stale Device Cleanup

Over time, devices may be retired (sold, lost, replaced). Periodically clean up old markers to prevent unbounded growth:

```swift
extension MessageStore {
    /// Remove read markers from devices that haven't updated in 90 days.
    /// Safe to run periodically - won't affect active devices.
    func pruneStaleReadMarkers(olderThan days: Int = 90) {
        guard ensureStoreLoaded() else { return }

        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 86400))
        let context = container.newBackgroundContext()

        context.perform {
            // Find markers with old or nil updatedAt
            // Note: No walletAddress filter needed - store-per-wallet isolation
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: CDReadMarker.entityName)
            request.predicate = NSPredicate(format: "updatedAt < %@ OR updatedAt == nil", cutoff as NSDate)

            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            deleteRequest.resultType = .resultTypeObjectIDs

            do {
                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                let deletedIds = result?.result as? [NSManagedObjectID] ?? []
                if !deletedIds.isEmpty {
                    NSLog("[MessageStore] Pruned %d stale read markers (older than %d days)", deletedIds.count, days)
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: deletedIds],
                                                       into: [self.viewContext])

                    // Recompute effective read status for affected conversations
                    // (the deleted markers may have been the "max" for some conversations)
                    // For simplicity, just post a notification to refresh all
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .readStatusDidChange, object: nil)
                    }
                }
            } catch {
                NSLog("[MessageStore] Failed to prune stale markers: \(error)")
            }
        }
    }

    /// Returns the number of unique devices that have read markers in this store.
    /// Useful for diagnostics.
    func countReadMarkerDevices() -> Int {
        guard ensureStoreLoaded() else { return 0 }

        var count = 0
        viewContext.performAndWait {
            let request = NSFetchRequest<NSDictionary>(entityName: CDReadMarker.entityName)
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["deviceId"]
            request.returnsDistinctResults = true

            do {
                let results = try viewContext.fetch(request)
                count = results.count
            } catch {
                NSLog("[MessageStore] Failed to count marker devices: \(error)")
            }
        }
        return count
    }
}
```

### Call on App Launch

```swift
// In ChatService.init() or on first sync:
Task.detached(priority: .utility) {
    MessageStore.shared.pruneStaleReadMarkers()
}
```

---

## Summary: Before vs After

| Aspect | Option A (Current) | Option B (Proposed) |
|--------|-------------------|---------------------|
| **Record per conv** | 1 mutable `ConversationState` | N markers (1 per device) |
| **Conflicts** | Frequent (3 devices = race) | None (each device writes own) |
| **Debounce** | 2s timer | 15s idle OR conversation exit |
| **Writes/day** | ~30 (with conflict retries) | ~30 (no retries needed) |
| **Merge logic** | Server conflict resolution | Local max(blockTime) |
| **CloudKit ops** | Fetch + modify + retry | Simple upsert |
| **Throttle risk** | Medium (burst conflicts) | Low (no conflicts, longer debounce) |
| **CloudKit zone** | Shared (NSPersistentCloudKitContainer limitation) | Same - shared zone |
| **Wallet isolation** | walletAddress field filtering | walletAddress field filtering |
| **Local storage** | Separate SQLite per wallet | Same - separate files |
| **History tokens** | Per walletAddress (buggy) | Per store URL (correct) |
| **Uniqueness** | Index (wrong) | Constraint with walletAddress |

### CloudKit Zone Reality Check

⚠️ **Important:** NSPersistentCloudKitContainer does NOT support custom zones. All data syncs to the same `com.apple.coredata.cloudkit.zone` regardless of the wallet. The `walletAddress` field is **required** on all entities to filter data correctly.

Future options for true zone isolation:
- **CKSyncEngine** (iOS 17+) - Full control over zones
- **Separate Core Data configurations** - Each config gets its own zone
- **Separate CloudKit containers** - Requires different bundle IDs (not practical)

---

---

## Phase 8: Ordering Key Considerations

### `blockTime` vs Monotonic Ordering Key

The current design uses `blockTime` (milliseconds since epoch) as the ordering key for read position. This works but has a subtle limitation:

**Problem:** In a DAG-based blockchain like Kaspa, `blockTime` is not perfectly monotonic. Two messages could have:
- Same `blockTime` (processed in same block)
- Inverted `blockTime` vs chain order (due to clock skew)

**Better Alternative:** Use `acceptingDaaScore` (DAA score of the accepting block) which IS monotonic in the DAG.

```swift
// CDReadMarker schema update (future improvement):
readMarkerEntity.properties = [
    makeAttribute(name: "conversationId", type: .stringAttributeType, optional: false, defaultValue: ""),
    makeAttribute(name: "deviceId", type: .stringAttributeType, optional: false, defaultValue: ""),
    makeAttribute(name: "lastReadTxId", type: .stringAttributeType, optional: true),
    makeAttribute(name: "lastReadBlockTime", type: .integer64AttributeType, optional: false, defaultValue: 0),
    // Add for perfect ordering:
    makeAttribute(name: "lastReadDaaScore", type: .integer64AttributeType, optional: false, defaultValue: 0),
    makeAttribute(name: "updatedAt", type: .dateAttributeType, optional: true)
]

// Monotonic check becomes:
guard lastReadDaaScore > marker.lastReadDaaScore else { return }
```

**For now:** `blockTime` is acceptable given message volume (~100/day). The edge cases are rare and the user impact is minimal (worst case: a message shows as unread when it shouldn't).

**Future:** When `acceptingDaaScore` is consistently available in message data, migrate to use it as the primary ordering key.

---

## Fixes Applied (Based on Review Feedback)

The following issues from `CLOUDKIT_IMPROVEMENT_v2_SUGGESTIONS.md` have been addressed:

| Issue | Fix |
|-------|-----|
| **Index vs Uniqueness** | Changed from `NSFetchIndexDescription` to `uniquenessConstraints` |
| **Multi-account inconsistency** | **REVISED:** `walletAddress` IS required (shared CloudKit zone) |
| **Never calls recompute** | `processRemoteChanges()` now actually calls `recomputeEffectiveReadStatus()` |
| **Unsafe object loading** | Added try/catch around `existingObject(with:)` with fallback |
| **Token key per-wallet** | Changed to `historyTokenKey` using store URL hash |
| **Derived field syncing** | Documented options (transient vs persisted), recommended keeping persisted |
| **Batch recomputes** | Added `immediateLimit` with deferred processing for large batches |
| **History purging** | Added `purgeOldHistory()` method |

### Additional Discovery: CloudKit Zone Limitation

After investigating the codebase, discovered that:

1. **NSPersistentCloudKitContainer ignores custom zones** - The manual `createZoneIfNeeded()` calls are ineffective
2. **All wallets share `com.apple.coredata.cloudkit.zone`** - This is Apple's managed zone
3. **`walletAddress` field IS required** - Must filter by wallet in all queries since data is mixed in CloudKit

This changes the earlier advice to "remove walletAddress" - it must be kept for correct operation.

---

## Migration Path

1. **Add `CDReadMarker` entity** to Core Data model
2. **Keep existing `CDConversation` read fields** for backward compatibility
3. **Add `effectiveLastReadBlockTime`** computed from markers
4. **Migrate on first launch**: Copy existing `lastReadBlockTime` to a marker for this device
5. **Gradually phase out** direct `CDConversation.lastReadBlockTime` writes

```swift
func migrateToReadMarkers() {
    // Run once on first launch after update
    guard !UserDefaults.standard.bool(forKey: "didMigrateToReadMarkers") else { return }

    let deviceId = KeychainService.shared.deviceIdentifier() ?? UUID().uuidString
    let conversations = fetchAllConversations()

    for conv in conversations {
        if conv.lastReadBlockTime > 0 {
            upsertReadMarker(
                conversationId: conv.contactAddress,
                deviceId: deviceId,
                lastReadTxId: conv.lastReadTxId,
                lastReadBlockTime: conv.lastReadBlockTime
            )
        }
    }

    UserDefaults.standard.set(true, forKey: "didMigrateToReadMarkers")
    NSLog("[MessageStore] Migrated %d conversations to read markers", conversations.count)
}
```
