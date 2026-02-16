> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Node Profiler Suspension Removed

## Change

Removed the node profiler pause/resume logic during message sync operations.

## What Was Removed

### ChatService.swift - fetchNewMessages()
**Before:**
```swift
await NodePoolService.shared.pauseProfilerForSync()
defer {
    Task { await NodePoolService.shared.resumeProfilerAfterSync() }
}
```

**After:**
```swift
// No profiler suspension - runs continuously
```

### NodePoolService.swift
**Removed:**
- `isProfilerPausedForSync` variable
- `pauseProfilerForSync()` function
- `resumeProfilerAfterSync()` function

## Rationale

**Original intent:** Pause node profiling/discovery during message sync to reduce CPU usage and network contention.

**Why it's no longer needed:**

1. **Batched message writes:** With the new Core Data batching optimization, message sync is now fast (2-5 seconds instead of 30-60 seconds)

2. **Node profiler is lightweight:**
   - Conservative mode: 60-second intervals
   - Minimal overhead: ~3-5 concurrent probes
   - Peer info check now runs once per epoch (not every probe)

3. **Network resources are independent:**
   - Profiler uses gRPC connections from the pool
   - Message sync uses indexer HTTP/REST API + same gRPC pool
   - They don't compete for the same connections

4. **Suspension breaks pool health:**
   - Stopping profiler means no latency monitoring during sync
   - Missing better node detection opportunities
   - Extra log noise: "Profiler paused" / "Profiler resumed"

5. **Sync is fast now:**
   - Full sync: 2-5 seconds for 357 messages
   - Poll sync: <1 second for incremental updates
   - Pausing profiler for such short durations provides no benefit

## Impact

**Before (with suspension):**
```
[ChatService] Fetching messages...
[NodePool] Profiler paused for sync
... (sync happens)
[NodePool] Profiler resumed after sync
```

Profiler stopped for 2-60 seconds during each sync cycle (every 10 seconds).

**After (without suspension):**
```
[ChatService] Fetching messages...
... (sync happens while profiler continues in background)
```

Profiler runs continuously, monitoring pool health and discovering better nodes.

## Benefits

1. **Continuous pool monitoring:** Latency stats always up to date
2. **Better node detection:** Won't miss opportunities during sync windows
3. **Simpler code:** Less state management, fewer edge cases
4. **Fewer logs:** No pause/resume noise
5. **No CPU savings needed:** Sync is fast, profiler is lightweight

## Testing

To verify profiler runs during sync:

1. **Check logs during sync:**
   ```
   [ChatService] Fetching messages...
   [NodeProfiler] Skipping peer info check for node1:16210 (already checked in epoch 5)
   [ChatService] Fetch complete
   ```

   Should see profiler logs interleaved with sync logs.

2. **Monitor CPU:**
   - Sync CPU usage should be the same (dominated by Core Data writes)
   - Profiler adds <5% CPU in conservative mode

3. **Pool health updates:**
   - `poolStats` should update continuously
   - No gaps in latency monitoring during sync

## Migration

No migration needed - profiler just keeps running.

If issues arise (unlikely), can re-add selective pausing with:
```swift
// Only pause for VERY long syncs (>30 seconds)
if isVeryLongSync {
    await NodePoolService.shared.profiler?.pause()
}
```

But with batched writes, syncs are never that long anymore.
