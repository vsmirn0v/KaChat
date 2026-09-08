# KaPosts Indexer — Handoff & Build Guide

**Audience:** the AI/engineer on the server box that will build and host the KaChat-owned
KaPosts indexer. This doc is the starting context: what the iOS app (branch `KaChat4.0i`)
already speaks, what the public K indexer gives us today, and exactly what the new indexer
must add on top. The single client integration point in the app is
`KaChat/Services/KaPostsAPIClient.swift` — read it alongside this doc; every wire shape the
app expects is defined there.

## 1. What KaPosts is

KaPosts is a Twitter/X-style social feed inside KaChat. **Everything is on-chain**: each
action (post, reply, vote, follow, quote/repost) is a Kaspa **self-send transaction**
(outputs pay back to the author's own address) whose `payload` field carries a `k:1:...`
protocol string. The indexer's job is to scan the DAG for these payloads, verify signatures,
and serve a REST read API. **The transaction id IS the content id.**

Today the app runs against the public K social indexer (`https://mainnet.kaspatalk.net`,
configurable in Settings → Connection Settings → "KaPost Indexer"). The new indexer replaces
it. Keeping the same endpoint paths/response shapes means the app works by just changing
that URL — that is the compatibility bar. Extensions below are additive.

## 2. Protocol the app writes (must parse verbatim)

Payload strings (all fields `:`-joined, prefix `k:1:`):

```
k:1:post:<pubkey>:<signature>:<b64_message>:<mentions_json>
k:1:reply:<pubkey>:<signature>:<post_id>:<b64_message>:<mentions_json>
k:1:vote:<pubkey>:<signature>:<post_id>:<upvote|downvote|unvote>:<author_pubkey>
k:1:follow:<pubkey>:<signature>:<follow|unfollow>:<followed_pubkey>
k:1:quote:<pubkey>:<signature>:<content_id>:<b64_message>:<quoted_author_pubkey>
k:1:unquote:<pubkey>:<signature>:<content_id>
```

`unvote` and `unquote` are the removal counter-actions (§5.1); they are implemented in the
KaChat indexer fork. The app does not write them yet — it will once the like/repost toggles
are re-enabled.

- `<pubkey>`: author's **66-hex compressed secp256k1** public key.
- `<signature>`: 128-hex schnorr signature over the **Kaspa personal-message hash**:
  `schnorr_sign(blake2b256(key="PersonalMessageSigningHash", msg=signing_string))`.
  Signing strings are the payload minus prefix/kind/pubkey/signature:
  - post: `"<b64_message>:<mentions_json>"`
  - reply: `"<post_id>:<b64_message>:<mentions_json>"`
  - vote: `"<post_id>:<vote>:<author_pubkey>"` (vote ∈ upvote|downvote|unvote)
  - follow: `"<action>:<followed_pubkey>"`
  - quote: `"<content_id>:<b64_message>:<quoted_author_pubkey>"`
  - unquote: `"<content_id>"`
- `<b64_message>`: base64 of the UTF-8 message text.
- `<mentions_json>`: JSON array of mentioned pubkeys; the app currently always sends `[]`.
- A **plain repost** is a quote whose message is empty-after-marker (see §3) — the K
  protocol has no separate repost action; `quotesCount` is the repost counter.

Reference builders: `KaPostsProtocol` enum in `KaPostsAPIClient.swift` (exact strings above
are copied from it).

## 3. KaChat exclusivity — the marker, and what the fork should do instead

Every message the app writes prepends an invisible **U+2060 WORD JOINER** inside the content
(so base64 starts `4oGg` for text). Today exclusivity is enforced *client-side*: the app
filters feeds to marker-carrying posts, because the public indexer's read API never exposes
raw payloads. This is one-way — K-website users can still see KaChat posts.

**The new indexer must enforce exclusivity server-side (two-way):**
- Index **only** KaChat content. Simplest robust rule: require the U+2060 marker in decoded
  post/reply/quote content. (Votes/follows have no content — accept them when they target
  indexed KaChat content / come from known KaChat identities.)
- Keep accepting the marker so existing on-chain history (already posted from the app)
  carries over.
- Optionally introduce a dedicated payload namespace (e.g. `kc:1:`) later; if so, the app
  and indexer must coordinate a dual-read/dual-write migration window. Don't start here —
  marker filtering gets v1 shipped without an app protocol change.

## 4. Read API the app consumes today (compatibility bar)

All content fields in responses are **base64**; timestamps are **milliseconds**; cursors are
opaque strings passed back via `before`; every endpoint takes `requesterPubkey` and uses it
to decorate per-viewer fields (`isUpvoted`, `isDownvoted`, `followedUser`, `blockedUser`).
Errors: JSON `{"error": "...", "code": "..."}`. Public indexer rate limit is 100 req/min/IP
— ours can be more generous but should still have one.

| Endpoint | Purpose | Notes |
|---|---|---|
| `get-posts-watching` | global feed | returns `{posts: [...], pagination: {hasMore, nextCursor, prevCursor}}` |
| `get-contents-following` | posts+replies from followed users | app filters replies out client-side |
| `get-posts?user=<pubkey>` | one user's posts | profile feed. **NEEDED: `includeReplies=true`** must also return the user's replies (with `parentPostId` set) - the app's profile Posts/Replies tabs split on it client-side; without server support the Replies tab stays empty |
| `get-replies?postId=` | replies to a post | |
| `get-user-details?user=` | `followersCount`, `followingCount`, `followedUser` | |
| `get-users-following` / `get-users-followers` | follow lists | takes `userPubkey`; items `{id, userPublicKey, timestamp, followedUser, ...}` wrapped under the key `posts` (yes, really - the app also tolerates `users`/`following`/`followers`) |
| `get-post?id=<txid>` | **NEEDED — see §5.5** single-post lookup by txid, any post, same `KPost` shape |
| `search?q=<text>&type=posts\|users` | **NEEDED — see §5.6** content and people search |
| `get-notifications` | actions on MY content | `{id, userPublicKey, postContent, timestamp, contentType, voteType, contentId}` — `id` is the **action's** txid |

Post objects (see `KPost` in the client): `id, userPublicKey, postContent, signature,
timestamp, repliesCount, upVotesCount, downVotesCount, quotesCount, repostsCount,
parentPostId, mentionedPubkeys, isUpvoted, isDownvoted, userNickname, blockedUser,
isQuote, quote`. Quote posts embed the quoted post inline:
`quote: {referencedContentId, referencedMessage (b64), referencedSenderPubkey,
referencedNickname}` — the app renders the X-style embed from this, keep it.

Note: the app **ignores** `userNickname`/avatar-ish fields entirely — identity (names,
avatars, banners) comes from KNS via the pubkey→Kaspa-address bridge. Don't invest in
profile features; serve social data only.

## 5. NEW capabilities the fork must add (the reason it exists)

These are confirmed product decisions; the iOS UI is already shaped for them.

> **Status — read this first.**
>
> **§5.1–§5.4 are DONE** and live in the KaChat indexer fork (see `K-indexer/KAPOSTS.md`).
> They are documented below for reference; you do not need to build them again.
>
> **§5.5 (`get-post`) and §5.6 (`search`) are the OUTSTANDING work** — that is what this
> handoff is asking for. Both are additive read endpoints: no schema change, no protocol
> change, no app release required to start benefiting. Ship them one at a time.
>
> Details of what is already done: the engagement endpoint is served as
> `GET /get-post-engagement?postId=&type=<upvote|downvote|repost|quote|all>&requesterPubkey=&limit=&before=`
> → `{ engagement: [{ actorPubkey, actionTxId, timestamp, kind }], pagination }`. Removal
> payloads are finalized in §2. App-side wiring is DONE too: the like/dislike/repost toggles
> write `unvote`/`unquote` (behind the 5s undo countdown), `KaPostEngagementView` reads
> `get-post-engagement` for any post (notification-stream fallback for older deployments),
> and the default indexer URL points at the fork.

1. **Removal counter-actions.** The chain is immutable but the indexer's *interpretation*
   doesn't have to be. Accept and honor:
   - `unvote` (removes a prior upvote/downvote by the same pubkey on the same post)
   - un-quote / un-repost (removes a prior quote by txid or by (pubkey, contentId))
   Suggested: extend the vote action's vote field (`upvote|downvote|unvote`) and add an
   explicit removal kind for quotes; verify the remover's pubkey matches the original
   actor. Counts and `isUpvoted`/`repostedByMe`-feeding fields must reflect removals. The
   app currently shows filled hearts/reposts as permanent no-ops ("option 1"); once the
   indexer supports removal, the client toggles get re-enabled to write the counter-action.
2. **Per-post actor lists.** Endpoints like
   `get-post-engagement?postId=` → who liked / disliked / reposted / quoted **any** post,
   each entry `{actorPubkey, actionTxId, timestamp, kind}`. Today the app fakes this from
   `get-notifications`, which only works for your own posts (see
   `KaPostEngagementView.load()` — it filters notifications by `contentId`). Rows deep-link
   to the explorer by `actionTxId`, so return the action's txid, not the post's.
3. **Real follower/following counts and lists** for any pubkey (the public ones exist but
   correctness matters once unfollow-removal semantics apply — a follow followed by
   unfollow nets to zero).
4. **Two-way exclusivity** (§3).

5. **Single-post lookup — `GET /get-post?id=<txid>`.** Returns one post object, same `KPost`
   shape as the feeds, for ANY post regardless of age or author. Two features need it:
   - **Shared links and notification taps.** Today the app resolves a txid by searching the
     loaded feed, then re-fetching the feed, then fetching its own posts and replies — and
     still misses other people's older content. See `openSharedPost` in the client.
   - **Thread ancestor chains.** Both apps now stack the chain of parent posts above the one
     you are reading (X-style), so you can jump up several levels at once. That chain is
     currently built from posts already in memory, so it stops at the first ancestor that was
     never loaded. With this endpoint the client can walk `parentPostId` to the root by txid
     and the chain becomes complete.

   Being able to fetch by id is the single highest-value addition for the client; both
   features degrade to partial behaviour without it, and neither needs a schema change.

6. **Search — `GET /search?q=<text>&type=posts|users`.** Same pagination envelope as the
   feeds.
   - `type=posts`: posts whose decoded content matches `q`, newest first, `KPost` shape.
   - `type=users`: users whose identity matches `q` **and who have posted at least once** —
     that last condition is a product requirement, not an optimisation. Rows want
     `{userPublicKey, address, postCount}`. Matching on KNS domain is ideal; the indexer only
     stores pubkeys, so either resolve pubkey→address→KNS server-side or return candidates by
     address prefix and let the client filter on the name it already resolves.

   Both apps ship a client-side search that pages the global feed and filters what comes
   back. It says so in the UI ("Searched the most recent N posts"), but it cannot see further
   than it has paged — a real index is the only way to search all of history.

Nice-to-haves once the core is up: richer notifications (mentions, replies to replies), and
a push hook — the app already runs a forked kasia-indexer with a `PushNotificationActor` for
chat push (see `PUSH_NOTIFICATIONS.md`), so mirroring that pattern for social notifications
is natural.

## 6. Getting started pointers

- **Scanning:** you need every accepted transaction's payload. The kasia-indexer fork this
  project already runs (`external/kasia-indexer` is the reference codebase) solves the same
  problem for `ciph_msg:` chat payloads — same DAG-scan skeleton, different payload prefix
  and handlers. `external/rusty-kaspa` documents the node RPC.
- **Verification:** reject any action whose schnorr signature doesn't verify against the
  embedded pubkey over the canonical signing string (§2). Also sanity-check that the tx was
  actually accepted (not orphaned) before treating its id as a content id.
- **Identity bridge (for reference, client-side):** pubkey → drop the 02/03 prefix byte →
  x-only → Kaspa Bech32 address. The indexer itself only ever needs pubkeys.
- **Testing against the app:** point Settings → KaPost Indexer at your box. The app's
  writes are live on mainnet already — there are existing marker-carrying posts (e.g. quote
  tx `f28587d7ac7ba1f8545e3b4f18dfc24f03160fa596feccbfb3da964272ca054b` quoting
  `cb60eea63d13ac668704670a0e843b0733be2a2123f4b2a864cc8605fe7ebdb9`) to validate a
  from-genesis backfill against.
- **Order of work:** (1) scan+verify+store `k:1:` payloads with marker filtering, (2) serve
  the §4 compatibility endpoints, (3) add removals + actor lists (§5.1–§5.4), (4) add
  `get-post` (§5.5) — smallest change, biggest client win, (5) add `search` (§5.6), (6) flip
  the app to the new URL as default.

- **What "done" looks like from the app side.** Nothing in §5.5 or §5.6 needs an app release
  to start being useful: both are additive endpoints the client will call once they answer.
  If an endpoint is missing the client already falls back (partial ancestor chain,
  feed-paging search), so shipping them one at a time is safe and each one is independently
  observable in the UI.


## 7. Universal Links for shared posts (domain config, NOT indexer work)

The app shares posts as `https://kachat.duckdns.org/post/<txid>`. With KaChat installed,
iOS opens the app straight into the post (the app ships the
`applinks:kachat.duckdns.org` entitlement). Without the app, the browser loads the URL -
so the domain must serve two small things (reverse-proxy/static config on the box; the
indexer process itself is not involved):

1. **`GET /.well-known/apple-app-site-association`** - JSON (Content-Type
   `application/json`, HTTPS, NO redirect, no auth):

```json
{
  "applinks": {
    "apps": [],
    "details": [
      { "appID": "RP4Z22SFSD.com.kachat.app", "paths": ["/post/*"] },
      { "appID": "5V64BP2H3P.com.kachat.app", "paths": ["/post/*"] }
    ]
  }
}
```

   (Both Team IDs found in the project are listed - harmless to include both; the one whose
   provisioning actually signs App Store builds is the one that matters. Verify with
   `curl -s https://kachat.duckdns.org/.well-known/apple-app-site-association`.)

2. **`GET /post/<txid>`** - the no-app fallback: respond `302 Location:
   <App-Store-URL>` (the KaChat listing on apps.apple.com - fill in the real URL). iOS
   auto-opens the App Store app on that URL, so users without KaChat land straight on the
   listing. Optional later upgrade: render a small post-preview page (fetch the post from
   the indexer by txid) with an App Store button instead of a bare redirect - better link
   unfurls in chat apps too.

Note: Apple's CDN fetches the AASA file when the app is installed - after first deploying
it, reinstall the app (or wait for the periodic refresh) before judging whether links open
the app.

3. **`GET /.well-known/assetlinks.json`** - the Android equivalent of the AASA file (the
   Android app declares an autoVerify intent filter for `https://kachat.duckdns.org/post/*`):

```json
[{
  "relation": ["delegate_permission/common.handle_all_urls"],
  "target": {
    "namespace": "android_app",
    "package_name": "com.kachat.app",
    "sha256_cert_fingerprints": ["<SHA256 of the Play signing cert - from Play Console > Setup > App integrity>"]
  }
}]
```

   Same serving rules as the AASA file: HTTPS, no redirect, `application/json`. Without it,
   Android falls back to showing an app-chooser for the https link (the `kachat://kapost/`
   scheme form in share texts still opens the app directly either way).
