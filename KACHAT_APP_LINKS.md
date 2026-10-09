# kachat.app links - the link site handoff

Every link the apps hand out is `https://kachat.app/...`:

| Link | Written by | Opens in the app as |
|---|---|---|
| `https://kachat.app/post/<txid>` | KaPosts share sheet (iOS, Android, desktop) | the post's thread |
| `https://kachat.app/broadcast/<room>` | broadcast room invite | the room |
| `https://kachat.app/u/<address>` | the share button beside the Profile title, and Share in User Info | that person's User Info screen (name, avatar, profile, Open Chat) |

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
| `TESTNET_INDEXER_URL` | `https://tnkachat.duckdns.org:7443` | Where `/u/kaspatest:...` links look the person up. |
| `HOME_URL` | `https://home.kachat.app` | The home page. Every link page uses its logo (`/kachat-logo.png`) and its 1200x630 preview image (`/og-image.png`, also `OG_IMAGE`), so the two sites look the same. |
| `APP_STORE_URL` | `https://apps.apple.com/app/id6759102359` | iOS download button + Safari's Smart App Banner. |
| `PLAY_URL` | `https://play.google.com/store/apps/details?id=com.kachat.app` | Android download button. |
| `DESKTOP_URL` | `https://desktop.kachat.app/` | The "Use it in your Browser" button and the bar's "Open web app". |
| `IOS_APP_IDS` | both Team IDs found in the project | `<TeamID>.com.kachat.app` entries in the AASA file. |
| `ANDROID_SHA256` | empty | **Required for Android App Links**: the SHA-256 of the Play App Signing certificate (Play Console > Setup > App integrity). Without it Android shows the browser page with the download buttons, which still works, but never opens the app directly. |

## What the site serves

- `GET /post/<txid>` - fetches the post from the indexer (cached 60 s), decodes the base64
  content and strips the KaChat marker, derives the poster's Kaspa address from their pubkey
  (Kaspa bech32, ported from `Bech32.swift`), looks the poster up (see "People" below), and
  renders the page with `og:title` "<name> on KaChat", `og:description` =
  the post text (300 chars), `og:image` = the avatar (or the home page's `og-image.png`), `twitter:card`,
  a canonical URL and the `apple-itunes-app` Smart App Banner. Replies are never fetched.
  A quote shows its quoted post inline. A missing post renders a "couldn't find" page (no cache).
- `GET /broadcast/<room>` - the invite page, same buttons.
- `GET /u/<address>` - a person's page. `<address>` is a Kaspa address; the apps write mainnet
  ones without the `kaspa:` prefix (a missing prefix means mainnet) and the checksum is
  verified before anything else. Looks the person up (see "People" below) and renders their
  banner, avatar, name, address, bio and Linktree, with `og:title` "Chat with <name>.kachat on
  KaChat" once they have a `.kachat` name ("Chat with me on KaChat" until then), the bio as
  `og:description` and the avatar as `og:image`. Plus a "Chat on KaChat" button
  (`kachat://profile/<address>`) and the store buttons. An invalid address is a 404 page.
- **People** are shown the way the app shows them (KACHAT_NAMES.md section 7), never from KNS:
  `GET /identity/{address}` on the address's network's indexer gives the `.kachat` label and
  the address's profile record. Its `avatar`, `banner` and `bio` are links to the person's own
  social accounts, which the site looks up the way `KachatSocialImageResolver` does (FxTwitter,
  then X's page, then unavatar.io for X; GitHub's and Discord's APIs; the page's Open Graph tags
  for the rest). Each account's answer is cached 24 h (1 min when it couldn't be reached) and a
  lookup never holds a page more than 7 s. The name is `<label>.kachat`, else the shortened
  address. No avatar shows the app's empty-avatar glyph.
- `GET /.well-known/apple-app-site-association` - `applinks` for `/post/*`, `/broadcast/*` and `/u/*`
  for every `IOS_APP_IDS` entry. Served as `application/json`, no redirect - exactly what Apple
  requires. The iOS app carries `applinks:kachat.app` (and still `applinks:kachat.duckdns.org`
  for links already out there).
- `GET /.well-known/assetlinks.json` - the Android equivalent, from `ANDROID_PACKAGE` and
  `ANDROID_SHA256`. The Android app must declare an `autoVerify` intent filter for
  `https://kachat.app/post/*`, `/broadcast/*` and `/u/*` (and keep the `kachat://` scheme filter).
- `GET /download` - 302 to the App Store on iPhone/iPad, Google Play on Android, `DESKTOP_URL`
  elsewhere. Use it anywhere a single "Get KaChat" link is wanted.
- `GET /`, `/eula.html`, `/og-default.png` - the static site. The preview image for invites
  and for people without an avatar is the home page's `og-image.png` (`OG_IMAGE`).

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
- **Android / desktop**: write the same `https://kachat.app/post/<txid>`,
  `/broadcast/<room>` and `/u/<address>` links in their share texts (the `kachat://` scheme form is no longer
  included in share text on iOS - it previews nowhere), accept `kachat.app` links on the way
  in, and add the App Links intent filter above. A `/u/<address>` or `kachat://profile/<address>`
  link opens that address's User Info screen (the per-person profile screen, with Open Chat on
  it). Your own address opens your own User Info - name, avatar, KNS profile, Address, KNS
  Domains, Share - without the per-contact rows, and never adds you as your own contact
  (iOS: `KaChatLinkRouter.openProfile`).
