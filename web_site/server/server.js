// kachat.app - the link site.
//
// Every link KaChat hands out is https://kachat.app/... so it unfurls everywhere (iMessage,
// WhatsApp, Telegram, X, Discord, Slack, Signal - anything that reads Open Graph tags) and
// opens the app when it is installed (Universal Links on iOS, App Links on Android, both
// verified against the two .well-known files served here). Without the app, a person lands
// on a page that shows the post itself - the post only, never the replies - and points at
// the App Store, Google Play and the web app.
//
// People are shown the way the app shows them (KACHAT_NAMES.md section 7): the avatar, banner
// and bio come from the social accounts their address's profile record points at, and the name
// is their .kachat name when they have one. Nothing comes from KNS any more.
//
// Plain Node 18+, no dependencies. Configuration is environment variables (see .env.example).

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number(process.env.PORT || 8080);
const SITE_ORIGIN = (process.env.SITE_ORIGIN || 'https://kachat.app').replace(/\/$/, '');
const INDEXER_URL = (process.env.INDEXER_URL || 'https://kachat.duckdns.org').replace(/\/$/, '');
// kaspatest: profile links are looked up on the testnet indexer.
const TESTNET_INDEXER_URL = (process.env.TESTNET_INDEXER_URL || 'https://tnkachat.duckdns.org:7443').replace(/\/$/, '');
// The indexer's get-post refuses to answer without a requesterPubkey (it only personalises
// isUpvoted & co.); a site has none, so it sends a fixed placeholder that is a valid
// compressed pubkey shape and belongs to nobody.
const INDEXER_REQUESTER_PUBKEY = process.env.INDEXER_REQUESTER_PUBKEY || '020000000000000000000000000000000000000000000000000000000000000001';
// The home page (home.kachat.app): its logo and preview image are used here too, so the
// link pages and the home page look the same and the nginx in front only proxies the routes.
const HOME_URL = (process.env.HOME_URL || 'https://home.kachat.app').replace(/\/$/, '');
const LOGO_URL = process.env.LOGO_URL || `${HOME_URL}/kachat-logo.png`;
const OG_IMAGE = process.env.OG_IMAGE || `${HOME_URL}/og-image.png`;
const APP_STORE_URL = process.env.APP_STORE_URL || 'https://apps.apple.com/app/id6759102359';
const PLAY_URL = process.env.PLAY_URL || 'https://play.google.com/store/apps/details?id=com.kachat.app';
const DESKTOP_URL = process.env.DESKTOP_URL || 'https://desktop.kachat.app/';
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

// Like `cached`, but an answer the producer marks `transient` (the source couldn't be reached)
// is kept for `retryMs` only, so one slow lookup doesn't pin a bare preview for the full TTL.
function cachedWithRetry(key, ttlMs, retryMs, producer) {
  const hit = cache.get(key);
  if (hit && hit.expires > Date.now()) return hit.value;
  const value = producer().then(({ result, transient }) => {
    if (transient) {
      const entry = cache.get(key);
      if (entry && entry.value === value) entry.expires = Date.now() + retryMs;
    }
    return result;
  });
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

function isTransient(res) {
  return res.status === 0 || res.status === 429 || res.status >= 500;
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

// A Kaspa address with a valid checksum - the only thing a /u/ link may carry.
const ADDRESS = /^(kaspa|kaspatest):[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{40,100}$/;
function isKaspaAddress(address) {
  if (!ADDRESS.test(address)) return false;
  const [hrp, data] = address.split(':');
  const expanded = [...hrp].map(c => c.charCodeAt(0) & 0x1f);
  expanded.push(0);
  return polymod([...expanded, ...[...data].map(c => CHARSET.indexOf(c))]) === 1n;
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

// ---------------------------------------------------------------- posts
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
      // Numbers, whatever the indexer sent: they go into the page unescaped.
      replies: Math.max(0, Math.floor(Number(post.repliesCount) || 0)),
      likes: Math.max(0, Math.floor(Number(post.upVotesCount) || 0)),
      reposts: Math.max(0, Math.floor(Number(post.quotesCount) || 0)),
      quote: post.quote && post.quote.referencedMessage
        ? { text: safeBase64(post.quote.referencedMessage), pubkey: post.quote.referencedSenderPubkey || '' }
        : null,
    };
  });
}

function safeBase64(s) {
  try { return Buffer.from(s, 'base64').toString('utf8').split(KACHAT_MARKER).join('').trim(); } catch (_) { return ''; }
}

// ---------------------------------------------------------------- social profile links
// A port of the app's KachatNames.SocialSource: a profile record's `avatar`, `banner` and `bio`
// are links to the person's own accounts, and each device - here, this site - looks up what
// that account shows right now. Never stored anywhere but this short-lived cache, so a
// platform's moderation (a removed picture, a suspended account) carries over within a day.
const PLATFORM_FIELDS = {
  x: ['avatar', 'banner', 'bio'], youtube: ['avatar', 'banner', 'bio'], discord: ['avatar', 'banner', 'bio'],
  telegram: ['avatar', 'bio'], twitch: ['avatar', 'bio'], github: ['avatar', 'bio'],
  facebook: ['avatar'], instagram: ['avatar'], tiktok: ['avatar'], linkedin: ['avatar'],
};

function socialSource(raw, kind) {
  let t = String(raw || '').trim();
  if (!t) return null;
  if (!/^https?:\/\//i.test(t)) t = 'https://' + t;
  let u;
  try { u = new URL(t); } catch (_) { return null; }
  const host = u.hostname.toLowerCase().replace(/^(www\.|m\.|mobile\.)/, '');
  const parts = u.pathname.split('/').filter(Boolean);
  const ok = s => !!s && s.length <= 100 && /^[\p{L}\p{N}._@-]+$/u.test(s);
  let platform = null, handle = '', link = '';
  if (host === 'x.com' || host === 'twitter.com') {
    if (parts.length === 1 && ok(parts[0]) && !['home', 'explore', 'search', 'i', 'settings'].includes(parts[0].toLowerCase())) { platform = 'x'; handle = parts[0]; link = `https://x.com/${handle}`; }
  } else if (host === 'youtube.com') {
    if (parts.length >= 1 && parts[0].startsWith('@') && ok(parts[0])) { platform = 'youtube'; handle = parts[0]; }
    else if (parts.length >= 2 && ['channel', 'c', 'user'].includes(parts[0]) && ok(parts[1])) { platform = 'youtube'; handle = `${parts[0]}/${parts[1]}`; }
    if (platform) link = `https://www.youtube.com/${handle}`;
  } else if (host === 'facebook.com' || host === 'fb.com') {
    if (parts.length === 1 && ok(parts[0]) && !['profile.php', 'groups', 'watch', 'events'].includes(parts[0].toLowerCase())) { platform = 'facebook'; handle = parts[0]; link = `https://www.facebook.com/${handle}`; }
  } else if (host === 'instagram.com') {
    if (parts.length === 1 && ok(parts[0]) && !['p', 'reel', 'reels', 'explore', 'stories'].includes(parts[0].toLowerCase())) { platform = 'instagram'; handle = parts[0]; link = `https://www.instagram.com/${handle}/`; }
  } else if (host === 'tiktok.com') {
    if (parts.length === 1 && parts[0].startsWith('@') && ok(parts[0])) { platform = 'tiktok'; handle = parts[0]; link = `https://www.tiktok.com/${handle}`; }
  } else if (host === 'twitch.tv') {
    if (parts.length === 1 && ok(parts[0])) { platform = 'twitch'; handle = parts[0]; link = `https://www.twitch.tv/${handle}`; }
  } else if (host === 'github.com') {
    if (parts.length === 1 && ok(parts[0])) { platform = 'github'; handle = parts[0]; link = `https://github.com/${handle}`; }
  } else if (host === 't.me' || host === 'telegram.me') {
    if (parts.length === 1 && ok(parts[0]) && !parts[0].startsWith('+')) { platform = 'telegram'; handle = parts[0]; link = `https://t.me/${handle}`; }
  } else if (host === 'linkedin.com') {
    if (parts.length >= 2 && ['in', 'company'].includes(parts[0]) && ok(parts[1])) { platform = 'linkedin'; handle = `${parts[0]}/${parts[1]}`; link = `https://www.linkedin.com/${handle}`; }
  } else if (host === 'discord.gg') {
    if (parts.length === 1 && ok(parts[0])) { platform = 'discord'; handle = parts[0]; link = `https://discord.gg/${handle}`; }
  } else if (host === 'discord.com' || host === 'discordapp.com') {
    if (parts.length === 2 && parts[0] === 'invite' && ok(parts[1])) { platform = 'discord'; handle = parts[1]; link = `https://discord.gg/${handle}`; }
  }
  if (!platform || !PLATFORM_FIELDS[platform].includes(kind)) return null;
  return { platform, handle, link };
}

const CRAWLER_AGENT = 'facebookexternalhit/1.1';
const BROWSER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';

async function fetchPage(url, { agent = BROWSER_AGENT, timeoutMs = 4000, cookie, json = false } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const headers = { 'user-agent': agent, 'accept-language': 'en-US,en;q=0.8' };
    if (cookie) headers.cookie = cookie;
    if (json) headers.accept = 'application/json';
    const res = await fetch(url, { signal: controller.signal, headers, redirect: 'follow' });
    const text = (await res.text()).slice(0, 3_000_000);
    return { status: res.status, text };
  } catch (_) {
    return { status: 0, text: '' };
  } finally {
    clearTimeout(timer);
  }
}

function parseJSON(text) { try { return JSON.parse(text); } catch (_) { return null; } }

function decodeEntities(s) {
  if (!s.includes('&')) return s;
  let out = s.replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' ');
  out = out.replace(/&#(x[0-9a-f]+|[0-9]+);/gi, (_, n) => {
    const code = n[0].toLowerCase() === 'x' ? parseInt(n.slice(1), 16) : parseInt(n, 10);
    try { return String.fromCodePoint(code); } catch (_) { return ''; }
  });
  return out.replace(/&amp;/g, '&');
}

function metaContent(html, keys) {
  for (const key of keys) {
    const esc = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const tag = html.match(new RegExp(`<meta[^>]+(?:property|name)=["']${esc}["'][^>]*>`, 'i'));
    if (!tag) continue;
    const c = tag[0].match(/content="([^"]*)"/) || tag[0].match(/content='([^']*)'/);
    if (c && c[1].trim()) return decodeEntities(c[1]).trim();
  }
  return null;
}

function openGraphImage(html) {
  const v = metaContent(html, ['og:image', 'og:image:secure_url', 'twitter:image']);
  return v && /^https:\/\//i.test(v) ? v : null;
}

const MAX_BIO = 160;
function trimmedBio(s) {
  const t = String(s || '').trim();
  return t ? t.slice(0, MAX_BIO) : null;
}

function bioFromPage(platform, description) {
  if (!description) return null;
  if (['x', 'youtube', 'telegram'].includes(platform)) return trimmedBio(description);
  if (platform === 'twitch') return trimmedBio(description.split(' — ')[0]);
  return null; // Instagram, TikTok, Facebook, LinkedIn put follower counts or site text there
}

// What one account shows now: { avatar, banner, bio }, {} when the platform answered with
// nothing (account gone, taken down), or null when it couldn't be reached.
async function lookUpSocial(source) {
  const { platform, handle, link } = source;
  if (platform === 'discord') {
    const r = await fetchPage(`https://discord.com/api/v10/invites/${encodeURIComponent(handle)}`, { json: true });
    if (r.status === 404) return {};
    const guild = r.status === 200 && (parseJSON(r.text) || {}).guild;
    if (!guild) return null;
    return {
      avatar: guild.icon ? `https://cdn.discordapp.com/icons/${guild.id}/${guild.icon}.png?size=256` : null,
      banner: guild.banner ? `https://cdn.discordapp.com/banners/${guild.id}/${guild.banner}.png?size=1024` : null,
      bio: trimmedBio(guild.description),
    };
  }
  if (platform === 'github') {
    const r = await fetchPage(`https://api.github.com/users/${encodeURIComponent(handle)}`, { json: true });
    if (r.status === 404) return {};
    const user = r.status === 200 && parseJSON(r.text);
    if (!user) return null;
    return { avatar: user.avatar_url || null, banner: null, bio: trimmedBio(user.bio) };
  }
  if (platform === 'x') {
    // FxTwitter first: X's own data in one small answer. Its "not found" isn't final (it says
    // that for real accounts too), so X's page decides; unavatar.io is the last resort.
    const fx = await fetchPage(`https://api.fxtwitter.com/${encodeURIComponent(handle)}`, { json: true });
    const body = fx.status === 200 && parseJSON(fx.text);
    if (body && body.code === 200 && body.user) {
      const u = body.user;
      const p = {
        avatar: /^https:\/\//.test(u.avatar_url || '') ? u.avatar_url.replace('_normal.', '_400x400.') : null,
        banner: /^https:\/\//.test(u.banner_url || '') ? (u.banner_url.endsWith('/1500x500') ? u.banner_url : u.banner_url + '/1500x500') : null,
        bio: trimmedBio(u.description),
      };
      if (p.avatar || p.banner || p.bio) return p;
    }
  }
  const page = await fetchPage(link, { agent: CRAWLER_AGENT });
  if (page.status === 404 || page.status === 410) return {};
  const image = page.status === 200 ? openGraphImage(page.text) : null;
  const description = page.status === 200 ? metaContent(page.text, ['og:description', 'description', 'twitter:description']) : null;
  // A page with no profile tags is a login wall or a script shell: "couldn't look it up".
  if (!image && !description) return platform === 'x' ? xAvatarOnly(handle) : null;
  const p = { avatar: null, banner: null, bio: bioFromPage(platform, description) };
  if (image) p.avatar = platform === 'x' ? image.replace('_200x200.', '_400x400.') : image;
  if (platform === 'x') {
    const m = page.text.match(/profile_banners\/[0-9]+\/[0-9]+/);
    if (m) p.banner = `https://pbs.twimg.com/${m[0]}/1500x500`;
  } else if (platform === 'youtube') {
    const yt = await fetchPage(link, { cookie: 'CONSENT=YES+1' });
    const start = yt.status === 200 ? yt.text.indexOf('"imageBannerViewModel":{') : -1;
    if (start >= 0) {
      const m = yt.text.slice(start, start + 4000).match(/https:\/\/yt3\.googleusercontent\.com\/[^"\\]+/);
      if (m) p.banner = m[0];
    }
  }
  return p;
}

async function xAvatarOnly(handle) {
  const url = `https://unavatar.io/x/${encodeURIComponent(handle)}?fallback=false`;
  const r = await fetchPage(url);
  return r.status === 200 && r.text.length > 0 ? { avatar: url, banner: null, bio: null } : null;
}

// One account's answer, cached a day (a minute when it couldn't be reached); a lookup never
// holds a page longer than SOCIAL_DEADLINE_MS.
const SOCIAL_DEADLINE_MS = 7000;
function resolveSocial(source) {
  return cachedWithRetry('social:' + source.link, 24 * 3_600_000, 60_000, async () => {
    const result = await Promise.race([
      lookUpSocial(source),
      new Promise(r => setTimeout(() => r(null), SOCIAL_DEADLINE_MS)),
    ]);
    return { result: result || {}, transient: result === null };
  });
}

// ---------------------------------------------------------------- identity
// A person, as the app shows them: GET /identity/{address} on the indexer of the address's
// network gives the .kachat label and the profile record; the profile's links are then looked
// up. `name` is "<label>.kachat", or null when they have no active name.
async function loadIdentity(pubkey) {
  const address = kaspaAddress(pubkey);
  if (!address) return { address: null, name: null, avatar: null, banner: null, bio: null, linktree: null };
  return loadIdentityForAddress(address);
}

function loadIdentityForAddress(address) {
  return cachedWithRetry('id:' + address, 600_000, 60_000, async () => {
    const identity = { address, name: null, avatar: null, banner: null, bio: null, linktree: null };
    const base = address.startsWith('kaspatest:') ? TESTNET_INDEXER_URL : INDEXER_URL;
    const res = await fetchJSON(`${base}/identity/${encodeURIComponent(address)}`, 5000);
    if (isTransient(res)) return { result: identity, transient: true };
    const body = res.body || {};
    if (typeof body.label === 'string' && /^[a-z0-9-]{1,63}$/.test(body.label)) identity.name = `${body.label}.kachat`;
    const profile = body.profile && typeof body.profile === 'object' ? body.profile : null;
    if (!profile) return { result: identity, transient: false };
    if (typeof profile.linktree === 'string' && /^https:\/\/linktr\.ee\/[A-Za-z0-9._-]{1,100}$/.test(profile.linktree)) identity.linktree = profile.linktree;
    const fields = ['avatar', 'banner', 'bio'];
    const sources = fields.map(kind => socialSource(profile[kind], kind));
    const answers = await Promise.all(sources.map(s => (s ? resolveSocial(s) : Promise.resolve(null))));
    fields.forEach((kind, i) => {
      const value = answers[i] && answers[i][kind];
      if (!value) return;
      if (kind === 'bio') identity.bio = value;
      else if (/^https:\/\//i.test(value)) identity[kind] = value;
    });
    return { result: identity, transient: false };
  });
}

// ---------------------------------------------------------------- html
function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function shortAddress(address) {
  if (!address) return 'Someone';
  const bare = address.replace(/^kaspa:/, '');
  return bare.length > 20 ? `${bare.slice(0, 8)}…${bare.slice(-6)}` : bare;
}

function displayName(identity) {
  if (identity.name) return identity.name;
  return shortAddress(identity.address);
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

// The avatar, or the app's empty-avatar look (a person glyph on gray) when there is none.
function avatarHTML(identity, cls = 'avatar') {
  if (identity && identity.avatar) {
    return `<img class="${cls}" src="${escapeHTML(identity.avatar)}" alt="" referrerpolicy="no-referrer">`;
  }
  return `<span class="${cls} avatar-empty"><svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="8.5" r="4"/><path d="M4 20.5c0-4.1 3.6-6.5 8-6.5s8 2.4 8 6.5z"/></svg></span>`;
}

const STORE_BADGES = `
  <div class="badges">
    <a class="badge" href="${escapeHTML(APP_STORE_URL)}">
      <span class="glyph"><svg viewBox="0 0 24 24" fill="#000"><path d="M17.564 13.19c-.023-2.596 2.12-3.85 2.216-3.91-1.206-1.765-3.083-2.006-3.75-2.033-1.596-.16-3.113.94-3.92.94-.81 0-2.052-.916-3.377-.89-1.737.025-3.34 1.01-4.233 2.566-1.805 3.128-.462 7.755 1.296 10.297.86 1.244 1.885 2.64 3.226 2.59 1.295-.052 1.784-.837 3.35-.837 1.564 0 2.006.837 3.375.812 1.39-.025 2.276-1.267 3.127-2.516.98-1.44 1.383-2.836 1.407-2.908-.03-.014-2.702-1.037-2.727-4.11zM14.98 4.9c.714-.866 1.196-2.07 1.064-3.27-1.03.042-2.275.686-3.013 1.55-.66.766-1.24 1.99-1.084 3.166 1.148.09 2.32-.583 3.033-1.446z"/></svg></span>
      <span class="t"><small>Download on the</small><strong>App Store</strong></span>
    </a>
    <a class="badge" href="${escapeHTML(PLAY_URL)}">
      <span class="glyph"><svg viewBox="0 0 24 24"><path fill="#00D7FE" d="M1.337.924a1.486 1.486 0 0 0-.112.568v21.017c0 .217.045.419.124.6l11.155-11.087z"/><path fill="#00F076" d="M13.544 10.989l3.258-3.238L3.45.195a1.466 1.466 0 0 0-.946-.179z"/><path fill="#FFD400" d="M22.018 13.298l-3.919 2.218-3.515-3.493 3.543-3.521 3.891 2.202a1.49 1.49 0 0 1 0 2.594z"/><path fill="#FF3A44" d="M13.544 13.056l-11 10.933c.298.036.612-.016.906-.183l13.324-7.54z"/></svg></span>
      <span class="t"><small>Get it on</small><strong>Google Play</strong></span>
    </a>
    <a class="badge" href="${escapeHTML(DESKTOP_URL)}">
      <span class="glyph"><svg viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4.5" width="19" height="13" rx="2"/><path d="M8.5 20.5h7M12 17.5v3"/></svg></span>
      <span class="t"><small>Use it in your</small><strong>Browser</strong></span>
    </a>
  </div>`;

function getKaChat(lead) {
  return `
  <p class="group-label">${escapeHTML(lead)}</p>
  ${STORE_BADGES}`;
}

// The home page's look (home.kachat.app), which is the iOS app's: system black, gray grouped
// cards, the KaChat teal, SF type, a glass bar, filled teal and gray buttons.
const STYLE = `
  :root { --bg:#000; --cell:#1c1c1e; --cell-2:#2c2c2e; --cell-3:#3a3a3c; --sep:rgba(84,84,88,.6);
          --text:#fff; --muted:#8e8e93; --teal:#70c7ba; --teal-dim:rgba(112,199,186,.16);
          --font:-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display","Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
  * { box-sizing:border-box; }
  html { -webkit-text-size-adjust:100%; }
  body { margin:0; background:var(--bg); color:var(--text); font-family:var(--font); font-size:17px; line-height:1.5;
         -webkit-font-smoothing:antialiased; min-height:100vh; overflow-x:hidden; }
  body::before { content:""; position:fixed; inset:0; z-index:-1; pointer-events:none;
                 background:radial-gradient(70% 45% at 50% -10%, rgba(112,199,186,.14), transparent 65%); }
  a { color:inherit; text-decoration:none; }
  .nav { position:sticky; top:0; z-index:5; background:rgba(28,28,30,.72);
         -webkit-backdrop-filter:blur(20px) saturate(180%); backdrop-filter:blur(20px) saturate(180%);
         border-bottom:.5px solid rgba(255,255,255,.12); }
  .nav-in { max-width:640px; margin:0 auto; padding:0 16px; height:56px; display:flex; align-items:center; gap:12px; }
  .brand { display:flex; align-items:center; gap:10px; font-weight:700; font-size:18px; }
  .tile { display:inline-grid; place-items:center; overflow:hidden; border-radius:22%; background:#fff; width:30px; height:30px; flex:none; }
  .tile img { width:100%; height:100%; object-fit:cover; transform:scale(2.6); }
  .nav .btn { margin-left:auto; }
  .shell { max-width:640px; margin:0 auto; padding:24px 16px 40px; }
  .btn { display:inline-flex; align-items:center; justify-content:center; gap:8px; border-radius:14px; font-weight:600; font-size:17px;
         height:50px; padding:0 20px; white-space:nowrap; -webkit-tap-highlight-color:transparent; }
  .btn:active { transform:scale(.98); }
  .btn-fill { background:var(--teal); color:#fff; } .btn-fill:hover { filter:brightness(1.07); }
  .btn-gray { background:var(--cell-2); color:var(--text); } .btn-gray:hover { background:var(--cell-3); }
  .btn-sm { height:34px; font-size:15px; padding:0 14px; border-radius:999px; }
  .btn-block { display:flex; width:100%; }
  .card { background:var(--cell); border-radius:20px; padding:18px; overflow:hidden; }
  .who { display:flex; align-items:center; gap:12px; }
  .avatar { width:48px; height:48px; border-radius:50%; object-fit:cover; background:var(--cell-2); flex:none; }
  .avatar-empty { display:grid; place-items:center; color:var(--muted); }
  .avatar-empty svg { width:60%; height:60%; }
  .name { font-weight:600; font-size:17px; letter-spacing:-.01em; overflow-wrap:anywhere; }
  .meta { color:var(--muted); font-size:14px; }
  .text { margin-top:14px; font-size:18px; line-height:1.45; overflow-wrap:anywhere; }
  .quote { margin-top:12px; border-radius:14px; padding:12px 14px; background:var(--cell-2); color:var(--muted); font-size:15px; overflow-wrap:anywhere; }
  .quote strong { color:var(--text); font-weight:600; }
  .counts { margin-top:14px; padding-top:12px; border-top:.5px solid var(--sep); color:var(--muted); font-size:14px; display:flex; gap:18px; }
  .counts b { color:var(--text); font-weight:600; }
  .cta { margin-top:16px; }
  .hint { color:var(--muted); font-size:14px; text-align:center; margin:10px 8px 0; }
  .group-label { font-size:13px; text-transform:uppercase; letter-spacing:.02em; color:var(--muted); margin:30px 0 8px 16px; }
  .badges { display:grid; gap:10px; }
  .badge { display:flex; align-items:center; justify-content:center; gap:11px; height:56px; padding:0 18px; border-radius:14px; background:#fff; color:#000; }
  .badge .glyph { width:26px; height:26px; flex:none; } .badge .glyph svg { width:100%; height:100%; display:block; }
  .badge .t { display:flex; flex-direction:column; line-height:1.05; min-width:118px; }
  .badge .t small { font-size:11px; color:#3a3a3c; font-weight:600; } .badge .t strong { font-size:18px; font-weight:700; margin-top:1px; }
  /* profile */
  .profile { padding:0; }
  .banner { height:150px; background:linear-gradient(135deg, rgba(112,199,186,.35), rgba(112,199,186,.08)); }
  .banner img { width:100%; height:100%; object-fit:cover; display:block; }
  .profile-body { padding:0 18px 18px; }
  .profile .avatar-lg { width:88px; height:88px; border-radius:50%; object-fit:cover; background:var(--cell-2); border:4px solid var(--cell);
                        margin-top:-44px; display:block; }
  .profile .avatar-lg.avatar-empty { display:grid; }
  .profile h1 { margin:10px 0 2px; font-size:24px; letter-spacing:-.02em; line-height:1.2; overflow-wrap:anywhere; }
  .addr { font-family:ui-monospace,"SF Mono",Menlo,monospace; font-size:13px; color:var(--muted); overflow-wrap:anywhere; }
  .bio { margin:12px 0 0; font-size:16px; overflow-wrap:anywhere; }
  .linkrow { display:flex; align-items:center; gap:10px; margin-top:14px; padding:11px 14px; background:var(--cell-2); border-radius:12px; font-size:15px; }
  .linkrow .ic { width:26px; height:26px; border-radius:7px; background:#43e55e; display:grid; place-items:center; flex:none; }
  .linkrow .ic svg { width:15px; height:15px; fill:#fff; }
  .linkrow span { flex:1; overflow-wrap:anywhere; }
  .linkrow .chev { width:8px; height:13px; color:#636366; flex:none; }
  /* room */
  .room-ic { width:52px; height:52px; border-radius:13px; background:var(--teal); color:#fff; display:grid; place-items:center;
             font-size:28px; font-weight:700; flex:none; }
  .foot { border-top:.5px solid var(--sep); margin-top:36px; padding:22px 16px calc(28px + env(safe-area-inset-bottom)); text-align:center; color:var(--muted); font-size:13px; }
  .foot a { color:var(--teal); }
  @media (min-width:600px) { .badges { grid-template-columns:repeat(3,1fr); } .badge { padding:0 12px; } .badge .t { min-width:0; } }
`;

function page({ title, description, image, canonical, appArgument, body, largeImage }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
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
<meta name="theme-color" content="#000000">
<meta name="color-scheme" content="dark">
<link rel="icon" href="${escapeHTML(LOGO_URL)}">
<style>${STYLE}</style>
</head>
<body>
<header class="nav"><div class="nav-in">
  <a class="brand" href="${escapeHTML(HOME_URL)}/"><span class="tile"><img src="${escapeHTML(LOGO_URL)}" alt=""></span>KaChat</a>
  <a class="btn btn-fill btn-sm" href="${escapeHTML(DESKTOP_URL)}">Open web app</a>
</div></header>
<main class="shell">
  ${body}
</main>
<footer class="foot">KaChat is end-to-end encrypted messaging, payments and posts on the Kaspa network.<br><a href="${escapeHTML(HOME_URL)}/">home.kachat.app</a></footer>
</body>
</html>`;
}

function postPage(txid, post, identity, quoteIdentity) {
  const name = displayName(identity);
  const canonical = `${SITE_ORIGIN}/post/${encodeURIComponent(txid)}`;
  // One line for the unfurl: chat apps show meta descriptions as a single paragraph anyway.
  const description = truncate((post.text || (post.quote ? 'Reposted a post on KaChat' : 'A post on KaChat')).replace(/\s+/g, ' ').trim(), 300);
  const edited = post.editedAt ? ' · edited' : '';
  const replyLine = post.parentPostId ? `<div class="meta" style="margin-top:10px">Replying to a post</div>` : '';
  const quoteBlock = post.quote
    ? `<div class="quote"><strong>${escapeHTML(displayName(quoteIdentity || {}))}</strong><br>${textHTML(truncate(post.quote.text, 400))}</div>`
    : '';
  const body = `
  <div class="card">
    <div class="who">
      ${avatarHTML(identity)}
      <div>
        <div class="name">${escapeHTML(name)}</div>
        <div class="meta">${escapeHTML(whenText(post.timestamp))}${edited}</div>
      </div>
    </div>
    ${replyLine}
    <div class="text">${textHTML(post.text)}</div>
    ${quoteBlock}
    <div class="counts"><span><b>${post.likes}</b> likes</span><span><b>${post.replies}</b> replies</span><span><b>${post.reposts}</b> reposts</span></div>
  </div>
  <div class="cta">
    <a class="btn btn-fill btn-block" href="kachat://kapost/${encodeURIComponent(txid)}">Open in KaChat</a>
    <p class="hint">Replies, likes and reposts live in the app. This page shows the post only.</p>
  </div>
  ${getKaChat("Don't have KaChat yet? It's free.")}`;
  return page({
    title: `${name} on KaChat`,
    description,
    image: identity.avatar || OG_IMAGE,
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
    <div class="who">
      <span class="room-ic">#</span>
      <div>
        <div class="name" style="font-size:22px">#${escapeHTML(channel)}</div>
        <div class="meta">A public chat on KaChat</div>
      </div>
    </div>
    <div class="text">You've been invited to join <strong>#${escapeHTML(channel)}</strong>. Public chats are open to everyone with the app, and the messages live on the Kaspa network.</div>
  </div>
  <div class="cta">
    <a class="btn btn-fill btn-block" href="kachat://broadcast/${encodeURIComponent(channel)}">Open in KaChat</a>
    <p class="hint">Public chats live in the app. Open this invite in KaChat to join and read along.</p>
  </div>
  ${getKaChat("Don't have KaChat yet? It's free.")}`;
  return page({
    title: `Join #${channel} on KaChat`,
    description: `An invite to the #${channel} public chat on KaChat.`,
    image: OG_IMAGE,
    canonical,
    appArgument: canonical,
    body,
    largeImage: true,
  });
}

// A person's page: the link a KaChat user shares from their profile. Unfurls with their .kachat
// name (once they have one) and the avatar from their profile's social account; with the app it
// opens their User Info, without it offers the download.
function profilePage(address, identity) {
  const pathForm = address.startsWith('kaspa:') ? address.slice('kaspa:'.length) : address;
  const shown = displayName(identity);
  const canonical = `${SITE_ORIGIN}/u/${encodeURIComponent(pathForm)}`;
  const banner = identity.banner ? `<img src="${escapeHTML(identity.banner)}" alt="" referrerpolicy="no-referrer">` : '';
  const bio = identity.bio ? `<p class="bio">${textHTML(identity.bio)}</p>` : '';
  const linktree = identity.linktree
    ? `<a class="linkrow" href="${escapeHTML(identity.linktree)}" rel="nofollow noopener ugc"><span class="ic"><svg viewBox="0 0 24 24"><path d="M11 2h2v6.59l4.3-4.3 1.4 1.42L14.42 10H21v2h-6.59l4.3 4.3-1.42 1.4L13 13.42V20h-2v-6.59l-4.3 4.3-1.4-1.42L9.58 12H3v-2h6.59L5.29 5.7 6.7 4.29 11 8.59z"/></svg></span><span>${escapeHTML(identity.linktree.replace(/^https:\/\//, ''))}</span><svg class="chev" viewBox="0 0 9 15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 1.5 7.5 7.5l-6 6"/></svg></a>`
    : '';
  const body = `
  <div class="card profile">
    <div class="banner">${banner}</div>
    <div class="profile-body">
      ${avatarHTML(identity, 'avatar-lg')}
      <h1>${escapeHTML(shown)}</h1>
      <div class="addr">${escapeHTML(address)}</div>
      ${bio}
      ${linktree}
    </div>
  </div>
  <div class="cta">
    <a class="btn btn-fill btn-block" href="kachat://profile/${encodeURIComponent(pathForm)}">Chat on KaChat</a>
    <p class="hint">End-to-end encrypted messages and payments on the Kaspa network.</p>
  </div>
  ${getKaChat("Don't have KaChat yet? It's free.")}`;
  const description = identity.bio
    ? truncate(identity.bio.replace(/\s+/g, ' '), 200)
    : `Message ${shown} on KaChat - encrypted chat and payments on Kaspa. Tap to start the chat, or get the free app.`;
  return page({
    title: identity.name ? `Chat with ${shown} on KaChat` : 'Chat with me on KaChat',
    description,
    image: identity.avatar || OG_IMAGE,
    canonical,
    appArgument: canonical,
    body,
    largeImage: !identity.avatar,
  });
}

function notFoundPage(what) {
  const body = `
  <div class="card">
    <div class="name" style="font-size:22px">${escapeHTML(what)}</div>
    <div class="text" style="color:var(--muted);font-size:16px">It may be brand new and not indexed yet, or it may have been deleted. Open it in KaChat to be sure.</div>
  </div>
  ${getKaChat('Get KaChat')}`;
  return page({
    title: 'KaChat',
    description: 'Encrypted messaging, payments and posts on Kaspa.',
    image: OG_IMAGE,
    canonical: SITE_ORIGIN,
    appArgument: SITE_ORIGIN,
    body,
    largeImage: true,
  });
}

// ---------------------------------------------------------------- well-known
function aasa() {
  const paths = ['/post/*', '/broadcast/*', '/u/*'];
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

// Only these files are served from STATIC_DIR. A decoded path segment can carry "/" or ".."
// ("/server%2Fserver.js" returned this file), so names are allowlisted, never joined blindly.
const STATIC_FILES = new Set(['index.html', 'eula.html', 'wallet-privacy.html', 'og-default.png', 'favicon.ico', 'robots.txt']);

function serveStatic(res, name) {
  if (!STATIC_FILES.has(name)) return false;
  const file = path.join(STATIC_DIR, name);
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) return false;
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

    if (parts.length === 2 && parts[0] === 'u') {
      // The app writes mainnet addresses without their "kaspa:" prefix; a missing prefix means mainnet.
      const raw = parts[1].trim().toLowerCase();
      const address = raw.includes(':') ? raw : `kaspa:${raw}`;
      if (!isKaspaAddress(address)) return send(res, 404, 'text/html; charset=utf-8', notFoundPage("That link isn't a KaChat profile"));
      const identity = await loadIdentityForAddress(address);
      return send(res, 200, 'text/html; charset=utf-8', profilePage(address, identity));
    }

    if (url.pathname === '/') return serveStatic(res, 'index.html') || send(res, 200, 'text/plain', 'KaChat');
    if (parts.length === 1 && serveStatic(res, parts[0])) return;

    return send(res, 404, 'text/html; charset=utf-8', notFoundPage('Nothing here'));
  } catch (error) {
    console.error(error);
    send(res, 500, 'text/plain', 'error', { 'cache-control': 'no-store' });
  }
});

server.listen(PORT, () => console.log(`kachat.app link site on :${PORT} (indexer ${INDEXER_URL}, testnet ${TESTNET_INDEXER_URL})`));
