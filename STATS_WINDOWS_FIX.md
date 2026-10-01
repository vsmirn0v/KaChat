# KaChat Stats: 24h / 7d counts for the chat categories (server ask)

Short handoff for the kachat-indexer. Background: [STATS_INDEXER.md](STATS_INDEXER.md) is the
full `/stats` contract; this file is only the one gap.

## The problem

Kaspa Hub > KaChat Stats has 24 Hours / 7 Days / All Time tabs. The live response
(`GET https://kachat.duckdns.org/stats`, 2026-09-30) sends rolling windows for the content-side
categories but **only `total`** for the six chat-side ones:

```json
"messages":      {"total": 771263},
"handshakes":    {"total": 4466},
"payments":      {"total": 1332},
"groupMessages": {"total": 3211},
"groupUpdates":  {"total": 1725},
"selfStash":     {"total": 2785},
"kaposts":       {"last24h": 24, "last7d": 251, "total": 2595}
```

So on the 24 Hours and 7 Days tabs those six show a dash, and the app labels them "All-time
only" and leaves them out of the headline total. Direct messages are about 98% of all traffic,
so the 24h/7d totals are badly understated until this is fixed.

## Where it comes from

Commit `68706a5` ("stats: GET /stats reports transaction counts by category"):

- `kasia-indexer/indexer/src/api/v1/export.rs` - `get_stats` builds the chat slice from
  `approximate_len()` of the `tx-id-to-*` partitions (`tx-id-to-contextual-message`,
  `tx-id-to-handshake`, `tx_id_to_payment`, `tx-id-to-group-message`, `tx-id-to-group-control`,
  `tx-id-to-self-stash`). A length has no time in it, so it can only give all-time totals.
- `kachat-webserver/src/web_server.rs` - `build_kachat_stats` fetches
  `127.0.0.1:8600/stats` (`CHAT_STATS_URL`) and merges its categories in as-is. **No webserver
  change is needed**: whatever fields the chat indexer adds pass straight through.

Work from `origin/main`. The `~/kachat-indexer` checkout on the Mac has diverged from it (213
commits ahead, 254 behind).

## The ask

Add `last24h` and `last7d` to each of those six categories in the chat indexer's `/stats`,
keeping `total` exactly as it is. Windows are by **accepted block time**: `last24h` = block time
after now-24h, `last7d` = after now-7d.

Suggested approach (your call - you know the store):

1. **Periodic scan, cached.** A background task (every ~5 min, in `spawn_blocking`) walks, for
   each category, one partition that has **exactly one row per transaction and carries its block
   time**, and counts the rows newer than the two cutoffs. `get_stats` returns the last cached
   counts and never scans on the request path. For example, `contextual_message_by_sender` keys
   are `sender | alias | block_time (u64 BE) | block_hash | receiver | version | tx_id`. It is
   sorted by sender, so a time window means a full key walk. That's fine: about 0.8M fixed-size
   keys, decode only the `block_time` field.
2. **Or, longer term:** a small time-ordered index (`block_time BE | category | tx_id`) written
   at insert time and backfilled once. A window count is then just a range scan from the cutoff.

Things to check while doing it:

- **Don't double count.** The partition you scan must give one row per tx. Contextual messages
  are first stored with a zero sender until it is resolved. Make sure a resolved message isn't
  then present under both the zero and the real sender. The windows should agree with `total`'s
  idea of a message, and `last24h <= last7d <= total` must always hold.
- **Units.** Make sure the stored `block_time` and your cutoffs use the same unit (Kaspa block
  timestamps are milliseconds).
- **Omit, don't zero.** If the windows aren't computed yet (cache still warming after a
  restart) or the scan fails, **leave `last24h`/`last7d` out** of the response. Don't send 0. A
  missing field shows "All-time only" in the app; a 0 would show as a real zero.
- **Same root as the totals.** STATS_INDEXER.md asks for the `kchat:1:` root only. If these
  partitions also hold legacy `ciph_msg:1:` (Kasia app) rows, the totals already include them.
  Keep the windows consistent with the totals, and just note which it is in your reply.

## Done when

```
curl -s https://kachat.duckdns.org/stats
```

…shows `last24h` and `last7d` on `messages`, `handshakes`, `payments`, `groupMessages`,
`groupUpdates` and `selfStash`. No app release is needed: the app reads whatever the server sends,
so the "All-time only" labels disappear and the 24h/7d totals include chats on the next refresh.

Out of scope here, still open from 68706a5: `chessGames` (games started) is not reported yet.
