# Indexer handoff: testnet-10 + `.kachat` names and profiles

For the KaChat indexer (the `kachat.duckdns.org` service: messages, push, KaPosts, public chats,
groups, stats). Two jobs:

- **Part A - run a testnet-10 instance** of the whole indexer, so the app's Testnet mode has a
  server to talk to.
- **Parts B-E - a new `names` module**: the `.kachat` name registry (Kaspa covenants), address
  profiles and the marketplace, on testnet first, mainnet later with the same code.

The design behind it is `KACHAT_NAMES.md` (app repo). The contracts, compiled artifacts and the
testnet deployment tool are in the private repo `KaspaSilver/kachat-domains`; its `README.md` is the
byte-level reference. Ask the app owner for access or for the files named below.

---

## Part A - a testnet-10 instance

The app's Settings > Connection > Testnet switches the whole app to **testnet-10** (TN10): the
account becomes its `kaspatest:` address, nodes and the REST API are TN10
(`api-tn10.kaspa.org`), and every KaChat indexer field is blank until a testnet indexer exists.
Blank means "none": KaPosts says "not available on Testnet", push stays unregistered, and chats
only work through the node. Mainnet and testnet never share data in the app.

What is needed:

1. **A second deployment of the same indexer, pointed at TN10.**
   - A Toccata-capable rusty-kaspa node on testnet-10, with `--utxoindex`. Toccata is the
     covenant hard fork, live on TN10 and on mainnet since DAA 474,165,565. Public TN10 nodes
     answer on gRPC port 16210 (DNS seeds `seeder1-tn.kaspad.net`,
     `dnsseeder-kaspa-testnet.x-con.at` and `n-testnet-10.kaspa.ws`, as in rusty-kaspa's
     `TESTNET_PARAMS`; the older `seeder1/2-testnet.kaspad.net` no longer resolve), but a node of
     your own is better for an indexer.
   - Its own database. Nothing may be shared with mainnet: same keys, different chain.
   - Its own base URL, for example `https://kachat-tn10.duckdns.org`, or a path prefix such as
     `https://kachat.duckdns.org/tn10`. **Tell the app owner the URL**: the app will use it as
     the testnet default for the chat indexer, KaPosts, public chats and push.
2. **Every existing module runs unchanged on TN10.** The only difference is the address prefix:
   - Addresses are `kaspatest:...`.
   - The inbox tag (`NO_HANDSHAKE_MESSAGING.md`) is computed over the full lowercased address
     including that prefix. That is the same code; it just produces different tags than mainnet.
   - Start indexing from the current DAA score. Testnet history is not needed.
3. **Push on testnet:**
   - Same APNs keys and topic as mainnet, but a separate registration store (the testnet
     instance's own database).
   - On testnet a device registers its `kaspatest:` primary address and contacts.
   - The app withdraws its mainnet registration while it runs on testnet and registers again
     when switched back, so one device is never registered on both.
4. **KaPosts, public chats, chess and stats:**
   - The same protocols and room names, indexed from TN10.
   - `GET /stats` works the same; on a new testnet the counts will simply be small.
5. **Translation** is network-independent. The app may point its testnet profile at the
   mainnet translation service. No action is needed.

Acceptance:
- The app's testnet profile pointed at the instance shows a live chat between two `kaspatest:`
  accounts, the KaPosts feed, public rooms and push notifications.
- The mainnet instance sees none of it.

---

## Part B - the `names` module: following the registry

### B1. What is on chain

All of these are version-1 transactions (Toccata) with output covenant bindings.

| UTXO | Script | Value | State (spliced into the script) |
|---|---|---|---|
| **Gap**: an unregistered interval `(lo, hi)` of the key space | P2SH of `KachatGap` | `gapValue` (1 KAS) | 66 B: `0x20 lo[32] 0x20 hi[32]` |
| **Name**: one per registered name | P2SH of `KachatName` | `bond` (1 KAS) | 117 B: `0x20 key[32] 0x20 name[32] 0x20 owner[32] 0x08 price[8] 0x08 expiresAt[8]` |
| **Offer**: KAS a buyer locks for one name | P2SH of `KachatOffer` | the offer amount | 75 B: `0x20 key[32] 0x20 buyer[32] 0x08 refundAfter[8]` |

- **Key:** `key = blake3(name)`, where `name` is the ASCII bytes of the lowercase name without
  `.kachat`. Rules: `a-z 0-9 -`, 1-32 characters, no hyphen at either end.
- **Name field:** the name zero-padded to 32 bytes.
- **Owner and buyer:** 32-byte x-only Schnorr keys. Address = `kaspa:`/`kaspatest:` P2PK of the
  key.
- **Integers** are 8 bytes, little-endian sign-magnitude (`num8` in the harness): the magnitude
  is little-endian and the top bit of byte 7 is the sign. All the values here are non-negative.
  - `price`: sompi; 0 = not listed.
  - `expiresAt`: unix milliseconds.
  - `refundAfter`: a DAA score.
- **Scripts:** each contract's script is `prefix ‖ state ‖ suffix`. The prefix and suffix are
  fixed per contract and per network: take them from the artifacts at
  `artifacts/<net>/*.json` in `kachat-domains`. The README has the lengths, e.g. name
  1 / 117 / 1884.
- **Output script:** standard P2SH, `OP_BLAKE2B <blake2b-256(script)> OP_EQUAL`. Use
  rusty-kaspa's `pay_to_script_hash_script`.
- **Covenant binding:** gaps and names carry the **registry covenant id** (KIP-20) in their
  covenant binding. Offers carry none.

### B2. The manifest: which registry is the real one

- The registry is created once by a **genesis transaction** on each network. Phase 2 produces
  `manifests/kachat-names-<network>.json`, and the app owner will hand it over after the TN10
  genesis.
- It contains:
  - `registryCovenantId`
  - the genesis `txId` and the authorized output
  - each contract's template hash, prefix and suffix bytes, and its dispatch tags
  - a scan checkpoint
  - the params: `bond`, `gapValue`, `tCommit` (600 DAA), `maxYears` (2), `graceMs` (10 days),
    `prices` and `renewPrices` per length (5+ chars 35 KAS, 4 = 250, 3 = 1000, 2 = 2000,
    1 = 4000, all per year), and `offerMaxFee` (0.02 KAS)
- **Testnet-10 is live (2026-10-02):**
  - registry id `9444187f09a3e77450e125d448b21eb79b3c54b692a5b3f3e8af38343b9a7a51`
  - genesis tx `cba68dd1b07f374410270f1e609a3e71deaf42d3bd3b5849ac9b0e9cc687f45f`, accepted at DAA
    585,767,203
  - genesis gap at output 0 (`00..00`, `ff..ff`), 1 TKAS
  - The manifest is `manifests/kachat-names-testnet-10.json` in `kachat-domains`. Index from
    the genesis transaction forward; the manifest's `genesis.scanFrom` block is a safe starting
    point.
- Load it from config, e.g. `KACHAT_NAMES_MANIFEST=/path/kachat-names-testnet-10.json`.
- The module stays **off** until a manifest is configured.
- **Trust rule:** an output counts only if it carries `registryCovenantId` **and** its lineage
  goes back to that genesis output. Consensus enforces the covenant id, so in practice: index
  from the genesis transaction forward, and ignore anything with the id that your own tracked
  set did not create.

### B3. Following transitions without trusting the app

A P2SH output does not show its state; the state becomes visible when the output is spent. The
module therefore derives every new state from the spending transaction itself:

1. **Find the spends.** For each accepted transaction (virtual chain order), find inputs that
   spend a tracked registry UTXO or a tracked offer.
2. **Decode each such input's signature script.** It is `<args...> <dispatch tag> <push(script)>`:
   - The last push is the redeem script: `prefix ‖ current state ‖ suffix`. Read the current
     state by offset.
   - The push before it is the 4-byte dispatch tag, the entry being called:

     | Contract | Entry | Tag |
     |---|---|---|
     | gap | `register` | `8667af5e` |
     | gap | `merge` | `63d25bc2` |
     | gap | `absorbed` | `dab76355` |
     | name | `transfer` | `794dca54` |
     | name | `list` | `674a8ea4` |
     | name | `buy` | `76a02eb9` |
     | name | `renew` | `b706ac38` |
     | name | `release` | `388ad0b4` |
     | name | `reclaim` | `f56af4df` |
     | offer | `accept` | `9d4043b4` |
     | offer | `withdraw` | `80344ff1` |
     | offer | `refund` | `777f5b11` |

   - The pushes before that are the entry's arguments, in ABI order (the artifact JSON lists
     each entry's parameters). Every push is a **minimal** push:
     - `byte[32]` is a 32-byte push.
     - `sig` is a 65-byte push (64-byte Schnorr signature + `0x01`).
     - `byte[]` is a minimal push of its bytes. The name suffix (1,884 B) and the redeem
       scripts use `OP_PUSHDATA2`.
     - `int` is a minimal script number, **not** the fixed 8-byte form used inside states:
       - 0 is `OP_0` (`0x00`), 1-16 are `OP_1`..`OP_16` (`0x51`-`0x60`), and -1 is
         `OP_1NEGATE`. So `years = 1` is the single byte `0x51`, and `accept(0)` is `0x00`.
       - Larger values are minimal 1-8 byte little-endian sign-magnitude pushes.
3. **Compute the new state(s)** with the transition rules below.
4. **Verify** each new state: `P2SH(prefix ‖ newState ‖ suffix)` must equal the output's
   `scriptPublicKey`. Index the output only if it matches. A mismatch is a bug, either in the
   module or in a contract; log it loudly.

Transitions. `YEAR` = 31,536,000,000 ms; `name continuation` = the one registry output of the tx.

| Spend | Outputs and new state |
|---|---|
| gap `register(name, ownerKey, salt, now, years, …)` on gap `(lo,hi)` | out 0 gap `(lo, key)`, out 1 gap `(key, hi)`, out 2 name `(key, pad(name), ownerKey, 0, now + years·YEAR)` |
| name `transfer(newOwner, sig)` | continuation: owner = `newOwner`, price = 0 |
| name `list(price, sig)` | continuation: price = `price` |
| name `buy(newOwner)` | continuation: owner = `newOwner`, price = 0. **Sale**: output continuation+1 paid the seller the listed price |
| name `renew(years)` | continuation: `expiresAt += years·YEAR` |
| exit: gap `merge` (input 0) + name `release`/`reclaim` (input 1) + gap `absorbed` (input 2) | out 0 gap `(lo of input 0, hi of input 2)`; the name is gone. `reclaim` also paid the bond back to the old owner (output 1) |
| offer `accept(nameIdx)` + name `transfer` (or `buy`) at `nameIdx` | the name goes to the offer's `buyer`; **sale at the offer amount**; the offer is gone |
| offer `withdraw` / `refund` | the offer is gone (the KAS returned to the buyer) |

Commits (`push(c) OP_DROP push(ownerKey) OP_CHECKSIG`) are plain P2SH and stay invisible until a
register spends one. Nothing needs indexing for them.

### B4. Offers: payload marker

Offer outputs are plain P2SH with no covenant id, so they can't be recognised before they are
spent. The app (and the CLI) put this in the **payload** of the transaction that creates an offer:

```
kchat:1:offer:<keyHex>:<buyerXonlyHex>:<refundAfterDaa>
```

Here `keyHex` and `buyerXonlyHex` are lowercase hex, and `refundAfterDaa` is decimal.

- Verify it: `P2SH(offerPrefix ‖ offerState(key, buyer, refundAfter) ‖ offerSuffix)` must equal
  one of the transaction's outputs. That output is the offer, and its value is the amount.
- Ignore a marker that matches no output.
- The offer prefix and suffix are per network, because the offer script bakes in the registry id.

All other name transactions (register, renew, transfer, list, buy, release, reclaim, accept)
also carry an informational payload, `kchat:1:name:<op>:<name>`. Commits carry none, because
naming the name there would defeat the salted commit; genesis, withdraw and refund carry none
either.
**Never rely on it**: B3 is the source of truth, and the marker is only for debugging.

### B5. Status

`now` is the wall clock in ms.

| Status | When | Resolves? |
|---|---|---|
| `active` | `now < expiresAt` | yes |
| `grace` | `expiresAt <= now < expiresAt + graceMs` | no; shown to the owner only, as "renew to keep it" |
| `lapsed` | `now >= expiresAt + graceMs`, name UTXO still unspent | no; anyone may `reclaim`, after which the name is free |

Forward lookups (name → address) and reverse lookups (address → names) return **`active` names
only**.

A registration can be **backdated**: the gap only checks that `now` is not in the future, so a
name can be minted already in grace, or lapsed. It costs only the registrant, and the testnet
plan uses it to test `reclaim` without waiting a year. Always compute status from `expiresAt`;
never assume a fresh registration is `active`.

### B6. Reorgs

Treat it like every other module: apply on virtual-chain acceptance, and roll back on removed
chain blocks, since the gap and name UTXO set is just derived state. A gap or name can only be
consumed once, so replaying in order always produces the same registry.

---

## Part C - profiles (identity lives on the address)

A profile belongs to an **address**, never to a name. Losing, selling or letting a name lapse
never changes it.

- **Record:** a transaction from the address to itself, with payload
  `kchat:1:profile:<json>` (UTF-8).
  - Accept it only if at least one input spends a UTXO of that address (the same
    sender-resolution the chat module already uses) **and** an output pays back to the same
    address.
  - The newest one by accepting block (then txid) replaces the whole profile. Records are full
    replacements, not patches.
- **JSON** (reject the record if it is over 2 KB):

  ```json
  {
    "v": 1,
    "social": "https://x.com/name",
    "linktree": "https://linktr.ee/name",
    "primaryName": "alice"
  }
  ```

  - Every field is optional. Drop unknown fields; that includes the old `avatar`, `banner`,
    `bio` and `links`, which are not part of the format.
  - `social` is a **profile link**, stored normalized by the app. Accept it only on X
    (`https://x.com/<handle>`), YouTube (`https://www.youtube.com/@<handle>` or
    `/channel|c|user/<id>`), Facebook, Instagram, TikTok (`/@<handle>`), Twitch, Kick, GitHub,
    Telegram (`https://t.me/<handle>`), LinkedIn (`/in|company/<id>`), or a Discord server invite
    (`https://discord.gg/<code>`). Drop anything else.
  - `linktree` must be `https://linktr.ee/<name>`. Drop anything else.
  - Store and serve both as strings. **Never fetch, store or proxy pictures or bios**: each
    app looks them up from the social profile itself, so the platform's moderation applies.
  - There is deliberately **no display-name field**.
- **`primaryName`** is honored only while the address owns that name and it is `active`.
  - Otherwise the label falls back to the address's oldest `active` name, then to none.
  - The app shows the address itself when there is no name.

---

## Part D - API

Every endpoint is on the same base URL as the rest of the indexer, and every response is JSON.

- **Amounts** are sompi as **strings** (they exceed 2^53 at the top end).
- **Times** are unix ms numbers.
- **Addresses** use the network's prefix.
- **Names** are given without `.kachat`. Accept and normalise case.

### Lookups

`GET /names/{name}` returns one answer, whether or not the name is taken:

```json
{ "name": "alice", "key": "<hex>",
  "registered": true, "status": "active",
  "owner": "kaspatest:…", "ownerKey": "<hex>",
  "price": "0", "expiresAt": 1822000000000,
  "outpoint": {"txId": "…", "index": 2},
  "registeredAt": 1790000000000, "registeredTxId": "…", "updatedAt": 1790000000000 }
```

When the name is not registered (or is lapsed and has been reclaimed):

```json
{ "name": "alice", "key": "<hex>", "registered": false,
  "gap": {"lo": "<hex>", "hi": "<hex>", "outpoint": {"txId": "…", "index": 0}} }
```

If the name is invalid (fails the charset or length rules): `400 {"error": "invalid_name"}`.

| Endpoint | Returns |
|---|---|
| `GET /names/by-owner/{address}?includeInactive=false` | `{"names": [ <name objects> ]}`, oldest first. `includeInactive=true` adds `grace` and `lapsed` |
| `GET /names/gap/{keyHex}` | the gap containing `key`: `{"lo","hi","outpoint"}` (what a register spends) |
| `GET /names/{name}/history?cursor=` | `{"events": [{"txId","op","at","daa","from","to","price","years"}], "next": cursor\|null}`. `op` ∈ `register, transfer, list, delist, sale, renew, release, reclaim, offer_accepted` |
| `GET /names/{name}/offers` | open offers: `{"offers": [{"outpoint","buyer","amount","refundAfter","createdAt","refundable": bool}]}` |
| `GET /offers/by-buyer/{address}` | the buyer's open offers, same shape plus `name` |
| `GET /market/listings?sort=recent\|price_asc\|price_desc&length=&cursor=` | listed `active` names: `{"listings": [<name object>], "next"}` |
| `GET /market/activity?cursor=` | recent sales, listings and offers across the registry: `{"events": [...], "next"}` |
| `GET /names/expiring?cursor=` | `lapsed` names awaiting reclaim, oldest first |
| `GET /profiles/{address}` | `{"address", "profile": {...}\|null, "updatedAt", "txId"}` |
| `GET /identity/{address}` | `{"address", "label": "alice"\|null, "names": ["alice","bob"], "profile": {...}\|null}`. `label` follows Part C. One call per profile card |
| `POST /identity/batch` `{"addresses": [...]}` (≤ 200) | `{"identities": {"<address>": <identity>}}`. Used for chat lists |
| `GET /names/manifest` | the manifest the module runs with |
| `GET /names/status` | `{"network", "registryCovenantId", "genesisTxId", "indexedDaa", "synced": bool}` |

Errors: `{"error": "<code>", "message": "…"}`, with 400 for bad input, 404 for an unknown
address or outpoint, and 503 while the module is syncing or has no manifest.

---

## Part E - push

These use the existing push registrations, routed by the address each device registered as its
`primaryAddress`.

| Event | To | When |
|---|---|---|
| `name_offer` | the name's current owner | an offer for one of their names is created |
| `name_sold` | the seller | `buy` on their listing, or one of their offers accepted |
| `name_offer_accepted` | the buyer | their offer was accepted |
| `name_expiring` | the owner | 30, 7 and 1 days before `expiresAt` (once each, by a scheduler) |
| `name_grace` | the owner | at `expiresAt` |

The APNs payload is the same shape as the existing app pushes. The alert is localised by the app:

```json
{ "aps": { "alert": {"title-loc-key": "…", "loc-args": ["alice"]}, "mutable-content": 1 },
  "type": "name_event", "event": "name_sold", "name": "alice", "tx_id": "…" }
```

For a first version, `title`/`body` in plain English are fine. The app's notification extension
rewrites them.

---

## Rollout

1. **Part A** now: the TN10 instance. Send the app owner its URL.
2. **Parts B-E** behind config, off until a manifest exists.
3. The TN10 genesis comes from the `kachat-domains` CLI. The app owner sends the manifest. Turn
   the module on for testnet and check `GET /names/status`.
4. End-to-end test on TN10 with the CLI and the app: register, renew, transfer, list and buy,
   offer and accept, offer and refund, release, and later reclaim. Every step should show up in
   `/names/{name}/history` with the right state.
5. Mainnet only after an audit and the app owner's explicit go-ahead. It uses the same code with
   the mainnet manifest.
