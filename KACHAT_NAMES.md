# .kachat names - design (v1)

KaChat's own name service: names like `alice.kachat`, registered, transferred, listed, bought and
offered on entirely on Kaspa through covenants. No server holds a name or a coin at any point;
the indexer only reads the chain. Status: **design, under review** (2026-10-01).

Decisions this rests on (from the user):

| | |
|---|---|
| Prices by name length | 5+ chars **35 KAS**, 4 **250**, 3 **1000**, 2 **2000**, 1 **4000** |
| Where the price goes | **Miners** - left as transaction fee. KaChat takes nothing. |
| Characters | `a-z`, `0-9`, `-`; 1-32 characters; no hyphen at either end |
| Marketplace fee | **None** - the buyer pays the seller the price, plus the network fee |
| Ownership | **Forever** until released or sold (recommended; open - see section 9) |
| Profile data | Lives on the **address**, never on the name (section 6) |

Research behind this: dotk's live `.k` registry, reverse-specified from its compiled covenant
bytecode, and Silverscript v1.0.0 (`~/silverscript`, builds and compiles on this Mac). Covenants
(Toccata: KIP-16/17/20/21) are live on **mainnet** since DAA 474,165,565 (~2026-06-30) and on
**testnet-10**. KaChat's testnet profile currently points at TN11; names test on **TN10**.

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
3. **Register** - one transaction, run by the registry gap's `register` entry:
   - input 0: the gap `(lo, hi)` containing `blake3(name)`;
   - input 1: the commit UTXO (signed by the owner);
   - inputs 2..: the owner's funding;
   - output 0 `(lo, key)` gap, output 1 `(key, hi)` gap, output 2 the **name UTXO**
     (`owner = ownerKey`, unlisted), output 3.. change.

   The gap checks: `lo < key < hi`; the name's characters and length; that input 1's script is
   exactly the commit script for `(name, ownerKey, salt)`; that input 1 was created at least
   `T_COMMIT` ago (`tx.daa >= OpTxInputDaaScore(1) + T_COMMIT`); the exact outputs and values;
   and that **inputs - outputs >= price(len(name))** - the price is the miner fee.

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

Value: `BOND` (proposal 1 KAS, returned on release). Entries:

| Entry | Who | Effect |
|---|---|---|
| `transfer(newOwner, sig)` | owner | new owner; any listing is cleared |
| `list(price, sig)` | owner | sets the asking price (0 = delist) |
| `buy(newOwner)` | anyone | requires the output right after the name's continuation to pay `price` to P2PK(owner); new owner = `newOwner`; price reset |
| `release(sig)` | owner | the exit: with `merge`/`absorbed` on the two gaps, destroys the name and returns `BOND` |

`buy` needs no seller signature; the buyer's own SIGHASH_ALL signature on their funding commits
to the continuation (so to `newOwner`), and the payout index is pinned to the name's own output,
so one payment can never settle two listings (the trap in published marketplace code). Every
entry also pins the continuation's value and uses `OpAuthOutputIdx`, since
`validateOutputState` checks only the script.

## 4. Offers

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
there is no template cycle.

## 5. Contracts and deployment

| Contract | Role | Covenant |
|---|---|---|
| `KachatGap` | registry interval: `register`, `merge`, `absorbed` | registry id |
| `KachatName` | a name: `transfer`, `list`, `buy`, `release` | registry id |
| `KachatOffer` | an offer: `accept`, `withdraw`, `refund` | none (plain P2SH) |
| commit script | fixed template, built by the gap's check | none |

- Written in Silverscript (`pragma silverscript ^0.1.0`), compiled with a pinned `silverc v1.0.0`
  (commit `3ed9733`); prices, `BOND`, `GAP_VALUE` (proposal 1 KAS), `T_COMMIT` baked in.
- **Genesis**: one version-1 transaction spends an ordinary UTXO and creates the single genesis gap
  with `covenant_id(outpoint, [gap])`. Nothing else is authorized (an extra ungoverned output in
  the genesis group could later forge a merge).
- **Manifest** (`kachat-names-<network>.json`): artifacts, template hashes, params, the genesis
  binding (outpoint + authorized output), the registry id. App and indexer embed it and verify the
  template hashes and the genesis binding before trusting any UTXO.
- **Immutable**: once deployed, a template never changes; a fix means a new registry. Hence
  testnet first, a review/audit of every entry against the consensus script engine, then mainnet.

## 6. Profiles (on the address, not the name)

A name can be sold, released or lost; a profile must not go with it. So:

- A profile is a **signed record by an address**: a transaction from the address to itself with
  payload `kchat:1:profile:<json>` (avatar URL, banner URL, bio, links, `primaryName`), latest wins.
- The indexer stores it by address and serves it to every app. A name only **points to its
  owner's address**; selling `alice.kachat` hands over the name, never Alice's avatar or bio.
- `primaryName` picks which of the address's names is shown; the indexer only honors it while the
  address actually owns that name.
- This works for every address, with or without a `.kachat` name - "Edit .kachat Profile" edits it.

## 7. Indexer

A `names` module in kachat-indexer (it already sees every block):

- Tracks UTXOs carrying the registry covenant id; decodes each transition from the spend
  arguments and the payload marker (`kchat:1:name:<op>`), and offer UTXOs from `kchat:1:offer:`.
- Endpoints: `/names/{name}`, `/names/by-owner/{address}`, `/names/gap/{key}` (the gap UTXO a
  register must spend), `/names/{name}/offers`, `/names/{name}/history`, `/market/listings`,
  `/market/activity`, `/profiles/{address}`, `/names/manifest`.
- Push: an offer on your name, a sale of your listing, an accepted offer.

## 8. App (iOS, then Android/desktop)

- Swift port of the transaction format: v1 transactions with output covenant bindings and input
  compute budgets, P2SH spends (`args ‖ dispatch tag ‖ redeem`), the state codecs, template
  splicing, covenant-id hashing, blake3, and the fee rule (100 sompi/gram over compute and size).
- The `.kachat` hub screens (search, claim, My Names, Marketplace, offers, activity) and the
  setup guide go live on top of the indexer; names resolve first everywhere (`NameServiceTLD`).
- Profiles: Edit .kachat Profile writes the profile record.

## 9. Open points

1. **Ownership: forever or yearly?** Forever is assumed. Yearly renewal would add an expiry to
   every name and a renewal entry; profiles are unaffected either way (section 6).
2. **`T_COMMIT`**: 600 DAA (~1 min) proposed.
3. **Bond / gap value**: 1 KAS each proposed (refunded on release; storage-mass floor is 0.2 KAS).
4. **Miner self-dealing**: a pool registering in its own block gets the price back - accepted.
5. **Large-fee transactions**: confirm on TN10 that nodes relay a transaction paying 35-4000 KAS
   in fee.

## 10. Plan

1. Contracts + a Rust test harness running every entry through the consensus script engine
   (new repo `kachat-names`, local until approved).
2. TN10 genesis + manifest; register / transfer / list / buy / offer end to end on testnet.
3. Indexer `names` module (handoff to the indexer AI, like the other indexer docs).
4. iOS wiring: Swift transaction builder, live `.kachat` screens, profiles.
5. Review / audit, then mainnet genesis.
