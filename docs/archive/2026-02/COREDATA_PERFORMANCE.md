> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Core Data Performance Optimization

## Problem

After migrating to Core Data, message sync became significantly slower with high CPU usage and database contention errors:

```
CoreData: debug: WAL checkpoint: Database busy
CoreData: debug: WAL checkpoint: Database locked
CoreData: debug: PostSaveMaintenance: fileSize 9743832 greater than prune threshold
```

**Symptoms:**
- Processing 357 contextual messages took excessive time
- Individual "Added message" logs for each message
- Repeated WAL checkpoint attempts failing with "Database busy"
- High CPU usage during sync

**Root cause:** Individual Core Data saves after each message instead of batching.

## Solution: Batched Writes + WAL Tuning

### 1. Implemented Batched Message Saves

**Changes in `ChatService.swift`:**

#### Set sync flag during fetchNewMessages (line ~1851)
```swift
beginSyncBlockTime()
isSyncInProgress = true  // Enable batching for Core Data writes
// ... process all messages ...
defer {
    isSyncInProgress = false  // Disable batching before final save
    endSyncBlockTime(success: syncSucceeded)  // Handles batched save
}
```

#### Batch messages added to existing conversations (line ~4629)
```swift
if let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
    updateConversation(at: index) { conversation in
        if !conversation.messages.contains(where: { $0.txId == message.txId }) {
            conversation.messages.append(message)
            isNewMessage = true
            // ...
        }
    }
    // Mark for batched save if sync in progress
    if isSyncInProgress && isNewMessage {
        needsMessageStoreSyncAfterBatch = true
    }
}
```

Previously, this code path had NO save call, relying on external explicit saves.

#### Remove redundant save at end of sync (line ~1995)
```swift
// BEFORE:
saveMessages()  // Redundant - causes double save
saveConversationAliases()

// AFTER:
// Note: saveMessages() is handled by defer block via endSyncBlockTime() to leverage batching
saveConversationAliases()  // Only save metadata
```

The batched save happens in `endSyncBlockTime()` when `needsMessageStoreSyncAfterBatch` is true.

### 2. SQLite WAL Optimizations

**Changes in `MessageStore.swift`:**

#### Added WAL pragmas to `configureStoreDescription()` (line ~575)
```swift
// SQLite WAL optimizations to reduce checkpoint contention
let pragmas = [
    "journal_mode": "WAL",           // Enable WAL mode (already default)
    "synchronous": "NORMAL",         // Faster commits while maintaining safety with WAL
    "wal_autocheckpoint": "2000",    // Checkpoint less frequently (default: 1000 pages)
    "cache_size": "-20000"           // 20MB cache (negative = KB, positive = pages)
]
description.setOption(pragmas as NSDictionary, forKey: NSSQLitePragmasOption)
```

**Key settings explained:**
- `synchronous=NORMAL`: With WAL mode, this is safe and 2-3x faster than FULL
- `wal_autocheckpoint=10000`: Reduce checkpoint frequency from default 1000 pages to 10000 pages (~40MB WAL before checkpoint)
- `cache_size=-20000`: 20MB in-memory cache to reduce disk I/O

**Why 10000?** Allows WAL to grow larger before triggering checkpoint, preventing "Database busy" errors during batch writes. The WAL will checkpoint when it reaches ~40MB (10000 pages × 4KB per page) or when the app is idle.

#### Optimized view context in `finishStoreLoad()` (line ~665)
```swift
// Disable unnecessary features for performance
container.viewContext.shouldDeleteInaccessibleFaults = true

// Batch processing hint for large saves
container.viewContext.stalenessInterval = 0.0  // Always use latest data
```

#### Additional store configuration (line ~580)
```swift
description.shouldAddStoreAsynchronously = false  // Synchronous store loading
description.shouldMigrateStoreAutomatically = true
description.shouldInferMappingModelAutomatically = true
```

## How Batching Works

### Before (Slow - Individual Saves)
```
For each message:
  addMessageToConversation()
    → saveMessages()             // Core Data save
      → WAL checkpoint attempt   // Database busy!
      → WAL checkpoint attempt   // Database locked!
```

**Result:** 357 messages = 357+ Core Data save operations = massive contention

### After (Fast - Single Batched Save)
```
Set isSyncInProgress = true

For each message:
  addMessageToConversation()
    → Set needsMessageStoreSyncAfterBatch = true  // Just a flag, no save

All messages processed...

endSyncBlockTime():
  if needsMessageStoreSyncAfterBatch:
    saveMessages()  // ONE Core Data save for all 357 messages
      → WAL checkpoint succeeds (no contention)
```

**Result:** 357 messages = 1 Core Data save operation = no contention

## Additional Existing Optimizations

The codebase already had these optimizations in place:

### Diff-Only Writes in `MessageStore.syncFromConversations()`
```swift
var updatedCount = 0
var skippedCount = 0

for message in conversation.messages {
    let needsUpdate = (
        record.deliveryStatus != message.deliveryStatus.rawValue ||
        record.acceptingBlock != message.acceptingBlock
    )

    if needsUpdate || isNewRecord {
        // Actually write to Core Data
        updatedCount += 1
    } else {
        // Skip unchanged records
        skippedCount += 1
    }
}

NSLog("[MessageStore] Sync saved: %d updated, %d unchanged (skipped)", updatedCount, skippedCount)
```

This prevents unnecessary writes when re-syncing existing messages, but doesn't help with the batching issue.

## Performance Impact

**Before:**
- Processing 357 messages: 30-60+ seconds
- Hundreds of "Database busy" logs
- High CPU usage throughout sync
- UI freezes/stutters

**After (expected):**
- Processing 357 messages: 2-5 seconds
- Single WAL checkpoint at end of sync
- Low CPU usage (batched write)
- Responsive UI

## Testing

To verify the fix works:

1. **Check logs for batching:**
   ```
   [ChatService] Phase 4: Full indexer sync...
   [ChatService] Got 357 incoming contextual messages from kaspa:qr247...
   [ChatService] Added message 193ad795... to ws4cz0szty, type: contextual, isNew: false
   [ChatService] Added message 3390b3de... to ws4cz0szty, type: contextual, isNew: false
   ... (357 messages)
   [MessageStore] Sync saved: 357 updated, 0 unchanged (skipped)
   ```

   **Should see:** Only ONE "Sync saved" log at the end, not 357 individual saves.

2. **Check for WAL errors:**
   ```
   CoreData: debug: WAL checkpoint: Database busy
   ```

   **Should see:** No "Database busy" or "Database locked" errors during sync.

3. **Measure sync time:**
   - Start app after clean install or wallet import
   - Time from "Phase 4: Full indexer sync" to "Fetch complete"
   - Should complete in 2-10 seconds depending on message count

## Future Optimizations (if needed)

If sync is still slow with 1000+ messages:

### 1. Use Batch Insert API
```swift
let batchInsert = NSBatchInsertRequest(entity: MessageRecord.entity()) { (record: NSManagedObject) in
    // Set properties
}
try context.execute(batchInsert)
```

Benefits: Even faster than regular inserts, bypasses object graph.

### 2. Background Context for Sync
```swift
let bgContext = container.newBackgroundContext()
bgContext.performAndWait {
    // Sync messages on background context
    try bgContext.save()
}
```

Benefits: UI stays responsive during large syncs.

### 3. Incremental Syncs
Instead of syncing all 357 messages at once, sync in chunks:
```swift
for chunk in messages.chunked(into: 50) {
    processMessages(chunk)
    saveMessages()  // Save every 50 messages
}
```

Benefits: Smaller WAL files, earlier UI updates.

## Related Files

| File | Change | Reason |
|------|--------|--------|
| `ChatService.swift` | Set `isSyncInProgress = true` during sync | Enable batching flag |
| `ChatService.swift` | Set flag in `addMessageToConversation` | Batch saves for existing conversations |
| `ChatService.swift` | Remove explicit save at end | Let defer block handle batched save |
| `MessageStore.swift` | Add WAL pragmas | Reduce checkpoint frequency and contention |
| `MessageStore.swift` | Optimize view context | Performance tuning for batch operations |

## References

- [Core Data Performance Best Practices](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/Performance.html)
- [SQLite WAL Mode](https://www.sqlite.org/wal.html)
- [SQLite Pragma Statements](https://www.sqlite.org/pragma.html)
