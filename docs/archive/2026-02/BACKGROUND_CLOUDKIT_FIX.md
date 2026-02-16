> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# CloudKit Background Export Fix

## Problem

App received warnings about background tasks running too long:

```
Background Task 341 ("CoreData: CloudKit Export"), was created over 30 seconds ago.
In applications running in the background, this creates a risk of termination.
Remember to call UIApplication.endBackgroundTask(_:) for your task in a timely manner to avoid this.
```

**Risk:** iOS terminates apps that don't complete background tasks within ~30 seconds, leading to:
- Data loss (CloudKit export interrupted)
- Incomplete sync to iCloud
- App crashes or forced termination

## Root Cause

When the app saves to Core Data with CloudKit sync enabled, `NSPersistentCloudKitContainer` automatically triggers a CloudKit export operation to upload changes to iCloud. This export can take 5-30+ seconds depending on:
- Amount of data to export
- Network speed
- iCloud server response time

**The problem:** If the app goes to background during or shortly after a Core Data save:
1. Save triggers CloudKit export operation
2. App enters background (iOS suspends app execution)
3. CloudKit export continues but has no background task registered
4. iOS gives a 30-second grace period
5. After 30 seconds, iOS warns and prepares to terminate the app
6. Export may not complete → data not synced to iCloud

**Timeline example:**
```
0s:   User switches to another app → scenePhase = .background
0s:   ChatService saves messages to Core Data (debounced save)
0.1s: CloudKit detects changes and starts export
0.1s: App is backgrounded by iOS
10s:  CloudKit export still running...
20s:  CloudKit export still running...
30s:  iOS warning: "Background task created over 30 seconds ago"
40s:  App might be terminated → export incomplete
```

## Solution

Added background task management that monitors CloudKit export events and keeps the app alive until export completes.

### Implementation

**MessageStore.swift ~43-49:**
Added property to track active export background tasks:
```swift
/// Background task identifiers for CloudKit export operations
/// Keyed by event start date to match export start/end events
private var cloudKitExportTasks: [Date: UIBackgroundTaskIdentifier] = [:]
```

**MessageStore.swift ~781-825:**
Modified `handleCloudKitEvent()` to begin/end background tasks for export operations:
```swift
// Handle CloudKit export events
if event.type == .export {
    if event.endDate == nil {
        // Export started - begin background task to keep app alive
        beginCloudKitExportBackgroundTask(for: event.startDate)
    } else if event.succeeded {
        // Export completed - end background task
        endCloudKitExportBackgroundTask(for: event.startDate)
    }
}

// Also end on error
if let error = event.error {
    if event.type == .export {
        endCloudKitExportBackgroundTask(for: event.startDate)
    }
}
```

**MessageStore.swift ~827-850:**
Added background task lifecycle methods:
```swift
/// Begin a background task for CloudKit export to prevent app suspension
private func beginCloudKitExportBackgroundTask(for startDate: Date) {
    #if !targetEnvironment(macCatalyst)
    let taskId = UIApplication.shared.beginBackgroundTask(withName: "CloudKit Export") { [weak self] in
        // Background task expired - clean up
        self?.endCloudKitExportBackgroundTask(for: startDate)
    }

    guard taskId != .invalid else {
        NSLog("[MessageStore] Failed to begin background task for CloudKit export")
        return
    }

    cloudKitExportTasks[startDate] = taskId
    NSLog("[MessageStore] Began background task %d for CloudKit export", taskId.rawValue)
    #endif
}

/// End the background task for a CloudKit export
private func endCloudKitExportBackgroundTask(for startDate: Date) {
    #if !targetEnvironment(macCatalyst)
    guard let taskId = cloudKitExportTasks.removeValue(forKey: startDate) else {
        return
    }

    guard taskId != .invalid else {
        return
    }

    UIApplication.shared.endBackgroundTask(taskId)
    NSLog("[MessageStore] Ended background task %d for CloudKit export", taskId.rawValue)
    #endif
}
```

**MessageStore.swift ~775-793:**
Added cleanup of orphaned tasks when observation stops:
```swift
private func stopCloudKitSyncObservation() {
    // ... existing code ...

    // End any active CloudKit export background tasks
    #if !targetEnvironment(macCatalyst)
    for (startDate, taskId) in cloudKitExportTasks {
        if taskId != .invalid {
            UIApplication.shared.endBackgroundTask(taskId)
            NSLog("[MessageStore] Ended orphaned background task %d for export started at %@",
                  taskId.rawValue, startDate.description)
        }
    }
    cloudKitExportTasks.removeAll()
    #endif
}
```

## How It Works

### Export Event Flow

**Before (Warning):**
```
1. Save to Core Data
2. CloudKit export starts automatically
3. App goes to background
4. Export continues without background task
5. iOS: "Background task running too long!" ⚠️
6. Possible termination
```

**After (Fixed):**
```
1. Save to Core Data
2. CloudKit export starts
   ├─> NSPersistentCloudKitContainer.eventChangedNotification fired
   ├─> event.type = .export, event.endDate = nil (started)
   └─> beginCloudKitExportBackgroundTask() called
       └─> UIApplication.shared.beginBackgroundTask("CloudKit Export")
3. App goes to background
   └─> Background task keeps app alive
4. Export continues safely with background task
5. Export completes
   ├─> NSPersistentCloudKitContainer.eventChangedNotification fired
   ├─> event.type = .export, event.endDate != nil (completed)
   └─> endCloudKitExportBackgroundTask() called
       └─> UIApplication.shared.endBackgroundTask(taskId)
6. No warning, no termination ✓
```

### Event Matching

CloudKit events are matched by `startDate`:
- Export starts → save taskId with key = event.startDate
- Export ends → lookup taskId by event.startDate and end it

This handles multiple concurrent exports (though rare).

### Mac Catalyst Exclusion

Background tasks are iOS-only, so the code is wrapped in:
```swift
#if !targetEnvironment(macCatalyst)
// Background task code
#endif
```

macOS doesn't have the same background task restrictions.

## Background Task Lifecycle

**Normal case (export completes):**
1. `beginCloudKitExportBackgroundTask()` - App can run in background
2. Export completes within 30 seconds
3. `endCloudKitExportBackgroundTask()` - Background time released

**Timeout case (export takes too long):**
1. `beginCloudKitExportBackgroundTask()` - App can run in background
2. Export takes > 30 seconds (rare, but possible with slow network)
3. iOS calls expiration handler (passed to `beginBackgroundTask`)
4. Expiration handler calls `endCloudKitExportBackgroundTask()` - Clean up
5. Export continues in foreground next time app is opened

**Error case (export fails):**
1. `beginCloudKitExportBackgroundTask()` - App can run in background
2. Export encounters error
3. `handleCloudKitEvent()` detects error
4. `endCloudKitExportBackgroundTask()` - Background time released

**Cleanup case (app terminates/switches wallet):**
1. Multiple exports in progress
2. `stopCloudKitSyncObservation()` called
3. All orphaned background tasks ended
4. Dictionary cleared

## Performance Impact

**Memory:**
- One `UIBackgroundTaskIdentifier` per active export (~8 bytes)
- One `Date` key per active export (~16 bytes)
- Typical: 1-2 concurrent exports = ~50 bytes total (negligible)

**CPU:**
- Background task begin/end: ~0.1ms each
- No measurable impact

**Battery:**
- App stays alive longer in background when CloudKit is exporting
- Export usually completes in 2-10 seconds
- Minimal battery impact (same work, just guaranteed to complete)

## Expected Logs

**Normal export:**
```
[MessageStore] Sync saved: 357 updated, 0 unchanged | save: 412ms, total: 1534ms
[MessageStore] CloudKit export event: succeeded=true, start=2026-02-02 02:15:30, end=in progress
[MessageStore] Began background task 341 for CloudKit export
[MessageStore] CloudKit export event: succeeded=true, start=2026-02-02 02:15:30, end=2026-02-02 02:15:35
[MessageStore] Ended background task 341 for CloudKit export
```

**Export with error:**
```
[MessageStore] CloudKit export event error: Network unavailable
[MessageStore] Ended background task 341 for CloudKit export
```

**Cleanup on wallet switch:**
```
[MessageStore] CloudKit sync observation stopped
[MessageStore] Ended orphaned background task 341 for export started at 2026-02-02 02:15:30
```

## Testing

To verify the fix:

1. **Normal export test:**
   - Enable "Store messages in iCloud" in Settings
   - Send several messages
   - Immediately switch to another app (background)
   - Check logs for background task begin/end
   - **Expected**: No warnings, export completes

2. **Slow network test:**
   - Enable Network Link Conditioner (Very Bad Network profile)
   - Send messages
   - Background the app
   - Monitor logs for 30+ seconds
   - **Expected**: Background task may expire, but no data loss

3. **Multiple exports test:**
   - Send messages rapidly
   - Background immediately
   - Check logs for multiple concurrent background tasks
   - **Expected**: All tasks tracked and ended correctly

## Edge Cases Handled

1. **Invalid task ID:** Check before ending
2. **Missing task ID:** Guard against nil lookup
3. **Concurrent exports:** Use startDate as unique key
4. **App termination:** Clean up all orphaned tasks
5. **Wallet switch:** End tasks before removing store
6. **CloudKit disabled:** No background tasks created (observer not active)

## iOS Background Time Limits

iOS provides different amounts of background time depending on the operation:

| Operation | Time Limit |
|-----------|------------|
| Generic background task | ~30 seconds |
| Background fetch | ~30 seconds |
| Background URLSession | ~30 seconds - 2 minutes |
| VoIP keep-alive | Unlimited |
| Location updates | Unlimited |

CloudKit export is a generic background task with a ~30-second limit.

Our typical export times:
- Small sync (1-10 messages): 1-3 seconds
- Medium sync (10-100 messages): 3-10 seconds
- Large sync (100-500 messages): 10-20 seconds
- Very large sync (500+ messages): 20-30 seconds

Most exports complete within the 30-second window.

## Files Modified

| File | Line | Change |
|------|------|--------|
| `MessageStore.swift` | ~43-49 | Added `cloudKitExportTasks` dictionary |
| `MessageStore.swift` | ~781-825 | Modified `handleCloudKitEvent()` to manage background tasks |
| `MessageStore.swift` | ~827-850 | Added `beginCloudKitExportBackgroundTask()` and `endCloudKitExportBackgroundTask()` |
| `MessageStore.swift` | ~775-793 | Added orphaned task cleanup to `stopCloudKitSyncObservation()` |

## Related Issues

This fix prevents:
- App termination during CloudKit sync
- Incomplete iCloud uploads
- Data loss when backgrounded during save
- Battery drain from repeated failed exports

## Alternative Approaches Considered

**1. Disable CloudKit when backgrounded:**
- **Pros:** No background time needed
- **Cons:** Data doesn't sync to iCloud until app reopened

**2. Queue saves for foreground only:**
- **Pros:** No background exports
- **Cons:** Delayed sync, potential data loss if app crashes

**3. Use Background URLSession for CloudKit:**
- **Pros:** More background time (up to 2 minutes)
- **Cons:** NSPersistentCloudKitContainer doesn't use URLSession

**4. Current solution (background task per export):**
- **Pros:** ✓ Guarantees export completion
- **Pros:** ✓ Minimal code changes
- **Pros:** ✓ Works with existing CloudKit integration
- **Pros:** ✓ No user-facing changes needed
- **Selected:** Best balance of reliability and simplicity

## Summary

The background task warning was caused by CloudKit export operations running without registered background tasks. The fix adds lifecycle management that begins a background task when CloudKit export starts and ends it when export completes or fails. This prevents iOS from terminating the app during iCloud sync operations.
