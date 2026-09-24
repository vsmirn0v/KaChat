# Push Extensions — Broadcasts + KaPosts (server handoff)

**Audience:** the AI/engineer on the server box running the push service (kasia-indexer fork
with `PushNotificationActor` — see `PUSH_NOTIFICATIONS.md` for the base chat/group system)
plus the KaPosts + broadcast indexers. The iOS app (branch `KaChat4.0i`) is FULLY wired for
remote push on broadcasts and KaPosts as of this doc — everything below is server work.
The app is the source of truth for payload shapes: `PushNotificationManager.swift`
(registration) and `KaChatApp.swift` (tap routing).

## 0a. Deployment reality (read first)

**LIVE:** the push service runs on `kachat.duckdns.org` and the app's default Push Indexer
URL points there (stored kasia.wtf values migrate forward; hand-entered custom URLs are
honored). This box must therefore serve the FULL push spec - the base chat/group system from
`PUSH_NOTIFICATIONS.md` (registration, auth, encrypted chat payloads, blinded group ids)
PLUS everything in this doc, signed with the operator-supplied APNs auth key (.p8) for team
RP4Z22SFSD / bundle `com.kachat.app`.

## 0. Routing — where registrations go

The app registers push state ONLY with the push service (the app's "Push Indexer URL"
setting - same endpoint chat/group push already uses). The KaPost Indexer URL and Broadcast
Indexer URL settings are read-only content sources and play NO role in push. Therefore the
broadcast + KaPosts indexers must notify the push service internally when they ingest a
push-worthy event (same box - function call/queue/HTTP, implementer's choice); the push
service owns device-token lookup and APNs delivery for everything.

## 1. Registration fields the app now sends

`/register` (POST) and the update endpoint (PUT) both carry, alongside the existing chat
fields (`watched_addresses`, `watched_group_ids`, `primary_address`, `aliases`, `auth`):

| Field | Type | Meaning |
|---|---|---|
| `watched_broadcast_channels` | `[String]` | Joined indexed channels with the bell ON (subset of `kaspa`, `kachat-bugs`). Bell toggles re-send registration immediately. Missing = `[]`. |
| `hidden_broadcast_senders` | `{channel: [address]}` | Per-room senders this device hid — never push their messages to this device. Missing = `{}`. |
| `kaposts_pubkey` | `String?` | The wallet's K identity (66-hex compressed secp256k1). Present = this device wants KaPosts pushes for actions on that identity's content. Missing/null = no KaPosts pushes. |
| `apns_environment` | `String` | `"development"` or `"production"` — which APNs host this device's token is valid at. Read from the build's `aps-environment` entitlement (embedded provisioning profile) at runtime; Xcode installs are `development`, TestFlight/App Store are `production`. The server MUST route each push to `api.sandbox.push.apple.com` vs `api.push.apple.com` per device using this; a mismatch is dropped silently as `BadDeviceToken`. Missing = fall back to the server's global setting (old clients). |

Store all four per device token. Old app versions omit them — treat as empty/none.

None of these fields are covered by the auth preimage, so adding them cannot break older
clients' signatures.

## 2. Broadcast pushes (spec recap — details in PUBLIC_CHATS_INDEXER.md §5)

When the broadcast indexer ingests a new message in a tracked channel, APNs-alert every
device watching that channel, skipping (a) the sender's own device(s) (match registered
`primary_address`/`watched_addresses`) and (b) devices listing the sender under that channel
in `hidden_broadcast_senders`.

```json
{
  "aps": {
    "alert": { "title": "#kaspa", "subtitle": "<sender KNS name or short address>",
               "body": "<message preview>" },
    "sound": "default",
    "thread-id": "broadcast:kaspa"
  }
}
```

- `thread-id` MUST be `broadcast:<channel>` — the app routes taps into the room by it, and
  clears delivered notifications for that thread when the user opens the room.
- HTTP/2 header `apns-collapse-id` = message txid (retry dedupe).
- **Send `"mutable-content": 1`** so the app's notification extension can tidy the body
  (reply text, base64, truncated envelopes) - it never runs without it.
- Preview rules: reply envelope (`{"type":"reply",...,"text":...}`) → its inner **`text`**
  (NOT `content` - that field does not exist; this doc said so by mistake), plain decoded
  text, never base64; file/audio
  envelope → `"Voice message"`; else text verbatim, ~150 chars. Reaction envelopes
  (`{"type":"reaction",...}`) → do NOT push at all (clients render them as pills on the
  target message, never as messages). Edit envelopes (`{"type":"edit",...}`, see
  MESSAGING.md "Message Edits") → do NOT push either: an edit changes an earlier message in
  place, there is nothing to announce.
- **Unwrap BEFORE truncating.** A reply envelope's txid and sender address alone are ~130
  characters, so truncating the raw JSON at 150 drops the reply's text entirely - the phone
  then has nothing to show but "Replied to a message". Parse first, cut the inner `text`.

## 3. KaPosts pushes (NEW)

When the KaPosts indexer ingests an accepted action **targeting content authored by a
registered `kaposts_pubkey`** — vote (up/down) on their post/reply, reply to their content,
quote/repost of their post, or a follow of them — push to every device registered with that
pubkey, skipping devices whose `kaposts_pubkey` equals the ACTOR's pubkey (no self-pings).
Honor removal counter-actions: an `unvote`/`unquote` should not generate a push.

```json
{
  "aps": {
    "alert": { "title": "KaPosts", "subtitle": "<actor KNS name or short address>",
               "body": "<action text>" },
    "sound": "default",
    "thread-id": "kaposts"
  },
  "postId": "<target content txid, when the action targets content>"
}
```

- `thread-id` MUST be exactly `kaposts`. The app routes a tap to the post's comment thread
  when `postId` is present (top-level custom key, NOT inside `aps`), else to the KaPosts
  Notifications screen. Viewing that screen clears the delivered `kaposts` notifications.
- `postId` = the txid of the content acted ON (the user's post/reply), not the action's txid.
  Omit for follows.
- `apns-collapse-id` = the ACTION's txid.
- **NEEDED: `kaposts_kind`** (top-level custom key) = one of `vote_up`, `vote_down`, `reply`,
  `quote`, `repost`, `follow`, `mention`. The app has five per-kind switches (Settings →
  Notifications → KaPosts) that the server knows nothing about, so it pushes every kind and the
  client has to filter. It does that today by matching the English body phrases below, which
  works only because they are server-generated and unlocalized — a brittle contract. This field
  replaces that guess.
- **NEEDED, and better still: per-kind registration.** Alongside `kaposts_pubkey`, accept
  `kaposts_notify_likes` / `_dislikes` / `_comments` / `_reposts` / `_follows` (booleans,
  default true) and skip the push server-side. Filtering on the device still wakes the phone
  and burns the push; skipping at the source is the real fix. Mentions are deliberately not
  switchable.
  **The app SENDS these five fields as of 4.1**, on every register and update call, and
  re-registers the moment a switch changes. Until the server honors them, a switched-off kind
  still arrives in the background - see the delivery note below on why the device cannot stop it.
  **Status check (5.0):** users with Likes switched OFF are still being pinged for likes, which
  means the server is not yet skipping on these fields. Please honor them - and, until then,
  send `"mutable-content": 1` in `aps` so the notification service extension runs and blanks
  the switched-off push on the device (a push with empty title and body is not shown).
- Body text (match the app's own in-app wording): `liked your post`, `disliked your post`,
  `replied to your post: <snippet>`, `quoted your post: <snippet>`, `reposted your post`,
  `followed you`. Snippets: marker-stripped (drop the leading U+2060), ~140 chars.
- Actor subtitle: KNS primary name for the actor's derived Kaspa address if you resolve KNS
  server-side, else the address shortened (`kaspa:qq12....wxyz`).

## 4. Delivery notes (both)

- Plain alert pushes; both content types are public/unencrypted so there is nothing for the
  app's notification service extension to decrypt. **But KaPosts pushes SHOULD carry
  `mutable-content: 1` anyway**, until per-kind registration is honored: without it the
  extension never runs, and the extension is where the app drops the kinds the reader switched
  off (§3). Today that means the switches only suppress banners while the app is in the
  foreground; a like arrives in the background no matter what the reader chose. With
  `mutable-content: 1` the extension gate becomes a real backstop, and once the server filters
  at the source the flag can go again.
- **The app posts NO local banners of its own, for anything** - not for 1:1 messages, group
  messages or reactions, broadcasts, or KaPosts activity - whatever it discovers through its
  subscription, sweep, polls, background fetch or a silent push (`ChatService.localBannersEnabled`,
  as of 4.1). The server's alert push is the only notification source, foreground or
  background, exactly as when the app is closed. Consequences the server side should know: a
  message the push service misses notifies nothing; broadcast rooms that are not indexed for
  push notify nothing; and the foreground no longer drops a push on the assumption the app will
  banner it itself, so every push shows unless the reader is looking at that very stream.
- APNs environment: production for TestFlight/App Store builds (see the CHANGENOW/secrets
  notes for the sandbox story on dev builds — same applies here).
- Rate sanity: batch/coalesce bursts (a viral post's votes) — collapse-id already dedupes
  retries; consider a per-device per-minute cap on KaPosts pushes.

## 5. Calls: VoIP pushes (NEW, 5.0)

KaChat 5.0 has voice/video calls (MESSAGING.md "Calls"). Ringing is an encrypted chat message,
which a closed app cannot see - so the caller's phone asks the push service to ring the callee
through **PushKit VoIP**, the only push kind iOS lets a terminated app answer by ringing. Two
pieces of server work: store a second token per device, and add one endpoint.

### 5a. Registration: `voip_token`

`/register` and the update endpoint now carry `voip_token` (`String?`, hex, from PushKit).
Store it per device token like the §1 fields; null/missing = this device cannot be rung (keep
sending ordinary pushes). It is NOT part of the auth preimage. It is valid at the same APNs
environment as `device_token` (`apns_environment`).

### 5b. `POST /v1/push/ring`

Body (JSON):

| Field | Type | Meaning |
|---|---|---|
| `device_token` | `String` | The CALLER's registered APNs token - identifies the calling device/wallet. |
| `to_address` | `String` | The callee's Kaspa address. Ring every registered device whose `primary_address` is this address and that has a `voip_token`. |
| `call_id` | `String` | The call's UUID (lowercase). |
| `video` | `Bool` | Video call or voice. |
| `kind` | `String` | `"invite"` (caller hosts the Talk room) or `"request"` (caller asks the callee to host). |
| `payload` | `String` | The opening call message, encrypted to the callee exactly as on chain (`kchat:1:comm:ALIAS:BASE64`, hex). Opaque; forward it. ≤ 2 KB. |
| `timestamp` | `UInt64` | Caller's clock, ms. |
| `auth` | object | The same signed challenge auth as every other push endpoint (`method=POST`, `path=/v1/push/ring`, empty `watched_addresses`/`watched_group_ids`/`aliases`, `primary_address` = the caller's wallet). |

Verify `auth` as for `/register`; the wallet it proves is the **sender** the push names, so
the callee can trust `sender` without decrypting anything. Reject (403) when `device_token`'s
registration is bound to a different wallet. Respond `200 {}` once the pushes are queued (or
`200` with no devices - the caller does not care), `404`/`204` is not needed.

Then send, to each of the callee's VoIP tokens, an APNs push with:

- topic `com.kachat.app.voip` (the app's bundle id + `.voip`), `apns-push-type: voip`,
  `apns-priority: 10`, `apns-expiration: 0` (never queue a stale ring - a push older than
  ~45 s is dropped on the phone anyway).
- Payload (all top level, no `aps` alert):

```json
{
  "call_id": "<call_id>",
  "kind": "invite",
  "video": false,
  "sender": "<the caller's wallet address, canonical>",
  "timestamp": <server receive time, ms>,
  "payload": "<payload hex, forwarded>"
}
```

Rules: one push per ring request (no retries beyond APNs' own - iOS punishes an app for every
VoIP push that does not become a visible call, and a duplicate becomes a "missed call" on the
callee's phone); rate-limit per sender (a few per minute is plenty); never send a VoIP push
for anything but this endpoint. The existing chat push for the on-chain call message still
goes out as usual (the notification service extension renders it as "📞 Incoming voice
call") - that is the fallback for devices without a VoIP token.
