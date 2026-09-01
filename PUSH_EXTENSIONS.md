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

## 2. Broadcast pushes (spec recap — details in BROADCAST_INDEXER.md §5)

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
- Preview rules: reply envelope (`{"type":"reply",...}`) → its inner `content`; file/audio
  envelope → `"Voice message"`; else text verbatim, ~150 chars. Reaction envelopes
  (`{"type":"reaction",...}`) → do NOT push at all (clients render them as pills on the
  target message, never as messages).

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
- Body text (match the app's own in-app wording): `liked your post`, `disliked your post`,
  `replied to your post: <snippet>`, `quoted your post: <snippet>`, `reposted your post`,
  `followed you`. Snippets: marker-stripped (drop the leading U+2060), ~140 chars.
- Actor subtitle: KNS primary name for the actor's derived Kaspa address if you resolve KNS
  server-side, else the address shortened (`kaspa:qq12....wxyz`).

## 4. Delivery notes (both)

- Plain alert pushes — NO `mutable-content` needed; both content types are public/unencrypted
  so there's nothing for the app's notification service extension to decrypt.
- The app SUPPRESSES its own local/scan-driven banners for broadcasts and its in-app KaPosts
  polling pings while in remote-push mode — the server is the ONLY notification source for
  these once this ships. Until it ships, users get no broadcast/KaPosts notifications when
  the app is closed, so this is the top-priority server item.
- APNs environment: production for TestFlight/App Store builds (see the CHANGENOW/secrets
  notes for the sandbox story on dev builds — same applies here).
- Rate sanity: batch/coalesce bursts (a viral post's votes) — collapse-id already dedupes
  retries; consider a per-device per-minute cap on KaPosts pushes.
