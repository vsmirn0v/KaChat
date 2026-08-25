# Kasia Messaging Protocol

This document explains how messaging, payments, and handshakes work in Kasia on the Kaspa blockchain.

## Core Concepts

### Self-Stash Pattern (Contextual Messages)

Messages in Kasia are NOT sent as direct transfers to recipients. Instead, they use a **self-stash** pattern:

1. **Sender creates a transaction spending their own UTXOs**
2. **Output goes back to the sender's own address** (self-spend)
3. **Message payload is embedded in the transaction**
4. **Recipient monitors sender's address** via UTXO subscriptions

This pattern allows:
- Zero-cost messaging (only transaction fee, no transfer)
- Messages are stored on the sender's "stash" (their address history)
- Recipients can't be spammed (they choose who to subscribe to)

### UTXO Subscriptions

The app subscribes to UTXO changes for:
- **Our own address**: Detect incoming payments and handshakes
- **All contacts' addresses**: Detect when they send messages (self-stash)

When a UTXO notification arrives, we know:
- **Which address** the UTXO is for
- **Transaction ID**
- **Amount**
- **Whether UTXOs were added or removed**

## Transaction Types

### 1. Contextual Messages (Self-Stash)

**Direction**: Sender's address → Sender's address (self-spend)

**Payload format**: `ciph_msg:1:msg:<alias>|<base64_encrypted_message>`

**Flow**:
```
1. Alice wants to send message to Bob
2. Alice creates TX spending her UTXOs
3. Output goes back to Alice's address (minus fee)
4. Payload contains encrypted message for Bob
5. Bob subscribes to Alice's address
6. Bob receives UTXO notification: "Alice's address has new UTXO"
7. Bob fetches TX payload (via mempool RPC or REST API)
8. Bob decrypts and checks if message is for him
```

**UTXO Notification contains**:
- `address`: Sender's address (Alice)
- `transactionId`: TX ID to fetch payload
- `amount`: Self-stash amount

**What we DON'T need from REST API**:
- Sender address (we know from subscribed address)
- Just need the **payload** for decryption

### 2. Payments

**Direction**: Sender's address → Recipient's address

**Payload format**: `ciph_msg:1:pay:<encrypted_memo>` (optional memo)

**Flow**:
```
1. Alice sends KAS to Bob's address
2. Bob receives UTXO notification for HIS address
3. Bob sees incoming funds immediately
4. Bob needs to resolve TX to find sender (Alice)
```

**UTXO Notification contains**:
- `address`: Bob's address (our address)
- `transactionId`: TX ID
- `amount`: Payment amount

**What we NEED from REST API**:
- **Sender address** (not in UTXO notification for incoming payments)
- Payload (if any memo attached)

### 3. Handshakes

**Direction**: Sender's address → Recipient's address (payment-style)

**Payload format**: `ciph_msg:1:hs:<encrypted_handshake_data>`

Handshakes are structurally similar to payments but carry encrypted public key exchange data in the payload. They establish the shared secret for future encrypted messaging.

**Flow**:
```
1. Alice wants to start conversation with Bob
2. Alice sends ~0.2 KAS to Bob's address with handshake payload
3. Bob receives UTXO notification for his address
4. Bob resolves TX to get sender and payload
5. Bob decrypts handshake to extract Alice's public key
6. Bob can now decrypt Alice's messages
7. Bob sends reciprocal handshake to complete key exchange
```

**What we NEED from REST API**:
- **Sender address** (critical for key exchange)
- **Payload** (encrypted handshake data)

## Message Resolution Flow

### For Self-Stash Messages (Fast Path)

```
UTXO Notification: Contact's address has new UTXO
                          ↓
            We know sender = subscribed address
                          ↓
    ┌─────────────────────┴─────────────────────┐
    ↓                                           ↓
Mempool RPC                              REST API
(immediate)                           (1.5s delay)
    ↓                                           ↓
Get TX payload                         Get TX payload
    ↓                                           ↓
    └─────────────→ First wins ←────────────────┘
                          ↓
              Decrypt & verify message
                          ↓
              Display in conversation
```

**Key insight**: For self-stash messages, we only need the **payload**, not the sender (we already know it from the subscription).

### For Payments/Handshakes (Requires REST)

```
UTXO Notification: Our address has new UTXO
                          ↓
        Sender unknown (only our address in notification)
                          ↓
               REST API required
                          ↓
        Resolve TX inputs to find sender
                          ↓
    ┌─────────────────────┴─────────────────────┐
    ↓                                           ↓
Has handshake payload?                   Regular payment
    ↓                                           ↓
Process as handshake                  Show in conversation
```

## Payload Encryption

### Contextual Messages

Uses ECIES (Elliptic Curve Integrated Encryption Scheme):
1. Generate ephemeral key pair
2. ECDH with recipient's public key → shared secret
3. Derive encryption key from shared secret
4. AES-256-GCM encrypt the message
5. Output: `ephemeral_pubkey || nonce || ciphertext || tag`

### Handshakes

Contains:
- Sender's public key (for key exchange)
- Sender's alias/name
- Encrypted with recipient's public key

### Payments (optional memo)

Same encryption as contextual messages, but attached to a value transfer.

## UTXO Subscription Strategy

```swift
addressesToSubscribe = [
    myAddress,                    // Incoming payments, handshakes
    contact1.selfStashAddress,    // Contact 1's messages
    contact2.selfStashAddress,    // Contact 2's messages
    ...
]
```

When we detect:
- **Our address + we're NOT spending** → Incoming payment/handshake
- **Contact's address + contact IS spending** → Self-stash (message to us)
- **Contact's address + WE are spending** → Outgoing payment to contact

### Subscription Loss and Backstops

The `utxosChanged` subscription is server-side state tied to the gRPC stream: a transparent
reconnect silently drops it while the connection still answers pings. iOS re-sends the
subscription whenever the connection generation changes (see `UtxoSubscriptionManager`) and
runs a catch-up sync for the gap. Independently of that, every platform runs a foreground
indexer poll over contacts as a backstop (desktop 5s, Android 2s, iOS 5s sequential sweep),
plus a 60s fallback poll when the subscription is down and push is off. All paths dedupe by
`txId` on insert.

There is no per-contact "disable realtime" flag or spam detector on any platform.

## Encrypted Backup Envelope (v1)

Cloud copies of the chat archive (the shared Nextcloud `kachat-backup.json` and Android's
per-account Google Drive files) are encrypted at rest. iCloud is unaffected (CloudKit already
encrypts server-side).

**Envelope** (the file's entire content):

```json
{
  "kachatEncryptedBackup": 1,
  "cipher": "aes-256-gcm",
  "nonce": "<base64, 12 random bytes, fresh per write>",
  "ciphertext": "<base64, AES-256-GCM ciphertext with the 16-byte tag appended>",
  "walletHint": "<first 8 bytes of SHA-256(walletAddress), hex>"
}
```

**Key derivation** (identical on every platform):
`key = SHA-256( identity_private_key_bytes || UTF8("kachat-backup-v1") )` where
`identity_private_key_bytes` is the raw 32-byte private key of the chatting/identity address
(m/44'/111111'/0'/0/0). Any device holding the seed derives the same key; nothing else can
read the archive.

**Plaintext** is the existing ChatHistoryArchive JSON, schema unchanged, including
`desktopState` and any foreign keys.

**Readers**: if the parsed top level has `kachatEncryptedBackup == 1`, decrypt then parse;
otherwise treat as a legacy plaintext archive and parse as-is. Legacy files stay restorable
indefinitely; writers ALWAYS encrypt. Merge-on-upload becomes download, decrypt (if
enveloped), merge, encrypt, upload. `walletHint` lets a device skip a foreign wallet's file
without decrypting; the decrypted archive's own `walletAddress` is still validated as today.
A failed decrypt (wrong seed, corrupt file) aborts before any upload, never overwrites.

## Fresh-Address Payment Pools

Privacy feature: when a user taps Send Kaspa in a 1:1 chat, the payment goes to a **fresh
address the contact's app previously shared** instead of their chatting address, so chain
observers can't link payments to the chat identity. When no pool exists for a contact (old
client version, never exchanged), the payment falls back to the chatting address — exact
pre-pool behavior. This is a cross-platform protocol: Android/desktop must implement the wire
format below identically.

iOS implementation: `PaymentPoolCodec` (Models.swift), `ChatService+PaymentPools.swift`,
`PaymentPoolStore.swift`.

### Wire Format

All three message types are plain JSON embedded in the **normal encrypted contextual content**
(`ciph_msg:1:comm:` self-stash channel) — the exact same envelope-in-plaintext pattern reactions
(`{"type":"reaction",...}`) use. No new payload prefix, no wire-protocol change. They are
**invisible**: clients intercept them before rendering and none of the three ever appears as a
chat bubble (a `payment_notice` *produces* a payment bubble, but the envelope itself is not
shown). Unknown `type` values must be left to the normal message pipeline, and clients must
ignore unknown extra fields inside these envelopes.

#### 1. `addr_pool` — share my fresh receive addresses

```json
{"type":"addr_pool","addresses":["kaspa:qq...","kaspa:qr..."],"replace":true}
```

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `type` | string | yes | Always `"addr_pool"` |
| `addresses` | array of string | yes | The **sender's own** fresh receive addresses, for the recipient to pay the sender at. Bech32 Kaspa addresses with the network prefix (`kaspa:` / `kaspatest:`). Typical batch: 2. Receivers MUST accept any batch size (subject to the stored-pool cap) — peers on older client versions may still send 5. |
| `replace` | bool | no | `true`: "discard my previous pool entirely, this list is authoritative". `false` or absent: **additive** — append to the existing pool, deduplicated by address (used by request-driven top-ups and replenish top-ups, which carry only the new address(es)). |

**Direction matters**: an `addr_pool` FROM contact C contains **C's** receive addresses — the
receiver stores them as "addresses I can pay C at".

Receiver-side validation (all required): each address must be bech32-valid, carry the correct
network prefix, and must NOT be any of the receiver's own addresses (chatting address, own
spending-chain addresses, or addresses the receiver itself has reserved for pools). Invalid
entries are dropped individually. The stored pool per contact is capped (iOS accepts max 20;
excess entries are dropped). `addr_pool` from a non-established conversation (established = at
least one incoming AND one outgoing message exchanged) is ignored.

On a `replace`, `used` flags carry over for any address that reappears — a replayed or
overlapping replace can never resurrect an already-spent address.

**Revocation primitive** (receivers MUST honor): a `replace:true` pool whose address list is
empty — or empty after per-address validation —

```json
{"type":"addr_pool","addresses":[],"replace":true}
```

**clears the receiver's stored pool for that contact entirely.** The receiver's next payment to
that contact falls back to the chatting address, and any "fresh address" UI indicator goes
false immediately. A revoke never triggers a reciprocal offer. (An *append* with no valid
addresses remains a no-op — only `replace:true` clears.) Senders use this when the user turns
the feature off (see User Toggle below) or otherwise wants to retract previously shared
addresses.

#### 2. `addr_pool_request` — ask for a fresh pool

```json
{"type":"addr_pool_request"}
```

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `type` | string | yes | Always `"addr_pool_request"` |

Sent when the stored pool for a contact runs low (iOS: ≤ 1 unused remaining, throttled to at
most one request per contact per 10 minutes). With the pool-of-2 auto-replenish (below) this is
a backstop for a lost top-up, not the primary refill path — a full fresh pool must never
trigger a request. The receiver responds by reserving a fresh batch and sending `addr_pool`
with `replace:false` (append semantics) — subject to the mandatory inbound rate limits below
(excess requests are silently ignored).

#### 3. `payment_notice` — tell the recipient about a pool payment

```json
{"type":"payment_notice","txId":"a1b2...","amountSompi":123450000,"address":"kaspa:qq..."}
```

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `type` | string | yes | Always `"payment_notice"` |
| `txId` | string | yes | Transaction id of the on-chain payment (lowercase hex) |
| `amountSompi` | integer | yes | Amount paid, in sompi |
| `address` | string | yes | The pool address the payment was sent to |

Sent by the **payer**, through the normal encrypted contextual channel, right after the payment
transaction is accepted. Why it exists: payment detection (both UTXO subscriptions and REST
history) watches the **chatting address only** — a payment to a pool address never touches
either party's chatting address, so without this notice the recipient's chat would show nothing.
(Verified against iOS `ChatService+UtxoProcessing`: a UTXO to an address that is neither `myAddress`
nor a contact address falls into the "unknown address — skip silently" case.)

**Payment-bubble contract** (all platforms must match): on receiving a `payment_notice`, the
recipient renders a normal incoming **payment bubble** in that conversation — same content as a
detected payment ("Received X KAS"), timestamped from the notice envelope's block time, with the
bubble's transaction id set to `txId`. Deduplicate by `txId`: if a message with that txId already
exists, do nothing. Rendering must NOT block on chain verification (the notice arrived over the
sender-authenticated encrypted channel); verifying the referenced tx against a REST API when
convenient is recommended — iOS corrects the amount from chain data if it disagrees and flags
the bubble with a warning state if the tx has no output to the claimed address. The payer does
NOT render anything from its own notice (its bubble was created by the send flow); an outgoing
`payment_notice` re-fetched from the indexer is swallowed.

### Pool Supply (sender side)

- Reserved addresses come from the wallet's **spending chain** (iOS: `m/44'/111111'/1'/0/<index>`),
  always at indices strictly past the highest ever revealed — guaranteed never used, never
  funded, never previously offered.
- **CRITICAL INVARIANT**: an address reserved for contact X is never offered to any other
  contact and never re-offered. Reservations are persisted per wallet + contact; new
  reservations always take fresh indices past the all-time max (which also keeps payment change
  addresses from ever colliding with reservations).
- Offer batch size: 2 (also the replenish target — see below). Earlier client versions sent 5;
  receivers must accept any batch size.
- When to send `addr_pool`:
  1. **Lazily, once per contact**, on first conversation open after the feature ships
     (persisted "offered" marker), only for established conversations, with `replace:true`;
  2. on receiving `addr_pool_request` (`replace:false`);
  3. reciprocally on receiving an `addr_pool` from a contact who hasn't gotten ours yet;
  4. **auto-replenish (pool of 2)**: whenever one of the sender's offered reservations is
     detected USED — a `payment_notice` from the contact naming it, or the offering wallet's
     own UTXO watch seeing funds arrive on it — top the contact back up so they always hold
     **2 fresh (unfunded, live) addresses**: reserve the shortfall and send an ADDITIVE
     `addr_pool` (`replace:false`) carrying just the new address(es). Re-check on every
     conversation open with that contact, so a top-up whose send failed gets retried.
     Replenish top-ups are **exempt from the 10-minute serve throttle** (they are driven by
     genuine pool consumption, not a re-offer) but honor the 60-second per-contact gap and
     both reservation caps in full — see the limits table. A contact who revoked the sender's
     pool (incoming empty `replace:true`) receives **no offer of any kind**: not just no
     replenish, but no lazy offer and no toggle-on re-offer either (their zero active count
     is disinterest, not consumption) until they re-engage with an `addr_pool_request` or a
     non-empty pool offer of their own, both of which clear the marker.
     Only OUTBOUND replenishes get the throttle exemption: inbound `addr_pool_request`
     handling keeps the full 10-minute serve throttle.
- Reserved addresses stay listed in the wallet's normal address management UI like any other
  revealed address (iOS: Manage Addresses) — the reservation only matters to pool logic and is
  not surfaced there.
- The offering wallet must watch its reserved-and-offered addresses for incoming funds (iOS adds
  them to the UTXO subscription set; they're skipped by chat classification, so watching them
  never creates bubbles).

### Consuming a Pool (payer side)

1. On Send Kaspa, if the contact's stored pool has an unused address: pay it and mark it
   consumed (persisted immediately — a consumed address is never offered to a payment again,
   even if that payment ultimately fails; burning an address is safe, reusing one is not).
   A retry of the same payment reuses the same destination.
2. After the payment tx is accepted, send `payment_notice`.
3. If consumption leaves ≤ 1 unused address, send `addr_pool_request` (backstop — the offerer's
   auto-replenish normally refills the pool without being asked).
4. No pool → pay the chatting address, no `payment_notice` (existing detection covers it).

### Rate Limits & Abuse Resistance (mandatory — part of the contract)

Serving an `addr_pool` costs the server real resources: a batch of enumerated future addresses
AND an on-chain transaction fee for the reply. Without limits, a malicious contact spamming
`addr_pool_request` (or replaying varied `addr_pool` envelopes to trigger reciprocity) could
enumerate unbounded address space and drain the victim's balance in fees. All ports MUST
enforce the same limits:

| Limit | Value | Applies to |
|-------|-------|------------|
| Pool-serve throttle | max **1 `addr_pool` send per contact per 10 minutes** | same-state sends: organic offers, reciprocity, and request-driven top-ups. **Exempt: replenish top-ups** (driven by a reservation actually getting funded — consumption-paced, so the consumption itself bounds them) and toggle broadcasts; both instead honor the 60-second gap below |
| Toggle-transition/replenish gap | min **60 seconds between consecutive broadcasts to the same contact** | throttle-exempt sends: toggle-driven broadcasts (revoke on OFF, re-offer on ON) and replenish top-ups — a genuine state change or consumption event bypasses the 10-minute throttle so it propagates promptly; rapid flapping stays bounded to one broadcast per contact per gap |
| Lifetime reservation cap | max **50 addresses ever reserved per contact** | reservation itself — batches are clamped so the total never exceeds it; applies to toggle re-offers too |
| Outstanding-unfunded cap | stop serving once **≥ 15 offered addresses have never received funds** | top-ups/offers, including toggle re-offers AND replenish top-ups (revokes bypass the caps — a revoke must always be allowed out, subject only to the transition gap) |

- Requests/offers suppressed by these limits are **silently ignored** (log locally, send
  nothing) — no error envelope exists.
- "Funded" knowledge comes from two sources: a `payment_notice` from that contact naming the
  reservation as its payment destination, and the offering wallet's own UTXO watch seeing
  funds arrive on the reserved address (offered reservations are in the watched set anyway).
  Still best-effort (a device that never sees either misses it), which is why the lifetime
  cap + throttle backstop it. A funded reservation stops counting as fresh: it leaves the
  live pool on the offering side and its row moves back into the wallet's normal
  spending-address list (iOS: Manage Addresses' main Addresses tab, force-unhidden).
- Outbound side (already stated above): `addr_pool_request` is sent at most once per contact
  per 10 minutes, and only when unused ≤ 1. A request suppressed by the peer's serve throttle
  resolves itself: payments fall back to the chatting address until a later request (retried on
  conversation open / consumption) is served.
- Implementations must also guard the reciprocity and initial-offer paths against queued
  duplicates: the "already offered" marker and the serve throttle must be re-checked at actual
  send time (after any send-queue serialization), not only when the triggering envelope is
  handled — otherwise several distinct replayed envelopes can each enqueue an offer before the
  first one flips the marker.

### Replay Protection

History re-fetch replays old envelopes. Clients must track handled envelope txIds (iOS persists
the last 500 per wallet) so a replayed `addr_pool_request` doesn't trigger another reservation
batch, a replayed `addr_pool` doesn't re-merge, and a replayed `payment_notice` doesn't
duplicate a bubble (the txId dedup covers that independently).

### Device-Local State

Pool state (my reservations per contact, their pool for me with used flags, offered markers) is
**device-local** — NOT synced via CloudKit or any backup channel. A restore onto a new device
loses it; the apps simply re-exchange: the restored device's lazy offer re-runs with
`replace:true` (which is why re-offering must always be safe), and payments fall back to the
chatting address until a fresh pool arrives. Funds received earlier on reserved spending-chain
addresses remain recoverable through normal BIP44 gap-limit discovery of the spending chain.

### User Toggle (optional)

Clients MAY expose a user-facing switch for this feature (iOS: Settings > Chats > "Chats
Privacy", default ON, stored **per account/wallet** — each wallet on the same install decides
independently, and switching accounts applies that account's value immediately). The toggle
gates the **send side only**:

- OFF → payments always go to the chatting address (stored pools are kept, just not consumed);
  no `addr_pool` is offered (initial, reciprocal, or top-up) and no `addr_pool_request` is
  sent; inbound `addr_pool_request` is silently ignored (same no-error semantics as the rate
  limits).
- OFF also switches the client's own **funding source** to the chatting address (client
  behavior, not wire protocol): 1:1 payments are funded from and change back to the chatting
  address instead of the spending chain, so sends are chatting-to-chatting end to end. Fee/max
  estimators must use the same source the send will use.
- **Revoke on toggle-off**: flipping OFF actively propagates — the client sends the empty
  `replace:true` revocation (see the `addr_pool` section) to **every contact currently holding
  a live pool of its addresses** (derived from PERSISTED reservation state: the offered-marker
  set unioned with contacts holding offered-flagged reservations, minus already-revoked), one
  revoke per contact, serialized through the normal outgoing queue. The revoke reaches
  contacts even if they were since deleted from the address book (the envelope only needs the
  address). Each success sets a persisted per-contact revoked-marker and clears that contact's
  offered-marker. Failures are logged and non-fatal: that contact simply drains the residual
  pool (the backstop semantics). A pass that leaves stragglers (contacts deferred by the
  transition gap or whose send failed) is automatically re-swept after the gap expires,
  bounded to a few passes (iOS: 3 follow-ups), so a single flip converges to "no contact
  holds a live pool" without user action; contacts still unreached after the last pass stay
  eligible on the next toggle-off. Toggle broadcasts honor the 60-second per-contact
  transition gap (see the limits table), not the 10-minute throttle.
- **Re-offer on toggle-on**: flipping ON clears the revoked-markers and **immediately
  broadcasts** a fresh `replace:true` pool-of-2 offer (the toggle is the switch; propagation
  must not wait for a conversation to be opened) to the union of:
  - every contact who **previously held a live pool** of the sender's addresses (derived from
    persisted reservation state: at least one reservation historically offered and not since
    reclaimed by the wallet's own address recycling) and doesn't hold one now; this reaches
    contacts whose conversation was deleted since the offer; and
  - every **established contact never offered before** (the lazy offer's set, sent now
    instead of on next conversation open).

  Excluded from both lanes: contacts currently holding a live pool (a revoke that never
  landed left theirs valid, so there is nothing to resend), contacts who **revoked the
  sender's pool at them** (no offers of any kind until they re-engage; see Pool Supply),
  contacts whose every reservation was reclaimed, and contacts no longer in the address book.
  Serialized, bounded by the per-contact transition gap and the reservation caps; contacts
  skipped by the gap are picked up by the lazy per-contact offer on next conversation open.
  The re-offer reuses previously offered but never-funded, never-reclaimed reservations first
  (the recipient discarded them on revoke; never-funded means no address reuse is created)
  and tops up with fresh indices to reach the batch size of 2, rather than burning a fresh
  batch against the lifetime cap each cycle.
- Reserved addresses are never un-reserved by any of this: they stay reserved for their one
  contact forever and stay in the UTXO watched set, so a payment that raced the revoke still
  lands and still renders (its `payment_notice` is honored regardless of the toggle).
- Regardless of the toggle (mandatory): inbound `payment_notice` handling stays active,
  previously offered reserved addresses stay valid and stay in the UTXO watched set (payments
  to them must keep rendering and being noticed), and inbound `addr_pool` may still be accepted
  and stored (harmless, ready if re-enabled).

### Push Notifications

The notification service extension humanizes `payment_notice` pushes ("Received X KAS") and
suppresses the banner entirely for `addr_pool` / `addr_pool_request` (they are still stored for
the main app to process on open).

## getMempoolEntry Usage

The `getMempoolEntry` RPC is used to speed up message delivery:

| Transaction Type | Need Sender? | Need Payload? | Use getMempoolEntry? |
|-----------------|--------------|---------------|---------------------|
| Self-stash message | No (known from subscription) | Yes | **Yes - primary path** |
| Incoming payment | Yes | Optional | No - REST API needed |
| Incoming handshake | Yes | Yes | No - REST API needed |

For self-stash messages, mempool RPC can reduce message latency from **2-4 seconds** (REST API indexing delay) to **~100ms** (immediate mempool query).

## Implementation Notes

### ChatService UTXO Handler

```swift
// Case 1: UTXO to our address, not us spending
if utxoAddress == myAddress && !weAreSpending {
    // Incoming payment or handshake
    // Need REST API to resolve sender
}

// Case 2: UTXO to contact's address
else if contactAddresses.contains(utxoAddress) {
    if weAreSpending {
        // Outgoing payment we sent
    } else if removedAddresses.contains(utxoAddress) {
        // Contact's self-stash - likely a message
        // Can use getMempoolEntry for fast payload retrieval
    }
}
```

### Message Decryption Filter

When we receive a self-stash notification, the message might not be for us:
- Sender could be messaging another contact
- We decrypt and check the recipient field
- If not for us, discard silently

## Transaction Payload Formats

```
ciph_msg:1:msg:<alias>|<base64_encrypted>     # Contextual message
ciph_msg:1:pay:<base64_encrypted>              # Payment with memo
ciph_msg:1:hs:<base64_encrypted>               # Handshake
ciph_msg:1:self_stash:<data>                   # Self-stash metadata
```

## Fees

- **Message (self-stash)**: ~0.0001-0.001 KAS (depends on payload size)
- **Payment**: Standard Kaspa fee + tiny payload if memo
- **Handshake**: ~0.2 KAS transfer + standard fee

## Summary

| Operation | TX Direction | Payload | Sender from UTXO? | Fast Path? |
|-----------|-------------|---------|-------------------|------------|
| Send message | Self → Self | Encrypted message | Yes (subscription) | getMempoolEntry |
| Send payment | Self → Recipient | Optional memo | N/A (we're sender) | Immediate |
| Receive payment | Sender → Self | Optional memo | No | REST API |
| Send handshake | Self → Recipient | Key exchange | N/A (we're sender) | Immediate |
| Receive handshake | Sender → Self | Key exchange | No | REST API |
