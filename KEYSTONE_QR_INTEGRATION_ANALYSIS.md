# Keystone Hardware Wallet + QR Integration Analysis (KaChat iOS)

Date: 2026-02-26

## TL;DR

Keystone QR integration is feasible for transaction signing, but **full "private key only on Keystone" custody is not compatible with KaChat's current messaging architecture** because KaChat uses the same wallet private key for:

- transaction signing
- message/payment/handshake decryption
- deterministic alias derivation and routing
- some push/CloudKit recovery paths

Recommended path:

1. Introduce a signer abstraction and add `KeystoneSigner` (QR request/response).
2. Start with **hybrid mode**: keep local key for decryption/routing, use Keystone for spending signatures.
3. Optionally add a constrained "watch-only + send-via-keystone" mode later, with explicit UX tradeoffs.

## What The Keystone Reference Code Shows

From `external/Keystone-cold-app`:

- QR transport uses animated UR:
  - `UREncoder(..., capacity, 10, 0)` and frame animation every 200ms:
    - `app/src/main/java/com/keystone/cold/ui/views/qrcode/DynamicQrCodeView.java`
  - UR multipart decode via `URDecoder.receivePart(...)`:
    - `app/src/main/java/com/keystone/cold/scan/CaptureHandler.java`

- Supported UR types are chain-specific (eth, sol, near, cosmos, cardano, etc.), no Kaspa:
  - `app/src/main/java/com/keystone/cold/ui/fragment/main/scan/scanner/ScanResultTypes.java`

- Legacy generic JSON/protobuf path exists (`TYPE_SIGN_TX`) but still requires Keystone-side coin support:
  - `app/src/main/java/com/keystone/cold/viewmodel/QrScanViewModel.java`
  - `app/src/main/java/com/keystone/cold/remove_wallet_mode/viewmodel/tx/KeystoneTxViewModel.java`

- Coin registry in this snapshot has no `KAS`/Kaspa:
  - `coinlib/src/main/java/com/keystone/coinlib/utils/Coins.java`

## Current KaChat Constraints

### 1) Transaction signing is local-key based

- `KasiaTransactionBuilder.signTransaction(...)` requires raw private key bytes.
  - `KaChat/Services/KaChatTransactionBuilder.swift`
- Send flows call `WalletManager.shared.getPrivateKey()` and pass key into builder.
  - `KaChat/Services/ChatService+Conversations.swift`

### 2) Messaging depends on local private key (critical)

KaChat decrypts on-chain payloads using local private key:

- handshake/contextual/payment/self-stash decrypt paths:
  - `KaChat/Services/ChatService+Decryption.swift`
- message storage encryption key is derived from wallet private key hash:
  - `KaChat/Services/ChatService+Persistence.swift` (`messageEncryptionKey()`)

### 3) Deterministic routing aliases depend on private key

- alias derivation is ECDH+HKDF from local private key:
  - `KaChat/Utilities/DeterministicAlias.swift`
- routing state creation/migration needs private key:
  - `KaChat/Services/ChatService+Persistence.swift`

### 4) Wallet model assumes software key material

- `WalletManager` + `KeychainService` center around seed/private key local storage.
  - `KaChat/Services/WalletManager.swift`
  - `KaChat/Services/KeychainService.swift`

## Feasibility Conclusion

### Not feasible today

"Never store private key on iPhone, only on Keystone" while preserving current KaChat messaging behavior.

Reason: KaChat's protocol and local data model currently require private key for decryption/routing, not only signing.

### Feasible now

"Use Keystone for transaction signing via QR, while keeping local key for messaging/decryption."

This still materially reduces hot-signing exposure and is implementable without redesigning the full messaging protocol.

## Proposed Architecture

### A) Introduce signing abstraction

Create a signing interface:

- `TransactionSigner`
  - `sign(inputs: [SignInput], txContext: ...) -> [InputSignature]`
  - `signMessage(...)` (for KNS and similar flows)

Implementations:

- `LocalSoftwareSigner` (current behavior)
- `KeystoneQrSigner` (new)

Then refactor `KasiaTransactionBuilder`:

- split transaction creation and signing:
  - build unsigned tx + per-input sighash metadata
  - signer returns Schnorr signatures
  - assemble final `signatureScript`

This is the core refactor to decouple signing from raw private key access.

### B) Add wallet custody mode

Extend wallet/account model:

- `software`
- `keystoneHybrid` (recommended first)
- `keystoneWatchOnly` (later, optional)

Persist Keystone metadata:

- master fingerprint (xfp)
- derivation path(s)
- account xpub / public key
- keystone device label/id

### C) Add UR QR transport layer in iOS

Current scanner is single-frame QR (`AVCaptureMetadataOutput`) and cannot assemble animated UR multipart:

- `KaChat/Views/Shared/QRScannerView.swift`

Need:

- UR multipart decoder with progress
- UR encoder for outbound animated QR
- frame scheduler/cadence controls

### D) Pairing and signing flows

1. Pair: scan Keystone exported account UR (xpub/public key + xfp).
2. Build unsigned Kaspa tx on iOS.
3. Encode sign request UR, display animated QR.
4. Scan Keystone signature UR response.
5. Assemble signed tx, submit via existing `NodePoolService.submitTransaction(...)`.

Broadcast path already accepts fully signed transaction and does not care where signature came from:

- `KaChat/Services/NodePool/NodePoolService.swift`

## Protocol Options For Kaspa

Because this Keystone snapshot does not support Kaspa UR types:

### Option 1 (recommended long-term)

Define a Kaspa UR registry type (request/response), add support in Keystone-side parser/signing stack, and iOS companion.

Pros:
- clean typed protocol
- better compatibility and future maintenance

Cons:
- requires Keystone-side implementation work

### Option 2 (faster prototype)

Use a generic payload (`ur:bytes` or legacy `TYPE_SIGN_TX`) with a custom Kaspa transaction schema understood by a Keystone fork.

Pros:
- faster proof of concept

Cons:
- less standard, easier to break, weaker interoperability

## Suggested Incremental Plan

1. Refactor signing boundary (`TransactionSigner`) without changing behavior.
2. Implement UR scanner/encoder UI primitives in KaChat.
3. Add Keystone pairing import (xfp + xpub/public key).
4. Implement `KeystoneQrSigner` for payment tx first.
5. Extend to handshake/contextual/self-stash tx signing.
6. Add KNS message-sign support via Keystone.
7. Ship hybrid mode; evaluate watch-only mode UX separately.

## Risks

- Major: full cold-only custody incompatible with current encrypted messaging design.
- Medium: Keystone firmware/app support for Kaspa Schnorr + transaction format likely required.
- Medium: QR UX reliability (multipart scan quality, retries, timeout, user cancellation).
- Medium: KNS and arbitrary signing flows need signer abstraction, not only tx signing.

## File-Level Impact In KaChat

Primary refactor targets:

- `KaChat/Services/KaChatTransactionBuilder.swift`
- `KaChat/Services/ChatService+Conversations.swift`
- `KaChat/Services/WalletManager.swift`
- `KaChat/Models/Models.swift` (wallet mode metadata)
- `KaChat/Views/Shared/QRScannerView.swift` (multipart UR)
- new QR transport/signer modules under `KaChat/Services/` and `KaChat/Views/`

Secondary review targets (private-key assumptions):

- `KaChat/Services/ChatService+Decryption.swift`
- `KaChat/Services/ChatService+Persistence.swift`
- `KaChat/Services/ChatService+PushAndSync.swift`
- `KaChat/Services/KNSService.swift`
