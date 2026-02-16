> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Background Fetch Optimization Notes (Kasia iOS)

## Current background fetch behavior
`BackgroundTaskManager` schedules a BGAppRefresh task and calls:
- `ChatService.shared.fetchNewMessages()`

### Cursor behavior update (implemented after this note was archived)

Message/handshake sync now uses per-object cursors instead of only a single global lookback:
- Each sync object tracks `lastFetchedBlockTime` (for example, handshake in/out and contextual alias in/out)
- If the object's last fetched block is within 10 minutes of the current sync, requests rewind by 10 minutes (reorg buffer)
- If older than 10 minutes, requests start at `lastFetchedBlockTime + 1` (inclusive cursor safe, avoids re-fetching old windows)
- `lastPollTime` remains a fallback for first fetches and migration cases

That method performs a full sync, including:
- **Indexer calls**
  - Handshakes: incoming + outgoing
  - Self-stash saved handshakes
  - Contextual messages for **all** known aliases (incoming + outgoing)
- **Kaspa REST API calls**
  - Full transaction pagination for payments
  - Transaction resolution for unknown senders (via `/transactions/{txId}?resolve_previous_outpoints=light`)

This is heavy for BGAppRefresh and can cause iOS to throttle or stop scheduling fetches.

## Optimization options

### Option A — Lightweight background sync
Introduce a background mode for `fetchNewMessages` that only:
- Fetches contextual messages
- Skips payments, handshakes, and self‑stash

### Option B — Limit alias fan‑out
For background mode:
- Fetch only the N most recent conversations (e.g., 5–10)
- Or stop after a time budget (e.g., 8–10s) and resume on next fetch

### Option C — Skip background fetch when realtime is active
If UTXO subscription or push notifications are active, skip background fetch entirely.

### Option D — Increase requested refresh interval
Current interval is 60s; iOS ignores such aggressive scheduling. Consider 15–30 minutes to improve reliability.

## Suggested next implementation
- Add `fetchNewMessages(mode: .background)` or `fetchNewMessagesLight()`
- Background mode:
  - Skips payments + handshakes + self‑stash
  - Limits alias count (N configurable)
  - Stops on task expiration
- Optionally skip if UTXO/push is active
- Increase `refreshInterval` to a saner value (15–30 min)
