# Group messages from the indexer - server handoff

**Audience:** whoever runs the KaChat indexer. Two things, in order of value:

1. A **batched read** the app already calls when it exists (falls back silently when it does not).
2. The endpoint shape that lets the app **stop streaming every block** for group chats, which is
   the single largest data and battery cost in the app today.

Everything here is additive. The existing endpoints stay as they are.

## What exists today

| Endpoint | Purpose |
|---|---|
| `GET /group-messages/by-blinded-group-id?blinded_group_id=<hex>&limit=<n>[&cursor=<c>]` | A member's group messages (`gcomm`), oldest first, cursor-paged |
| `GET /group-control/by-sender?sender=<address>&limit&cursor` | An admin's control messages (`gctl`) |
| `GET /group-control/by-recipient?recipient=<address>&limit&cursor` | Controls addressed to a wallet (first-invite discovery) |

Rows are JSON objects with camelCase keys, e.g. a message row:

```json
{ "txId": "...", "sender": "kaspa:...", "blindedGroupId": "<hex>", "blockTime": 1790000000000,
  "cursor": "<opaque>", "acceptingBlock": "...", "acceptingDaaScore": 123, "messagePayload": "<hex>" }
```

Each member of a group sends under their **own** blinded group id, so a client that wants a
group's messages asks once per member. The app does that every minute while open (3 groups of
8 is about 28 requests a minute), plus on every return to the foreground.

## 1. Batched read (the app already uses it when present)

```
POST /group-messages/by-blinded-group-ids
Content-Type: application/json

{ "queries": [
    { "blindedGroupId": "<hex>", "cursor": "<opaque or null>", "limit": 50 },
    ...
] }
```

Response, one result per query, in any order, each `messages` array exactly what the GET for
that id, cursor and limit would have returned (oldest first, cursor-paged, same row shape):

```json
{ "results": [
    { "blindedGroupId": "<hex>", "messages": [ { ...row... }, ... ] },
    ...
] }
```

Rules:
- Up to 64 queries per request; reject more with 400.
- A query for an id with nothing to return gets an empty `messages` array, not an omission.
- `cursor` absent or null means "from the beginning", exactly as the GET.
- Status 200 on success. The app treats **404, 405 and 501** as "this indexer has no batched
  endpoint" and stops asking for the rest of the session, so a server that does not implement
  it costs nothing.

Client behaviour (`GroupChatService.catchUpGroupMessagesBatched`): one request per group per
pass carrying every member's lane and cursor, repeated while any lane still returns full
pages. This turns "1 + admins + members" requests per group into "1 + admins".

## 2. Replacing the block stream (the real prize)

Today, while any group exists, the app subscribes to `blockAdded` on a Kaspa node and receives
every full block (about ten a second) to find group messages the moment they land. That is
tens of megabytes an hour and sustained CPU and radio. Public chats already have a polling
path against this indexer; groups do not, because there is no "what is new since T across all
of these ids" read.

Add:

```
POST /group-messages/since
{ "blindedGroupIds": ["<hex>", ...], "sinceBlockTime": 1790000000000, "limit": 200 }
```

Response: `{ "messages": [ ...rows... ], "latestBlockTime": 1790000012345 }` - every row across
the given ids with `blockTime > sinceBlockTime`, oldest first, capped at `limit`; the client
pages by feeding `latestBlockTime` back. Up to 256 ids per request.

And the same for control:

```
POST /group-control/since
{ "senders": ["kaspa:...", ...], "recipient": "kaspa:...", "sinceBlockTime": ..., "limit": 200 }
```

With those two the app polls open groups every 5 s and all groups every 30 s, the way rooms
poll `/get-broadcasts` today, and never registers for blocks. Indexing latency of a few
seconds is fine: the block stream's only advantage was immediacy, and the push server already
covers the closed-app case.

## Notes for the implementer

- `blindedGroupId` is 32 bytes hex; index it. Rows for one id are strictly ordered by
  `(blockTime, txId)`, which is what the opaque cursor encodes today.
- Nothing in these payloads is readable by the indexer: `messagePayload` is ciphertext. The
  server learns which blinded ids are asked for together, which it can already infer from the
  per-member GETs.
- Android and desktop will adopt the same endpoints; keep the shapes above exact.
