# .kachat names - design (v1)

KaChat's own name service: names like `alice.kachat`, registered, renewed, transferred, listed,
bought and offered on entirely on Kaspa through covenants. No server holds a name or a coin at any
point; the indexer only reads the chain. Status: **design, under review** (2026-10-01).

Decisions this rests on (from the user):

| | |
|---|---|
| Prices by name length, **per year** | 5+ chars **35 KAS**, 4 **250**, 3 **1000**, 2 **2000**, 1 **4000** |
| Where the price goes | **Miners** - left as transaction fee. KaChat takes nothing. |
| Characters | `a-z`, `0-9`, `-`; 1-32 characters; no hyphen at either end |
| Marketplace fee | **None** - the buyer pays the seller the price, plus the network fee |
| Ownership | **Yearly** - a name is held until its expiry and renewed by paying again (section 4) |
| Identity data | Avatar, banner, bio, links live on the **address**, never on the name (section 7) |

Research behind this: dotk's live `.k` registry, reverse-specified from its compiled covenant
bytecode, and Silverscript v1.0.0 (`~/silverscript`, builds and compiles on this Mac). Covenants
(Toccata: KIP-16/17/20/21) are live on **mainnet** since DAA 474,165,565 (~2026-06-30) and on
**testnet-10**. KaChat's testnet mode runs on TN10 (since 2026-10-01), where names are tested.

## 1. How uniqueness works (the registry)

Borrowed from dotk, which has run it on mainnet since September:

- Every unregistered name lives inside a **gap** - a UTXO whose state is an open interval
  `(lo, hi)` of the 32-byte key space, where a name's key is `blake3(name)`. Genesis creates one
  gap, `(0x00…00, 0xff…ff)`.
- Registering `name` spends the one gap containing `key` and writes back `(lo, key)`, `(key, hi)`
  and a **name UTXO** at `key`. `key` is now a seam inside no gap, so no second registration of it
  can ever happen - consensus, not a server, guarantees one owner per name.
- Releasing a name spends `(lo, key)`, the name and `(key, hi)` and writes back `(lo, hi)`.
- All gaps and names carry one **registry covenant id** (KIP-20), minted once at genesis; only
  registry scripts can create UTXOs with it, and each script pins exactly which outputs carry it.

## 2. Registration: commit, wait, register

dotk's split publishes `blake3(name)` up front, so anyone watching can recover a short or
dictionary name from it and race the registration. `.kachat` closes that:

1. **Commit** - an ordinary transaction creates a small **commit UTXO** (0.2 KAS, returned at
   registration) whose script is
   `push(commitment) OP_DROP push(ownerKey) OP_CHECKSIG`, with
   `commitment = blake3("kachat-commit:v1" ‖ name ‖ ownerKey ‖ salt32)`. It is a plain P2SH
   spendable only by the owner - nothing about the name is visible, and it locks up nothing else.
2. **Wait** at least `T_COMMIT` (proposal: 600 DAA, about a minute).
3. **Register** - one transaction, run by the registry gap's `register(…, years, now)` entry:
   - input 0: the gap `(lo, hi)` containing `blake3(name)`;
   - input 1: the commit UTXO (signed by the owner);
   - inputs 2..: the owner's funding;
   - output 0 `(lo, key)` gap, output 1 `(key, hi)` gap, output 2 the **name UTXO**
     (`owner = ownerKey`, unlisted, `expiresAt = now + years × 1 year`), output 3.. change.

   The gap checks: `lo < key < hi`; the name's characters and length; that input 1's script is
   exactly the commit script for `(name, ownerKey, salt)`; that input 1 carries a relative
   sequence lock of at least `T_COMMIT` (so consensus only accepts the transaction once the block
   DAA is `>= commitDaa + T_COMMIT`); `1 <= years <= MAX_YEARS`;
   `tx.time >= now` (the transaction's time lock proves `now` is not in the future); the exact
   outputs and values; and that **inputs - outputs >= price(len(name)) × years** - the price is
   the miner fee.

   Lock time and sequences: `lockTime = now`, input 1 `sequence = T_COMMIT`, input 0
   `sequence = 0`. Maturity is a sequence lock rather than a DAA lock-time check because a
   transaction has one lock time and it is already spent on `now` (time domain); the two units
   can't share it. `now` is checked against the block's median time, which lags the clock by
   ~2.2 minutes, so the app sends `now = wall clock - 3 min`.

A front-runner who sees the register transaction knows the name, but registering it needs a
commit for *their* key that is already `T_COMMIT` old. Two people who both committed the same
name earlier race on equal terms - first registered wins.

Because commits never touch the registry, an abandoned commit blocks nothing and costs nothing:
**there is no deposit and no eviction step** (dotk needs both because its pending claims sit in
the registry). The owner can spend an unused commit back to themselves any time.

## 3. The name UTXO

State (fixed layout, script pushes):

| Field | Type | Meaning |
|---|---|---|
| `key` | byte[32] | `blake3(name)` |
| `name` | byte[32] | the name, zero-padded |
| `owner` | byte[32] | x-only Schnorr key (KaChat addresses are P2PK) |
| `price` | int | 0 = not listed; otherwise the asking price in sompi |
| `expiresAt` | int | unix time in milliseconds when the paid period ends |

Value: `BOND` (proposal 1 KAS, returned on release). Entries:

| Entry | Who | Effect |
|---|---|---|
| `transfer(newOwner, sig)` | owner | new owner; any listing is cleared; expiry unchanged |
| `list(price, sig)` | owner | sets the asking price (0 = delist) |
| `buy(newOwner)` | anyone | requires the output right after the name's continuation to pay `price` to P2PK(owner); new owner = `newOwner`; price reset; expiry unchanged |
| `renew(years)` | anyone | `expiresAt += years × 1 year`; requires `1 <= years <= MAX_YEARS` and **inputs - outputs >= renewPrice(len) × years** as miner fee |
| `release(sig)` | owner | the exit: with `merge`/`absorbed` on the two gaps, destroys the name and returns `BOND` |
| `reclaim()` | anyone | the expired exit: once `tx.time >= expiresAt + GRACE`, destroys the name like `release`, pays `BOND` back to P2PK(owner) at output 1, and the caller keeps the freed gap value (less the network fee) at output 2 as a bounty |

`buy` needs no seller signature; the buyer's own SIGHASH_ALL signature on their funding commits
to the continuation (so to `newOwner`), and the payout index is pinned to the name's own output,
so one payment can never settle two listings (the trap in published marketplace code). Every
entry also pins the continuation's value and uses `OpAuthOutputIdx`, since
`validateOutputState` checks only the script.

## 4. Yearly renewal and expiry

A name is paid for by the year, in the same tiers and to the same place (miners) as registration.

- **Registration** pays for 1 to `MAX_YEARS` years up front (`MAX_YEARS` = **2**, decided).
- **Renewal** (`renew`) adds 1 to `MAX_YEARS` years to the current expiry, as often as anyone
  likes - there is no practical cap on how far ahead a name can be paid (the script refuses
  past ~3 million years, only to rule out integer overflow). Anyone can renew any name (a gift
  needs no signature); the owner does not change.
- **Expiry only ever moves forward.** No entry shortens it, so the expiry a buyer sees on a
  listing or an offer is the least they get.
- **Time is wall-clock milliseconds**, the time-lock domain of `OpCheckLockTimeVerify`, not DAA
  score: a year of DAA would drift with any future change to the block rate.

Script can say "not before" but never "not after", so the covenant never blocks an entry because a
name has expired; expiry is enforced by who reads the name, and by `reclaim`:

| Period | On-chain | In the app and indexer |
|---|---|---|
| Active (`now < expiresAt`) | everything works | the name resolves; the owner gets reminders 30 / 7 / 1 days before expiry |
| Grace (`expiresAt <= now < expiresAt + GRACE`) | everything still works; nobody can take it | the name **stops resolving**; only the owner is shown "Expired - renew to keep it" |
| Lapsed (`now >= expiresAt + GRACE`) | anyone may `reclaim`, returning the bond to the old owner and reopening the gap; the owner can still renew until someone does | the name shows as available; claiming it is reclaim + the usual commit/register |

`GRACE`: **10 days** (decided). A renewal during or after grace counts from the old expiry, so lapsed
time is paid for (no free gap years). Anyone wanting a lapsed name can commit before the reclaim,
so a dropping name is a fair race between people who already committed - the same as a fresh one.

Listing, buying and offers are not tied to expiry on-chain. The app shows the expiry on every
listing and offer, refuses to list a name in grace, and warns before buying one with less than 30
days left.

## 5. Offers

An **offer** is a separate UTXO a buyer creates for a name that may not be listed - KAS locked
under a script, not held by anyone.

State: `key` (the name wanted), `buyer` (x-only key), `refundAfter` (DAA score). Value: the
offered KAS. Entries:

| Entry | Who | Effect |
|---|---|---|
| `accept(nameIdx)` | the name's owner (their `transfer` signature on the same tx) | checks input `nameIdx` is a registry name (covenant id + template) with `key`, its continuation goes to `buyer`, and the output after it pays the offer's value to the old owner |
| `withdraw(sig)` | buyer | any time: the KAS goes back |
| `refund()` | anyone | once `tx.daa >= refundAfter`: the KAS goes back to the buyer |

Script can say "not before", never "not after": an owner can still accept after `refundAfter`
until someone refunds. The app shows it as "refundable after", and refunds it automatically.
The offer bakes in the registry id and name template hash; the name never references offers, so
there is no template cycle. The buyer sees the name's expiry when making the offer, and it can
only grow.

## 6. Contracts and deployment

| Contract | Role | Covenant |
|---|---|---|
| `KachatGap` | registry interval: `register`, `merge`, `absorbed` | registry id |
| `KachatName` | a name: `transfer`, `list`, `buy`, `renew`, `release`, `reclaim` | registry id |
| `KachatOffer` | an offer: `accept`, `withdraw`, `refund` | none (plain P2SH) |
| commit script | fixed template, built by the gap's check | none |

- Written in Silverscript (`pragma silverscript ^0.1.0`), compiled with a pinned `silverc v1.0.0`
  (commit `3ed9733`); registration and renewal prices, `BOND`, `GAP_VALUE` (proposal 1 KAS),
  `T_COMMIT`, `MAX_YEARS`, `GRACE` baked in.
- **Genesis**: one version-1 transaction spends an ordinary UTXO and creates the single genesis gap
  with `covenant_id(outpoint, [gap])`. Nothing else is authorized (an extra ungoverned output in
  the genesis group could later forge a merge).
- **Manifest** (`kachat-names-<network>.json`): artifacts, template hashes, params, the genesis
  binding (outpoint + authorized output), the registry id. App and indexer embed it and verify the
  template hashes and the genesis binding before trusting any UTXO.
- **Immutable**: once deployed, a template never changes - including its prices; a fix or a price
  change means a new registry. Hence testnet first, a review/audit of every entry against the
  consensus script engine, then mainnet.

## 7. Identity: everything lives on the address

A name is rented by the year and can be sold, transferred or lapse. Your identity must survive all
of that, so **identity belongs to the address, and a name is only a label pointing at it.**

### The profile record

- A profile is a transaction **from the address to itself** with payload
  `kchat:1:profile:<json>`. Spending the address's own UTXO is the signature - only the key holder
  can write it. The indexer accepts it only if an input is the address's and an output pays back
  to it.
- Each record is the **whole profile** (no patches): latest accepted wins, ordered by accepting
  block, then txid. Clearing a field = writing the profile without it.
- Fields (JSON, ≤ 2 KB):

  | Field | Meaning |
  |---|---|
  | `v` | `1` |
  | `avatar` | a **profile link** on X, YouTube, Facebook, Instagram, TikTok, Twitch, Kick, GitHub, Telegram, LinkedIn, or a Discord server invite |
  | `banner` | a profile link on X or YouTube, or a Discord server invite |
  | `bio` | ≤ 280 characters |
  | `links` | `{ "website", "x", "github", "telegram", "discord", "nostr" }`, all optional |
  | `primaryName` | which of the address's `.kachat` names to show (optional) |

  **Pictures are never uploaded.** The record stores the profile link only, and each device
  looks up the picture that platform currently shows and caches it
  (`KachatSocialImageResolver`; no indexer involved). The platform's own moderation therefore
  applies: a picture it takes down, or an account it removes, disappears from KaChat at the
  next lookup (24 h). A link the app can't reach keeps the last picture.

  There is deliberately no free-text display name: the label for an address is its name or its
  address, never something anyone can type (no impersonation by display name).
- Cost: one self-transfer, network fee only. No `.kachat` name needed - every address can have a
  profile.

### How the app shows an address

1. **Label** - the address's `primaryName` if the address owns it and it is active; otherwise its
   oldest active `.kachat` name; otherwise the short address `kaspa:qr…xyz4`. `.k` / `.kaspa`
   names stay read-only extras, never the label.
2. **Avatar, banner, bio, links** - always from the address's own profile, whatever its name.

So:

- A name lapses, is sold or transferred: the label falls back to the next name or the address;
  avatar, banner, bio and links **don't change at all**.
- You buy a name: it labels your existing profile - you never inherit the seller's avatar or bio.
- Contacts and chats are keyed by address, never by name. If `alice.kachat` changes hands, your
  chat with the old owner stays with the old owner's address; looking up `alice.kachat` again
  leads to the new owner, shown with the new owner's own profile.
- Look-ups are per address (reverse) for display, and per name (forward) only when you type or tap
  a name - forward results always show the address they resolved to.

### Privacy

Profiles are public and on-chain: the indexer keeps their history even after nodes prune the
payload. The edit screen says so before the first save.

## 8. Indexer

A `names` module in kachat-indexer (it already sees every block):

- Tracks UTXOs carrying the registry covenant id; decodes each transition from the spend
  arguments and the payload marker (`kchat:1:name:<op>`), and offer UTXOs from `kchat:1:offer:`.
- Computes each name's status (`active` / `grace` / `lapsed`) from `expiresAt` and `GRACE`;
  forward and reverse resolution return only `active` names.
- Profiles from `kchat:1:profile:` self-transfers, by address; `primaryName` honored only while the
  address owns that name and it is `active`.
- Endpoints: `/names/{name}`, `/names/by-owner/{address}`, `/names/gap/{key}` (the gap UTXO a
  register must spend), `/names/{name}/offers`, `/names/{name}/history`, `/names/expiring`
  (lapsed names awaiting reclaim), `/market/listings`, `/market/activity`, `/profiles/{address}`,
  `/identity/{address}` (label + profile in one call), `/names/manifest`.
- Push: an offer on your name, a sale of your listing, an accepted offer, a name expiring in
  30 / 7 / 1 days, a name entering grace.

## 9. App (iOS, then Android/desktop)

- Swift port of the transaction format: v1 transactions with output covenant bindings and input
  compute budgets, P2SH spends (`args ‖ dispatch tag ‖ redeem`), the state codecs, template
  splicing, covenant-id hashing, blake3, time-locked transactions, and the fee rule
  (100 sompi/gram over compute and size).
- The `.kachat` hub screens (search, claim with a years picker, My Names with expiry and Renew,
  Marketplace, offers, activity) and the setup guide go live on top of the indexer; names resolve
  first everywhere (`NameServiceTLD`).
- Identity: one `/identity/{address}` lookup feeds every profile card, chat header and contact row;
  Edit .kachat Profile writes the profile record and works with no name at all.

### App transaction core (iOS, phase 4a)

The kachat-domains CLI's builders (`tools/kachat-names-cli/src/ops.rs`) ported to Swift, testnet-10
only. The live screens (below) call it.

| File | What |
|---|---|
| `KaChat/Utilities/Blake3.swift` | BLAKE3, hash and keyed hash (rusty-kaspa's keyed BLAKE3 domains for v1 txids) |
| `KaChat/Services/KachatNames/KachatNamesCodec.swift` | name rules, `key = blake3(name)`, commit hash + script, `num8`, script numbers, state codecs, minimal pushes, P2SH/P2PK, template hash, covenant id, payload markers |
| `KaChat/Services/KachatNames/KachatNamesTransaction.swift` | version-1 tx (covenant bindings, compute budgets, storage-mass commitment), rest/full preimages, v1 txid, tx hash, SIGHASH_ALL sighash, compute / transient / storage mass, fee |
| `KaChat/Services/KachatNames/KachatNamesManifest.swift` | the manifest and its verification |
| `KaChat/Services/KachatNames/KachatNamesBuilder.swift` | commit, register, renew, transfer, list, buy, offer, accept/withdraw/refund offer, release, reclaim, cancel commit |
| `KaChat/Services/KachatNames/KachatNamesService.swift` | `@MainActor`: testnet gate, manifest loading, DAG point, funding and live registry UTXOs, P256K signing, protowire conversion, submit, profile record |

- **Manifest**: `kachat-names-testnet-10.json` from the app bundle when present, else the indexer's
  `GET /names/manifest` (the chat indexer URL). Before use: network `testnet-10`, every template hash
  recomputed from its prefix and suffix (gap and name pinned to the README's hashes), every dispatch
  tag present, the offer baked with this registry id and name template, the genesis output equal to
  the genesis gap `(00..00, ff..ff)` worth `gapValue`, and `registryCovenantId ==
  covenant_id(genesis outpoint, [(0, gap)])`. A dry-run manifest is refused.
- **Compute budgets**: the CLI measures each input in the script engine; the app has none, so it
  commits a fixed budget per entry (register 7, merge 3, absorbed 0, transfer/list 11, buy 1, renew 1,
  release 10, reclaim 0, accept 3, withdraw 10, refund 0, commit/P2PK 10). Budgets are not in the
  sighash or the txid; a higher one only costs 100 grams per unit.
- **Signing**: BIP-340 Schnorr with the wallet key (P256K), SIGHASH_ALL over the v1 sighash. The
  builders leave 65-byte placeholders, so sizes and fees are final before signing.
- **Submission**: `Protowire_RpcTransaction` with `version = 1`, `computeBudget` (and `sigOpCount = 0`)
  on inputs, `covenant` on registry outputs and `storageMass`, through `NodePoolService`. The
  protowire is regenerated from rusty-kaspa a41a333 (`scripts/regenerate_protowire.sh`).
- **Verified against vectors**: `KaChatTests/KachatNamesVectors.json`, written by kachat-domains'
  `kachat-names-vectors` from the CLI's own builders (the whole e2e plan plus ten edge cases - the tenth a cancelled commit, since kachat-domains 101f966 - each
  validated by rusty-kaspa's consensus validator). `scripts/test_kachat_names_core.swift` checks the
  pure core byte for byte, with the recorded signatures fed in: inputs, sequences, budgets, outputs,
  covenant bindings, lock time, payload, masses, fee, rest and full preimages, every sighash, every
  signature script, txid and tx hash. All 28 transactions match. It also checks codecs, BLAKE3 against
  the official vectors and Rust `blake3::hash`, and the manifest checks. With the app's fixed budgets
  instead of the measured ones, all 28 rebuilt transactions pass `kachat-names-vectors check` (signed
  with the vectors' key and run through the consensus validator, under their budgets, standardness
  and the relay floor).
- **Not verified without a device build**: P256K signing itself, the protowire conversion and the
  gRPC submit path (`KachatNamesService`), and the manifest fetch.

### Live screens on testnet (iOS, phase 4b)

On testnet-10 (Settings > Connection > Testnet) with the bundled manifest verified, the `.kachat`
screens run on the live registry. Mainnet is unchanged: mockups, "Coming soon", no network actions.

| File | What |
|---|---|
| `KaChat/Resources/kachat-names-testnet-10.json` | the TN10 manifest, bundled (registry `9444187f…7a51`) |
| `KaChat/Services/KachatNames/KachatNamesRegistryState.swift` | pure: status (B5), label rule, profile record, REST tx parser, indexer shapes, the walker state and its decoder (`apply`, a port of the CLI's `Registry::apply`), the walk loop |
| `KaChat/Services/KachatNames/KachatNamesRegistry.swift` | `@MainActor` reads: lookup, by owner, listings, lapsed, offers, history, activity, exit gaps, identity; source = names indexer or chain walker; cache in Application Support |
| `KaChat/Services/KachatNames/KachatNamesActions.swift` | `@MainActor` actions (renew, transfer, list, buy, offer, withdraw, refund, accept, release, reclaim, profile), quotes, the resumable registration driver, cancel commit |
| `KaChat/Views/Ecosystem/KachatNamesLiveViews.swift` | the live hub pages, claim sheet, name detail, transaction sheets, Your Domains tab, profile editor |

**Where the registry is read from.** `KachatNamesRegistry` uses the names indexer (KACHAT_NAMES_INDEXER.md
Part D) at the chat indexer URL when it is set and `GET /names/status` answers 200 with this
manifest's `registryCovenantId`. Otherwise it walks the chain itself:

- It keeps the registry's live UTXO set (gaps and names, plus the offers this device made), decoded,
  from the manifest's genesis gap forward, cached per network (`Application Support/KachatNames/testnet-10/registry.json`).
- A refresh asks a node (`GetUtxosByAddresses` on each state's P2SH address) which tracked UTXOs are
  unspent. For each spent one it finds the spending transaction through the Kaspa REST API
  (`GET /addresses/{p2sh}/full-transactions`, which returns v1 inputs' signature scripts and outputs'
  covenant bindings), decodes the spend exactly like B3 (dispatch tag, arguments, revealed redeem),
  predicts every registry output and accepts the transaction only if each prediction matches an
  output's P2SH script with the registry covenant id, authorized by the input that predicted it.
  New outputs are tracked in the next round; a transaction that needs a registry input not tracked
  yet waits for one later in the same round.
- Records from either source are only for display: every action re-reads its UTXOs from a node
  (registry ones with the registry covenant id) before building anything.

| | With a names indexer | Without (chain walker) |
|---|---|---|
| Lookup, gaps, owners, expiry, listings, lapsed names | yes | yes |
| Registration, renew, list, buy, transfer, release, reclaim | yes | yes |
| Offers you made (withdraw, refund) | yes | yes (tracked from your own transactions) |
| Offers others made on your names (accept) | yes | no - the screens say "Offers from others appear once a names indexer is connected" |
| History and activity | the indexer's | every registry transition the walker walked (not offers made by others) |
| Labels (section 7) | `/identity` | from the walked names; `primaryName` known only for your own address |
| Other people's profiles (avatar, bio...) | `/identity`, `/profiles` | no; your own last record only |

**Registration** (`KachatNamesActions`): a fresh 32-byte salt goes to the Keychain (per wallet and
registration), the salted commit is sent, and a record (name, years, commit outpoint and DAA, stage,
txids) goes to `Application Support/KachatNames/testnet-10/pending-<wallet>.json`. A driver (resumed
on app-active) waits until the virtual DAA is `commitDaa + tCommit + 20`, refreshes the registry and
registers by itself; if someone registered the name meanwhile it stops at "taken", where the commit
can be cancelled (`Builder.cancelCommit`: commit -> P2PK(owner) less the fee, in the vectors as the
28th transaction and validated by `kachat-names-vectors check`). A registration that is not accepted
within two minutes while its commit is still there is sent again.

**Actions** build at `max(100, REST /info/fee-estimate priority feerate)`, check on the secp256k1
curve every key a name or an offer will be locked to (new owner, buyer, accepting buyer), show the
price, network fee and balance change, confirm (twice for transfer, release and accept), pass the
device lock (`DeviceAuth`), then sign and submit, show the txid and refresh the registry once the
REST API reports the transaction accepted.

**Identity on testnet**: `NameServiceTLD.kachat` resolves (active names only) in every
resolve-everywhere field; the profile hero shows your label; Edit .kachat Profile writes the
`kchat:1:profile:` record (avatar, banner, bio, links, primary name - no display name).

**Verified without a device**: `scripts/test_kachat_names_registry.swift` (the decoder over all
vector transactions in order, refusals, the walk over a simulated chain, the rules, the REST and
indexer shapes, and `--live`: a read-only walk of the TN10 registry through api-tn10.kaspa.org);
`scripts/test_kachat_names_core.swift` (28/28 transactions byte-identical, and all 28 pass the
consensus validator with the app's fixed budgets). **Only a device build verifies**: the screens,
the node reads and submits, P256K signing, DeviceAuth, Keychain salts and the driver's timing.

## 10. Open points

1. **Renewal price**: the same tiers as registration (35 / 250 / 1000 / 2000 / 4000 KAS per
   year) - decided. (Kept as a separate contract parameter, set equal.)
2. **`GRACE`**: 10 days (decided). **`MAX_YEARS`**: 2 per transaction (decided).
3. **`T_COMMIT`**: 600 DAA (~1 min) proposed.
4. **Bond / gap value**: 1 KAS each proposed (refunded on release or reclaim; storage-mass floor
   is 0.2 KAS).
5. **Miner self-dealing**: a pool registering or renewing in its own block gets the price back -
   accepted.
6. **Large-fee transactions**: confirm on TN10 that nodes relay a transaction paying 35-8,000 KAS
   in fee (4000 × 2 years), and how the mempool treats the time-locked ones.
7. From the contract build (`~/kachat-domains/README.md`, "OPEN ISSUES"): register/renew are limited
   to 8 inputs and 8 outputs (the wallet consolidates first); the app must validate owner keys
   (an invalid key locks the name until it lapses); a registration is ~125-155k grams of storage
   mass; anyone may match a listing with a higher offer and keep at most 0.02 KAS (the app warns);
   offers follow the name, so a re-registered name's new owner can accept old offers; the
   manifest's genesis binding must be verified by app and indexer.

## 11. Plan

1. Contracts + a Rust test harness running every entry through the consensus script engine
   (repo `kachat-domains`, private on GitHub). **Done 2026-10-01**: `KachatGap` /
   `KachatName` / `KachatOffer` compile (3965 / 2002 / 897 bytes), 120 tests through rusty-kaspa's
   own `TransactionValidator` pass, and a mutation check deletes each of 37 security checks and
   confirms a test catches it.
2. TN10 genesis + manifest; register / renew / transfer / list / buy / offer / reclaim end to end
   on testnet.
3. Indexer `names` + profiles module (handoff to the indexer AI, like the other indexer docs).
4. iOS wiring: Swift transaction builder, live `.kachat` screens, identity lookups, profiles. The
   transaction core is done (phase 4a, section 9 "App transaction core"); the screens are live on
   testnet (phase 4b, section 9 "Live screens on testnet"), with or without a names indexer.
5. Review / audit, then mainnet genesis.
