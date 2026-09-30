# KaChat Stats - indexer handoff

Kaspa Hub > **KaChat Stats** (5.2, `KaChat/Views/Ecosystem/KaChatStatsView.swift`) shows how many
transactions KaChat has put on Kaspa, split by kind. The app never counts anything itself: it
asks the indexer. Until an indexer serves the endpoint below, the screen says "Stats aren't
available yet" and shows its rows with the numbers redacted.

## Endpoint

```
GET {indexer}/stats
```

The app calls it on every KaChat indexer the network is configured with (message indexer,
public chat indexer, KaPosts indexer - deduplicated, so the default single server gets one
request). Each category is taken from the first indexer, in that order, that reports it. One
server can report everything; split deployments report their own slice.

```json
{
  "updatedAt": 1727712000000,
  "indexedSince": 1718000000000,
  "categories": {
    "messages":      { "total": 1204331, "last24h": 5120, "last7d": 36004 },
    "handshakes":    { "total": 18420,   "last24h": 61,   "last7d": 402 },
    "payments":      { "total": 40211,   "last24h": 190,  "last7d": 1320 },
    "groupMessages": { "total": 88012,   "last24h": 710,  "last7d": 4902 },
    "chessMoves":    { "total": 51007 }
  }
}
```

- `updatedAt` / `indexedSince`: unix **milliseconds**, both optional. `updatedAt` = when the
  counters were last brought up to date (the app shows "Updated 2 minutes ago");
  `indexedSince` = the block time counting starts from ("Counting since ...").
- `categories`: keys from the table below. **Leave out a category you don't count**; the app
  hides it rather than showing 0. Unknown keys are ignored, so new ones can ship server-first.
- `total` = all time, `last24h` / `last7d` = rolling windows by accepted block time. Each is
  optional; a missing one shows as a dash for that range.
- Cache it: the app refetches at most once a minute per phone (more on pull-to-refresh).
  Recomputing every 30-60 s is plenty. Plain JSON, no auth, `200` on success; anything else
  (including `404` from an indexer without this endpoint) reads as "not available".

## Categories

Count **accepted transactions** by payload. Written payloads use the `kchat:1:` root
(MESSAGING.md "Transaction Payload Formats", KAPOSTS_INDEXER.md §2, ONLINE_CHESS.md).

| Key | Shown as | Counts |
|-----|----------|--------|
| `messages` | Direct Messages | `kchat:1:comm:` |
| `handshakes` | New Chats | `kchat:1:handshake:` |
| `payments` | Payments | `kchat:1:pay:` |
| `groupMessages` | Group Messages | `kchat:1:gcomm:` |
| `groupUpdates` | Group Updates | `kchat:1:gctl:` |
| `publicChats` | Public Chats | `kchat:1:bcast:<channel>:` for every channel **except** `chess-arena` |
| `kaposts` | KaPosts | `kchat:1:` `post`, `reply`, `quote`, `poll` |
| `kapostActions` | KaPost Activity | `kchat:1:` `vote`, `follow`, `unquote`, `edit`, `delete`, `pollvote` |
| `chessMoves` | Chess Moves | `kchat:1:bcast:chess-arena:` whose JSON has `"a":"move"` |
| `chessGames` | Chess Games | games started, as the `/chess/leaderboard` reducer sees them (a 1v1 room's second join, a tournament's eighth) |
| `selfStash` | Saved Records | `kchat:1:self_stash:` |

Notes:

- **Only the `kchat:1:` root.** The legacy roots (`ciph_msg:1:`, `k:1:`) are shared with the
  Kasia and K apps, so counting them would count other apps' traffic as KaChat's. The cost is
  that history before the root migration isn't counted - `indexedSince` makes that honest.
- **1:1 content is encrypted.** Voice notes, reactions, 1:1 chess moves and call signalling are
  all `comm` messages and cannot be told apart; they count as `messages`. The app says so in
  its "What counts" sheet. Never try to classify them.
- KaPosts signatures: count a KaPost action only if it verifies, the same rule the feed
  applies, so garbage payloads don't inflate the numbers.
- Count a transaction once, when it is accepted; a reorg that drops it should drop the count
  (or the next full recompute will).
