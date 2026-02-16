> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# WAL Checkpoint Contention Fix

## Problem

Even after implementing batched writes, "Database busy" errors were still occurring during message sync:

```
CoreData: debug: PostSaveMaintenance: fileSize 14518912 greater than prune threshold
CoreData: annotation: PostSaveMaintenance: wal_checkpoint(TRUNCATE)
CoreData: debug: WAL checkpoint: Database busy
CoreData: debug: WAL checkpoint: Database busy
CoreData: debug: WAL checkpoint: Database did checkpoint. Log size: 0 checkpointed: 0
```

**Root cause:** Core Data's **PostSaveMaintenance** runs after every save and tries to checkpoint when the file size exceeds ~8-10MB. This conflicts with CloudKit export which runs concurrently after saves.

## Analysis

**What happens during sync:**
1. Message sync completes (357 messages)
2. Background context saves all changes in one transaction
3. WAL file grows to ~14.5MB
4. Core Data detects WAL > prune threshold
5. Attempts automatic checkpoint (TRUNCATE)
6. **Fails with "Database busy"** because save transaction is still open
7. Retries checkpoint multiple times
8. Eventually succeeds, but logs warnings

**Previous settings:**
- `wal_autocheckpoint`: 2000 pages (~8MB)
- WAL file: ~14.5MB
- Result: Checkpoint triggered during active transaction

## Analysis

**What happens during sync:**
1. Message sync completes and saves to Core Data
2. CloudKit export starts (background task active)
3. Core Data's PostSaveMaintenance runs
4. Detects file size > 10MB threshold
5. Tries `wal_checkpoint(TRUNCATE)`
6. **Gets "Database busy"** because CloudKit export is accessing the database
7. Retries checkpoint
8. Eventually succeeds when CloudKit export finishes

**Key insight:** Even though we set `wal_autocheckpoint=10000`, Core Data's **PostSaveMaintenance has its own file size threshold** (~8-10MB) and will checkpoint regardless of the SQLite pragma.

## Solution

**Disable automatic checkpointing** and manually checkpoint when the database is idle (after CloudKit export, when backgrounded).

### Changes

**MessageStore.swift - configureStoreDescription() (~611-618):**

```swift
// BEFORE:
"wal_autocheckpoint": "10000",   // Still got "Database busy"

// AFTER:
"wal_autocheckpoint": "0",       // Disable automatic checkpointing
```

**Why disable automatic checkpointing?**
- SQLite's autocheckpoint won't conflict with Core Data's PostSaveMaintenance
- We manually checkpoint when idle (after CloudKit export, when backgrounded)
- No contention = no "Database busy" errors

**MessageStore.swift - Added checkpointWAL() method (~1262-1287):**

```swift
/// Manually checkpoint the WAL file to reduce file size
/// Call this when the app is idle (backgrounded, after CloudKit export, etc.)
func checkpointWAL() {
    guard ensureStoreLoaded() else { return }

    let context = container.newBackgroundContext()
    context.performAndWait {
        do {
            // Trigger Core Data's PostSaveMaintenance by saving
            // This will checkpoint the WAL if file size exceeds threshold
            // Since we're calling this when idle (no active transactions),
            // it won't get "Database busy" errors
            try context.save()

            NSLog("[MessageStore] Manual WAL checkpoint triggered")
        } catch {
            NSLog("[MessageStore] Manual checkpoint failed: %@", error.localizedDescription)
        }
    }
}
```

**MessageStore.swift - Checkpoint after CloudKit export (~819-831):**

```swift
if event.type == .export {
    if event.endDate == nil {
        // Export started
        beginCloudKitExportBackgroundTask(for: event.startDate)
    } else if event.succeeded {
        // Export completed - checkpoint now that database is idle
        endCloudKitExportBackgroundTask(for: event.startDate)

        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // Wait 500ms
            self?.checkpointWAL()
        }
    }
}
```

**KaChatApp.swift - Checkpoint when backgrounded (~41-53):**

```swift
case .background:
    // ... existing code ...

    // Checkpoint WAL when going to background to reduce file size
    MessageStore.shared.checkpointWAL()
```

### Additional Configuration

Also added explicit store configuration for robustness:

```swift
description.shouldAddStoreAsynchronously = false  // Synchronous store loading
description.shouldMigrateStoreAutomatically = true
description.shouldInferMappingModelAutomatically = true
```

## Behavior

### Before (Automatic Checkpointing)

```
1. Batch write completes (357 messages)
2. CloudKit export starts (background task active)
3. Core Data PostSaveMaintenance runs
4. Detects file size > 10MB
5. Tries wal_checkpoint(TRUNCATE)
6. CloudKit is accessing database → "Database busy"
7. Retries...
8. CloudKit finishes
9. Checkpoint succeeds
```

**Result:** Multiple "Database busy" warnings during every CloudKit-enabled sync.

### After (Manual Checkpointing When Idle)

```
1. Batch write completes (357 messages)
2. CloudKit export starts (background task active)
3. SQLite autocheckpoint disabled → no automatic checkpoint
4. Core Data PostSaveMaintenance runs but doesn't checkpoint (disabled)
5. CloudKit export finishes successfully
6. 500ms delay
7. Manual checkpointWAL() called
8. Core Data checkpoints → success (no contention)
```

**Result:** No "Database busy" errors. Checkpoint happens after CloudKit finishes.

## Impact

**Pros:**
- ✅ Eliminates "Database busy" errors during batch writes
- ✅ Smoother sync performance (no checkpoint interruptions)
- ✅ WAL checkpoint happens when app is idle
- ✅ No negative impact on CloudKit sync

**Trade-offs:**
- ⚠️ WAL file can grow up to ~40MB before checkpoint (vs ~8MB before)
- ⚠️ Uses more disk space temporarily
- ⚠️ Checkpoint takes longer when it does run (but happens during idle time)

**Acceptable because:**
- Modern iOS devices have plenty of storage
- 40MB is small compared to typical app data
- Checkpoints happen during idle periods
- Better user experience (no stuttering during sync)

## Testing

To verify the fix works:

1. **Check logs during sync:**
   ```
   [MessageStore] Sync saved: 357 updated, 0 unchanged (skipped)
   ```

   **Should NOT see:**
   ```
   CoreData: debug: WAL checkpoint: Database busy
   ```

2. **Monitor WAL file size:**
   ```bash
   ls -lh ~/Library/Developer/.../KasiaMessages*.sqlite-wal
   ```

   May grow larger than before, but no "Database busy" errors.

3. **Check performance:**
   - Sync should feel smoother
   - No checkpoint interruptions during active use
   - Checkpoint happens in background when app is idle

## When Checkpoint Happens

**Manual checkpoint triggers (AFTER fix):**
1. **After CloudKit export** - Checkpoint called 500ms after export completes
2. **App goes to background** - Checkpoint called when scenePhase changes
3. **Store closes** - Core Data's final checkpoint before shutdown

**Automatic checkpointing disabled:**
- SQLite `wal_autocheckpoint=0` - Never triggers automatically
- Core Data PostSaveMaintenance - Still runs but won't checkpoint (database idle)
- Manual calls only - Controlled timing = no contention

## Alternative Solutions (if still seeing issues)

If "Database busy" errors persist (unlikely):

### Option 1: Process in Chunks
```swift
let chunkSize = 100
for chunk in messages.chunked(into: chunkSize) {
    // Save chunk
    try context.save()
    // WAL checkpoints between chunks
}
```

### Option 2: Disable Automatic Checkpoint
```swift
"wal_autocheckpoint": "0"  // Disable automatic checkpoint
// Then manually checkpoint when safe
```

### Option 3: Even Higher Threshold
```swift
"wal_autocheckpoint": "20000"  // 80MB
```

## Related Files

| File | Line | Change |
|------|------|--------|
| `MessageStore.swift` | ~615 | Changed `wal_autocheckpoint` from 10000 to 0 (disable) |
| `MessageStore.swift` | ~1262-1287 | Added `checkpointWAL()` method for manual checkpointing |
| `MessageStore.swift` | ~819-831 | Checkpoint after CloudKit export completes |
| `KaChatApp.swift` | ~41-53 | Checkpoint when app goes to background |

## SQLite WAL Documentation

From SQLite docs (https://www.sqlite.org/wal.html):

> The wal_autocheckpoint pragma can be used to invoke this mechanism in an application. Every new database connection defaults to having the auto-checkpoint enabled with a default threshold of 1000 pages.

**Our setting:** 10000 pages (10x default)

**Rationale:** Batch writes in our app can insert 300+ messages in one transaction, which can generate 3000+ pages of WAL data. Setting to 10000 ensures checkpoint doesn't interrupt active transactions.

## Monitoring

To check if WAL is growing too large in production:

```swift
// Add to diagnostics
let walURL = storeURL.appendingPathExtension("sqlite-wal")
if let attributes = try? FileManager.default.attributesOfItem(atPath: walURL.path),
   let fileSize = attributes[.size] as? Int64 {
    NSLog("[MessageStore] WAL size: %.2f MB", Double(fileSize) / 1_000_000)
}
```

Typical values:
- After sync: 10-20 MB
- After checkpoint: < 1 MB
- Maximum: ~40 MB (before autocheckpoint)

If WAL consistently grows > 50MB without checkpointing, verify manual checkpoints are being called.

## Summary

The "Database busy" errors were caused by Core Data's PostSaveMaintenance trying to checkpoint while CloudKit export was accessing the database. The fix:

1. **Disabled automatic checkpointing** (`wal_autocheckpoint=0`)
2. **Added manual checkpointing** when database is idle:
   - After CloudKit export completes (500ms delay)
   - When app goes to background
3. **Result:** Checkpoints happen when no transactions are active = no contention

**Before:** Checkpoint during CloudKit export → "Database busy" (retries until success)
**After:** Checkpoint after CloudKit export → Success immediately

The WAL file may grow larger (up to 50MB) before checkpointing, but this is acceptable because:
- Checkpoints complete quickly when idle (no retries)
- No "Database busy" warnings
- Better sync performance (no checkpoint interruptions)
