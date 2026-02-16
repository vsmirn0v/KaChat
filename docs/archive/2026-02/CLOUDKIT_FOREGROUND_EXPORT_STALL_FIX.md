> Archived document (2026-02-12): historical context only. Current references are listed in `docs/README.md`.

# CloudKit Foreground Export Stall Fix

## Symptom

- In foreground, message send triggers repeated:
  - `Touched CloudKit export marker (view context)`
  - `Retrying CloudKit export (attempt 2/3)`
  - `CloudKit export retry exhausted`
- If app is backgrounded, export starts immediately and succeeds.

## Repro Pattern (Confirmed)

1. Cold app start.
2. First send often exports successfully.
3. Consecutive sends in foreground hit retry loop and exhaust.
4. Sending app to background immediately allows export to complete.

This pattern indicates app-side scheduling/trigger behavior, not CloudKit API exhaustion.

## Root Cause

Two trigger paths used `touchCloudKitExportMarker(useViewContext: true)`:

1. `kickCloudKitMirroringIfNeeded(reason:)`
2. `performCloudKitExport()` fallback path when `viewContext` had no changes

This bypassed the background-context marker path that also schedules a WAL checkpoint.  
Result: foreground touches could stay invisible to CloudKit export scheduling for long periods, while background lifecycle checkpointing made exports appear immediately.

## Fix

Switch both trigger paths to background marker touches:

- `touchCloudKitExportMarker(useViewContext: false)`

Also add a retry-exhaustion safety fallback:

- On `CloudKit export retry exhausted`, force `checkpointWAL()` and issue one more
  background-context marker touch.

Follow-up tuning for consecutive sends (same day):

- Reduced export minimum interval from 5s to 2s.
- Replaced aggressive 4s multi-retry marker loop with a slow single forced flush retry
  (12s delay, max 1 retry) to avoid foreground write churn.
- Retry action changed to one explicit `flushCloudKitExport()` instead of repeated marker writes.

### Code locations

- `KaChat/Services/MessageStore.swift`:
  - `kickCloudKitMirroringIfNeeded(reason:)`
  - `performCloudKitExport()` fallback branch
  - `scheduleCloudKitExportRetry(after:)` (retry behavior tuning)
  - constants:
    - `cloudKitExportMinInterval = 2.0`
    - `cloudKitExportRetryDelay = 12.0`
    - `cloudKitExportMaxRetries = 1`

## Why This Works

- Background marker path uses a background context and follow-up checkpoint behavior that reliably
  makes changes visible to CloudKit export machinery.
- Foreground retry storms (marker writes every few seconds) can keep local churn high while not
  producing observed export events in time.
- One forced flush retry is more deterministic than repeated marker touches.

## Expected Logs After Fix

- Foreground sends should primarily show:
  - `Touched CloudKit export marker (background context)`
  - `CloudKit export event: succeeded=false ... end=in progress`
  - `CloudKit export event: succeeded=true ...`
- Repeated sequences below should no longer appear in normal sends:
  - `Retrying CloudKit export (attempt 2)`
  - `Retrying CloudKit export (attempt 3)`
  - `CloudKit export retry exhausted`

## Regression Checklist

- If this regresses, verify these first:
  1. `kickCloudKitMirroringIfNeeded(reason:)` still uses `useViewContext: false`.
  2. `performCloudKitExport()` no-change fallback still uses `useViewContext: false`.
  3. Retry constants remain: min interval 2s, retry delay 12s, max retries 1.
  4. Retry path still calls `flushCloudKitExport()` (not repeated marker touches).
  5. Exhaustion safety fallback still does `checkpointWAL()` + one background marker touch.

## Notes

- Additional log spam (`CDX_AB_*`, `NSBundle(null)`, CoreData `134092`) was observed in the same
  sessions and can obscure diagnosis, but was not the direct cause of this CloudKit export stall.

## Verification signal

After fix, foreground logs should show background-marker path:

- `Touched CloudKit export marker (background context)`

and should no longer repeatedly show immediate retry exhaustion for normal sends.
