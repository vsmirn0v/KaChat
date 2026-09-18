// kachat.app - the link site.
//
// Every link KaChat hands out is https://kachat.app/... so it unfurls everywhere (iMessage,
// WhatsApp, Telegram, X, Discord, Slack, Signal - anything that reads Open Graph tags) and
// opens the app when it is installed (Universal Links on iOS, App Links on Android, both
// verified against the two .well-known files served here). Without the app, a person lands
// on a page that shows the post itself - the post only, never the replies - and points at
// the App Store, Google Play and the desktop app.
//
// Plain Node 18+, no dependencies. Configuration is environment variables (see .env.example).

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8080);
const SITE_ORIGIN = (process.env.SITE_ORIGIN || 'https://kachat.app').replace(/\/$/, '');
const INDEXER_URL = (process.env.INDEXER_URL || 'https://kachat.duckdns.org').replace(/\/$/, '');
// The indexer's get-post refuses to answer without a requesterPubkey (it only personalises
// isUpvoted & co.); a site has none, so it sends a fixed placeholder that is a valid
// compressed pubkey shape and belongs to nobody.
const INDEXER_REQUESTER_PUBKEY = process.env.INDEXER_REQUESTER_PUBKEY || '020000000000000000000000000000000000000000000000000000000000000001';
const KNS_URL = (process.env.KNS_URL || 'https://api.knsdomains.org/mainnet/api/v1').replace(/\/$/, '');
const APP_STORE_URL = process.env.APP_STORE_URL || 'https://apps.apple.com/app/id6759102359';
const PLAY_URL = process.env.PLAY_URL || 'https://play.google.com/store/apps/details?id=com.kachat.app';
const DESKTOP_URL = process.env.DESKTOP_URL || 'https://kachat.app/#desktop';
const IOS_APP_IDS = (process.env.IOS_APP_IDS || 'RP4Z22SFSD.com.kachat.app,5V64BP2H3P.com.kachat.app').split(',').map(s => s.trim()).filter(Boolean);
const ANDROID_PACKAGE = process.env.ANDROID_PACKAGE || 'com.kachat.app';
const ANDROID_SHA256 = (process.env.ANDROID_SHA256 || '').split(',').map(s => s.trim()).filter(Boolean);
const APPLE_APP_ID = process.env.APPLE_APP_ID || '6759102359';
const STATIC_DIR = process.env.STATIC_DIR || path.resolve(__dirname, '..');

// The invisible KaChat marker every KaPost carries (KaPostsAPIClient.kaChatMarker).
const KACHAT_MARKER = '⁠';

// ---------------------------------------------------------------- tiny cache
const cache = new Map();
function cached(key, ttlMs, producer) {
  const hit = cache.get(key);
  if (hit && hit.expires > Date.now()) return hit.value;
  const value = producer();
  cache.set(key, { value, expires: Date.now() + ttlMs });
  if (cache.size > 5000) cache.delete(cache.keys().next().value);
  return value;
}

async function fetchJSON(url, timeoutMs = 8000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, { signal: controller.signal, headers: { accept: 'application/json' } });
    if (!res.ok) return { status: res.status, body: null };
    return { status: res.status, body: await res.json() };
  } catch (e) {
    return { status: 0, body: null };
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------- Kaspa address from pubkey
// A straight port of KaChat's Bech32.swift (Kaspa's bech32 variant): version byte prepended
// before the 8->5 bit regroup, lowercase-masked prefix expansion, 40-bit polymod.
const CHARSET = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const GENERATOR = [0x98f2bc8e61n, 0x79b76d99e2n, 0xf33e5fb3c4n, 0xae2eabe2a8n, 0x1e4f43e470n];

function polymod(values) {
  let chk = 1n;
  for (const v of values) {
    const top = chk >> 35n;
    chk = ((chk & 0x07ffffffffn) << 5n) ^ BigInt(v);
    for (let i = 0n; i < 5n; i++) {
      if (((top >> i) & 1n) === 1n) chk ^= GENERATOR[Number(i)];
    }
  }
  return chk;
}

function convertBits(data, from, to, pad) {
  let acc = 0, bits = 0;
  const out = [];
  const maxv = (1 << to) - 1;
  for (const value of data) {
    if (value >> from !== 0) return null;
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      out.push((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) out.push((acc << (to - bits)) & maxv);
  } else if (bits >= from || ((acc << (to - bits)) & maxv)) {
    return null;
  }
  return out;
}

function kaspaAddress(pubkeyHex, hrp = 'kaspa') {
  if (!/^[0-9a-fA-F]+$/.test(pubkeyHex)) return null;
  let bytes = Buffer.from(pubkeyHex, 'hex');
  if (bytes.length === 33) bytes = bytes.subarray(1);
  if (bytes.length !== 32) return null;
  const values = convertBits([0, ...bytes], 8, 5, true);
  if (!values) return null;
  const expanded = [...hrp].map(c => c.charCodeAt(0) & 0x1f);
  expanded.push(0);
  const poly = polymod([...expanded, ...values, 0, 0, 0, 0, 0, 0, 0, 0]) ^ 1n;
  const checksum = [];
  for (let i = 0; i < 8; i++) checksum.push(Number((poly >> BigInt(5 * (7 - i))) & 31n));
  return hrp + ':' + [...values, ...checksum].map(v => CHARSET[v]).join('');
}

// ---------------------------------------------------------------- data
async function loadPost(txid) {
  return cached('post:' + txid, 60_000, async () => {
    const query = new URLSearchParams({ id: txid });
    if (INDEXER_REQUESTER_PUBKEY) query.set('requesterPubkey', INDEXER_REQUESTER_PUBKEY);
    const { status, body } = await fetchJSON(`${INDEXER_URL}/get-post?${query}`);
    if (status === 404) return { missing: true };
    const post = body && body.post;
    if (!post || !post.postContent) return null;
    let text = '';
    try { text = Buffer.from(post.postContent, 'base64').toString('utf8'); } catch (_) { return null; }
    text = text.split(KACHAT_MARKER).join('').trim();
    return {
      id: post.id,
      pubkey: post.userPublicKey || '',
      text,
      timestamp: Number(post.timestamp) || Date.now(),
      parentPostId: post.parentPostId || null,
      editedAt: post.editedAt ? Number(post.editedAt) : null,
      replies: post.repliesCount || 0,
      likes: post.upVotesCount || 0,
      reposts: post.quotesCount || 0,
      quote: post.quote && post.quote.referencedMessage
        ? { text: safeBase64(post.quote.referencedMessage), pubkey: post.quote.referencedSenderPubkey || '' }
        : null,
    };
  });
}

function safeBase64(s) {
  try { return Buffer.from(s, 'base64').toString('utf8').split(KACHAT_MARKER).join('').trim(); } catch (_) { return ''; }
}

// The poster's KNS name and avatar: primary-name by address, then the domain's profile.
async function loadIdentity(pubkey) {
  const address = kaspaAddress(pubkey);
  if (!address) return { address: null, name: null, avatar: null };
  return cached('id:' + address, 3_600_000, async () => {
    const out = { address, name: null, avatar: null };
    const primary = await fetchJSON(`${KNS_URL}/primary-name/${address}`);
    const domain = primary.body && primary.body.success && primary.body.data && primary.body.data.domain;
    if (!domain) return out;
    const name = domain.fullName || (domain.name ? `${domain.name}${domain.tld ? '.' + domain.tld : ''}` : null);
    if (name) out.name = String(name).toLowerCase();
    const assetId = domain.assetId || domain.inscriptionId || domain.id;
    if (assetId) {
      const profile = await fetchJSON(`${KNS_URL}/domain/${assetId}/profile`);
      const avatar = profile.body && profile.body.success && profile.body.data && profile.body.data.profile && profile.body.data.profile.avatarUrl;
      if (avatar) out.avatar = /^https?:\/\//i.test(avatar) ? avatar : `https://${avatar}`;
    }
    return out;
  });
}

// ---------------------------------------------------------------- html
function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function displayName(identity) {
  if (identity.name) return identity.name.replace(/\.kas$/i, '');
  if (identity.address) return identity.address.slice(-10);
  return 'Someone';
}

function whenText(ms) {
  const d = new Date(ms);
  return d.toLocaleString('en-US', { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'UTC' }) + ' UTC';
}

function truncate(s, n) {
  return s.length > n ? s.slice(0, n - 1).trimEnd() + '…' : s;
}

// Post text as HTML: escaped, newlines kept, bare URLs and @mentions shown as such (not linked
// - a preview page sends people to the app, not off it).
function textHTML(text) {
  return escapeHTML(text).replace(/\n/g, '<br>');
}

const STORE_BUTTONS = `
  <div class="stores">
    <a class="store" href="${escapeHTML(APP_STORE_URL)}"><span>iPhone &amp; iPad</span><strong>App Store</strong></a>
    <a class="store" href="${escapeHTML(PLAY_URL)}"><span>Android</span><strong>Google Play</strong></a>
    <a class="store" href="${escapeHTML(DESKTOP_URL)}"><span>Mac, Windows, Linux</span><strong>Desktop</strong></a>
  </div>`;

const STYLE = `
  :root { --bg:#f4efe8; --card:#fffdf9; --ink:#0f1f2b; --ink-soft:#37566a; --line:#d9cfc1; --brand:#0a9396; --brand-2:#ee9b00; }
  * { box-sizing: border-box; }
  body { margin:0; font-family: "IBM Plex Sans","Avenir Next","Segoe UI",sans-serif; color:var(--ink); line-height:1.5;
         background: radial-gradient(1200px 500px at 15% -20%, rgba(10,147,150,.2), transparent 60%),
                     radial-gradient(1000px 460px at 95% 0%, rgba(238,155,0,.15), transparent 55%),
                     linear-gradient(180deg, var(--bg) 0%, #efe9df 100%); min-height:100vh; }
  .shell { max-width: 620px; margin: 0 auto; padding: 28px 18px 48px; }
  .brand { display:flex; align-items:center; gap:10px; text-decoration:none; color:var(--ink); font-weight:700; letter-spacing:.2px; }
  .brand .dot { width:14px; height:14px; border-radius:50%; background:var(--brand); box-shadow:0 0 0 4px rgba(10,147,150,.18); }
  .card { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:20px; margin-top:18px; box-shadow:0 18px 32px rgba(16,32,44,.08); }
  .who { display:flex; align-items:center; gap:12px; }
  .avatar { width:48px; height:48px; border-radius:50%; object-fit:cover; background:rgba(10,147,150,.2); flex:none; }
  .name { font-weight:700; } .meta { color:var(--ink-soft); font-size:14px; }
  .text { margin-top:14px; font-size:19px; word-wrap:break-word; overflow-wrap:anywhere; }
  .quote { margin-top:12px; border:1px solid var(--line); border-radius:12px; padding:12px; color:var(--ink-soft); font-size:15px; }
  .counts { margin-top:14px; color:var(--ink-soft); font-size:14px; display:flex; gap:16px; }
  .note { margin-top:22px; padding:16px 18px; border-radius:14px; background:rgba(238,155,0,.12); border:1px solid rgba(238,155,0,.35); }
  .note strong { display:block; margin-bottom:4px; }
  .stores { display:grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap:10px; margin-top:16px; }
  .store { display:block; text-decoration:none; color:var(--ink); background:var(--card); border:1px solid var(--line); border-radius:12px; padding:12px 14px; }
  .store span { display:block; font-size:12px; color:var(--ink-soft); } .store strong { font-size:16px; }
  .open { display:inline-block; margin-top:16px; background:var(--brand); color:#fff; text-decoration:none; font-weight:700; padding:12px 18px; border-radius:999px; }
  .foot { margin-top:28px; color:var(--ink-soft); font-size:13px; }
  .foot a { color:var(--brand); }
`;

function page({ title, description, image, canonical, appArgument, body, largeImage }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHTML(title)}</title>
<meta name="description" content="${escapeHTML(description)}">
<link rel="canonical" href="${escapeHTML(canonical)}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="KaChat">
<meta property="og:title" content="${escapeHTML(title)}">
<meta property="og:description" content="${escapeHTML(description)}">
<meta property="og:url" content="${escapeHTML(canonical)}">
<meta property="og:image" content="${escapeHTML(image)}">
<meta name="twitter:card" content="${largeImage ? 'summary_large_image' : 'summary'}">
<meta name="twitter:title" content="${escapeHTML(title)}">
<meta name="twitter:description" content="${escapeHTML(description)}">
<meta name="twitter:image" content="${escapeHTML(image)}">
<meta name="apple-itunes-app" content="app-id=${escapeHTML(APPLE_APP_ID)}, app-argument=${escapeHTML(appArgument)}">
<meta name="theme-color" content="#0a9396">
<link rel="icon" href="/favicon.ico">
<style>${STYLE}</style>
</head>
<body>
<div class="shell">
  <a class="brand" href="/"><span class="dot"></span>KaChat</a>
  ${body}
  <p class="foot">KaChat is end-to-end encrypted messaging, payments and posts on the Kaspa network. <a href="/">kachat.app</a></p>
</div>
</body>
</html>`;
}

function postPage(txid, post, identity, quoteIdentity) {
  const name = displayName(identity);
  const canonical = `${SITE_ORIGIN}/post/${encodeURIComponent(txid)}`;
  const description = truncate(post.text || (post.quote ? 'Reposted a post on KaChat' : 'A post on KaChat'), 300);
  const avatar = identity.avatar || `${SITE_ORIGIN}/og-default.png`;
  const edited = post.editedAt ? ' · edited' : '';
  const replyLine = post.parentPostId ? `<div class="meta">Replying to a post</div>` : '';
  const quoteBlock = post.quote
    ? `<div class="quote"><strong>${escapeHTML(displayName(quoteIdentity || {}))}</strong><br>${textHTML(truncate(post.quote.text, 400))}</div>`
    : '';
  const body = `
  <div class="card">
    <div class="who">
      <img class="avatar" src="${escapeHTML(avatar)}" alt="">
      <div>
        <div class="name">${escapeHTML(name)}</div>
        <div class="meta">${escapeHTML(whenText(post.timestamp))}${edited}</div>
      </div>
    </div>
    ${replyLine}
    <div class="text">${textHTML(post.text)}</div>
    ${quoteBlock}
    <div class="counts"><span>${post.likes} likes</span><span>${post.replies} replies</span><span>${post.reposts} reposts</span></div>
  </div>
  <div class="note">
    <strong>Replies, likes and reposts live in the app.</strong>
    This page shows the post only. To read the replies or react to it, open it in KaChat.
    <br><a class="open" href="kachat://kapost/${encodeURIComponent(txid)}">Open in KaChat</a>
  </div>
  <p class="meta" style="margin-top:22px">Don't have KaChat yet? It's free.</p>
  ${STORE_BUTTONS}`;
  return page({
    title: `${name} on KaChat`,
    description,
    image: avatar,
    canonical,
    appArgument: canonical,
    body,
    largeImage: !identity.avatar,
  });
}

function broadcastPage(channel) {
  const canonical = `${SITE_ORIGIN}/broadcast/${encodeURIComponent(channel)}`;
  const body = `
  <div class="card">
    <div class="name" style="font-size:22px">#${escapeHTML(channel)}</div>
    <div class="meta">A public room on KaChat</div>
    <div class="text">You've been invited to join <strong>#${escapeHTML(channel)}</strong>. Rooms are open to everyone with the app; messages are on the Kaspa network.</div>
  </div>
  <div class="note">
    <strong>Rooms live in the app.</strong>
    Open this invite in KaChat to join and read the room.
    <br><a class="open" href="kachat://broadcast/${encodeURIComponent(channel)}">Open in KaChat</a>
  </div>
  <p class="meta" style="margin-top:22px">Don't have KaChat yet? It's free.</p>
  ${STORE_BUTTONS}`;
  return page({
    title: `Join #${channel} on KaChat`,
    description: `An invite to the #${channel} room on KaChat.`,
    image: `${SITE_ORIGIN}/og-default.png`,
    canonical,
    appArgument: canonical,
    body,
    largeImage: true,
  });
}

function notFoundPage(what) {
  const body = `
  <div class="card">
    <div class="name" style="font-size:22px">${escapeHTML(what)}</div>
    <div class="text">It may be brand new and not indexed yet, or it may have been deleted. Open it in KaChat to be sure.</div>
  </div>
  ${STORE_BUTTONS}`;
  return page({
    title: 'KaChat',
    description: 'Encrypted messaging, payments and posts on Kaspa.',
    image: `${SITE_ORIGIN}/og-default.png`,
    canonical: SITE_ORIGIN,
    appArgument: SITE_ORIGIN,
    body,
    largeImage: true,
  });
}

// ---------------------------------------------------------------- well-known
function aasa() {
  const paths = ['/post/*', '/broadcast/*'];
  return JSON.stringify({
    applinks: { apps: [], details: IOS_APP_IDS.map(appID => ({ appID, paths })) },
    // Also lets the Intents / Share extensions open these links - harmless without them.
    webcredentials: { apps: IOS_APP_IDS },
  });
}

function assetlinks() {
  return JSON.stringify([{
    relation: ['delegate_permission/common.handle_all_urls'],
    target: { namespace: 'android_app', package_name: ANDROID_PACKAGE, sha256_cert_fingerprints: ANDROID_SHA256 },
  }]);
}

// ---------------------------------------------------------------- routing
const TXID = /^[A-Za-z0-9_-]{8,128}$/;
const CHANNEL = /^[a-z0-9][a-z0-9_-]{0,35}$/i;

function send(res, status, type, body, extraHeaders = {}) {
  res.writeHead(status, { 'content-type': type, 'cache-control': 'public, max-age=60', 'x-content-type-options': 'nosniff', ...extraHeaders });
  res.end(body);
}

function serveStatic(res, name) {
  const file = path.join(STATIC_DIR, name);
  if (!file.startsWith(STATIC_DIR) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) return false;
  const types = { '.html': 'text/html; charset=utf-8', '.png': 'image/png', '.ico': 'image/x-icon', '.svg': 'image/svg+xml', '.css': 'text/css', '.js': 'text/javascript', '.txt': 'text/plain' };
  send(res, 200, types[path.extname(file)] || 'application/octet-stream', fs.readFileSync(file), { 'cache-control': 'public, max-age=3600' });
  return true;
}

function storeRedirect(req, res) {
  const ua = String(req.headers['user-agent'] || '');
  const target = /iPhone|iPad|iPod/i.test(ua) ? APP_STORE_URL : /Android/i.test(ua) ? PLAY_URL : DESKTOP_URL;
  res.writeHead(302, { location: target, 'cache-control': 'no-store' });
  res.end();
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, SITE_ORIGIN);
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);

    if (url.pathname === '/.well-known/apple-app-site-association') return send(res, 200, 'application/json', aasa(), { 'cache-control': 'public, max-age=3600' });
    if (url.pathname === '/.well-known/assetlinks.json') return send(res, 200, 'application/json', assetlinks(), { 'cache-control': 'public, max-age=3600' });
    if (url.pathname === '/download' || url.pathname === '/get') return storeRedirect(req, res);
    if (url.pathname === '/healthz') return send(res, 200, 'text/plain', 'ok', { 'cache-control': 'no-store' });

    if (parts.length === 2 && parts[0] === 'post') {
      const txid = parts[1];
      if (!TXID.test(txid)) return send(res, 404, 'text/html; charset=utf-8', notFoundPage("That link isn't a KaChat post"));
      const post = await loadPost(txid);
      if (!post || post.missing) return send(res, 404, 'text/html; charset=utf-8', notFoundPage("We couldn't find that post"), { 'cache-control': 'no-store' });
      const [identity, quoteIdentity] = await Promise.all([
        loadIdentity(post.pubkey),
        post.quote && post.quote.pubkey ? loadIdentity(post.quote.pubkey) : Promise.resolve(null),
      ]);
      return send(res, 200, 'text/html; charset=utf-8', postPage(txid, post, identity, quoteIdentity));
    }

    if (parts.length === 2 && parts[0] === 'broadcast') {
      const channel = parts[1].replace(/^#/, '').toLowerCase();
      if (!CHANNEL.test(channel)) return send(res, 404, 'text/html; charset=utf-8', notFoundPage("That link isn't a KaChat room"));
      return send(res, 200, 'text/html; charset=utf-8', broadcastPage(channel));
    }

    if (url.pathname === '/') return serveStatic(res, 'index.html') || send(res, 200, 'text/plain', 'KaChat');
    if (parts.length === 1 && serveStatic(res, parts[0])) return;

    return send(res, 404, 'text/html; charset=utf-8', notFoundPage('Nothing here'));
  } catch (error) {
    console.error(error);
    send(res, 500, 'text/plain', 'error', { 'cache-control': 'no-store' });
  }
});

server.listen(PORT, () => console.log(`kachat.app link site on :${PORT} (indexer ${INDEXER_URL})`));
