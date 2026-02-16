> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# CloudKit Sync Improvement Plan

## Current Problem

When the same iCloud account is used on two devices (device1 and device2):
- **device1** sends a message to **device3**
- On **device2**, the sent message either:
  - Does not appear at all
  - Shows as "📤 Sent via another device"

**Expected behavior:** device2 should show the actual message content, synced from device1 via CloudKit.

---

## Current Architecture Analysis

### How Messages Are Stored

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│    device1      │     │    CloudKit     │     │    device2      │
├─────────────────┤     │  (Private DB)   │     ├─────────────────┤
│  Core Data      │────▶│                 │◀────│  Core Data      │
│  CDMessage      │     │  CDMessage      │     │  CDMessage      │
│                 │     │  CDConversation │     │                 │
│ contentEncrypted│     │                 │     │ contentEncrypted│
│ (AES encrypted) │     │                 │     │ (AES encrypted) │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

**CDMessage schema:**
- `txId` - unique transaction ID from chain
- `contentEncrypted` - message content encrypted with wallet-derived symmetric key
- `isOutgoing` - direction flag
- `walletAddress` - per-wallet partitioning

### Current Sync Flow

```
startPolling()
  │
  ├─▶ Phase 1: Fetch handshakes (encryption keys)
  │
  ├─▶ Phase 2: Setup UTXO subscription (real-time)
  │
  ├─▶ Phase 3: Wait for CloudKit sync (no timeout)
  │     └─▶ waitForCloudKitSync() - waits for NSPersistentCloudKitContainer import event
  │
  └─▶ Phase 4: Full indexer sync (diff-only writes)
        └─▶ fetchNewMessages() → syncFromConversations()
```

### Encryption Key Derivation

```swift
// MessageStore encryption key (same across all devices with same wallet)
func messageEncryptionKey() -> SymmetricKey? {
    guard let privateKey = WalletManager.shared.getPrivateKey() else { return nil }
    // HKDF from private key - deterministic, same result on all devices
    return CryptoUtils.deriveKey(from: privateKey, info: "kasia-message-store")
}
```

**Key insight:** The encryption key IS the same across devices because it's derived from the wallet private key (from seed phrase), which is entered separately on each device.

---

## Root Cause Analysis

### Issue 1: Race Condition in Sync Order

**Problem:** The protection `!isPlaceholder` in `syncFromConversations()` prevents overwriting CloudKit data with placeholders. BUT if CloudKit hasn't synced the specific message yet when indexer sync runs, placeholder wins.

```swift
// In syncFromConversations():
let isPlaceholder = message.content == "📤 Sent via another device"

if !isPlaceholder, let encrypted = self.encryptContent(message.content, key: encryptionKey) {
    record.contentEncrypted = encrypted  // Only update if NOT placeholder
}
```

**Race scenario:**
1. device1 sends message → stores `contentEncrypted` with actual content
2. CloudKit syncs... (takes time)
3. device2 starts app
4. device2 Phase 4 runs BEFORE CloudKit delivers that specific message
5. device2 indexer returns outgoing tx → creates placeholder message
6. Placeholder saved to Core Data
7. Later, CloudKit delivers the actual content...
8. BUT Core Data merge policy `NSMergeByPropertyStoreTrumpMergePolicy` may keep local (placeholder) version

### Issue 2: CloudKit Sync Status Not Per-Record

**Problem:** `waitForCloudKitSync()` only waits for the first import event or timeout. It doesn't guarantee all records are synced.

```swift
// Current implementation waits for ONE import event
if event.type == .import && event.succeeded && event.endDate != nil {
    cloudKitSyncStatus = .synced  // Marks as done after first import
}
```

CloudKit may need multiple import cycles to sync all records, especially for large datasets.

### Issue 3: Missing Trigger on Push Notification

**Problem:** When device2 receives a push notification with `txId` for a message sent by device1, it doesn't trigger CloudKit sync specifically for that record.

**Current flow:**
1. Push arrives with `txId`
2. `fetchMessageByTxId()` tries indexer, mempool, Kaspa REST
3. For outgoing message from other device → can't decrypt (no plaintext available)
4. Falls back to placeholder

**What should happen:**
1. Push arrives with `txId` for outgoing message
2. Trigger CloudKit delta sync
3. Look for `contentEncrypted` in CloudKit-synced CDMessage record
4. Use that content instead of placeholder

---

## Proposed Solutions

### Solution 1: Push-Triggered CloudKit Sync (Quick Win)

When receiving a push notification for a message sent from another device:

```swift
func handleOutgoingMessageFromPush(txId: String) async {
    // 1. Check if message already exists with content
    if let existing = findLocalMessage(txId: txId),
       existing.content != "📤 Sent via another device" {
        return  // Already have content
    }

    // 2. Force CloudKit delta sync
    await triggerCloudKitDeltaSync()

    // 3. Wait briefly for CloudKit to deliver
    try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s

    // 4. Reload from store and check for content
    loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

    // 5. If still placeholder, it's a timing issue - CloudKit will deliver eventually
}
```

### Solution 2: Improve CloudKit Sync Status Tracking

Track sync status more granularly:

```swift
enum CloudKitSyncStatus {
    case notStarted
    case syncing
    case partiallysynced(Date)  // Track when last import completed
    case fullySynced
    case disabled
    case failed
}

// Wait for multiple import cycles
func waitForCloudKitSync(timeout: TimeInterval = 10) async {
    let startTime = Date()
    var lastImportTime: Date?

    while Date().timeIntervalSince(startTime) < timeout {
        // Wait for import event
        await waitForNextImportEvent()
        lastImportTime = Date()

        // Wait 1s to see if more imports are coming
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // If no new import in 1s, consider sync done
        if Date().timeIntervalSince(lastImportTime!) > 1.0 {
            break
        }
    }
}
```

### Solution 3: Two-Phase Message Resolution

For outgoing messages from other devices, implement retry with CloudKit fallback:

```swift
func resolveOutgoingMessage(txId: String) async -> String? {
    // Phase 1: Check local store (CloudKit-synced)
    if let content = getMessageContentFromStore(txId: txId) {
        return content
    }

    // Phase 2: Wait for CloudKit (message might be in transit)
    await triggerCloudKitDeltaSync()
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    if let content = getMessageContentFromStore(txId: txId) {
        return content
    }

    // Phase 3: Return nil (will show placeholder, CloudKit will deliver later)
    return nil
}
```

### Solution 4: Smarter Merge Policy

Instead of relying on Core Data merge policy, implement explicit merge logic:

```swift
func mergeCloudKitMessage(_ cloudRecord: CDMessage, with localRecord: CDMessage) {
    // Prefer non-nil contentEncrypted
    if cloudRecord.contentEncrypted != nil && localRecord.contentEncrypted == nil {
        localRecord.contentEncrypted = cloudRecord.contentEncrypted
    }

    // Prefer more recent updatedAt
    if let cloudDate = cloudRecord.updatedAt,
       let localDate = localRecord.updatedAt,
       cloudDate > localDate {
        localRecord.contentEncrypted = cloudRecord.contentEncrypted
    }
}
```

---

## Implementation Plan

### Phase 1: Quick Fixes (Immediate)

1. **Add CloudKit refresh on app foreground:**
```swift
// In KaChatApp.swift
.onChange(of: scenePhase) { newPhase in
    if newPhase == .active {
        Task {
            // Trigger CloudKit delta sync
            await MessageStore.shared.refreshFromCloudKit()
            // Reload messages
            ChatService.shared.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
        }
    }
}
```

2. **Increase CloudKit wait time for initial sync:**
```swift
// Wait for multiple import events, not just one
await messageStore.waitForCloudKitSync(timeout: 10)  // Increased from 5s
```

3. **Fix merge policy priority:**
```swift
// Use NSMergeByPropertyObjectTrumpMergePolicy for better CloudKit merge
context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
```

### Phase 2: Push-Triggered Sync (1-2 days)

1. **Add outgoing message detection to push handler:**
```swift
// In addPaymentFromPush / fetchMessageByTxId
let isOutgoingFromOtherDevice = sender == myAddress && !isMessageLocallyKnown(txId)

if isOutgoingFromOtherDevice {
    // This is a message WE sent from another device
    await resolveOutgoingMessageFromCloudKit(txId: txId)
}
```

2. **Implement CloudKit delta sync trigger:**
```swift
func triggerCloudKitDeltaSync() async {
    // Force Core Data to fetch from CloudKit
    let context = container.newBackgroundContext()
    context.refreshAllObjects()

    // Or use CKFetchRecordZoneChangesOperation directly
}
```

### Phase 3: Segmented Archive (Future - Major Refactor)

Implement the architecture from `CLOUDKIT_IMPROVEMENT_SUGGESTIONS.md`:

1. **Replace per-message CloudKit records with segment blobs**
2. **Each segment contains 25-50 messages**
3. **Immutable write pattern (no merge conflicts)**
4. **Add `MessageLocator(txId → segment)` for fast lookup**

Benefits:
- Fewer CloudKit operations (4 segments/day vs 100 records/day)
- No merge conflicts (immutable segments)
- Faster sync (bulk download instead of record-by-record)

---

## Immediate Action Items

### 1. Fix Race Condition (Priority: HIGH)

**File:** `ChatService.swift`

```swift
// In startPolling(), after Phase 3:

// Phase 3.5: Double-check CloudKit has synced outgoing messages
if cloudKitEnabled {
    // Load what CloudKit has synced so far
    loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

    // Give CloudKit a bit more time for any in-flight syncs
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}

// Phase 4: Now safe to sync from indexer
```

### 2. Preserve CloudKit Content (Priority: HIGH)

**File:** `MessageStore.swift`

```swift
// In syncFromConversations(), before updating contentEncrypted:

// Check if CloudKit already has content for this record
let hasCloudKitContent = record.contentEncrypted != nil &&
                         (record.updatedAt ?? .distantPast) > Date().addingTimeInterval(-3600)

let isPlaceholder = message.content == "📤 Sent via another device"

// Only update content if:
// - New content is NOT a placeholder, AND
// - CloudKit doesn't already have content (or our content is newer)
if !isPlaceholder && !hasCloudKitContent {
    if let encrypted = self.encryptContent(message.content, key: encryptionKey) {
        record.contentEncrypted = encrypted
    }
}
```

### 3. Add Retry for Outgoing Messages (Priority: MEDIUM)

**File:** `ChatService.swift`

```swift
// When decoding a message shows placeholder, schedule retry
func scheduleCloudKitRetry(for txId: String) {
    Task {
        // Wait for CloudKit to potentially deliver
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // Check if content arrived
        loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

        if let msg = findLocalMessage(txId: txId),
           msg.content == "📤 Sent via another device" {
            // Still placeholder - CloudKit hasn't delivered yet
            // Will be resolved on next app launch or remote change notification
            NSLog("[ChatService] Message %@ still awaiting CloudKit sync", txId)
        }
    }
}
```

### 4. Leverage Push txId for CloudKit Sync (Priority: MEDIUM)

**File:** `PushNotificationManager.swift` (or AppDelegate)

```swift
func handlePushNotification(userInfo: [AnyHashable: Any]) async {
    guard let txId = userInfo["tx_id"] as? String,
          let sender = userInfo["sender"] as? String else { return }

    let myAddress = WalletManager.shared.currentWallet?.publicAddress
    let isOutgoingFromOtherDevice = sender == myAddress

    if isOutgoingFromOtherDevice {
        // This is our own message sent from another device
        // Wait for CloudKit to sync it
        NSLog("[Push] Outgoing message from other device: %@", txId)

        // Trigger CloudKit refresh
        await MessageStore.shared.waitForCloudKitSync(timeout: 5)
        ChatService.shared.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
    } else {
        // Normal incoming message handling
        await ChatService.shared.fetchMessageByTxId(txId, sender: sender)
    }
}
```

---

## Testing Checklist

### Test Case 1: Basic Cross-Device Sync
1. [ ] device1: Send message to contact
2. [ ] device2: Open app within 30s
3. [ ] device2: Message should appear with actual content (not placeholder)

### Test Case 2: Delayed Sync
1. [ ] device1: Send message while device2 is closed
2. [ ] Wait 5 minutes
3. [ ] device2: Open app
4. [ ] device2: Message should appear with actual content

### Test Case 3: Push Notification Trigger
1. [ ] device1: Send message
2. [ ] device2: Receive push notification
3. [ ] device2: Tap notification to open app
4. [ ] device2: Message should appear with actual content

### Test Case 4: Offline Sync
1. [ ] device1: Send message while device2 is offline
2. [ ] device2: Go online, open app
3. [ ] device2: Message should sync eventually (may take 1-2 minutes)

---

## Monitoring & Debugging

### Add Logging

```swift
// Log CloudKit events
NSLog("[CloudKit] Import event: %d records, took %.2fs", recordCount, duration)
NSLog("[CloudKit] Message %@ synced, hasContent=%@", txId, hasContent)

// Log merge decisions
NSLog("[MessageStore] Merging %@: cloudContent=%@, localContent=%@, winner=%@",
      txId, cloudHasContent, localHasContent, winner)
```

### Diagnostics View

Add to Settings > Diagnostics:
- CloudKit sync status
- Last sync time
- Number of messages with placeholder content
- Button to force CloudKit refresh

---

## Summary

| Issue | Root Cause | Solution | Priority |
|-------|------------|----------|----------|
| Messages show placeholder | Race condition: indexer runs before CloudKit | Wait for CloudKit, then merge carefully | HIGH |
| Messages don't appear | CloudKit sync incomplete | Longer wait, multiple import cycles | HIGH |
| Push doesn't help | Push triggers indexer, not CloudKit | Detect outgoing from push, trigger CloudKit | MEDIUM |
| Eventual consistency | NSPersistentCloudKitContainer limitations | Consider segmented archive in future | LOW |

**Recommended implementation order:**
1. Fix race condition in sync flow (Phase 3.5)
2. Preserve CloudKit content in merge logic
3. Add push-triggered CloudKit refresh
4. Add retry mechanism for placeholders
5. (Future) Implement segmented archive for robust sync
