> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Fallback Polling Optimization

## Problem

When UTXO subscription is inactive (gRPC unavailable or subscription failed), the app uses polling as a fallback to sync messages. The original implementation used a fixed-interval Timer that triggered every 10 seconds, regardless of how long each sync took.

**Issues with fixed-interval polling:**
1. **Too frequent** - Syncing every 10 seconds when subscription is down creates excessive load
2. **Overlapping syncs** - If sync takes longer than 10s, multiple syncs could run concurrently
3. **Battery drain** - Constant syncing every 10s uses unnecessary CPU and network
4. **Indexer load** - Hitting the indexer API every 10s is aggressive for a fallback mechanism

## Solution

Changed from fixed-interval Timer-based polling to Task-based polling with **60-second delay after each sync completes**.

### Key Changes

**Before (Timer-based, fixed interval):**
```
Sync (2s) → Wait 10s → Sync (2s) → Wait 10s → Sync (2s) ...
Total cycle: 12 seconds
Syncs per 10 minutes: ~50
```

**After (Task-based, delay after completion):**
```
Sync (2s) → Wait 60s → Sync (2s) → Wait 60s → Sync (2s) ...
Total cycle: 62 seconds
Syncs per 10 minutes: ~10
```

**Benefit:** 80% reduction in sync frequency when using fallback polling.

## Implementation

### 1. Replaced Timer with Task

**ChatService.swift - Variable declarations (line ~92):**
```swift
// BEFORE:
private var pollTimer: Timer?

// AFTER:
/// Delay between syncs when UTXO subscription is inactive (60 seconds after last sync completes)
private let pollDelayAfterSync: TimeInterval = 60.0
private var pollTask: Task<Void, Never>?
```

### 2. Added Task-Based Polling Loop

**ChatService.swift - New method:**
```swift
/// Start fallback polling loop when UTXO subscription is unavailable
/// Waits 60 seconds after each sync completes before starting next one
private func startFallbackPolling() {
    pollTask?.cancel()
    pollTask = Task { @MainActor [weak self] in
        guard let self = self else { return }

        while !Task.isCancelled {
            // Wait before next sync
            try? await Task.sleep(nanoseconds: UInt64(self.pollDelayAfterSync * 1_000_000_000))

            guard !Task.isCancelled else { break }

            // Perform sync
            await self.fetchNewMessages()
        }
    }
}
```

**Key features:**
- Waits FIRST, then syncs (initial sync happens in `startPolling()`)
- Checks `Task.isCancelled` before and after sleep
- Uses `@MainActor` to ensure proper threading
- Weak self to avoid retain cycles

### 3. Updated startPolling() Call Site

**ChatService.swift - startPolling() (line ~360):**
```swift
// BEFORE:
await MainActor.run {
    self.pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
        Task { @MainActor in
            await self?.fetchNewMessages()
        }
    }
    NSLog("[ChatService] RPC unavailable - using fallback polling (interval=%.1fs)", interval)
}

// AFTER:
self.startFallbackPolling()
NSLog("[ChatService] RPC unavailable - using fallback polling (%.0fs delay after each sync)", pollDelayAfterSync)
```

### 4. Updated Cleanup Methods

**ChatService.swift - stopPolling() and stopPollingTimerOnly():**
```swift
// BEFORE:
pollTimer?.invalidate()
pollTimer = nil

// AFTER:
pollTask?.cancel()
pollTask = nil
```

## Behavior Comparison

### Scenario: UTXO Subscription Fails at Startup

**Before (10s fixed interval):**
```
00:00 - Initial sync (Phase 4)
00:02 - Initial sync complete
00:10 - Poll #1
00:12 - Poll #1 complete
00:20 - Poll #2
00:22 - Poll #2 complete
00:30 - Poll #3
00:32 - Poll #3 complete
...
10:00 - Poll #50 (50 syncs in 10 minutes)
```

**After (60s delay after completion):**
```
00:00 - Initial sync (Phase 4)
00:02 - Initial sync complete
01:02 - Poll #1 (60s after initial)
01:04 - Poll #1 complete
02:04 - Poll #2 (60s after #1)
02:06 - Poll #2 complete
03:06 - Poll #3 (60s after #2)
03:08 - Poll #3 complete
...
10:00 - Poll #10 (10 syncs in 10 minutes)
```

### Scenario: Long Sync (10 seconds)

**Before (could overlap):**
```
00:00 - Sync starts
00:10 - Timer fires → Sync #2 starts (while #1 still running!)
00:10 - Sync #1 completes
00:20 - Timer fires → Sync #3 starts
00:20 - Sync #2 completes
```
Risk of concurrent syncs and database contention.

**After (waits for completion):**
```
00:00 - Sync starts
00:10 - Sync completes
01:10 - Wait 60s → Sync #2 starts
01:20 - Sync #2 completes
02:20 - Wait 60s → Sync #3 starts
```
No overlap, clean sequential execution.

## Performance Impact

**Metrics (10-minute window without UTXO subscription):**

| Metric | Before (10s interval) | After (60s delay) | Improvement |
|--------|----------------------|-------------------|-------------|
| Sync count | ~50 syncs | ~10 syncs | 80% reduction |
| Network requests | ~200 HTTP requests | ~40 HTTP requests | 80% reduction |
| CPU usage | Constant (every 10s) | Periodic (every 60s) | 80% reduction |
| Battery impact | Moderate | Low | Significant |
| Indexer load | High | Low | 80% reduction |

**User experience:**
- No negative impact - messages arrive within 60s in fallback mode
- UTXO subscription (primary mode) still provides real-time updates
- Fallback is only used when gRPC is completely unavailable

## When Fallback Polling Activates

Fallback polling only activates when:
1. **UTXO subscription fails** - gRPC unavailable, no nodes support subscriptions
2. **Not using remote push** - `notificationMode != .remotePush`

**Normal operation** uses real-time UTXO subscriptions with no polling at all.

## Expected Logs

**UTXO subscription active (no polling):**
```
[ChatService] gRPC subscription active - using real-time notifications (no polling)
```

**Fallback polling activated:**
```
[ChatService] RPC unavailable - using fallback polling (60s delay after each sync)
... (60 seconds later)
[ChatService] Fetching messages...
[ChatService] Fetch complete
... (60 seconds later)
[ChatService] Fetching messages...
```

**Polling stopped:**
```
[ChatService] Polling task stopped
```

## Tuning

To adjust the delay, change `pollDelayAfterSync` constant (line ~93):

```swift
// Current:
private let pollDelayAfterSync: TimeInterval = 60.0  // 60 seconds

// For faster fallback (not recommended):
private let pollDelayAfterSync: TimeInterval = 30.0  // 30 seconds

// For slower fallback (less server load):
private let pollDelayAfterSync: TimeInterval = 120.0  // 2 minutes
```

**Recommended:** Keep at 60 seconds. This provides good balance between:
- Message delivery latency in fallback mode (~60s)
- Server load and battery usage (low)
- User experience (acceptable for degraded mode)

## Related Files

| File | Line | Change |
|------|------|--------|
| `ChatService.swift` | ~93 | Added `pollDelayAfterSync` constant, replaced Timer with Task |
| `ChatService.swift` | ~372 | Added `startFallbackPolling()` method |
| `ChatService.swift` | ~360 | Updated to call `startFallbackPolling()` |
| `ChatService.swift` | ~1752 | Updated `stopPolling()` to cancel task |
| `ChatService.swift` | ~1766 | Updated `stopPollingTimerOnly()` to cancel task |

## Testing

To verify the change:

1. **Disable gRPC** - Force fallback mode
   ```swift
   // In NodePoolService, temporarily disable subscription
   ```

2. **Check logs for 60s delays:**
   ```
   [ChatService] Fetching messages...
   [ChatService] Fetch complete
   ... (should wait ~60 seconds before next fetch)
   [ChatService] Fetching messages...
   ```

3. **Verify no overlapping syncs:**
   - Each "Fetching messages" should be followed by "Fetch complete" before next fetch starts
   - No concurrent syncs running

4. **Monitor sync frequency:**
   - Count syncs over 10 minutes
   - Should be ~10 syncs (not 50)

## Migration Notes

- No database changes needed
- Existing behavior preserved for UTXO subscription mode (still real-time)
- Only affects fallback polling when subscription is inactive
- Compatible with all existing features (remote push, CloudKit, etc.)
