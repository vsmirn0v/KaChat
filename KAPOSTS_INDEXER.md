# KaPosts Indexer — Handoff & Build Guide

**Audience:** the AI/engineer on the server box that will build and host the KaChat-owned
KaPosts indexer. This doc is the starting context: what the iOS app (branch `KaChat4.0i`)
already speaks, what the public K indexer gives us today, and exactly what the new indexer
must add on top. The single client integration point in the app is
`KaChat/Services/KaPostsAPIClient.swift` — read it alongside this doc; every wire shape the
app expects is defined there.

> Only here for the reply-thread work? `KAPOSTS_REPLIES_FIX.md` is the short version: the two
> endpoints to add and why, without the protocol and build material below.

## 1. What KaPosts is

KaPosts is a Twitter/X-style social feed inside KaChat. **Everything is on-chain**: each
action (post, reply, vote, follow, quote/repost) is a Kaspa **self-send transaction**
(outputs pay back to the author's own address) whose `payload` field carries a `kchat:1:...`
protocol string (the legacy `k:1:` root exists on chain from before the migration - read it,
never write it; see §2). The indexer's job is to scan the DAG for these payloads, verify signatures,
and serve a REST read API. **The transaction id IS the content id.**

Today the app runs against the public K social indexer (`https://mainnet.kaspatalk.net`,
configurable in Settings → Connection Settings → "KaPost Indexer"). The new indexer replaces
it. Keeping the same endpoint paths/response shapes means the app works by just changing
that URL — that is the compatibility bar. Extensions below are additive.

## 2. Protocol the app writes (must parse verbatim)

Payload strings (all fields `:`-joined, prefix **`kchat:1:`** - `KaPostsProtocol.prefix`):

```
kchat:1:post:<pubkey>:<signature>:<b64_message>:<mentions_json>
kchat:1:reply:<pubkey>:<signature>:<post_id>:<b64_message>:<mentions_json>
kchat:1:vote:<pubkey>:<signature>:<post_id>:<upvote|downvote|unvote>:<author_pubkey>
kchat:1:follow:<pubkey>:<signature>:<follow|unfollow>:<followed_pubkey>
kchat:1:quote:<pubkey>:<signature>:<content_id>:<b64_message>:<quoted_author_pubkey>
kchat:1:unquote:<pubkey>:<signature>:<content_id>
kchat:1:edit:<pubkey>:<signature>:<post_id>:<b64_message>:<mentions_json>
kchat:1:delete:<pubkey>:<signature>:<post_id>
kchat:1:poll:<pubkey>:<signature>:<b64_question>:<options_b64_csv>:<closes_at_ms>:<mentions_json>
kchat:1:pollvote:<pubkey>:<signature>:<poll_id>:<option_index>
```

**Root migration.** The app used to write the K indexer's `k:1:` root; it now writes
`kchat:1:` for every action, and reads both (`KaPostsProtocol.parseChainPayload`). The
indexer must do the same: **scan and verify both roots** (posts from before the migration
are still posts), and treat everything after the root identically. Nothing new is ever
written under `k:1:`. Any new action (polls, scheduling, ...) is defined under `kchat:1:` only.

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
  - edit: `"edit:<post_id>:<b64_message>:<mentions_json>"` — note the literal `edit:` prefix
    inside the signed string (a reply signs the same three fields; without it a reply to your
    own post could be replayed as an edit of it). See §5.7.
  - delete: `"delete:<post_id>"` — same idea (an unquote signs a bare content id). See §5.8.
  - poll: `"poll:<b64_question>:<options_b64_csv>:<closes_at_ms>:<mentions_json>"` — see §5.9.
  - pollvote: `"pollvote:<poll_id>:<option_index>"` — see §5.9.
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
| `get-post?id=<txid>` | **SHIPPED** single-post lookup by txid, any post, same `KPost` shape. Returns `{post: KPost}` |
| `search?q=<text>&type=posts\|users` | **NEEDED — see §5.6** content and people search |
| `get-thread?id=<txid>` | **SHIPPED** the ancestor walk done server-side in one request. Returns `{ancestors: [KPost], post: KPost}`, ancestors ROOT FIRST and excluding the requested post |
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

5. ~~**Single-post lookup — `GET /get-post?id=<txid>`.**~~ **SHIPPED**, along with the
   `get-thread?id=` optimisation described in `KAPOSTS_REPLIES_FIX.md`. Both verified live:
   `get-post?id=` returns `{post: KPost}`, and `get-thread?id=` returns
   `{ancestors: [KPost], post: KPost}` with ancestors root-first.

   The client uses them in `KaPostsAPIClient.fetchPost` / `fetchThread`: shared links and
   notification taps resolve a txid in one request instead of re-fetching feeds and profiles,
   and thread ancestor chains are complete rather than limited to whatever was in memory. The
   chain reader (`KaPostChainReader`) remains the fallback behind both, for the window where a
   post exists on chain but the indexer has not indexed it yet.

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

7. **Edits — the `edit` action (NEW, outstanding; 5.0).** A post, reply or quote can be
   edited by its author for **two hours** after it was posted; after that it is permanent. The
   chain still keeps every version - the indexer's *interpretation* is what changes, exactly
   like `unvote`/`unquote`.

   Payload (§2): `kchat:1:edit:<pubkey>:<signature>:<post_id>:<b64_message>:<mentions_json>`,
   signature over `"edit:<post_id>:<b64_message>:<mentions_json>"`. The app writes it
   immediately (no undo countdown) with `deliveryStatus` pending until the tx is accepted.

   Accept an edit only when ALL of these hold; otherwise ignore it silently:
   - `<post_id>` is a post, reply or quote already indexed, and its `userPublicKey` equals the
     edit's `<pubkey>` (an author edits only their own content);
   - the signature verifies for `<pubkey>` over the signing string above;
   - the edit transaction's chain time is **≤ original.timestamp + 7 200 000 ms**
     (measured from the ORIGINAL post's timestamp, not from a previous edit);
   - `<b64_message>` decodes and, marker stripped, is non-empty.

   Interpretation: the latest accepted edit (by chain time) is the content. In every read
   endpoint that returns a `KPost` (feeds, replies, profiles, `get-post`, `get-thread`,
   search, the embedded `quote.referencedMessage` of quotes), return:
   - `postContent` = the edited base64 message (the original stays retrievable on chain);
   - `timestamp` = the ORIGINAL post's timestamp, unchanged (ordering must not move);
   - **`editedAt`** (new field, ms) = the accepted edit's chain time; absent/null when never
     edited. The apps show "edited" next to the time when it is set.
   `mentions_json` on an edit: treat newly-added pubkeys as mentions for notifications, like
   a post's; do not re-notify pubkeys already mentioned by the original.

   Nothing else changes: votes, quotes, replies and counts all stay attached to the same
   `post_id`. An edit received after the window, or for someone else's post, is dropped with
   no effect.

8. **Deletes — the `delete` action (NEW, outstanding; 5.0).** An author can delete their own
   post, reply or quote at any time. Payload (§2):
   `kchat:1:delete:<pubkey>:<signature>:<post_id>`, signature over `"delete:<post_id>"`.

   Accept when `<post_id>` is an indexed post/reply/quote whose `userPublicKey` equals
   `<pubkey>` and the signature verifies; otherwise ignore. No time window.

   Interpretation once accepted:
   - the post disappears from EVERY read endpoint (feeds, profiles, replies, search,
     bookmarks-by-id, `get-post` → 404, `get-thread` → the deleted level is omitted or 404 when
     it is the requested post itself);
   - its parent's `repliesCount` and, for a quote, the quoted post's `quotesCount` go down by
     one; votes on the deleted post no longer count anywhere;
   - replies TO the deleted post stay (their authors own them) with `parentPostId` unchanged;
     clients render a missing parent as "post deleted";
   - a quote whose `quote.referencedContentId` was deleted keeps its own text and gets
     `quote.referencedMessage = null` (clients show "post deleted" in the embed);
   - notifications about the deleted post can be dropped.

   The chain keeps the bytes, so a client's chain reader may still find the original by txid;
   that is expected and no different from any other removal counter-action.

9. **Polls — the `poll` and `pollvote` actions (NEW, outstanding; 5.1).** A poll is a post
   whose message is the question and which carries two to four options and a closing time;
   a vote is a separate action naming the poll and an option.

   Payloads (§2):
   - `kchat:1:poll:<pubkey>:<signature>:<b64_question>:<options_b64_csv>:<closes_at_ms>:<mentions_json>`
     - `<b64_question>`: base64 of the marker-prefixed question, exactly like a post's message
       (the question IS the post text - an older client that knows no polls shows it as a
       plain post);
     - `<options_b64_csv>`: the options, each base64 of its UTF-8 text, joined with `,`
       (base64 has no `,` or `:`, so the payload still splits cleanly). 2–4 options, each
       1–40 characters decoded, no two identical;
     - `<closes_at_ms>`: unix ms when voting closes. Accept only if it is > the poll
       transaction's chain time and ≤ chain time + 7 days;
     - signature over `"poll:<b64_question>:<options_b64_csv>:<closes_at_ms>:<mentions_json>"`.
   - `kchat:1:pollvote:<pubkey>:<signature>:<poll_id>:<option_index>`, signature over
     `"pollvote:<poll_id>:<option_index>"`. `<option_index>` is 0-based.

   Accept a vote only when `<poll_id>` is an indexed poll, the index is in range, the
   signature verifies, and the vote's chain time is < `closes_at_ms`; otherwise ignore.
   **One vote per pubkey**: a later vote (by chain time) by the same pubkey replaces the
   earlier one. The author may vote in their own poll. `delete` on a poll removes it and its
   votes like any post; `edit` is NOT accepted on a poll (the options are what people voted
   on).

   Interpretation, in every read endpoint that returns a `KPost`: a poll is a post with
   `contentType = "poll"` and a new object
   ```json
   "poll": { "options": ["<b64>", "<b64>"], "counts": [12, 7], "total": 19,
             "closesAt": 1790300000000, "myVote": 1 }
   ```
   `counts[i]` = number of pubkeys whose current vote is option `i`; `total` = their sum;
   `myVote` = the requester's option index or `null` (requester = the `requesterPubkey`
   query the feeds already carry; `null` when absent). Also serve
   `GET /get-poll?postId=&requesterPubkey=` → the same `poll` object plus `"id"`, so a
   client can refresh one poll's numbers without reloading the feed. Votes do not count as
   replies or votes on the post; they produce no notification. A poll appears in feeds
   exactly where a post with the same timestamp would.

10. **Scheduled posts — server-submitted transactions (NEW, outstanding; 5.1).** A post
    scheduled for later is built and **signed on the phone now**, and handed to the indexer,
    which submits it to the network at the chosen time. The phone cannot be counted on to be
    awake at that minute; the server can. The server never signs anything - it only forwards
    bytes it was given.

    - `POST /schedule-post` (JSON body):
      ```json
      { "pubkey": "<66-hex>", "txId": "<the signed tx's id>", "notBefore": 1790300000000,
        "signature": "<128-hex over \"schedule:<txId>:<notBefore>\">",
        "transaction": { ...the signed transaction, kaspa REST /transactions shape... } }
      ```
      `transaction` is the exact JSON the Kaspa REST API's `POST /transactions` accepts
      (`{"transaction":{"version","inputs":[{"previousOutpoint":{"transactionId","index"},
      "signatureScript","sequence","sigOpCount"}],"outputs":[{"amount","scriptPublicKey":
      {"version","scriptPublicKey"}}],"lockTime","subnetworkId","payload"}}` with hex
      strings) - so the server submits it with that call, or via its own kaspad gRPC
      `SubmitTransaction`. Verify the signature for `pubkey`, that the transaction's payload
      is a `kchat:1:` action signed by the same pubkey, and that `notBefore` is between now
      and now + 30 days; store `{txId, pubkey, notBefore, transaction, status: "scheduled"}`.
      Reply `{ "txId", "notBefore", "status": "scheduled" }`. Idempotent on `txId`.
    - At `notBefore` (a scheduler tick each minute is fine): submit the transaction. On
      success `status = "submitted"` with `submittedAt`; on a rejection (typically its inputs
      were spent meanwhile) `status = "failed"` with `error`, and retry nothing - the phone
      shows the failure and the author reposts by hand.
    - `GET /scheduled-posts?pubkey=` → `{ "posts": [{ "txId", "notBefore", "status",
      "submittedAt", "error", "postContent" }] }` - `postContent` is the decoded payload's
      base64 message so the list can show a preview. Only the owner's; `requesterPubkey`
      style auth is not needed since the list carries nothing secret, but do not serve the
      `transaction` bytes back.
    - `POST /cancel-scheduled-post` `{ "pubkey", "txId", "signature": "<over
      \"cancel-schedule:<txId>\">" }` → drops a still-`scheduled` entry (`status =
      "cancelled"`); a submitted one cannot be cancelled (it is on chain).
    - Once submitted, the post indexes like any other `kchat:1:` action - nothing marks it as
      having been scheduled.

    Client side: the phone keeps the coins the transaction spends reserved until it is
    submitted (`KaPostsScheduledStore`), lists its scheduled posts from `/scheduled-posts`,
    and, if the server is unreachable when the time comes, falls back to submitting the
    transaction itself the next time the app runs.

Nice-to-haves once the core is up: richer notifications (mentions, replies to replies), and
a push hook — the app already runs a forked kasia-indexer with a `PushNotificationActor` for
chat push (see `PUSH_NOTIFICATIONS.md`), so mirroring that pattern for social notifications
is natural.

## 6. Getting started pointers

- **Scanning:** you need every accepted transaction's payload. The kasia-indexer fork this
  project already runs (`external/kasia-indexer` is the reference codebase) solves the same
  problem for `kchat:1:comm:` chat payloads (legacy `ciph_msg:`) — same DAG-scan skeleton, different payload prefix
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
- **Order of work:** (1) scan+verify+store `kchat:1:` (and legacy `k:1:`) payloads with marker filtering, (2) serve
  the §4 compatibility endpoints, (3) add removals + actor lists (§5.1–§5.4), (4) add
  `get-post` (§5.5) — smallest change, biggest client win, (5) add `search` (§5.6), (6) flip
  the app to the new URL as default.

- **What "done" looks like from the app side.** Nothing in §5.5 or §5.6 needs an app release
  to start being useful: both are additive endpoints the client will call once they answer.
  If an endpoint is missing the client already falls back (partial ancestor chain,
  feed-paging search), so shipping them one at a time is safe and each one is independently
  observable in the UI.


## 7. Universal Links for shared posts

Superseded: shared links are now `https://kachat.app/post/<txid>` and the site that serves
them - previews, the `.well-known` files for iOS and Android, the no-app download page - is
`web_site/server/` in this repo. See `KACHAT_APP_LINKS.md`. The indexer's only part is
answering `GET /get-post?id=` for the site (ideally without requiring `requesterPubkey`).
