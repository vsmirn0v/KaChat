# Documentation Index

This repository contains a mix of active reference docs and historical implementation notes.

## Canonical (Current)

- `CLAUDE.md` - project architecture and coding guidance.
- `SECURITY_AUDIT.md` - security findings and current mitigation status.
- `MESSAGING.md` - messaging and payment protocol behavior.
- `POOLS_v2.md` - current node pool architecture reference.
- `PUSH_NOTIFICATIONS.md` - push notification design and app/indexer flow.
- `PUSH_SECURITY_AUDIT.md` - push service threat model and hardening plan.
- `DETERMINISTIC_ALIASES.md` - deterministic alias migration and compatibility notes.
- `GIFT.md` - 1 KAS gift flow and constraints.
- `MACOS_NOTIFICATION_LIMITATION.md` - platform-specific notification caveats.
- `CLOUDKIT_IMPROVEMENT_v2.md` - CloudKit/read-status design reference.

## Archived (Historical)

Historical docs were moved to `docs/archive/2026-02/` to keep root docs focused on active behavior:

- `BACKGROUND_CLOUDKIT_FIX.md`
- `BATCH_FETCH_OPTIMIZATION.md`
- `BGFETCH.md`
- `CLOUDKIT_CONTACTS_PLAN.md`
- `CLOUDKIT_IMPROVEMENT_SUGGESTIONS.md`
- `CLOUDKIT_IMPROVEMENT_v2_SUGGESTIONS.md`
- `CLOUDKIT_SYNC_IMPROVEMENT_PLAN.md`
- `CLOUDKIT_FOREGROUND_EXPORT_STALL_FIX.md` - foreground-only CloudKit export stall incident, final retry/flush tuning.
- `CLOUDKIT_WIPE_CRASH_FIX.md`
- `CONSOLE_WARNINGS.md`
- `COREDATA_PERFORMANCE.md`
- `FALLBACK_POLLING_OPTIMIZATION.md`
- `GHOST_PAYMENTS.md`
- `GHOST_PAYMENT_FIX.md`
- `PEER_INFO_CHECK_OPTIMIZATION.md`
- `POOLS.md`
- `POOLS_v2_IMPROVEMENTS.md`
- `PROFILER_SUSPENSION_REMOVED.md`
- `UNREAD_COUNTER_FIX.md`
- `WAL_CHECKPOINT_FIX.md`

Archived documents are kept for context and postmortem history; they are not source-of-truth for current behavior.
