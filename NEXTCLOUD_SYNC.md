# Nextcloud Automatic Sync: the shared contract

Every KaChat client that backs chat history up to Nextcloud follows this contract:
- iOS;
- Android;
- Desktop;
- the extension wallet.

They all read and write **the same file**, so a client that drifts from this document breaks the
others. When the behaviour changes, change this document first.

The iOS implementation (`KaChat/Services/NextcloudService.swift`, the archive merge in
`ChatService+PushAndSync.swift`) is the reference. The encryption format is specified in
`MESSAGING.md` § "Encrypted Backup Envelope (v1)".

---

## 1. One file, overwritten in place

- **The file:** `<backup folder>/kachat-backup.json`. The backup folder defaults to `KaChat` at
  the root of the user's files; §2 covers choosing it.
- **Writing:** every backup, automatic or manual, is a WebDAV `PUT` to that exact path. A `PUT`
  replaces the file, so there is only ever one.
- **A client MUST NOT create any other file as part of backup or sync.** That rules out:
  - dated, numbered or "damaged" copies;
  - one file per device, per wallet or per platform;
  - temp files left behind.

  Old copies are Nextcloud's job: its **Versions** feature keeps earlier contents of the same
  file, as versions of that one file.
- **Legacy file:** `kachat-backup-desktop.json` is an old Desktop-only file. Clients may *read*
  it once to import old history, and MUST NOT write it.

The only other files a client puts in the backup folder come from deliberate user actions, never
from sync:

| What | Where | Why it's a new file |
|---|---|---|
| Media sent "via Nextcloud" | `KaChat/Media/<name>` | one per photo, video or voice note; the chat carries its share link |
| Manual exports: Portfolio CSV | `<backup folder>/<portfolio name> <timestamp>.csv` (the name the user gave the portfolio; "KaChat Portfolio" if none) | one per tap on Export |
| Manual exports: Address Book | `<backup folder>/KaChat Address Book <timestamp>.json` | one per tap on Export to Nextcloud. Plain JSON `{type: "kachat-address-book", version: 1, exportedAt, walletAddress, entries: [<addressBook entry, with photo>]}` (entry shape in §5). Importing adds every address not saved (even one deleted since) and updates one already saved only from a newer `updatedAt`. Any wallet may import it |

## 2. Which folder

1. **On connect, discover an existing backup before creating anything.** Walk the user's files
   breadth-first, at most 40 folders and 3 levels deep:
   1. a folder that already holds `kachat-backup.json` is the backup folder, so stop there;
   2. otherwise, the first folder named `KaChat` (case-insensitive);
   3. otherwise, nothing is found, and the default `KaChat` is created on the first upload.

   Without this step, a new device would start a second backup next to the first.
2. The user may pick another folder. It's stored with the account, per wallet.
3. Before each `PUT`, `MKCOL` the folder. `405` means it already exists, which is fine.

## 3. Encryption

- **Writers ALWAYS encrypt**, using the v1 envelope in `MESSAGING.md`: AES-256-GCM, a fresh
  12-byte nonce per write, and
  `key = SHA-256(identity_private_key_raw_32_bytes || UTF8("kachat-backup-v1"))`.
- If the key isn't available, the backup is **skipped**. It is never uploaded readable.
- Readers accept the envelope, and legacy plaintext archives for old backups.
- The envelope's `walletHint` is the first 8 bytes of SHA-256(walletAddress), as hex. It lets a
  reader recognise another wallet's file without trying to decrypt it.

## 4. One sync = read, merge, write

Each backup does the following:

1. **One at a time per device.** The manual button, the automatic sync and anything else that
   backs up all queue on one chain; a caller arriving mid-sync waits, then does its own cycle.
   Two `PUT`s at once get `423 Locked` from Nextcloud.
2. **ETag short-cut.** If the server's ETag (a Depth-0 `PROPFIND` for `getetag`) equals the ETag
   of this device's own last write, the server copy is already merged locally. Skip the download
   and go to step 4. Any doubt means a full read.
3. **Read.** `GET` the file and decrypt it.
   - `404` means there is no backup yet. This is the **only** case that writes without merging.
   - Any other read failure aborts **before** the `PUT`. §7 covers unreadable files.
4. **Merge** the server copy with this device's history, using the rules in §5.
5. **Write.** Encrypt and `PUT` to the same path.
   - Record the new ETag from the response: `OC-ETag` first, then `ETag`. If a proxy stripped
     both, do one Depth-0 `PROPFIND`.
   - This device's change watcher must never download its own write back (§6).
6. **Verify.** Read back the stored size (a Depth-0 `PROPFIND` for `getcontentlength`) and compare
   it with the bytes sent. If they differ, report "the upload was cut off" and stop. Don't retry
   in a loop.
7. **Re-check the active wallet after every `await`.** If the user switched wallets mid-sync,
   abort. One wallet's history must never land in another's file.

A backup can only ever **add** to the shared file. No device can delete another device's chat
history, except by an explicit chat deletion (tombstones, §5).

## 5. Merge rules

- **Conversations** are merged by `contactAddress`.
  - For per-conversation metadata (alias, photo), the archive with the newer `exportedAt` wins.
  - A missing `conversationId` is filled from the other side.
- **Messages** are merged by key: `tx:<txId>`, or `id:<id>` when there's no txId. When both sides
  have the same key, keep in order of preference:
  1. a real body over a placeholder;
  2. the further-along delivery status;
  3. the later `blockTime`.
- **Phantoms are dropped:** messages with a blank or `pending_…` txId never reached the chain.
- **Deletion tombstones** are the union of both sides. A tombstoned conversation is left out of
  the merged file, so a chat deleted on one device stays deleted.
- **Address Book** (iOS since 2026-10-08; optional top-level keys, older archives omit them). It
  replaced syncing with the phone's Contacts, and it is per wallet like the rest of the file.
  - `addressBook`: an array of `{id, address, name, note, createdAt, updatedAt, photo?}`. `id` is a
    UUID, `address` is the lowercased Kaspa address with no `?query`, and the dates are ISO 8601.
    `photo` is the photo the user assigned to the entry, as a base64 JPEG (at most 384 px, quality
    0.8). It's absent when the entry shows the avatar the address set on its own profile.
  - The winning entry decides the photo: a photo it carries replaces the local one; if it has none
    and it's newer than the local entry, the local photo is removed. On a device, photos are files
    and not part of the stored entry.
  - `addressBookDeleted`: an array of `{address, deletedAt}`.
  - Merge per address: the newest `updatedAt` of either side's entries, unless a tombstone's
    `deletedAt` is at or after it. Then it's deleted and only the tombstone is kept.
  - A restore applies only to the archive's own wallet (or an unstamped archive).
  - In the app, a saved name is how that address is shown when the chat contact has no name of
    its own. The contact's `contactAlias` is unchanged.
- **Portfolios** (iOS since 2026-10-09; optional top-level keys, older archives omit them). Per
  wallet like the rest of the file; a restore applies only to the archive's own wallet (or an
  unstamped archive).
  - `portfolios`: an array of `{id, name, sortOrder, createdAt, updatedAt?}` (`id` a UUID, dates
    ISO 8601).
  - `portfolioTransactions`: an array of ledger rows `{id, type: "buy"|"sell"|"transfer",
    amountSompi, fiatValue, timestamp, notes?, portfolioId, sourceAddress?, sourceTxId?,
    updatedAt?}`.
  - `portfolioFees`: an array of `{txId, portfolioId, sourceAddress, amountSompi, timestamp,
    fiatValue?}`.
  - `portfolioDeleted`: an array of `{kind: "portfolio"|"transaction", id, deletedAt}`.
  - `updatedAt` is stamped whenever a portfolio is created, renamed or moved and whenever a row
    is added or edited. Merge per `id`: the newest `updatedAt` wins (a portfolio without one
    counts as its `createdAt`, a row without one as the oldest possible), unless a tombstone's
    `deletedAt` is at or after it. Tombstones are the union of both sides, the newest per item.
  - A row or fee lives only while its portfolio does: deleting a portfolio takes its rows and
    fees with it. Fees are merged by `portfolioId:txId`; a copy with a `fiatValue` beats one
    without.
  - Every install seeds its wallet with an empty "Portfolio 1". That seed is never uploaded
    while it is untouched (no `updatedAt`, no rows or fees), and a device that receives other
    portfolios drops its own untouched seed, so a second device never shows two
    "Portfolio 1"s.
  - After a merge the list is ordered by `sortOrder` (ties by `createdAt`) and renumbered
    0, 1, 2... The active portfolio is per device and not synced.
  - Portfolio edits mark the archive dirty like a message does (§6).
- **Keys this client doesn't model** are carried through untouched, so a newer client's fields
  survive an older client's write.
- The merged archive is normalised to the strictest shape every platform's decoder accepts
  (for example, `conversationId` must be a UUID or absent).

## 6. When to write, when to read

**Automatic Sync** is per wallet and **on by default once Nextcloud is connected**. All clients
use these timings:

| Trigger | Timing |
|---|---|
| Any message lands (incoming or outgoing) | Mark the archive **dirty** (persisted, so a kill can't lose it), then upload after a quiet time of **5 s** with a chat open on screen, **15 s** elsewhere |
| Upload floor | At most one automatic upload per **90 s**, or **300 s** on metered or expensive networks. An upload due earlier re-arms for the earliest allowed time, and is never dropped |
| App goes to the background | Catch-up upload if the last one was **≥ 1 h** ago, or the archive is dirty |
| App launch | Catch-up upload if the last one was **≥ 24 h** ago, or the archive is dirty |
| Manual "Back Up Now" | Immediately; ignores the floor, but still runs the full read, merge and write |

The dirty flag clears only after a successful upload.

**Watching for other devices.** While the app is in the foreground:
- poll the file's ETag with a Depth-0 `PROPFIND` (ETag only, no body):
  - **5 s** with a chat open, **30 s** elsewhere;
  - **30 s / 60 s** on metered networks;
  - back off to at most **60 s** on errors;
- when the ETag differs from this device's last known one, download, decrypt and merge-import
  it, then record that ETag;
- if the file can't be read, record its ETag anyway, so it isn't downloaded on every poll.

**Silent restore, once per wallet.** The first time a wallet activates with sync on, import the
shared file quietly. Mark that as done **only after a successful import**: if the file is
missing, a backup that appears later (first sync from another device) still triggers the restore.

**Mainnet only.** Nextcloud backup, sync, media and calls are off on testnet, so a testnet
wallet can never overwrite a mainnet backup.

## 7. Errors

| Situation | Do this |
|---|---|
| `401` | Credentials are wrong or revoked. Stop syncing and tell the user to reconnect |
| `423 Locked` | Another request holds the file. Retry the `PUT` after **1, 2, 4, 8, 15 s**, then fail with "backup locked" |
| `404` on read | No backup yet. Write without merging |
| Network error or timeout, including a **download that stopped early** (fewer bytes than `Content-Length`) | Leave the dirty flag set; the next trigger retries. This is a transfer problem, not a damaged file: **never overwrite** on it, and never write a partial merge |
| File uses a **newer schema version** than this client merges | **Never write.** A newer app wrote it; tell the user to update |
| File belongs to **another wallet** (`walletHint` mismatch, or plaintext `walletAddress` mismatch) | **Never write.** Stop syncing this folder and tell the user: "The backup in this folder belongs to a different account" |
| File is **this wallet's but unreadable** (cut off, failed decrypt with a matching hint, invalid JSON) | **Overwrite it in place** with this device's merged history, and **make no copy**: Nextcloud's version history already keeps the old content. Log it. Nothing is lost for good: every other device unions its own history back in on its next sync |
| Upload cut off (verify step fails) | Say so plainly ("the upload was cut off") and stop. Don't loop |

**Relays and proxies.** Anything between the client and Nextcloud (Desktop's nc-proxy, a dev
server) must give writes **at least 120 s**. A large backup `PUT` can sit silent while the server
stores it, and cutting it short leaves a short file, which the next sync then reads as damaged.

## 8. Conformance (2026-10-03)

| Rule | iOS | Android | Desktop | Extension |
|---|---|---|---|---|
| One file, `PUT` in place (§1) | ✅ | ✅ | ✅ for normal syncs | check |
| No extra files during sync (§1) | ✅ | check | ❌ still writes `kachat-backup-damaged-<date>.json` (limited to one a day by local commit `3b06ea0`, unpushed). **Remove it** | check |
| Folder discovery (§2) | ✅ | check | ✅ | check |
| Timings (§6) | ✅ | ✅ same constants | ✅ same constants | check |
| Own-but-unreadable file is overwritten in place (§7) | ✅ | check | copies aside, then overwrites. **Drop the copy** | check |
| Verify stored size after upload (§4.6) | ✅ (only when the stored file is still its own write, by ETag) | check | ✅ (`3b06ea0`) | check |
| Writes get ≥ 120 s through relays (§7) | n/a (direct) | n/a | ✅ (`3b06ea0`) | check |

"check" means the owner of that client confirms against this document and fills the cell in.
