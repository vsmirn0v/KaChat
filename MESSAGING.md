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
    contact1.selfStashAddress,    // Contact 1's messages (if realtime enabled)
    contact2.selfStashAddress,    // Contact 2's messages (if realtime enabled)
    ...
]
```

**Contact Exclusion:**

> **⚠️ TODO:** This feature is currently broken and not working. Needs fix in a future update.

- Contacts with `realtimeUpdatesDisabled = true` are excluded from subscription
- Their messages/payments are fetched via periodic polling (60-second interval) instead
- Reduces subscription load for noisy contacts

When we detect:
- **Our address + we're NOT spending** → Incoming payment/handshake
- **Contact's address + contact IS spending** → Self-stash (message to us)
- **Contact's address + WE are spending** → Outgoing payment to contact

### Disabled Contacts Polling

For contacts with realtime updates disabled:

```swift
// ChatService.startDisabledContactsPolling()
private let disabledContactsPollingInterval: TimeInterval = 60

// Polls only contacts with realtimeUpdatesDisabled = true
// Fetches messages and payments via Kasia Indexer + REST API
```

**Spam Detection:**
When a contact produces 20+ irrelevant TX notifications in 1 minute:
1. Warning popup is shown to user
2. User can "Disable" realtime for that contact or "Dismiss"
3. Dismissed warnings are tracked per-session (reset on app restart)

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
| `addresses` | array of string | yes | The **sender's own** fresh receive addresses, for the recipient to pay the sender at. Bech32 Kaspa addresses with the network prefix (`kaspa:` / `kaspatest:`). Typical batch: 5. |
| `replace` | bool | no | `true`: "discard my previous pool entirely, this list is authoritative". `false` or absent: append to the existing pool, deduplicated by address. |

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

#### 2. `addr_pool_request` — ask for a fresh pool

```json
{"type":"addr_pool_request"}
```

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `type` | string | yes | Always `"addr_pool_request"` |

Sent when the stored pool for a contact runs low (iOS: ≤ 2 unused remaining, throttled to at
most one request per contact per 10 minutes). The receiver responds by reserving a fresh batch
and sending `addr_pool` with `replace:false` (append semantics) — subject to the mandatory
inbound rate limits below (excess requests are silently ignored).

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
- Offer batch size: ~5.
- When to send `addr_pool`:
  1. **Lazily, once per contact**, on first conversation open after the feature ships
     (persisted "offered" marker), only for established conversations, with `replace:true`;
  2. on receiving `addr_pool_request` (`replace:false`);
  3. reciprocally on receiving an `addr_pool` from a contact who hasn't gotten ours yet.
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
3. If consumption leaves ≤ 2 unused addresses, send `addr_pool_request`.
4. No pool → pay the chatting address, no `payment_notice` (existing detection covers it).

### Rate Limits & Abuse Resistance (mandatory — part of the contract)

Serving an `addr_pool` costs the server real resources: a batch of enumerated future addresses
AND an on-chain transaction fee for the reply. Without limits, a malicious contact spamming
`addr_pool_request` (or replaying varied `addr_pool` envelopes to trigger reciprocity) could
enumerate unbounded address space and drain the victim's balance in fees. All ports MUST
enforce the same limits:

| Limit | Value | Applies to |
|-------|-------|------------|
| Pool-serve throttle | max **1 `addr_pool` send per contact per 10 minutes** | every send: initial offer, reciprocity, and request-driven top-ups |
| Lifetime reservation cap | max **50 addresses ever reserved per contact** | reservation itself — batches are clamped so the total never exceeds it |
| Outstanding-unfunded cap | stop serving once **≥ 15 offered addresses have never received funds** | top-ups/offers |

- Requests/offers suppressed by these limits are **silently ignored** (log locally, send
  nothing) — no error envelope exists.
- "Funded" knowledge is best-effort: a reservation counts as funded when a `payment_notice`
  from that contact names it as the payment destination. This is only a proxy (a payer could
  omit notices), which is why the lifetime cap + throttle backstop it.
- Outbound side (already stated above): `addr_pool_request` is sent at most once per contact
  per 10 minutes, and only when unused ≤ 2. A request suppressed by the peer's serve throttle
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
