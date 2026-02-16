> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

Here’s a **“segmented archive” schema** that keeps CloudKit ops low, supports **multiple in-app accounts**, and fits your volume (≈100 msgs/day/account) + small inline media (≤12 KB) + mostly “encrypted text + CDN links”.

The core trick: **don’t store each message as a CloudKit record**. Store **immutable segment blobs** (assets) plus a tiny amount of metadata for discovery.

CloudKit constraints this design respects: **~1 MB max record fields** (assets excluded) and historical **50 MB max per asset field**; Core Data/CloudKit also externalizes large fields into assets automatically in some flows. ([Apple Developer][1])

---

## 1) Partitioning and “who writes what”

### Partition keys

* **accountId** — your app account (not Apple ID). E.g. hash of your account pubkey.
* **conversationId** — stable ID for chat/thread.
* **dayBucket** — `YYYYMMDD` in UTC (derived from message timestamp).
* **shard** — small int (0..N) used only if a day gets large.
* **writerDeviceId** — stable per device install (UUID).

### Immutable segments (conflict-proof)

To avoid CloudKit write conflicts, **segments are append-free**:

* A device **creates** a new segment record containing a batch of messages.
* It never updates that segment again.
* Other devices download it and merge.

This avoids “read-modify-write” collisions entirely.

---

## 2) CloudKit layout (multiple accounts supported)

### One private DB, **one record zone per app account**

Create a **CKRecordZone** per `accountId`:

* Zone name: `kazia.<accountId>`
* Benefits: easy wipe per account, independent change tokens, and independent subscriptions.

If you use **CKSyncEngine**, reinitialize sync state when switching accounts (Apple sample guidance echoed by third-party analysis). ([Apple Developer][2])

### Record types (minimal)

#### A) `AccountState` (1 record per zone)

RecordName: `state`

| Field          |   Type | Notes                                |
| -------------- | -----: | ------------------------------------ |
| accountId      | String | redundant but useful                 |
| schemaVersion  |    Int | migrate payload formats              |
| syncKeyVersion |    Int | if you rotate your Cloud archive key |
| createdAt      |   Date |                                      |

#### B) `Device` (one per device per account)

RecordName: `dev.<deviceId>`

| Field      |   Type | Notes              |
| ---------- | -----: | ------------------ |
| deviceId   | String | UUID               |
| deviceName | String | “Vitalii’s iPhone” |
| lastSeenAt |   Date | optional           |
| appVersion | String | optional           |

#### C) `ArchiveSegment` (the workhorse)

RecordName (example):
`seg.<conversationId>.<dayBucket>.<writerDeviceId>.<seq>`

Store the segment bytes as an **asset** (or a Data field that becomes an asset). Keep record fields tiny to stay well under the 1 MB record-field limit. ([Apple Developer][1])

| Field           |       Type | Notes                              |
| --------------- | ---------: | ---------------------------------- |
| accountId       |     String |                                    |
| conversationId  |     String | index/query                        |
| dayBucket       |        Int | `YYYYMMDD` UTC                     |
| writerDeviceId  |     String | helps debugging/partitioning       |
| seq             |        Int | monotonic per (device, day, convo) |
| startTs / endTs |       Date | for sorting                        |
| msgCount        |        Int |                                    |
| byteCount       |        Int | compressed bytes                   |
| payloadVersion  |        Int |                                    |
| payloadHash     |       Data | integrity                          |
| payloadAsset    | Asset/Data | encrypted+compressed segment blob  |

> Push: create a **CKQuerySubscription** per account zone for `ArchiveSegment` where `accountId == <accountId>` (or just on recordType in the zone). That gives you “new segment arrived” hints. ([Apple Developer][3])

---

## 3) Segment payload format (inside `payloadAsset`)

You want: compact, easy to parse, and resilient to partial corruption.

**Pipeline**

1. Build `SegmentEnvelope` (protobuf or your custom varint format)
2. Compress (LZFSE is great on Apple platforms)
3. Encrypt (AES-GCM / ChaCha20-Poly1305)

**Keying**

* Per account: `ArchiveMasterKey` (AMK) shared across the user’s devices of that *app account* (stored in Keychain; optionally iCloud Keychain if you want auto multi-device).
* Per segment: derive `SegmentKey = HKDF(AMK, salt = recordName or (conversationId+dayBucket+seq))`.

### Suggested `MessageEntry` fields

Keep it minimal and rely on txid as the stable join key:

* `txid` (32 bytes)
* `direction` (sent/received)
* `senderTs` (int64 seconds)
* `chainHint` (optional: daa score / order key if you have it)
* `bodyCipherForArchive` (bytes)

  * **This is your “sender-readable” copy** for sent messages; and optionally the decrypted+re-encrypted copy for received.
* `attachments[]`:

  * usually just `cdnURLCipher` + metadata (mime, duration, w/h)
  * for ≤12 KB photo/voice: either inline `smallBlobCipher` or keep it as CDN too (your call)

Because you’re only doing ~100 msgs/day, a segment size target like **25–50 messages** is plenty.

---

## 4) Local Core Data schema (multi-account friendly)

### Strong recommendation: **one local store per app account**

Create `Account_<accountId>.sqlite` per account.

* Switching accounts = swapping persistent store
* No risk of cross-account queries
* Easy “delete account locally” behavior

If you prefer one store for all accounts, add `accountId` everywhere and use unique constraints on `(accountId, txid)`.

### Entities (per account store)

#### `Conversation`

* `conversationId` (unique)
* participants metadata
* last chain checkpoint (optional)

#### `Message`

* `txid` (unique)
* `conversationId` (index)
* `direction`
* `senderTs`
* `status` (pending/seen/confirmed)
* `body` (either decrypted or encrypted-at-rest)
* `attachmentRefs` (CDN links, etc.)

#### `ChainEvent` (optional, if you want to keep chain metadata separate)

* `txid`
* ordering cursor / daa score / block info
* confirmation state

#### `SegmentMeta`

* `recordName`
* `conversationId`, `dayBucket`
* `downloadedAt`
* `payloadHash`
* helps you avoid re-downloading

#### `ArchiveQueueItem`

* txid + minimal fields needed to pack into a segment
* used by the segment builder

---

## 5) Sync algorithms

### Upload (per account, per device)

* When you **send** a message: queue an `ArchiveQueueItem` immediately (you have plaintext).
* When you **receive** and decrypt: optionally queue it too (improves new-device restore).

Flush policy (tuned for your volume):

* Flush when any triggers:

  * `queueCount >= 25`
  * `queuedBytes >= 128 KB` (after compression estimate)
  * `timeSinceLastFlush >= 5 min`

Flush action:

* Build a new `ArchiveSegment` record (immutable)
* Upload asset
* On CloudKit throttle errors, back off (CloudKit can enforce throttles; handle retry intervals). ([Apple Developer][4])

### Download

* Maintain a per-account change token / checkpoint (zone changes).
* On push hint (subscription) or app wake:

  * fetch new `ArchiveSegment` records since last token
  * download asset, decrypt, unpack
  * upsert Messages by `txid`

### Merge with Kaspa chain

* Chain scanning gives you **txid + ordering + confirmation**.
* Cloud segments give you **readable body** for sent (and optionally received).
* UI row for a txid is complete when you have both; otherwise show placeholders until the other side arrives.

---

## 6) How this solves your cost issue

* **No second envelope on chain.** On-chain remains recipient-only ciphertext.
* Your “sender-readable” copy is stored in **CloudKit private DB**, paid by the user’s iCloud storage, not your servers.
* CloudKit ops are low: with 100 msgs/day and segment size 25, you create ~4 segment records/day per active conversation/device (often less). That’s far cheaper than 100 records/day.

---

## Practical defaults for your stated load

* Segment size: **25 messages** or **≤256 KB compressed** (whichever first)
* Bucket: **UTC dayBucket**
* Keep segments immutable
* Store attachments as **CDN links**; inline blobs only for ≤12 KB if you really want offline restore

---

If you tell me whether you want to use **CKSyncEngine** (newer, less glue code) or classic “zone changes” operations, I can sketch the exact “sync state per account” objects and the subscription setup pattern for multiple zones.

[1]: https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/PropertyMetrics.html?utm_source=chatgpt.com "CloudKit Web Services Reference: Data Size Limits"
[2]: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5?utm_source=chatgpt.com "CKSyncEngine | Apple Developer Documentation"
[3]: https://developer.apple.com/documentation/cloudkit/ckquerysubscription?utm_source=chatgpt.com "CKQuerySubscription | Apple Developer Documentation"
[4]: https://developer.apple.com/news/site-updates/?id=02202024c&utm_source=chatgpt.com "Understanding CloudKit throttles - Site Updates"

# Q: device1 receives push message with txid of sent message when user sends message from same account on his another device2. can we use this to trigger attempt to resolve unencrypted message text stored from device2 on device1?


Yes — that push with the **txid** is exactly the right trigger. Treat it as a **“sync hint”**: “a message exists on-chain; go try to fetch *my* readable copy from iCloud”.

The only thing you must add is: the push needs to identify **which in-app account** it belongs to (because your app can switch accounts). So the minimal push payload should be:

* `accountId`
* `txid`
* optionally `conversationId` (nice-to-have to narrow the fetch)

## Recommended flow on Device1 (txid push arrives)

### 0) Create/Update a stub message locally

In Core Data (your per-account store), upsert a `Message` row by `txid`:

* `txid = ...`
* `direction = outgoing`
* `body = nil` (placeholder like “Syncing…”)
* `status = pending/confirmed_unknown`

This makes the UI consistent immediately, even before you fetch the body.

### 1) Trigger CloudKit delta sync for that `accountId` zone

Because you’re using the **segmented archive**, you usually **don’t need a “lookup by txid” query**. Just fetch “new segments since last change token” for that account zone, import them, and you’ll get the message body if Device2 already archived it.

* Fetch new `ArchiveSegment` records (since last token)
* Download segment assets
* Decrypt → unpack → upsert messages by `txid`

After import, check if `Message(txid).body != nil`:

* if yes → replace placeholder with text
* if no → keep placeholder and retry later (eventual consistency is fine)

With ~100 msgs/day, you’ll be importing *a handful* of small segments; this is efficient.

### 2) (Optional but good) Also refresh chain metadata

Separately, resolve confirmation/order for the txid (from your Kaspa scanning path). This updates status/order even if body hasn’t arrived yet.

---

## Why this works well with segmented archive

Your segments contain entries keyed by `txid`, so after any segment import you can answer: “do I now have the body for this txid?”

No extra CloudKit query cost per message; it’s just “pull new segments”.

---

## Make it more deterministic (optional “fast path”)

If you want Device1 to resolve the body *immediately* after receiving the txid push (without waiting for “next segment import”), you can add one of these lightweight indexes:

### Option A — `MessageLocator` record (tiny, still cheap at 100/day)

Create an extra CloudKit record per message:

* RecordType: `MessageLocator`
* RecordName: `txid`
* Fields: `accountId`, `conversationId`, `segmentRecordName`

Then Device1 can:

1. fetch `MessageLocator(txid)` by recordName (1 op)
2. fetch that exact segment (1 op)
3. import and resolve

This adds ~100 tiny writes/day/account — still typically fine, but it’s more ops than “segments only”.

### Option B — Put a small “txid bloom / min-max” in `ArchiveSegment` metadata

Store in the segment record (not the asset):

* `firstTxid`, `lastTxid` (or a small bloom filter)
  Then Device1 can query only a narrow set of segments for that day/conversation. This is more complex than A.

For your scale, **A is the simplest deterministic accelerator**.

---

## Multi-account handling (important)

When the push arrives, you must know which account zone to sync:

* Best: include `accountId` in the push.
* If you can’t: you’d have to try all enabled accounts (wasteful) or maintain a local “recent txid → accountId” map (fragile).

So: **push must include accountId**.

---

## What service sends the push?

* If you already have a push coming in “when a tx appears on chain”, then you already have some notifier (node/indexer/relay).
* The push should carry **only txid/accountId** (no plaintext, no ciphertext needed).

(If you’re trying to do *zero backend at all*, you can use **CloudKit subscriptions** to notify on new segments instead, but that won’t fire on “txid appeared on chain” — it fires when Device2 archives to CloudKit. Many apps actually use *both*: chain notifier push for immediacy + CloudKit subscription as a backup.)

---

## Summary

✅ Yes: use the txid push as a wake-up to **pull CloudKit segments** for that account and try to resolve the body.
For faster deterministic resolution, add a tiny `MessageLocator(txid → segment)` record.

If you tell me whether you currently get txid pushes from (a) your own infra, (b) a third-party explorer API, or (c) CloudKit itself, I'll recommend the cleanest "trigger strategy" with the fewest moving parts.

---

# Read Status Sync Between Devices

When a user reads messages on device1, the read status should sync to device2. This includes:
- **Unread count** per conversation
- **Last read message** (txid or timestamp)
- **Read receipts** (optional: which specific messages were read and when)

## Challenges

Unlike message content, read status is **mutable**:
- User opens chat → messages marked as read
- New messages arrive → unread count increases
- User reads on another device → need to merge

The immutable segment pattern doesn't fit well for frequently-changing state.

---

## Option A: `ConversationState` Record (Recommended)

### Design

One **mutable** CloudKit record per conversation:

**RecordType:** `ConversationState`
**RecordName:** `conv.<conversationId>`

| Field              |   Type | Notes                                      |
| ------------------ | -----: | ------------------------------------------ |
| accountId          | String | for filtering                              |
| conversationId     | String | matches local conversation                 |
| contactAddress     | String | for lookup                                 |
| lastReadTxId       | String | txid of last read message (nil = none)     |
| lastReadAt         |   Date | when lastReadTxId was read                 |
| lastReadBlockTime  |  Int64 | blockTime of last read (for ordering)      |
| unreadCount        |    Int | cached count (can be recomputed)           |
| updatedAt          |   Date | for conflict resolution                    |
| updatedByDeviceId  | String | which device last updated                  |

### Write Flow

When user reads messages on device1:

```swift
func markConversationAsRead(conversationId: String, lastReadTxId: String, blockTime: Int64) {
    // 1. Update local state immediately
    updateLocalUnreadCount(conversationId: conversationId, count: 0)

    // 2. Queue CloudKit update (debounced)
    cloudKitUpdateQueue.enqueue {
        let record = fetchOrCreateConversationState(conversationId)

        // Only update if our read is "later" than existing
        if record.lastReadBlockTime < blockTime {
            record.lastReadTxId = lastReadTxId
            record.lastReadAt = Date()
            record.lastReadBlockTime = blockTime
            record.unreadCount = 0
            record.updatedAt = Date()
            record.updatedByDeviceId = deviceId

            try await saveWithConflictResolution(record)
        }
    }
}
```

### Conflict Resolution

CloudKit may return `CKError.serverRecordChanged` if another device updated simultaneously.

**Resolution strategy:** Last-read-wins (by blockTime)

```swift
func resolveConflict(client: CKRecord, server: CKRecord) -> CKRecord {
    let clientBlockTime = client["lastReadBlockTime"] as? Int64 ?? 0
    let serverBlockTime = server["lastReadBlockTime"] as? Int64 ?? 0

    // Keep the one with the later read position
    if clientBlockTime > serverBlockTime {
        // Client read further - merge client into server
        server["lastReadTxId"] = client["lastReadTxId"]
        server["lastReadAt"] = client["lastReadAt"]
        server["lastReadBlockTime"] = client["lastReadBlockTime"]
        server["unreadCount"] = client["unreadCount"]
    }
    // else: server already has later read - keep server values

    server["updatedAt"] = Date()
    return server
}
```

### Read Flow (device2 sync)

On app launch or CloudKit notification:

```swift
func syncConversationStates() async {
    // Fetch all ConversationState records for this account
    let records = await fetchConversationStates(accountId: currentAccountId)

    for record in records {
        let conversationId = record["conversationId"] as! String
        let lastReadTxId = record["lastReadTxId"] as? String
        let lastReadBlockTime = record["lastReadBlockTime"] as? Int64 ?? 0

        // Update local conversation
        updateLocalReadStatus(
            conversationId: conversationId,
            lastReadTxId: lastReadTxId,
            lastReadBlockTime: lastReadBlockTime
        )
    }
}
```

### Debouncing Writes

To avoid excessive CloudKit operations when user is actively reading:

```swift
class ReadStatusSyncManager {
    private var pendingUpdates: [String: ConversationReadUpdate] = [:]
    private var debounceTimer: Timer?

    func markAsRead(conversationId: String, lastReadTxId: String, blockTime: Int64) {
        // Store pending update (overwrites previous for same conversation)
        pendingUpdates[conversationId] = ConversationReadUpdate(
            lastReadTxId: lastReadTxId,
            blockTime: blockTime,
            timestamp: Date()
        )

        // Debounce: flush after 2 seconds of no new updates
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            self.flushPendingUpdates()
        }
    }

    func flushPendingUpdates() {
        let updates = pendingUpdates
        pendingUpdates.removeAll()

        Task {
            for (conversationId, update) in updates {
                await uploadReadStatus(conversationId: conversationId, update: update)
            }
        }
    }
}
```

---

## Option B: Per-Device `ReadMarker` Records (Conflict-Free)

If conflicts become problematic, use one record per device per conversation:

**RecordName:** `read.<conversationId>.<deviceId>`

| Field              |   Type | Notes                              |
| ------------------ | -----: | ---------------------------------- |
| conversationId     | String |                                    |
| deviceId           | String |                                    |
| lastReadTxId       | String |                                    |
| lastReadBlockTime  |  Int64 |                                    |
| updatedAt          |   Date |                                    |

**No write conflicts:** Each device only writes its own record.

**Merge locally:** When syncing, find the max `lastReadBlockTime` across all devices:

```swift
func mergeReadMarkers(markers: [ReadMarker]) -> (lastReadTxId: String?, lastReadBlockTime: Int64) {
    let latest = markers.max(by: { $0.lastReadBlockTime < $1.lastReadBlockTime })
    return (latest?.lastReadTxId, latest?.lastReadBlockTime ?? 0)
}
```

**Downside:** More records (numConversations × numDevices), but each is tiny.

---

## Option C: Immutable `ReadEvent` Segments (Overkill for most cases)

Similar to message segments, but for read events:

**RecordName:** `readseg.<conversationId>.<dayBucket>.<deviceId>.<seq>`

Each segment contains:
```
[
  { txid: "abc...", readAt: 1699999999 },
  { txid: "def...", readAt: 1700000001 },
  ...
]
```

**Pros:** Fits immutable pattern, full read history
**Cons:** Complex, storage overhead, rarely needed

---

## Recommended Implementation

### Phase 1: Simple `ConversationState` (Option A)

1. **Add `ConversationState` record type** with fields above
2. **Update on read:** When user opens a conversation and marks messages as read
3. **Sync on app wake:** Fetch all `ConversationState` records for the account
4. **Handle conflicts:** Use last-read-wins by `lastReadBlockTime`
5. **Debounce writes:** 2-second debounce to batch rapid reads

### Phase 2: Add CloudKit Subscription

Subscribe to `ConversationState` changes in the account zone:

```swift
let subscription = CKQuerySubscription(
    recordType: "ConversationState",
    predicate: NSPredicate(format: "accountId == %@", accountId),
    options: [.firesOnRecordUpdate]
)

subscription.notificationInfo = CKSubscription.NotificationInfo()
subscription.notificationInfo?.shouldSendContentAvailable = true  // Silent push
```

When notification arrives, fetch updated `ConversationState` records and update local UI.

### Phase 3: Integrate with MessageEntry

Extend `MessageEntry` in segments with optional read info:

| Field       |  Type | Notes                                |
| ----------- | ----: | ------------------------------------ |
| txid        |  Data | (existing)                           |
| direction   |   Int | (existing)                           |
| senderTs    | Int64 | (existing)                           |
| **readAt**  | Int64 | 0 = unread, else Unix timestamp      |
| **readBy**  |  Data | deviceId that first read (optional)  |

This embeds read status in the segment payload, so new devices get full history on restore.

**Update flow:**
- When segment is created, `readAt = 0` for received messages
- When read, update local DB `readAt`
- Next segment flush includes updated `readAt` values
- OR: keep `readAt` only in `ConversationState` to avoid segment updates

---

## Local Core Data Schema Updates

### `CDConversation` (existing entity)

Add fields:

| Field                |   Type | Notes                              |
| -------------------- | -----: | ---------------------------------- |
| lastReadTxId         | String | txid of last read message          |
| lastReadBlockTime    |  Int64 | for ordering comparisons           |
| lastReadAt           |   Date | when marked as read locally        |
| cloudKitRecordName   | String | `conv.<conversationId>`            |
| cloudKitUpdatedAt    |   Date | server's updatedAt                 |

### `CDMessage` (existing entity)

Optionally add:

| Field   |  Type | Notes                       |
| ------- | ----: | --------------------------- |
| readAt  |  Date | when this message was read  |
| readBy  | String | deviceId that read it first |

---

## Calculating Unread Count

Instead of storing `unreadCount` directly, compute it:

```swift
func unreadCount(for conversation: Conversation) -> Int {
    let lastReadBlockTime = conversation.lastReadBlockTime ?? 0

    return conversation.messages.filter { msg in
        !msg.isOutgoing &&
        msg.blockTime > lastReadBlockTime
    }.count
}
```

**Benefits:**
- Always accurate (no stale count)
- No need to sync `unreadCount` field
- `lastReadBlockTime` is the single source of truth

**Cache:** Compute once on conversation load, invalidate on new messages or read status change.

---

## Edge Cases

### 1. Message read on device1 before it syncs to device2

- device1 reads message → `lastReadBlockTime = X`
- device2 doesn't have message yet (segment not synced)
- device2 syncs → sees message with `blockTime = X`
- Compare: `blockTime <= lastReadBlockTime` → already read ✓

### 2. New message arrives after read marker

- Current `lastReadBlockTime = 100`
- New message arrives with `blockTime = 150`
- `150 > 100` → message is unread ✓

### 3. User reads on both devices simultaneously

- device1: reads up to blockTime 200
- device2: reads up to blockTime 180
- Both upload `ConversationState`
- Conflict resolution: `200 > 180` → keep device1's marker
- device2 downloads → updates to blockTime 200 ✓

### 4. Device offline for extended period

- device1 offline, reads many messages
- Comes online → uploads `ConversationState` with latest read position
- Other devices sync → jump to current read position ✓

---

## Summary

| Aspect              | Recommendation                                    |
| ------------------- | ------------------------------------------------- |
| **Record type**     | `ConversationState` (one per conversation)        |
| **Conflict strategy** | Last-read-wins by `lastReadBlockTime`           |
| **Write frequency** | Debounce 2s, flush on app background              |
| **Sync trigger**    | App wake + CloudKit subscription                  |
| **Unread count**    | Compute from `lastReadBlockTime`, don't sync      |
| **Per-message read**| Optional, store in local DB only unless needed    |

This approach:
- ✅ Low CloudKit ops (~1 write per conversation when read, debounced)
- ✅ Handles conflicts gracefully
- ✅ Works across unlimited devices
- ✅ Supports offline usage
- ✅ Integrates with existing segment architecture

---

## Implementation Status (Phase 1 Complete)

**Implemented (Feb 2026):**

1. ✅ **Core Data schema updated** - Added `lastReadTxId`, `lastReadBlockTime`, `lastReadAt` fields to `CDConversation` entity
2. ✅ **ReadStatusSyncManager created** - New service with 2-second debounced writes
3. ✅ **ChatService integration** - `markConversationAsRead()` now tracks the last read message's blockTime and syncs via ReadStatusSyncManager
4. ✅ **Unread count computation** - When loading from store, unread count is computed from `lastReadBlockTime` if available
5. ✅ **App lifecycle integration** - Flushes pending updates on app background, syncs from CloudKit on app foreground
6. ✅ **Last-read-wins conflict resolution** - `updateReadStatus()` only updates if new blockTime > existing

**Files changed:**
- `KaChat/Services/MessageStore.swift` - Schema updates, read status methods
- `KaChat/Services/ReadStatusSyncManager.swift` - New file for debounced CloudKit sync
- `KaChat/Services/ChatService.swift` - Integration with read status tracking
- `KaChat/App/KaChatApp.swift` - Lifecycle hooks for sync

**How it works:**
1. User opens conversation → `markConversationAsRead()` called
2. Finds the latest incoming message's blockTime
3. Updates local Core Data immediately
4. Queues CloudKit sync (2s debounce)
5. On app background → flushes pending updates
6. On another device → CloudKit syncs via NSPersistentCloudKitContainer
7. On app foreground → refreshes from CloudKit, recomputes unread counts

**Pending (Phase 2):**
- CloudKit subscription for real-time read status updates (silent push)
- Per-message read tracking (optional)
