# Push Filter Persistence: Plan and Change Details

## Context
- Symptom: after indexer restart, push notifications were sent to all watched addresses without applying alias-based filtering.
- Root cause: alias and primary-address filters were stored only in in-memory caches and were not persisted/reloaded.

## Implemented Changes (Requested items 1-4)

### 1) Persist alias and primary filter fields
- Added fields to persisted registration model in `indexer/src/push.rs`:
  - `aliases: Vec<String>`
  - `primary_address: Option<String>`
- Added `#[serde(default)]` on both fields for backward compatibility with older DB rows.
- Reference: `indexer/src/push.rs:419`

### 2) Persist filter updates and tighten fast-path conditions
- `register(...)` now:
  - normalizes aliases and primary address first,
  - compares existing aliases/primary as part of fast-path eligibility,
  - writes normalized aliases/primary to `DeviceRegistration`.
- `update(...)` now does the same.
- This prevents alias/primary changes from being cache-only updates.
- References:
  - `indexer/src/push.rs:53`
  - `indexer/src/push.rs:74`
  - `indexer/src/push.rs:94`
  - `indexer/src/push.rs:171`
  - `indexer/src/push.rs:192`
  - `indexer/src/push.rs:206`

### 3) Rehydrate filter caches from DB on cache miss
- Added lazy hydration path for both checks:
  - `token_allows_alias(...)`
  - `token_primary_matches(...)`
- On cache miss, code loads persisted registration and repopulates caches via `hydrate_filter_caches(...)`.
- References:
  - `indexer/src/push.rs:339`
  - `indexer/src/push.rs:362`
  - `indexer/src/push.rs:409`

### 4) Preserve explicit filter semantics
- Alias semantics:
  - empty alias list means allow all aliases.
  - cache now stores explicit empty set marker.
- Primary semantics:
  - missing/invalid primary means no match for receiver-filtered pushes.
  - cache now stores explicit `None` marker.
- Added deterministic normalization helpers:
  - `normalize_aliases_vec(...)` (sorted aliases)
  - `normalize_primary_address(...)` (canonical address string)
- References:
  - `indexer/src/push.rs:385`
  - `indexer/src/push.rs:397`
  - `indexer/src/push.rs:896`
  - `indexer/src/push.rs:902`

## Previous Plan (as discussed)

1. Extend persisted registration model to include `aliases` and `primary_address`, with backward-compatible serde defaults.
2. Persist aliases/primary on every register/update write, and only use fast path when watched addresses + platform + aliases + primary + `last_seen` freshness are unchanged.
3. Rehydrate in-memory filter caches from DB after restart (at least on demand), so filtering works before clients re-register.
4. Keep explicit semantics:
   - alias empty => allow all aliases
   - primary missing => no receiver match for payment/handshake filtering
5. Add tests:
   - restart simulation preserves filtering,
   - update changes take effect,
   - old JSON rows without new fields still deserialize.
6. Rollout note:
   - existing already-persisted registrations without alias/primary cannot be inferred; clients should send `/v1/push/update` once after deploy.
7. Optional observability:
   - metric or debug endpoint for registrations with persisted alias/primary.
8. Staging validation:
   - verify non-matching alias blocked after restart,
   - verify matching alias delivered after restart.

## Current Status
- Items 1-4: implemented.
- Items 5-8: not implemented in code in this change set (still recommended).

## Follow-up Change (Refresh Write Debounce)
- Updated fast-path behavior for unchanged registration payloads:
  - keep skipping DB writes for identical payloads most of the time,
  - but force a heartbeat write when `last_seen` is stale.
- New staleness rule:
  - base: 3 days,
  - plus deterministic jitter: 24-72 hours (derived from device token + previous `last_seen`).
- Purpose:
  - preserve periodic liveness refresh for future stale-device pruning,
  - spread refresh writes to avoid synchronized client waves.
