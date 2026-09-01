# KaChat Post Translation Service — Handoff & Build Guide

**Audience:** the AI/engineer on the server box. This doc specifies a translation endpoint that
serves the KaChat apps (iOS and Android) so a reader can translate a KaPost written in another
language. It runs on the same host as the KaPosts indexer by default (`kachat.duckdns.org`), but
has its own client setting — Settings → Connection Settings → **Translation Service** — so anyone
can point the app at a translator they host themselves without also having to run their own
KaPosts indexer.

Both apps are already wired to consume this. `PostTranslationService` in
`KaChat/Services/PostTranslationService.swift` (iOS) and
`app/src/main/java/com/kachat/app/services/PostTranslationService.kt` (Android) define the exact
contract. Those clients are the source of truth — build the server to satisfy them.

## 1. Why this exists

Translation used to run **on the device**: Apple's Translation framework on iOS 18+, ML Kit on
Android. That works and is private, but it costs the reader a per-language-pair model download of
tens of megabytes before the first translation completes, it is unavailable entirely on iOS 16 and
17, and every device translates the same post over again.

Moving it to the server is what X does, and it buys three things:

1. **No download, no wait.** The first tap returns in one round trip.
2. **Every OS version.** The affordance no longer disappears on older iOS.
3. **Translate once, serve forever.** This is the part X cannot do as cheaply as you can: **a
   KaPost is immutable**. Its text is fixed on-chain the moment it is published, so a translation
   of `(txid, targetLanguage)` is correct permanently. Cache it and the second reader of that post
   in that language costs you nothing but a database read.

### The privacy trade this makes

Be aware of what changed, because the on-device design was chosen deliberately for this reason.
KaPost **content** is public — it is on the Kaspa blockDAG, anyone can read it. But **which posts
a particular reader stopped to translate** was previously known only to their phone, and now it
reaches this server. Design accordingly:

- **Send no identity.** The endpoint takes no `requesterPubkey`, no auth token, no account id.
  Unlike every other KaPosts endpoint, it must not require or accept one.
- **Do not log request bodies or per-request client IPs** beyond what is needed to rate-limit,
  and keep those counters short-lived.
- **Warm the cache proactively** (§6). The more requests that are cache hits on posts translated
  before anyone asked, the less any single request says about the reader.

## 2. The endpoint

### `POST /translate`

Request:

```json
{
  "target": "en",
  "posts": [
    { "id": "1943b5083d67c98cac49c775e1809d8c1b317053a02b2489206fab7a5fca026f", "text": "hola mundo" },
    { "id": "6068917e087d...", "text": "..." }
  ]
}
```

- `target` — required. BCP-47 primary language subtag of the reader's language (`en`, `pt`, `zh`).
  The client sends the bare language, never a region.
- `posts` — required, 1 to 50 entries. **The shipping clients send exactly one**, because the
  affordance is per-post (tap Translate under the post you want). The array is in the contract
  so a future "translate everything on screen" action does not need a new endpoint.
- `posts[].id` — the post's transaction id, when the client has one. **Optional**: a post the
  client resolved straight off the chain may be outside the indexer's window. Without an id, the
  server translates and does not cache.
- `posts[].text` — the source text as the client has it, marker already stripped. **Optional when
  `id` is present** — see the cache-poisoning rule below, which is why the server should prefer
  its own copy anyway.

Response `200`:

```json
{
  "translations": [
    {
      "id": "1943b508...",
      "source": "es",
      "target": "en",
      "text": "hello world",
      "cached": true
    }
  ]
}
```

- `source` — the detected source language. The client shows this in "Translated from Spanish", so
  return a bare BCP-47 subtag and let the client localize the name.
- `text` — the translation. When `source == target`, return the input unchanged with
  `"untranslated": true` rather than an error; the client's detection is a guess and is sometimes
  wrong, and echoing the text is a better outcome than a failure banner under a readable post.
- `cached` — optional, for your own observability. Clients ignore it.
- Order is not significant; clients match on `id` (or on position when no id was sent).

Per-entry failure does not fail the batch. Return the entry with an `error` and no `text`:

```json
{ "id": "6068917e...", "error": "Unsupported language pair", "code": "UNSUPPORTED_PAIR" }
```

Whole-request errors use the same shape the other KaPosts endpoints already use, which the
clients' error handling expects:

```json
{ "error": "Invalid post id. Must be 64 hex characters.", "code": "INVALID_POST_ID" }
```

Codes to implement: `MISSING_PARAMETER`, `INVALID_POST_ID`, `TOO_MANY_POSTS`, `TEXT_TOO_LONG`,
`UNSUPPORTED_PAIR`, `RATE_LIMITED`, `TRANSLATION_FAILED`.

### `GET /translate/languages`

```json
{ "source": ["ar","de","en","es","fr","..."], "target": ["ar","de","en","es","fr","..."] }
```

Lets a client stop offering a link it knows will fail. Cache-friendly; clients fetch it at most
once per launch and fall back to "offer anyway" if it is unavailable.

## 3. Rules the server must hold

**Never cache a translation under a txid whose text you did not verify.** `posts[].text` is
attacker-controlled: anyone can POST an arbitrary string with someone else's txid. If you cache
that under the txid, you have let a stranger rewrite what every future reader sees that post say.
So:

- If you hold the post (indexer DB) or can read it from the chain: translate **your** copy, ignore
  the supplied text, and cache under the txid.
- If you do not hold it: translate the supplied text, return it, and **do not cache**. Reading the
  transaction yourself is cheap (`GET /transactions/<txid>` on the Kaspa REST API, parse the
  `kchat:1:` payload — the clients do exactly this, see `KaPostChainReader`), so preferring that
  path over trusting the body is worth it.

Other rules:

- **Cache key is `(txid, target)`.** Immutable, so no TTL and no invalidation. A post translated a
  year ago is still correctly translated.
- **Length cap**: posts are capped at 25,000 characters client-side
  (`POST_CHARACTER_LIMIT`). Reject longer with `TEXT_TOO_LONG`.
- **Strip before detecting.** URLs and `@mentions` skew language identification badly; a post that
  is mostly a link identifies as whatever language its URL letters resemble. The clients strip
  `https?://\S+` and `@[A-Za-z0-9._-]+` before their own detection — do the same before yours.
- **Preserve the text otherwise.** No trimming of newlines, no collapsing whitespace, no HTML
  escaping. KaPosts renders markdown; mangling it shows up immediately.
- **Rate-limit by IP**, generously — a reader scrolling a multilingual feed legitimately sends
  batches. Something like 60 requests or 600 posts per minute, returning `RATE_LIMITED`.
- **No auth.** Deliberately, per §1.

## 4. Suggested implementation

LibreTranslate in Docker, with a thin endpoint in front of it that does the caching and the
txid verification. Self-hosted means no per-character bill, which matters because the whole point
of the cache is that you translate a popular post once and serve it thousands of times.

```yaml
# docker-compose.yml (fragment)
services:
  libretranslate:
    image: libretranslate/libretranslate:latest
    restart: unless-stopped
    environment:
      # Preload only what you serve; each pair is a model in memory.
      LT_LOAD_ONLY: "en,es,pt,fr,de,it,nl,ru,uk,tr,ar,hi,id,ja,ko,zh"
      LT_DISABLE_WEB_UI: "true"
      LT_THREADS: "4"
    expose:
      - "5000"
    volumes:
      - lt-models:/home/libretranslate/.local/share/argos-translate

volumes:
  lt-models:
```

LibreTranslate's own API is `POST /translate {q, source, target}` with `source: "auto"` for
detection, and `POST /detect {q}`. Your endpoint is a wrapper: check cache, verify text, call
LibreTranslate for the misses, write the cache, return the batch.

Alternatives if quality matters more than cost: DeepL (best quality, per-character billing,
limited language list) or Google Cloud Translation (widest coverage, per-character). The endpoint
contract above is deliberately engine-agnostic — swapping the backend should not touch the clients.

Schema sketch:

```sql
CREATE TABLE post_translations (
  post_id     TEXT NOT NULL,     -- Kaspa txid, 64 hex
  target_lang TEXT NOT NULL,     -- BCP-47 primary subtag
  source_lang TEXT NOT NULL,     -- detected
  text        TEXT NOT NULL,
  created_at  BIGINT NOT NULL,
  PRIMARY KEY (post_id, target_lang)
);
```

## 5. Optional, and worth doing: language at index time

The clients currently identify a post's language **on the device** to decide whether to offer a
Translate link at all. That is cheap and offline, but it is a guess, and it is the last piece of
translation still running client-side.

If the indexer detects and stores each post's language when it indexes it, and returns it as a
`language` field on the post object in `get-posts` / `get-posts-watching` / `get-replies`, the
clients can drop their own detection entirely and offer the link based on your answer, which is
better than theirs (you see the whole post, you can afford a real model, and you compute it once
for everyone instead of once per reader per scroll).

Add it as a nullable field; the clients keep their local detection as a fallback for deployments
that do not send it.

## 6. Cache warming

Every post the indexer sees can be translated ahead of demand into the languages your readers
actually use. This is the difference between a translation feature and a fast one, and it is also
the strongest privacy mitigation available (§1): a request served from a cache filled before
anyone asked reveals nothing about who asked.

A reasonable policy:

- On index, detect the post's language.
- If it is not English, queue a translation to English.
- Track which `target` values you are actually asked for; keep the top few and warm those too.
- Warm at low priority, rate-limited, well behind serving live requests.

## 7. Checklist

1. `POST /translate` (batch, no auth) and `GET /translate/languages`, error shapes per §2.
2. Cache keyed `(txid, target)`, written **only** for text the server verified itself (§3).
3. LibreTranslate behind it, preloaded with the languages you serve (§4).
4. Rate limiting by IP; no request-body logging.
5. Then, in order of value: cache warming (§6), then `language` on the post objects (§5).
