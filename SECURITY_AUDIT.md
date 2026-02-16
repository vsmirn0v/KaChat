# Security Audit Report: Kasia iOS App

**Date:** 2026-02-09
**Scope:** Full codebase security review of Kasia iOS messaging and payment application
**Auditor:** Claude Code (automated static analysis)

## Executive Summary

Kasia is a messaging and payment app built on the Kaspa blockchain. The core cryptographic primitives (ECDH, ChaCha20-Poly1305, Schnorr signatures, Secure Enclave wrapping) are implemented correctly. Several vulnerabilities were identified at the protocol, transport, and data-handling layers.

**Original findings: 7 Critical, 8 High, 12 Medium, 6 Low**
**Current status: 9 fixed, 8 accepted risk/design decisions, 6 actionable open items (3 TODO + 3 BACKLOG)**

---

## Findings (Open + Fixed)

### CRITICAL

#### C1. App Transport Security Disabled

**File:** `KaChat/Resources/Info.plist:11-15`

`NSAllowsArbitraryLoads` is set to `true`, allowing all plaintext HTTP connections.

**Status:** Accepted risk — Kaspa nodes don't have TLS by default; decentralized node discovery requires plaintext gRPC. Mitigate via consensus trust model rather than transport-level TLS.

---

#### C2. gRPC Connections Use Plaintext (No TLS)

**File:** `KaChat/Services/NodePool/GRPCStreamConnection.swift:259`

All gRPC communication with Kaspa nodes is unencrypted.

**Status:** Accepted risk — trust comes from global consensus, not individual node trust. Consider sending TX to multiple nodes to reduce meddling risk.

---

#### C3. No Certificate Pinning

All REST endpoints (indexer, KNS, Kaspa REST API) rely solely on the system CA trust store.

**Status:** Accepted risk — indexers share only encrypted data; user can configure multiple indexers. Pinning not viable for changeable data sources.

---

#### C6. Weak Key Derivation for Core Data Message Encryption

**File:** `KaChat/Services/ChatService.swift:7344-7347`

Messages in Core Data encrypted with single SHA-256 hash of private key — no salt, no HKDF.

**Status:** Accepted by design — CoreData DB must be decryptable by any device with the seed phrase. Seed phrase = data ownership.

### HIGH

#### H1. Handshake Has No Mutual Authentication

**File:** `KaChat/Services/ChatService.swift:5043-5065`

Incoming handshakes auto-create contacts without challenge-response verification.

**Status:** BACKLOG — rework with new handshake support (decline handshake, archive chat).

---

#### H3. Contact Impersonation via Unverified Aliases

**File:** `KaChat/Services/ChatService.swift:2707-2740`

Aliases from handshake payloads displayed without verification. Attacker can claim any alias.

**Status:** Accepted risk (hybrid compatibility) — deterministic aliases are active, but legacy handshake aliases are still accepted for backward compatibility.

---

#### H6. No Biometric Authentication

No Face ID / Touch ID gate before viewing seed phrases, sending payments, or accessing the app.

**Status:** BACKLOG — will make optional in future.

---

#### H8. Incoming Payment Signature Not Verified Client-Side

**File:** `KaChat/Services/KasiaTransactionBuilder.swift`

App trusts gRPC node / REST API for payment validity. A malicious node can report fake incoming payments.

**Status:** FIXED — Added `KasiaTransactionBuilder.verifyTransactionSignatures()` for Schnorr verification on REST-fetched incoming payments. Verification uses existing `computeSighash()` and P256K `XonlyKey.isValid()`. Payments with invalid signatures are skipped. Gracefully skips verification when required fields are missing.

### MEDIUM

#### M1. DNS Resolution Without DNSSEC

**File:** `KaChat/Services/NodePool/NodeProfiler.swift:1162-1217`

Uses raw `getaddrinfo()` for node discovery. Vulnerable to DNS spoofing.

**Status:** TODO with fallback (DPI regions might have this blocked).

---

#### M2. URL String Concatenation with User Input

**Files:** `KaChat/Services/KNSService.swift:210`, `KaChat/Services/KasiaAPIClient.swift:298`

Direct string interpolation with addresses instead of `URLComponents`.

**Status:** FIXED — Replaced all string-interpolated URLs with `URLComponents` in `KNSService.swift` (3 instances) and `ChatService.swift` (8 instances via new `kaspaRestURL()` helper).

---

#### M3. Arbitrary Handshake Payload Accepted

**File:** `KaChat/Services/ChatService.swift:7788-7792`

If JSON parsing fails, first 12 characters of decrypted plaintext used as alias. No schema validation or length limits.

**Status:** Accepted risk — deterministic aliases are active; fallback parser remains for legacy payload compatibility.

---

#### M4. UTXO Race Condition

**File:** `KaChat/Services/ChatService.swift:1654,3517-3560`

Race condition between UTXO fetch and subscription notifications during message sends.

**Status:** FIXED — Reworked realtime UTXO handling to avoid dropped events and pending-ID races: notifications are now queued/drained sequentially (no drop on in-flight), outgoing sends are tracked by message ID (`queued/submitting/submitted`) and promoted deterministically, and ambiguous realtime classification is deferred while local send attempts are unresolved.

---

#### M6. No Content-Type Validation on API Responses

**File:** `KaChat/Services/KasiaAPIClient.swift:498-536`

Responses JSON-decoded without verifying `Content-Type` header.

**Status:** FIXED — Added Content-Type validation in `KasiaAPIClient.processResponse()`. Rejects non-JSON Content-Types when header is present; allows missing Content-Type for compatibility.

---

#### M7. Wallet Keychain Item May Sync to iCloud

**File:** `KaChat/Services/KeychainService.swift:405-406`

Wallet metadata saved with `kSecAttrSynchronizable` potentially enabled.

**Status:** TODO

---

#### M8. Push Device Token Stored in UserDefaults

**File:** `KaChat/Services/PushNotificationManager.swift:640-649`

Device tokens stored unencrypted in UserDefaults instead of Keychain.

**Status:** FIXED — Push device token now stored in Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, non-synchronizable). Includes automatic migration from UserDefaults on first launch.

---

#### M9. No URL Validation for Custom Endpoints

**File:** `KaChat/Views/Settings/SettingsView.swift`

Users can set arbitrary indexer/KNS/REST URLs with no HTTPS enforcement.

**Status:** TODO — show warning to user next to problem URL; update connection status view to include risk indicator.

---

#### M10. Change Address Dust Silently Becomes Fee

**File:** `KaChat/Services/KasiaTransactionBuilder.swift:145-150,305-306`

Change below dust threshold (10,000 sompi) silently becomes additional miner fee.

**Status:** Accepted — standard UTXO behavior, no action needed.

---

#### M11. Payment Amount Resolution by Timestamp

**File:** `KaChat/Services/ChatService.swift:2090-2140`

Incoming payment amounts matched to messages using `blockTime` proximity.

**Status:** BACKLOG

---

#### M12. No Memory Zeroing of Sensitive Data

Private keys, shared secrets, and seed phrases in Swift `Data` objects never explicitly zeroed after use.

**Status:** FIXED — Added `Data.zeroOut()` extension using `memset_s` (guaranteed not optimized away). Applied in `WalletManager.deriveKeysFromSeed()` (seed), `KasiaCipher.encrypt/decrypt()` (shared secrets), `KasiaTransactionBuilder.signTransaction()` (sighash), `ChatService.messageEncryptionKey()` (private key). Known limitation: Swift Data is COW value type, so transient copies may persist.

### LOW

| ID | Issue | File | Status |
|----|-------|------|--------|
| L1 | UInt64 addition overflow theoretically possible in UTXO sum | `KaChat/Services/KasiaTransactionBuilder.swift:534,605`; `KaChat/Services/ChatService.swift:4510` | FIXED |
| L2 | Temporary audio files not securely deleted | `KaChat/Views/Chat/ChatDetailView.swift:2064-2099` | FIXED |
| L3 | CloudKit metadata reveals communication patterns to Apple | `KaChat/Services/MessageStore.swift:212-223` | Accepted (iCloud trade-off) |
| L4 | BIP39 word list fetched from GitHub at runtime without integrity check | `KaChat/Services/BIP39.swift:17-21` | FIXED |

**L3 note:** CloudKit metadata is inherently visible to Apple — architectural trade-off of `NSPersistentCloudKitContainer`. Message content is E2E encrypted. Accepted as known privacy limitation of iCloud-based sync.

---

## Attack Vectors Summary

| Attack Vector | Open Vulnerabilities | Impact |
|---|---|---|
| **Network MITM** | C1, C2, C3, M1 | Intercept or redirect network traffic to unreliable/malicious infrastructure |
| **Contact Forgery** | H1, H3, M3 | Impersonate contacts, spoof aliases |
| **Device Compromise** | C6, H6 | Access sensitive content on unlocked device, bypass app-level intent checks |
| **Malicious Node** | C2, M11 | Distort transaction metadata interpretation and payment attribution |
| **Social Engineering** | M9 | Trick user into pointing to attacker-controlled endpoints |
| **Privacy Metadata Exposure** | L3 | Reveal communication graph metadata to cloud provider |
| **Operational Hardening Gaps** | M7, M10 | Risky defaults in keychain sync semantics and fee/change UX behavior |

---

## Positive Findings

The following areas are implemented correctly:

- **KasiaCipher (ECDH + ChaCha20-Poly1305):** Proper AEAD encryption with ephemeral keys, HKDF-SHA256 key derivation, and authenticated encryption
- **Secure Enclave wrapping:** Seed phrases and private keys wrapped with device-specific SE keys, non-transferable between devices
- **BIP39 seed-to-key derivation:** Standard PBKDF2-SHA512 with 2048 iterations
- **BIP32 key derivation:** Correct HMAC-SHA512 with standard "Bitcoin seed" domain separation
- **Schnorr transaction signing:** Correct sighash computation with Blake2b domain separation
- **Secure random generation:** `SecRandomCopyBytes` with return value validation
- **No deprecated crypto algorithms:** No MD5, SHA1, DES, RC4, or ECB mode found
- **Network epoch monitoring:** Detects WiFi/cellular transitions and resets connection state
- **Screenshot protection:** Seed phrase screens use `SecureView` with iOS screen capture protection
- **Clipboard hygiene:** Seed phrase auto-cleared from clipboard after 30 seconds
- **BIP39 validation:** Checksum validation catches typos on seed phrase import
- **HTTP/1.1 client:** HTTPS-only enforcement, OS-level TLS, 10MB response buffer limit, proper timeout handling

---

## Remaining Recommendations (Priority Order)

1. **Remove `NSAllowsArbitraryLoads`** and enforce HTTPS everywhere
2. **Add mutual authentication** to handshake protocol (decline/archive)
3. **Biometric authentication** gate for sensitive screens
4. **DNS hardening** for node discovery where compatible with hostile-network regions
5. **URL safety UX** in Settings (warn/block insecure custom endpoints)
6. **Keychain synchronizable audit** for wallet metadata persistence path (M7)
7. **Harden payment attribution logic** to reduce timestamp-based ambiguity (M11)
8. **Continue reducing alias spoof surface** while maintaining legacy interoperability (H3/M3)
