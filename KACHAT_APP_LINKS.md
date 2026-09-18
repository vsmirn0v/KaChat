# kachat.app links - the link site handoff

Every link the apps hand out is `https://kachat.app/...`:

| Link | Written by | Opens in the app as |
|---|---|---|
| `https://kachat.app/post/<txid>` | KaPosts share sheet (iOS, Android, desktop) | the post's thread |
| `https://kachat.app/broadcast/<room>` | broadcast room invite | the room |

One link, three behaviours:

1. **Pasted into any chat app** (iMessage, WhatsApp, Telegram, Signal, X, Discord, Slack,
   Facebook, LinkedIn...) it unfurls a preview: the poster's name and avatar, the post text.
   Those apps read the Open Graph / Twitter Card tags the site serves.
2. **Tapped on a phone with KaChat installed** it opens straight into the post (iOS Universal
   Links, Android App Links) - never the browser.
3. **Tapped without KaChat** it opens the site's page: the post itself (the post ONLY - no
   replies, no likes), a note that replies and reactions live in the app, an "Open in KaChat"
   button, and download buttons for the App Store, Google Play and the desktop app.

`web_site/server/` is the site. Plain Node 18+, no dependencies, one file (`server.js`). It
serves the existing static pages (`web_site/index.html`, `eula.html`), the two preview
routes, the two `.well-known` files the phones verify against, and `/download` (a
per-platform store redirect).

## Deploy (Docker + Caddy, automatic HTTPS)

On the box that will answer for kachat.app:

```bash
git clone https://github.com/vsmirn0v/KaChat.git && cd KaChat/web_site
cp server/.env.example server/.env        # fill in ANDROID_SHA256 at least (see below)
docker compose -f server/docker-compose.yml up -d --build
```

DNS: `kachat.app` and `www.kachat.app` -> A/AAAA records to that box. Caddy (in the compose
file) obtains and renews the Let's Encrypt certificate itself; ports 80 and 443 must reach it.

Environment (`server/.env`):

| Variable | Default | Meaning |
|---|---|---|
| `INDEXER_URL` | `https://kachat.duckdns.org` | The KaPosts indexer; the site calls `GET /get-post?id=<txid>`. |
| `INDEXER_REQUESTER_PUBKEY` | a nobody placeholder | `get-post` requires a `requesterPubkey` (it only personalises `isUpvoted` & co.); the placeholder is accepted as-is by the current indexer. |
| `KNS_URL` | `https://api.knsdomains.org/mainnet/api/v1` | Poster name (`/primary-name/<address>`) and avatar (`/domain/<assetId>/profile`). |
| `APP_STORE_URL` | `https://apps.apple.com/app/id6759102359` | iOS download button + Safari's Smart App Banner. |
| `PLAY_URL` | `https://play.google.com/store/apps/details?id=com.kachat.app` | Android download button. |
| `DESKTOP_URL` | `https://kachat.app/#desktop` | Desktop download button - point it at the real desktop download page. |
| `IOS_APP_IDS` | both Team IDs found in the project | `<TeamID>.com.kachat.app` entries in the AASA file. |
| `ANDROID_SHA256` | empty | **Required for Android App Links**: the SHA-256 of the Play App Signing certificate (Play Console > Setup > App integrity). Without it Android shows the browser page with the download buttons, which still works, but never opens the app directly. |

## What the site serves

- `GET /post/<txid>` - fetches the post from the indexer (cached 60 s), decodes the base64
  content and strips the KaChat marker, derives the poster's Kaspa address from their pubkey
  (Kaspa bech32, ported from `Bech32.swift`), resolves the KNS primary name and avatar
  (cached 1 h), and renders the page with `og:title` "<name> on KaChat", `og:description` =
  the post text (300 chars), `og:image` = the avatar (or `og-default.png`), `twitter:card`,
  a canonical URL and the `apple-itunes-app` Smart App Banner. Replies are never fetched.
  A quote shows its quoted post inline. A missing post renders a "couldn't find" page (no cache).
- `GET /broadcast/<room>` - the invite page, same buttons.
- `GET /.well-known/apple-app-site-association` - `applinks` for `/post/*` and `/broadcast/*`
  for every `IOS_APP_IDS` entry. Served as `application/json`, no redirect - exactly what Apple
  requires. The iOS app carries `applinks:kachat.app` (and still `applinks:kachat.duckdns.org`
  for links already out there).
- `GET /.well-known/assetlinks.json` - the Android equivalent, from `ANDROID_PACKAGE` and
  `ANDROID_SHA256`. The Android app must declare an `autoVerify` intent filter for
  `https://kachat.app/post/*` and `/broadcast/*` (and keep the `kachat://` scheme filter).
- `GET /download` - 302 to the App Store on iPhone/iPad, Google Play on Android, `DESKTOP_URL`
  elsewhere. Use it anywhere a single "Get KaChat" link is wanted.
- `GET /`, `/eula.html`, `/og-default.png` - the static site. **Replace `og-default.png`**
  (a 1200x630 placeholder in the brand teal) with real artwork; it is the preview image for
  invites and for posters without a KNS avatar.

## Verify

```bash
curl -sI https://kachat.app/.well-known/apple-app-site-association | grep -i content-type   # application/json
curl -s  https://kachat.app/.well-known/assetlinks.json
curl -s  https://kachat.app/post/<a real txid> | grep -o '<meta property="og:[a-z:]*" content="[^"]*"'
```

Then paste a post link into iMessage and into WhatsApp: both should show the poster and the
text. On a phone with KaChat, tapping it must open the app (after the first install following
the deploy - Apple fetches the AASA file at install time; reinstall the app once if a link still
opens Safari). Facebook's and X's crawlers cache aggressively: use their "sharing debugger" /
"card validator" to refresh a URL after changing the page.

## Apps

- **iOS** (done in this repo): writes `https://kachat.app/...` in every share, opens both
  `kachat.app` and the old `kachat.duckdns.org` links, entitlement `applinks:kachat.app`.
- **Android / desktop**: write the same `https://kachat.app/post/<txid>` and
  `/broadcast/<room>` links in their share texts (the `kachat://` scheme form is no longer
  included in share text on iOS - it previews nowhere), accept `kachat.app` links on the way
  in, and add the App Links intent filter above.
