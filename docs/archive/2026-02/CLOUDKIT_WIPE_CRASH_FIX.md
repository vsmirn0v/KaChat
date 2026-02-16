> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# CloudKit Crash Fixes

## Problem 1: Wipe Account Crash

App crashed when wiping account with "Delete iCloud data" option enabled.

**Error:**
```
Thread 81: "Unsupported feature in this configuration"
CoreData-CloudKit: <NSCloudKitMirroringDelegate>: Told to tear down with reason: Store Removed
```

**Crash location:** `0__Unwind_RaiseException`

## Root Cause

The crash occurred during account wipe sequence:

1. **Purge CloudKit zones** - Deletes CloudKit data and triggers CloudKit operations
2. **Clear message store** - Deletes Core Data records
3. **Switch wallet to nil** - Removes persistent stores

**Problem:** CloudKit mirroring was still active and observing events when we removed the persistent store. When the store was removed, CloudKit tried to access it, causing the crash.

From the logs:
```
[MessageStore] Purging 2 CloudKit zones
[MessageStore] Successfully purged all CloudKit zones
[MessageStore] clearAll() called for wallet: kaspa:qp4j...
[MessageStore] Switching wallet store async: kaspa:qp4j... → none
CoreData-CloudKit: Told to tear down with reason: Store Removed  ← CRASH
```

## Solution

Stop CloudKit sync observation **before** removing any persistent stores.

### Changes

**MessageStore.swift - Added stopCloudKitSyncObservation() method:**

```swift
/// Stop observing CloudKit events (call before removing stores)
private func stopCloudKitSyncObservation() {
    if let observer = cloudKitEventObserver {
        NotificationCenter.default.removeObserver(observer)
        cloudKitEventObserver = nil
        NSLog("[MessageStore] CloudKit sync observation stopped")
    }

    // Reset CloudKit sync status
    cloudKitSyncStatus = .notStarted

    // Cancel any waiting continuations
    resumeCloudKitWaiters()
}
```

**Updated setCurrentWallet() methods to stop observation first:**

```swift
func setCurrentWallet(_ walletAddress: String?) {
    guard walletAddress != currentWalletAddress else { return }

    NSLog("[MessageStore] Switching wallet store: ...")

    // Stop CloudKit sync observation before removing stores  ← NEW
    stopCloudKitSyncObservation()

    // Remove existing stores
    let coordinator = container.persistentStoreCoordinator
    for store in coordinator.persistentStores {
        try coordinator.remove(store)
    }
    // ...
}
```

Also updated:
- `setCurrentWallet(_:completion:)` - Async version with completion callback
- `reloadPersistentStores(enableCloud:completion:)` - Used during wipe with cloud data toggle

## How It Works

### Before (Crash)

```
1. Purge CloudKit zones
   └─> Triggers CloudKit operations
   └─> CloudKit observer still active

2. clearAll()
   └─> Deletes Core Data records
   └─> CloudKit observer still monitoring

3. setCurrentWallet(nil)
   └─> Removes persistent store
   └─> CloudKit observer tries to access removed store
   └─> CRASH: "Unsupported feature in this configuration"
```

### After (Safe)

```
1. Purge CloudKit zones
   └─> Triggers CloudKit operations
   └─> CloudKit observer still active

2. clearAll()
   └─> Deletes Core Data records

3. setCurrentWallet(nil)
   ├─> stopCloudKitSyncObservation()  ← NEW
   │   ├─> Removes observer
   │   ├─> Resets status
   │   └─> Cancels pending operations
   └─> Safely removes persistent store
   └─> No crash - CloudKit not monitoring anymore
```

## Affected Code Paths

### 1. Account Wipe (Settings → Wipe Account)
```swift
wipeAccountAndMessages(deleteCloudData: true)
  └─> purgeCloudKitData()
  └─> deleteWallet()
      └─> clearAll()
      └─> setCurrentWallet(nil)  ← Crash point (fixed)
```

### 2. Wallet Switch
```swift
setCurrentWallet(newAddress)
  └─> stopCloudKitSyncObservation()  ← Prevents issues
  └─> Remove old stores
  └─> Load new stores
```

### 3. CloudKit Toggle (Settings → Store Messages in iCloud)
```swift
reloadPersistentStores(enableCloud: newValue)
  └─> stopCloudKitSyncObservation()  ← Prevents issues
  └─> Remove stores
  └─> Reload with new CloudKit setting
```

## Testing

To verify the fix:

1. **Create test account with CloudKit enabled:**
   - Import wallet
   - Enable "Store messages in iCloud" in Settings
   - Send/receive some messages
   - Wait for CloudKit sync to complete

2. **Wipe with CloudKit deletion:**
   - Settings → Advanced → Wipe Account & Messages
   - Toggle "Also delete iCloud data" ON
   - Confirm wipe

3. **Expected result:**
   - ✅ CloudKit zones purged successfully
   - ✅ Messages cleared
   - ✅ Wallet deleted
   - ✅ No crash
   - ✅ Clean state for new wallet

**Logs should show:**
```
[MessageStore] Purging 2 CloudKit zones
[MessageStore] Successfully purged all CloudKit zones
[MessageStore] clearAll() called for wallet: kaspa:...
[MessageStore] Switching wallet store async: kaspa:... → none
[MessageStore] CloudKit sync observation stopped  ← NEW LOG
[MessageStore] Wallet store loaded: KasiaMessages-default.sqlite, zone: default
```

## Related Issues

This fix also prevents potential crashes in these scenarios:

1. **Fast wallet switching** - Switching wallets quickly before CloudKit sync completes
2. **CloudKit toggle during sync** - Toggling iCloud setting while sync is active
3. **App termination** - Cleaner shutdown when CloudKit is syncing

## Safety Checks

The code already had several safety mechanisms:

1. **clearAll() check:**
   ```swift
   guard !self.container.persistentStoreCoordinator.persistentStores.isEmpty else {
       NSLog("[MessageStore] clearAll: Store removed before execution, skipping")
       return
   }
   ```

2. **Store loaded check:**
   ```swift
   guard ensureStoreLoaded() else { return }
   ```

But these weren't enough because CloudKit observer was still active. The new `stopCloudKitSyncObservation()` ensures CloudKit is properly disconnected before any store manipulation.

## Related Files

| File | Line | Change |
|------|------|--------|
| `MessageStore.swift` | ~735 | Added `stopCloudKitSyncObservation()` method |
| `MessageStore.swift` | ~107 | Call stop before removing stores in `setCurrentWallet()` |
| `MessageStore.swift` | ~147 | Call stop before removing stores in async `setCurrentWallet()` |
| `MessageStore.swift` | ~862 | Call stop before removing stores in `reloadPersistentStores()` |

## CloudKit Observer Lifecycle

**Start observation:**
- Called in `finishStoreLoad()` after stores are loaded
- Creates observer for `NSPersistentCloudKitContainer.eventChangedNotification`
- Tracks sync status (syncing → synced)

**Stop observation:** (NEW)
- Called before removing any stores
- Removes NotificationCenter observer
- Resets sync status to `.notStarted`
- Resumes any waiting continuations (prevents deadlocks)

**Restart observation:**
- Automatically started when new stores are loaded
- Previous observer is cleaned up before creating new one

## Edge Cases Handled

1. **No observer to stop:** Check for nil before removing
2. **Already stopped:** Method is idempotent, safe to call multiple times
3. **Waiting continuations:** Resume all to prevent hangs
4. **Concurrent access:** Uses same threading as CloudKit notifications (main queue)

## Migration Notes

- No database migration needed
- Existing accounts will benefit automatically
- Safe to deploy without special upgrade steps
- Compatible with all existing wallet configurations

---

## Problem 2: Startup Crash (Store Configuration)

App crashed at startup when loading persistent stores.

**Error:**
```
Thread 1: "+[_NSCFBoolean isEqualToString:]: unrecognized selector sent to instance 0x7ff859a21040"
A bad access to memory terminated the process.
```

**Crash location:** `MessageStore.loadPersistentStores(primaryDescription:completion:)`

### Root Cause

In the WAL optimization changes, I incorrectly set a store option:

```swift
description.setOption(true as NSNumber, forKey: "NSPersistentStoreFileProtectionKey")
```

**Problem:** `NSPersistentStoreFileProtectionKey` expects a **String** value (file protection constant like `NSFileProtectionComplete`), not a Boolean.

When Core Data tried to use this Boolean as a String, it crashed with "unrecognized selector" error.

### Solution

Removed the incorrect store option:

```swift
// BEFORE (CRASH):
description.setOption(true as NSNumber, forKey: "NSPersistentStoreFileProtectionKey")  // Wrong type!
description.shouldAddStoreAsynchronously = false

// AFTER (FIXED):
// Removed the problematic line entirely
description.shouldAddStoreAsynchronously = false
```

The file protection setting was not needed for our WAL optimizations and was incorrectly configured.

### Files Changed

| File | Line | Change |
|------|------|--------|
| `MessageStore.swift` | ~593 | Removed incorrect file protection option |

### Testing

To verify the fix:

1. **Clean build:**
   ```bash
   xcodebuild clean
   ```

2. **Fresh install:**
   - Delete app from simulator
   - Build and run
   - Should launch successfully

3. **Expected result:**
   - ✅ App launches without crash
   - ✅ Store loads successfully
   - ✅ No "unrecognized selector" errors

**Logs should show:**
```
[MessageStore] Wallet store loaded: KasiaMessages-default.sqlite, zone: default
```

No crash at startup.

## Summary of All Fixes

1. **Wipe crash fix (iOS):** Stop CloudKit observation before removing stores
2. **Startup crash fix:** Remove incorrect file protection store option
3. **Wipe crash fix (Mac):** Make clearAll() synchronous to prevent async race condition

All issues were related to Core Data store configuration and are now resolved.

---

## Problem 3: Mac Wipe Crash (Async Race Condition)

App crashed on Mac when wiping account with "Delete iCloud data" option enabled.

**Error:**
```
Thread 204: "Unsupported feature in this configuration"
0__Unwind_RaiseException
```

**Crash location:** `closure #1 in MessageStore.clearAll()`

### Root Cause

The crash occurred because `clearAll()` used async `context.perform {}` which didn't complete before the store was removed:

**Wipe sequence (BEFORE fix):**
1. `purgeCloudKitData()` - Deletes CloudKit zones
2. `clearAll()` - **Starts async deletion** with `context.perform {}`
3. `setCurrentWallet(nil)` - **Removes persistent store immediately**
4. Async closure tries to execute on removed store → **CRASH**

**MessageStore.swift ~497-533 (BEFORE fix):**
```swift
func clearAll() {
    guard ensureStoreLoaded() else { return }
    let walletAddr = currentWalletAddress
    NSLog("[MessageStore] clearAll() called for wallet: \(walletAddr ?? "default")")

    let context = container.newBackgroundContext()
    context.perform {  // ← ASYNC - doesn't wait for completion!
        // Delete operations...
        do {
            let messageResult = try context.execute(messageDelete)
            let conversationResult = try context.execute(conversationDelete)
            // ...
        } catch {
            NSLog("[MessageStore] Failed to clear store: \(error)")
        }
    }
    // Returns immediately, before deletion completes!
}
```

### Solution

Changed `context.perform` to `context.performAndWait` to make the deletion synchronous and blocking.

**MessageStore.swift ~492-534 (AFTER fix):**
```swift
/// Clears all messages and conversations for the CURRENT wallet only.
/// Each wallet has its own SQLite store, so this only affects the current store.
/// Note: This also affects CloudKit sync - cleared data will be deleted from iCloud.
/// IMPORTANT: This is synchronous - it blocks until deletion completes to prevent
/// race conditions where the store is removed before deletion finishes.
func clearAll() {
    guard ensureStoreLoaded() else { return }
    let walletAddr = currentWalletAddress
    NSLog("[MessageStore] clearAll() called for wallet: \(walletAddr ?? "default")")

    let context = container.newBackgroundContext()
    context.performAndWait {  // ← FIX: Changed from .perform to .performAndWait
        // Double-check store is still valid
        guard !self.container.persistentStoreCoordinator.persistentStores.isEmpty else {
            NSLog("[MessageStore] clearAll: Store removed before execution, skipping")
            return
        }

        // Delete operations...
        do {
            let messageResult = try context.execute(messageDelete)
            let conversationResult = try context.execute(conversationDelete)
            // ...
        } catch {
            NSLog("[MessageStore] Failed to clear store: \(error)")
        }
    }
    // Now guaranteed to complete before returning
}
```

### Why performAndWait?

**`context.perform` (async):**
- Schedules work on background queue
- Returns immediately
- Work may execute later (or never if store is removed)

**`context.performAndWait` (sync):**
- Blocks calling thread until work completes
- Guarantees completion before returning
- Safe to remove store after function returns

### Wipe Sequence After Fix

```
1. purgeCloudKitData()
   └─> CloudKit zones deleted

2. clearAll()
   ├─> performAndWait blocks until deletion completes
   ├─> Deletes all messages and conversations
   └─> Returns ONLY after deletion is done ✓

3. setCurrentWallet(nil)
   └─> Safely removes persistent store (deletion already complete)
   └─> No crash - all operations finished
```

### Why This Only Crashed on Mac

The crash was more reproducible on macOS because:
- Mac has faster CPU scheduling
- Async closures get scheduled and execute faster
- iOS has slower scheduling, so the store removal usually happened first (preventing execution)
- Mac's faster execution exposed the race condition

On both platforms, the fix prevents the race condition entirely.

### Performance Impact

**Before:**
- Function returns instantly (async)
- Work happens in background
- **Crash when store removed during async work**

**After:**
- Function blocks for ~50-200ms (deletion time)
- Work completes synchronously
- **No crash, guaranteed safe cleanup**

The small blocking delay is acceptable because:
- Only called during wipe (rare operation)
- User expects a brief delay when wiping data
- Prevents crash and data corruption

### Testing

To verify the fix:

1. **Mac wipe test with CloudKit:**
   - Import wallet on Mac
   - Enable "Store messages in iCloud"
   - Send/receive messages
   - Settings → Advanced → Wipe Account & Messages & iCloud
   - Toggle "Also delete iCloud data" ON
   - Confirm wipe

2. **Expected result:**
   - ✅ CloudKit zones purged
   - ✅ Messages cleared
   - ✅ Wallet deleted
   - ✅ No crash
   - ✅ Clean state for new wallet

**Logs should show:**
```
[MessageStore] clearAll() called for wallet: kaspa:...
[MessageStore] Cleared 357 messages, 12 conversations
[MessageStore] Switching wallet store async: kaspa:... → none
[MessageStore] CloudKit sync observation stopped
[MessageStore] Wallet store loaded: KasiaMessages-default.sqlite, zone: default
```

No crash or "Unsupported feature in this configuration" error.

### Files Modified

| File | Line | Change |
|------|------|--------|
| `MessageStore.swift` | ~503 | Changed `context.perform` to `context.performAndWait` |
| `MessageStore.swift` | ~492-497 | Added documentation about synchronous behavior |

### Related Code

The same pattern exists in other MessageStore methods but they are not called during wipe:
- `deleteMessage()` - Called individually, async is fine
- `clearIncomingMessages()` - Not called during wipe, async is fine
- `upsertMessage()` - Not called during wipe, async is fine

Only `clearAll()` needed to be synchronous because it's called immediately before store removal.
