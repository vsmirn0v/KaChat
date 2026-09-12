# KaPosts: make reply threads complete

> **STATUS: DELIVERED.** Both endpoints are live on `kachat.duckdns.org` and verified against a
> real reply: `get-post?id=<txid>` returns `{post: KPost}`, and `get-thread?id=<txid>` returns
> `{ancestors: [KPost], post: KPost}` with the chain root-first and the requested post carrying
> its `parentPostId`.
>
> The client side had NOT been updated to match — every platform still assumed "the indexer has
> no single-post lookup", which is what made a reply opened from a profile a dead end. iOS now
> calls both (`KaPostsAPIClient.fetchPost` / `fetchThread`); desktop and Android are to follow.
> Everything below is kept as the contract those calls are written against.

**Ask:** two read endpoints on the KaChat KaPosts indexer. Everything else already works.
No protocol change, no schema change, no app release needed — the apps call these the moment
they answer, and fall back to today's partial behaviour when they don't.

Full protocol/build reference, if you need it: `KAPOSTS_INDEXER.md`.

## The problem

A reply's parent is on chain, but there is no way to **fetch a post by id**. Every read
endpoint is a feed or a list. So the apps can only show the parts of a thread that happen to
be loaded in memory, which breaks in two visible ways:

1. **Ancestor chains stop early.** Both apps stack the chain of parent posts above the reply
   you are reading (X-style), so you can jump up several levels. That chain is assembled from
   posts already in memory, so it ends at the first ancestor that was never loaded — most
   obviously when you open a reply from a notification or a shared link and land mid-thread
   with nothing above it.

2. **Deep replies fail to open.** Resolving a txid today means: search the loaded feed →
   re-fetch the feed → fetch the viewer's own posts and replies → give up. Other people's
   older replies are outside all of those, so the tap does nothing useful.

## What to build

### 1. `GET /get-post?id=<txid>&requesterPubkey=<pubkey>` — required

Returns **one** post, any age, any author, same `KPost` shape the feeds return (including
`parentPostId` and the per-viewer fields `isUpvoted` / `isDownvoted`).

```json
{ "post": { "id": "...", "userPublicKey": "...", "postContent": "<base64>",
            "timestamp": 1736200000000, "parentPostId": "...", "repliesCount": 3,
            "upVotesCount": 0, "downVotesCount": 0, "quotesCount": 0,
            "isUpvoted": false, "isDownvoted": false, "isQuote": false } }
```

404 with the usual `{"error":"...","code":"..."}` when the id is unknown.

This alone fixes both problems: the apps walk `parentPostId` upward one fetch at a time until
it is null, and a shared or notified txid resolves directly.

### 2. `GET /get-thread?id=<txid>&requesterPubkey=<pubkey>` — better, if cheap for you

The same walk, done server-side in one request:

```json
{ "ancestors": [ /* KPost, ROOT FIRST, excluding the requested post */ ],
  "post": { /* KPost */ } }
```

Cap the chain at ~25 and truncate from the root end if longer. Worth it because the client
walk is one round trip per level — five levels deep on a slow connection is a visible stall,
and the chain renders above the post the user is already reading.

Build §1 first; §2 is an optimisation of the same data and the apps will use whichever exists.

## Two things that must hold for either to help

- **`parentPostId` set on every reply**, including replies-to-replies, and `null` on roots.
  It is the only link upward — the walk terminates on null.
- **`repliesCount` = direct replies only**, not the whole subtree. The apps render "View N
  replies" from it and then fetch exactly that list, so a subtree count shows a number the
  next request cannot produce.

## How to tell it worked

Open a reply that is several levels deep from a push notification. Today you see that reply
and nothing above it. Working, you see the chain of parents stacked above it, each tappable,
up to the original post.
