# KaChat Broadcast Indexer — Handoff & Build Guide

**Audience:** the AI/engineer on the server box. This doc specifies a small, self-contained
indexer that tracks KaChat **broadcast** messages for exactly two channels — `#kaspa` and
`#kachat-bugs` — and serves their history over REST. The iOS app (branch `KaChat4.0i`) is
already wired to consume it: Settings → Connection Settings → **Broadcast Indexer** takes the
base URL, and `BroadcastIndexerClient` in `KaChat/Services/BroadcastService.swift` defines the
exact API contract (that client is the source of truth — build the server to satisfy it).

## 1. Why this exists

Broadcasts are public, unencrypted, many-to-many channels riding on Kaspa transactions. Today
the app only sees messages **while it is live-scanning new blocks** (channel screen open, or
"always listen" enabled) — anything sent while the app was closed is gone forever for that
user. This indexer watches the chain 24/7 for the two curated channels and lets every client
backfill history on channel open. The app merges indexer history with its live scanning and
dedupes by txid, so the server only needs to be honest and reasonably complete, not realtime.

## 2. On-chain format (what to scan for)

A broadcast is a Kaspa **self-send transaction** (outputs pay the sender's own address) whose
`payload` is the UTF-8 string:

```
ciph_msg:1:bcast:<channel>:<content>
```

- Fast pre-filter: payload (hex) starts with hex of `ciph_msg:1:bcast:`.
- `<channel>`: everything up to the **first** colon after the prefix. Normalize before
  comparing: trim whitespace, lowercase. Valid names are ≤36 chars, no whitespace, no colons.
  **Index only** normalized `kaspa` and `kachat-bugs`; drop everything else.
- `<content>`: the remainder — may itself contain colons; do NOT split it further. Plain text,
  except it may be a JSON envelope:
  - reply: `{"type":"reply","reference":{...},"content":"..."}` (app's `MessageReplyCodec`)
  - audio: `{"type":"file","mimeType":"audio/webm",...}` (voice broadcasts)
  Store content **verbatim**; clients do all decoding/rendering.
- **Sender address** = the address encoded by the **first output's** `scriptPublicKey`
  (self-send, so it's the author). hrp `kaspa` for mainnet.
- **Message id** = the transaction id. **Timestamp** = the containing block's `blockTime`
  (milliseconds).
- No signature scheme exists for broadcasts (unlike KaPosts' `k:1:` payloads) — the sender is
  authenticated by having signed the transaction itself. Nothing to verify beyond the tx
  being accepted.
- Retention: **the product retention for these channels is 3 days** — clients display/prune at
  a fixed 3 days (the in-app retention setting is hidden for them). Serve at least 3 days of
  history; keeping more server-side is fine (clients just won't show it).

## 3. REST API (compatibility bar — matches `BroadcastIndexerClient`)

### `GET /get-broadcasts?channel=<name>&limit=<n>[&before=<blockTimeMs>]`

- `channel`: normalized name (`kaspa` or `kachat-bugs`). Unknown channel → `200` with empty
  `messages` (don't error).
- `limit`: max rows (client sends 200; cap at e.g. 500).
- `before` (optional): return only rows with `blockTime < before` — pages older history.
- Response (JSON), newest-first:

```json
{
  "messages": [
    {
      "txId": "…64-hex…",
      "channel": "kaspa",
      "senderAddress": "kaspa:qq…",
      "content": "verbatim payload content",
      "blockTime": 1786000000000
    }
  ],
  "hasMore": true
}
```

- Errors: non-2xx with JSON `{"error":"…"}`. The app treats any failure as "no backfill" and
  retries on the next channel open — nothing user-facing breaks.
- Nice-to-have: `GET /health` returning `200` + last-indexed DAA score/block time, for
  monitoring.
- CORS: not needed for the iOS app; add permissive CORS only if a web client comes later.
- Rate limiting: light (e.g. 60 req/min/IP) is plenty — the app makes one request per channel
  per session.

## 4. Build guidance

- **Skeleton:** fork/reuse the kasia-indexer codebase the project already runs (reference
  checkout under `external/kasia-indexer` in the app repo) — it already connects to a Kaspa
  node, streams accepted transactions, and filters `ciph_msg:` payloads for chat; this indexer
  is the same loop with the `bcast` subtype, a channel allowlist, and a much simpler store.
  Alternatively a from-scratch service (Rust + rusty-kaspa wRPC, or anything that can consume
  a kaspad's gRPC `notifyBlockAdded` / virtual chain stream) is fine — the protocol above is
  the whole spec.
- **Reorg safety:** index from the accepted/virtual-chain view, or wait a few confirmations
  before serving a row; dedupe by txId either way (the app also dedupes).
- **Backfill at launch:** on first start, walk historical blocks as far as practical (or start
  from "now" and accept that history begins at deployment — acceptable v1).
- **Store:** anything durable — SQLite is plenty (two channels, text rows, one index on
  `(channel, blockTime DESC)`).

### Docker

Ship as a small compose stack. Suggested shape:

```yaml
# docker-compose.yml
services:
  kaspad:                      # skip if the box already runs a node (push indexer does)
    image: supertypo/rusty-kaspad:latest
    restart: unless-stopped
    command: kaspad --utxoindex --rpclisten-borsh=0.0.0.0:17110 --rpclisten=0.0.0.0:16110
    volumes: [kaspad-data:/app/data]

  broadcast-indexer:
    build: .
    restart: unless-stopped
    environment:
      KASPAD_URL: grpc://kaspad:16110      # or borsh://kaspad:17110 for wRPC
      CHANNELS: "kaspa,kachat-bugs"
      DB_PATH: /data/broadcasts.sqlite
      LISTEN: 0.0.0.0:8580
    volumes: [indexer-data:/data]
    ports: ["8580:8580"]

volumes:
  kaspad-data:
  indexer-data:
```

Front it with the box's existing reverse proxy for TLS (the app requires https in practice).
**Decided: it shares the KaPosts indexer's domain** - the app's Broadcast Indexer setting
defaults to `https://kaposts.duckdns.org`, so the reverse proxy there must route
`/get-broadcasts` (and `/health` if implemented) to this service alongside the KaPosts
endpoints. No new DNS needed.

## 5. Remote push for broadcast rooms (REQUIRED for v1)

The app expects closed-app notifications for these two channels, gated by each channel's
in-app bell toggle. The plumbing on the app side is DONE:

- The push registration/update payloads sent to the push indexer (the kasia-indexer fork's
  `/register` + update endpoints - see `PUSH_NOTIFICATIONS.md`) now include
  `"watched_broadcast_channels": ["kaspa", "kachat-bugs"]` - only channels the user has
  JOINED with the bell ON. Toggling a bell re-sends the registration, so the server list is
  always current. Devices with an older app simply omit the field - treat missing as `[]`.
- Registrations also carry `"hidden_broadcast_senders": {"kaspa": ["kaspa:qq…", …], …}` -
  per-room senders this device has hidden. Missing field = `{}`.
- Server work: (1) push service stores `watched_broadcast_channels` AND
  `hidden_broadcast_senders` per device; (2) when the broadcast indexer ingests a new message
  in a tracked channel, send an APNs alert to every device watching that channel - skipping
  the sender's own device (matched by registered primary/watched address) and any device that
  lists the sender under that channel in `hidden_broadcast_senders`.
- APNs payload - broadcasts are public/unencrypted, so send a ready-made alert (no mutable
  content / extension work needed):

```json
{
  "aps": {
    "alert": { "title": "#kaspa", "subtitle": "<sender KNS name or shortened address>",
               "body": "<message preview>" },
    "sound": "default",
    "thread-id": "broadcast:kaspa"
  }
}
```

  - `thread-id` MUST be `broadcast:<channel>` - the app routes notification taps by that
    prefix straight into the channel screen.
  - Set the HTTP/2 header `apns-collapse-id` to the message txId so retries never duplicate.
  - Body preview: if content is a reply envelope (`{"type":"reply",...}`) use its inner
    `content`; if a file/audio envelope, send "Voice message"; else the text verbatim
    (truncate ~150 chars).

## 6. How the app consumes it (context)

- Setting: `AppSettings.broadcastIndexerURL` (empty = feature off; app then behaves exactly as
  before, live scanning only).
- On opening a channel screen the app calls `/get-broadcasts` once per channel per session,
  inserts rows into its local Core Data store (dedupe by txId; hidden-sender filter and local
  retention pruning still apply), and refreshes the visible list.
- Live messages keep arriving via the app's own block scanning while the app is open (for the
  two indexed channels, scanning follows the bell toggle - they have no "always listen"
  toggle); remote push (§5) covers the closed-app case.
- The two tracked channels match the app's curated "Popular" list
  (`BroadcastService.featuredChannels = ["kaspa", "kachat-bugs"]`). If more channels get
  curated later, the allowlist is the only thing to extend.
