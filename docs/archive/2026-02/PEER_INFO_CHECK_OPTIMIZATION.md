> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Peer Info Check Optimization

## Problem

The peer info check (`getConnectedPeerInfo` RPC) was being called multiple times for the same nodes, causing unnecessary network overhead and latency.

**Symptoms:**
- Same nodes showing peer info check logs repeatedly
- Redundant 10-20KB payload transfers for DPI validation
- Increased probe latency due to unnecessary checks

**Example logs (before fix):**
```
[NodeProfiler] Peer info check passed for node1:16210 (15234 bytes, 42 peers)
... (10 seconds later, same node probed again)
[NodeProfiler] Peer info check passed for node1:16210 (15234 bytes, 42 peers)
... (60 seconds later, same node probed again)
[NodeProfiler] Peer info check passed for node1:16210 (15234 bytes, 42 peers)
```

## Root Cause

The peer info check in `probeNode()` was running unconditionally on every probe cycle (10s aggressive, 60s conservative). This meant:

- Active nodes: Checked every 60s (conservative mode)
- Verified nodes: Checked every probe when being promoted
- Candidate nodes: Checked every probe during evaluation

The check was designed to detect DPI-blocked nodes (Deep Packet Inspection that blocks large payloads), but once a node passes, there's no need to repeat the check until the network path changes.

## Solution

**Track peer info checks per epoch:**

1. Added `peerInfoEpochId` field to `NodeProfile` to track which epoch the check was performed in
2. Modified `probeNode()` to skip peer info check if already performed in current epoch
3. When network epoch changes (WiFi ↔ cellular, VPN, etc.), the check can run again

### Code Changes

**NodeModels.swift - Added epoch tracking:**
```swift
struct NodeProfile: Codable {
    // DPI / payload check (GetConnectedPeerInfo)
    var peerInfoOk: Bool?                 // Passed connected peer info check
    var peerInfoCheckedAt: Date?          // Last time peer info was checked
    var peerInfoSampleBytes: Int?         // Size of last peer info response (bytes)
    var peerInfoEpochId: Int?             // Epoch when peer info was last checked ← NEW
    // ...
}
```

**NodeProfiler.swift - Check only once per epoch:**
```swift
// DPI check: Request connected peer info (10-20KB payload)
// This detects DPI-blocked nodes where large transfers fail
// Only run once per epoch to avoid redundant checks
let currentEpochId = await MainActor.run { epochMonitor.epochId }
let existingRecord = await registry.get(endpoint)
let alreadyCheckedInEpoch = existingRecord?.profile.peerInfoEpochId == currentEpochId

// Skip check if already performed in this epoch
if !alreadyCheckedInEpoch {
    // Run peer info check...
    await registry.updateProfile(endpoint) { profile in
        profile.peerInfoOk = peerInfoOk
        profile.peerInfoCheckedAt = Date()
        profile.peerInfoSampleBytes = peerInfoBytes
        profile.peerInfoEpochId = currentEpochId  // ← Track epoch
    }
} else {
    NSLog("[NodeProfiler] Skipping peer info check for %@ (already checked in epoch %d)",
          endpoint.key, currentEpochId)
}
```

## Behavior

### Before Fix

**Same node probed 10 times in 10 minutes:**
- Probe 1 (0:00): getInfo ✓, getBlockDagInfo ✓, getPeerInfo ✓ (15KB)
- Probe 2 (1:00): getInfo ✓, getBlockDagInfo ✓, getPeerInfo ✓ (15KB) ← redundant
- Probe 3 (2:00): getInfo ✓, getBlockDagInfo ✓, getPeerInfo ✓ (15KB) ← redundant
- ... 7 more redundant peer info checks

**Total overhead:** 10 × 15KB = 150KB transferred, 10 × 200ms = 2 seconds wasted

### After Fix

**Same node probed 10 times in 10 minutes (same epoch):**
- Probe 1 (0:00): getInfo ✓, getBlockDagInfo ✓, getPeerInfo ✓ (15KB) [epoch 5]
- Probe 2 (1:00): getInfo ✓, getBlockDagInfo ✓, skip getPeerInfo (already checked)
- Probe 3 (2:00): getInfo ✓, getBlockDagInfo ✓, skip getPeerInfo (already checked)
- ... 7 more probes skip peer info check

**Total overhead:** 1 × 15KB = 15KB transferred, 1 × 200ms = 200ms latency

**Savings:** 135KB and 1.8 seconds per node per 10-minute window

### Network Epoch Change

**When network path changes (WiFi → cellular):**
- Epoch increments from 5 to 6
- Next probe: getInfo ✓, getBlockDagInfo ✓, getPeerInfo ✓ [epoch 6]
- Check runs again because DPI behavior may differ on new network path

## When Peer Info Check Runs

| Scenario | Check Runs? | Reason |
|----------|-------------|--------|
| First probe of new node | ✅ Yes | `peerInfoEpochId` is nil |
| Re-probe same node (same epoch) | ❌ No | Already checked in epoch 5 |
| Re-probe after epoch change | ✅ Yes | Epoch 5 → 6, check needed for new network |
| Active node re-probed | ❌ No | Already checked in current epoch |
| Verified node promoted to active | ❌ No | Already checked when first probed |
| Candidate node evaluated | ✅ Yes (first time) | Needs DPI check before promotion |

## Performance Impact

**Typical pool with 20 active nodes, 60s probe interval:**

**Before:**
- 20 nodes × 1 peer info check/minute = 20 checks/minute
- 20 × 15KB = 300KB/minute
- 20 × 200ms = 4 seconds/minute spent on redundant checks

**After:**
- 20 nodes × 0 redundant checks = 0 checks/minute (after initial)
- New nodes still get checked on first probe
- Network change triggers re-check (appropriate)

**Savings:** ~300KB/minute and ~4s/minute of unnecessary work

## Expected Logs

**New node first probe:**
```
[NodeProfiler] Peer info check passed for node1:16210 (15234 bytes, 42 peers)
```

**Same node re-probed (same epoch):**
```
[NodeProfiler] Skipping peer info check for node1:16210 (already checked in epoch 5)
```

**After network change (epoch increment):**
```
[NodeProfiler] Peer info check passed for node1:16210 (14892 bytes, 39 peers)
```

## Related Code

| File | Line | Function | Purpose |
|------|------|----------|---------|
| `NodeModels.swift` | ~173 | `NodeProfile` | Added `peerInfoEpochId` field |
| `NodeProfiler.swift` | ~517 | `probeNode()` | Conditional peer info check logic |
| `NetworkEpochMonitor.swift` | - | - | Provides epoch ID that increments on network changes |

## Testing

To verify the optimization:

1. **Check logs for skipped checks:**
   ```bash
   grep "Skipping peer info check" logs.txt
   ```
   Should see multiple skip messages for same nodes

2. **Verify check after epoch change:**
   - Toggle airplane mode on/off
   - Check logs show epoch increment
   - Next probe should run peer info check

3. **Monitor bandwidth:**
   - Before: ~300KB/minute for 20 nodes
   - After: ~15KB/minute (only new nodes)

## Migration Notes

- No database migration needed (new field is optional)
- Existing nodes will have `peerInfoEpochId = nil`, triggering check on next probe
- After first probe in current epoch, field is set and checks are skipped
- Compatible with persisted node data from previous versions
