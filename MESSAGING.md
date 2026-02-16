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
