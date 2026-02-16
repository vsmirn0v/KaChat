> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Ghost Payment Fix (Self-Stash Duplicate)

## Problem

Self-stash messages (messages sent to yourself, stored on-chain) were appearing twice in the UI:
1. **Correctly** as a contextual message (from indexer sync)
2. **Incorrectly** as a payment (from UTXO notification or payment fetch)

**Example:**
```
txId: f97e88bd8f997585...
Logs: "[ChatService] Added message f97e88bd8f997585... to ws4cz0szty, type: contextual, isNew: false"
UI:   Shows as "Received 3.37213977 KAS" payment
```

User confirmed all data was from fresh sync after database wipe, indicating this was a sync-time duplicate creation issue.

## Root Cause

Self-stash transactions have the pattern: **sender == receiver == myAddress**

The duplicate was created because:

1. **Indexer sync** correctly fetches self-stash as contextual message
2. **UTXO notification handler** (`handleUtxoChangeNotification`) sees:
   - Output to our address: `utxoAddress == myAddress`
   - We're not spending (from perspective of this specific UTXO): `!weAreSpending`
   - Infers sender from `removedAddresses` (our address, since we spent our own UTXOs)
   - Creates duplicate payment because sender is not nil

3. **Payment fetch** (`fetchPaymentsFromKaspaAPI`) sees:
   - Transaction to our address with sender == our address
   - No payload check if payload is missing
   - Creates incoming payment

## Solution

Added `sender == receiver` checks in all payment creation points to skip self-stash transactions.

### Changes

**1. UTXO Notification Handler - Incoming Payment (ChatService.swift ~1247)**

```swift
if let sender = inferredSender {
    // Skip self-stash transactions (sender == receiver) - these are handled as contextual messages
    if sender == myAddress {
        NSLog("[ChatService] Skipping self-stash payment %@ - handled as contextual message",
              String(txId.prefix(12)))
        continue
    }

    // We have handshake with this contact - show payment immediately
    let payment = PaymentResponse(...)
    await processPayments([payment], isOutgoing: false, myAddress: myAddress)
}
```

**2. UTXO Notification Handler - Outgoing Payment (ChatService.swift ~1326)**

```swift
if updateUniquePendingOutgoingMessage(contactAddress: utxoAddress, newTxId: txId) {
    continue
}

// Skip self-stash transactions (sender == receiver) - these are handled as contextual messages
if utxoAddress == myAddress {
    NSLog("[ChatService] Skipping self-stash outgoing payment %@ - handled as contextual message",
          String(txId.prefix(12)))
    continue
}

let payment = PaymentResponse(...)
await processPayments([payment], isOutgoing: true, myAddress: myAddress)
```

**3. Payment Fetch from Kaspa API (ChatService.swift ~3366)**

```swift
if isIncomingTx && incoming {
    receiver = address
    amount = totalToUs
    sender = senderAddress.isEmpty ? "pending_resolution" : senderAddress

    // Skip self-stash transactions (sender == receiver) - these are handled as contextual messages
    if sender == address {
        NSLog("[ChatService] Skipping self-stash payment %@ - handled as contextual message",
              String(tx.transactionId.prefix(12)))
        continue
    }
}
```

**4. Resolve Incoming Payment from Unknown Sender (ChatService.swift ~1527)**

```swift
// Check 2: Kasia indexer for handshake
if let handshake = await checkIndexerForHandshake(txId: txId, myAddress: myAddress) {
    // ... process handshake
    return
}

// Skip self-stash transactions (sender == receiver) - these are handled as contextual messages
if info.sender == myAddress {
    NSLog("[ChatService] Skipping self-stash payment %@ in resolveAndProcessIncomingPayment - handled as contextual message",
          String(txId.prefix(12)))
    return
}

// Confirmed as regular payment
let payment = PaymentResponse(...)
await processPayments([payment], isOutgoing: false, myAddress: myAddress)
```

## Why sender == receiver Works

Self-stash messages always have:
- **sender**: Your address (you create the transaction)
- **receiver**: Your address (you're the recipient)
- **purpose**: Store encrypted message on-chain for yourself

Real payments have:
- **sender**: Contact's address OR your address
- **receiver**: Your address OR contact's address
- **sender ≠ receiver** (different parties)

So checking `sender == receiver` reliably identifies self-stash transactions.

## Existing Payload-Based Protection

The code already had payload-based filtering:

```swift
if isContextualPayload(payload) || isSelfStashPayload(payload) {
    NSLog("[ChatService] Skipping non-payment tx - isContextual/isSelfStash")
    continue
}
```

However, this requires the payload to be available and non-empty. The UTXO notification arrives **before** the payload is fetched, so payload-based filtering alone wasn't enough.

The `sender == receiver` check works regardless of payload availability.

## Testing

To verify the fix:

1. **Create self-stash message:**
   - Send message to yourself
   - Check logs for payment creation attempts

2. **Expected logs:**
   ```
   [ChatService] Added message <txId>... to <address>, type: contextual, isNew: true
   [ChatService] Skipping self-stash payment <txId>... - handled as contextual message
   ```

3. **UI verification:**
   - Message appears ONCE as contextual message
   - NO payment entry for the same txId

4. **Fresh sync test:**
   - Wipe database
   - Re-import wallet
   - All self-stash messages should sync as contextual only

## Edge Cases Handled

1. **User as contact**: You must have yourself as a contact for self-stash to work - handled by sender == receiver check
2. **Missing payload**: UTXO notifications don't have payload initially - handled by sender == receiver check
3. **Outgoing self-stash**: When you send to yourself - handled by outgoing payment check
4. **Incoming self-stash**: When you receive from yourself - handled by incoming payment check
5. **Payment fetch**: REST API fetch includes self-stash - handled by payment fetch check

## Related Code

| Function | Line | Check Added |
|----------|------|-------------|
| `handleUtxoChangeNotification` (incoming) | ~1253 | Skip if `sender == myAddress` |
| `handleUtxoChangeNotification` (outgoing) | ~1331 | Skip if `utxoAddress == myAddress` |
| `fetchPaymentsFromKaspaAPI` | ~3369 | Skip if `sender == address` |
| `resolveAndProcessIncomingPayment` | ~1538 | Skip if `info.sender == myAddress` |

## Files Modified

| File | Changes |
|------|---------|
| `ChatService.swift` | Added sender == receiver checks in 4 payment creation points |

## Summary

The ghost payment issue was caused by UTXO notifications and payment fetches creating duplicate entries for self-stash messages. The fix adds `sender == receiver` checks at all payment creation points to skip self-stash transactions, which are properly handled by the indexer sync as contextual messages.

This fix ensures self-stash messages appear exactly once in the UI, as contextual messages, never as payments.
