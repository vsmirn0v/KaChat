> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# Ghost Payments Bug

## Problem

Self-stash messages are incorrectly being displayed as payments in the chat UI instead of being filtered out or processed as contextual messages.

## Example Case

Transaction ID: `f97e88bd8f997585...`

**Expected behavior:** Should be processed as a contextual message or skipped (self-stash)

**Actual behavior:** Displayed as "Received 3.37213977 KAS" payment

### Transaction Details

From user logs and indexer data:

```json
{
  "tx_id": "f97e88bd8f997585...",
  "sender": "kaspa:qp4jkz5jmajtdgtf4k8r5hrgwzal3ge7j3z92zv62qux5dhvgcrsxwhh5r7z4",
  "receiver": "kaspa:qp4jkz5jmajtdgtf4k8r5hrgwzal3ge7j3z92zv62qux5dhvgcrsxwhh5r7z4",
  "alias": "353062386564306535343339",
  "message_payload": "[present in transaction]",
  "amount": 337213977
}
```

**Key observation:** sender == receiver (user's own address)

Log output:
```
[ChatService] Added message f97e88bd8f997585... to ws4cz0szty, type: payment, isNew: false
```

## Root Cause Analysis

### Payment Processing Flow

1. **Fetch from Kaspa API** (`fetchPaymentsFromKaspaAPI` - line 3257)
   - Scans all transactions for an address
   - Classifies as incoming/outgoing based on input addresses
   - **Issue location:** Line 3327-3338 - Direction classification

2. **Payment Filtering** (line 3369-3382)
   - Should skip transactions with contextual or self-stash payloads
   - Uses `isContextualPayload()` and `isSelfStashPayload()` to detect
   - **Issue:** Not catching this self-stash message

3. **Process Payments** (`processPayments` - line 4245)
   - Line 4286: Should skip if `contactAddress == myAddress`
   - **Issue:** This check is failing to catch the self-stash

### Payload Detection

Expected payload prefixes:

- **Contextual message:** `ciph_msg:1:comm:` (16 bytes checked)
- **Self-stash message:** `ciph_msg:1:self_stash:` (22 bytes checked)
- **Handshake:** `ciph_hs:1:` or similar

Functions:
- `isContextualPayload()` - line 3668
- `isSelfStashPayload()` - line 3675
- `payloadPrefixString()` - line 3682 (handles OP_RETURN prefix `6a`)

## Possible Causes

### Theory 1: Address Format Mismatch

The wallet's `publicAddress` might have a different format than the API-returned sender:

- **Wallet address:** `kaspa:qp4j...` (mainnet prefix)
- **API sender:** `kaspatest:qp4j...` (testnet prefix) or no prefix
- **Result:** String comparison `contactAddress == myAddress` fails

### Theory 2: Payload Format Variation

The transaction might use a different protocol version or format:

- **Expected:** `ciph_msg:1:self_stash:`
- **Actual:** Could be `ciph_msg:2:self_stash:` or `ciph_msg:1:self_stsh:` or similar

### Theory 3: OP_RETURN Prefix Handling

The payload might have an OP_RETURN prefix that's not being stripped correctly:

- Raw payload: `6a<len>ciph_msg:1:self_stash:...`
- Current code strips first 4 chars (`6a` + length byte)
- **Issue:** Length byte might be multi-byte for large payloads

### Theory 4: Incoming Payment Logic Issue

At line 3344-3360, the code determines if it's incoming/outgoing:

```swift
let isIncomingTx = totalToUs > 0 && !weAreSender
```

For a self-stash where sender == receiver (our address):
- `totalToUs > 0` = true (we received the output)
- `weAreSender` = true (our address is in inputs)
- `isIncomingTx` = false ✓ Correct

But if called with `incoming: true` parameter, this transaction should be filtered at line 3331-3333. **This suggests the issue is in how the transaction is being fetched or processed.**

## Debug Logging Added

### 1. Address Comparison (line ~4286)

```swift
NSLog("[ChatService] Payment %@ - contactAddress: %@, myAddress: %@, match: %d",
      String(payment.txId.prefix(16)),
      String(contactAddress.suffix(20)),
      String(myAddress.suffix(20)),
      contactAddress == myAddress ? 1 : 0)
```

### 2. Self-Stash Detection at API Level (line ~3344)

```swift
if sender == address {
    NSLog("[ChatService] WARNING: Incoming payment %@ has sender == receiver (self-stash?) - sender: %@, receiver: %@",
          String(tx.transactionId.prefix(16)), String(sender.suffix(20)), String(receiver.suffix(20)))
}
```

### 3. Payload Filtering Detail (line ~3369)

```swift
let isContextual = isContextualPayload(payload)
let isSelfStash = isSelfStashPayload(payload)
if isContextual || isSelfStash {
    NSLog("[ChatService] Skipping non-payment tx %@ (isContextual: %d, isSelfStash: %d, payload prefix: %@)",
          String(tx.transactionId.prefix(12)),
          isContextual ? 1 : 0,
          isSelfStash ? 1 : 0,
          String(payload.prefix(44)))
    continue
}
```

### 4. Payload Prefix Near-Miss Detection

```swift
private func isSelfStashPayload(_ payloadHex: String) -> Bool {
    guard let payloadString = Self.payloadPrefixString(from: payloadHex, byteCount: 22) else {
        return false
    }
    let matches = payloadString.hasPrefix("ciph_msg:1:self_stash:")
    if !matches && payloadString.hasPrefix("ciph_msg:") {
        NSLog("[ChatService] Payload prefix '%@' starts with 'ciph_msg:' but not 'ciph_msg:1:self_stash:'", payloadString)
    }
    return matches
}
```

## Debugging Steps

1. **Reproduce the issue**
   - Wait for or trigger a self-stash message
   - Check if it appears as a payment

2. **Check logs for:**
   - `WARNING: Incoming payment ... has sender == receiver` - confirms self-stash detection at API level
   - `Payload prefix '...' starts with 'ciph_msg:'` - shows actual payload format
   - `Payment ... contactAddress: ..., myAddress: ..., match: 0` - shows why address comparison failed
   - `Skipping non-payment tx ... (isContextual: 0, isSelfStash: 0, payload prefix: ...)` - shows payload detection failure

3. **Look for patterns:**
   - Are addresses normalized (same prefix format)?
   - What is the actual payload prefix?
   - Is the transaction being fetched as incoming or outgoing?

## Related Code Locations

| File | Line | Function | Purpose |
|------|------|----------|---------|
| `ChatService.swift` | 3257 | `fetchPaymentsFromKaspaAPI` | Fetches all transactions from Kaspa REST API |
| `ChatService.swift` | 3327 | (local logic) | Classifies transaction as incoming/outgoing |
| `ChatService.swift` | 3344 | (local logic) | Determines sender/receiver/amount |
| `ChatService.swift` | 3369 | (local logic) | Filters contextual/self-stash payloads |
| `ChatService.swift` | 3668 | `isContextualPayload` | Detects `ciph_msg:1:comm:` prefix |
| `ChatService.swift` | 3675 | `isSelfStashPayload` | Detects `ciph_msg:1:self_stash:` prefix |
| `ChatService.swift` | 3682 | `payloadPrefixString` | Extracts payload prefix, strips OP_RETURN |
| `ChatService.swift` | 4245 | `processPayments` | Main payment processing loop |
| `ChatService.swift` | 4286 | (local check) | Skips payments where contactAddress == myAddress |

## Expected Fix Locations

Depending on root cause:

1. **If address format mismatch:** Normalize addresses before comparison (strip/add prefix consistently)
2. **If payload format variation:** Update regex or add version 2 detection
3. **If OP_RETURN handling:** Fix `payloadPrefixString` to handle multi-byte length
4. **If fetch logic issue:** Ensure self-stash transactions aren't fetched by payment APIs at all

## Additional Context

From user-reported TX details, the transaction has:
- `alias` field populated (`"353062386564306535343339"` - hex encoded)
- `message_payload` present
- sender == receiver (user's own address)

This confirms it's a self-stash message that should be processed by the self-stash flow in `resolveAndProcessSelfStash()` (line 1532), not the payment flow.

The presence of the `alias` field suggests this might have come from the **indexer API** rather than the **Kaspa REST API**, which could explain why it's not being filtered - the indexer might return it as a "contextual message" or separate endpoint, not a "payment".

## Next Steps

1. Run app with new logging and reproduce the issue
2. Share complete logs showing the transaction processing
3. Confirm the payload format and address comparison results
4. Implement fix based on identified root cause
