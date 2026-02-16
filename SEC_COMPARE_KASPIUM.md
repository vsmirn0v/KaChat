# Private Key Security: KaChat vs Kaspium

## 1. Hardware Protection

| | KaChat | Kaspium |
|---|---|---|
| **Secure Enclave** | Yes — explicit `kSecAttrTokenIDSecureEnclave` | No — relies on `flutter_secure_storage` defaults |
| **Encryption algorithm** | ECIES (cofactor/standard) X963-SHA256-AES-GCM via SE hardware key | None (platform Keychain handles encryption) |
| **SE key creation** | Explicit `SecKeyCreateRandomKey` with SE token | N/A |

KaChat generates a P-256 key **inside the Secure Enclave** (`KeychainService.swift:691`) and uses it to encrypt/decrypt the private key with ECIES. The SE key never leaves the hardware — decryption is performed on the SE chip itself.

Kaspium delegates entirely to `FlutterSecureStorage` which stores values in the iOS Keychain, but does not request SE-backed encryption.

## 2. Device Binding

| | KaChat | Kaspium |
|---|---|---|
| **Device-specific keys** | Yes — `keyName.{deviceId}` derived from SE pubkey hash | No |
| **iCloud sync possible** | No — `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` + `synchronizable: false` | Unlikely (default `synchronizable: false`) but not explicitly hardened |
| **Cross-device portability** | Impossible — SE-wrapped data can't decrypt on another device | Theoretically possible if Keychain syncs |

KaChat uses a **double barrier**: the Keychain item is marked `ThisDeviceOnly` AND the data inside is encrypted to a device-specific SE key. Even if the Keychain item somehow synced, the ciphertext is useless on another device.

## 3. Memory Protection

| | KaChat | Kaspium |
|---|---|---|
| **Zeroization** | `Data.zeroOut()` via `memset_s` (5 call sites) | None visible |
| **In-memory encryption** | N/A (key loaded on demand, zeroed after use) | Session key re-encryption (AES/CBC) |
| **Implementation** | `memset_s` — guaranteed not optimized away by compiler | Dart GC-managed strings — no control over memory lifecycle |

KaChat's `memset_s` is the gold standard for secure memory clearing. Kaspium keeps the seed encrypted with a random session key in memory, but Dart's garbage collector can leave plaintext copies in the heap with no way to scrub them.

## 4. Encryption at Rest

| | KaChat | Kaspium |
|---|---|---|
| **Seed/private key** | SE-wrapped (ECIES-AES-GCM, hardware-bound) | Keychain plaintext (OS-encrypted) + optional user password (AES/CBC/PKCS7) |
| **User password option** | No (SE wrapping is stronger) | Yes — NanoCrypt with SHA256-based KDF and random salt |
| **Database** | Core Data + CloudKit (per-wallet zones) | Hive + AES cipher (key stored in Keychain) |

Kaspium's optional password encryption uses a single SHA-256 as its KDF — no iterations, no memory-hardness. This is far below industry standards (PBKDF2 with 100K+ iterations, or Argon2).

## 5. Access Control

| | KaChat | Kaspium |
|---|---|---|
| **Keychain accessibility** | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | Library default (`accessible when unlocked`) |
| **SE access control** | `.privateKeyUsage` flag — key operations only, no export | N/A |
| **Biometric gate** | Via SE access control flags | `local_auth` plugin (app-level, not Keychain-level) |

KaChat's SE key has `.privateKeyUsage` access control (`KeychainService.swift:671`), meaning the key can only be used for crypto operations — it can never be exported, even by the app itself.

## 6. Attack Surface Summary

| Attack Vector | KaChat | Kaspium |
|---|---|---|
| **Jailbroken device reads Keychain** | Gets SE-encrypted ciphertext (useless without hardware) | Gets plaintext seed (unless password-protected) |
| **iCloud backup extraction** | `ThisDeviceOnly` items excluded from backup | Depends on library defaults |
| **Memory dump** | Seed scrubbed with `memset_s` | Seed may persist in Dart heap |
| **Device theft (locked)** | `AfterFirstUnlockThisDeviceOnly` — accessible only after first unlock | Similar (default accessibility) |
| **Device theft (unlocked)** | SE decryption allowed, but key still hardware-bound | Keychain accessible |

## 7. Kaspium Password Brute-Force Analysis

### The KDF (Key Derivation Function)

From `sha256_kdf.dart:12-24`, the comment says it all:

> "It's not very anti-brute forceable, but it's fast which is an important feature"

The entire key derivation is **a single SHA-256 hash**:

```
key = SHA256(password + salt)
iv  = SHA256(key + password + salt)[0:16]
```

No iterations, no memory-hardness. Compare to industry standard PBKDF2 (100,000+ iterations) or Argon2 (memory-hard).

### Brute-Force Time Estimates

A modern GPU (RTX 4090) can compute ~24 billion SHA-256 hashes/second. Since Kaspium's KDF requires 2 SHA-256 calls per attempt, that's ~12 billion password attempts/second on a single consumer GPU.

| Password | Search Space | Time (1x RTX 4090) | Time (8x GPU rig) |
|---|---|---|---|
| **4-digit PIN** | 10,000 | **< 1 microsecond** | instant |
| **6-char lowercase** | ~309 million | **< 1 second** | instant |
| **8-char alphanumeric** | ~218 billion | **~18 seconds** | **~2 seconds** |
| **8-char mixed (upper+lower+digit+symbol)** | ~6.1 trillion | **~8 minutes** | **~1 minute** |
| **12-char mixed** | ~4.76 x 10^23 | **~1.3 million years** | ~160K years |

A dedicated cracking setup with 8 GPUs costs around $15-20K. Cloud-based attacks scale further.

### vs KaChat SE-Encrypted Seed

KaChat's Secure Enclave encryption is **not brute-forceable at all** in the traditional sense:

| Property | Kaspium (password) | KaChat (Secure Enclave) |
|---|---|---|
| **What protects the seed** | `SHA256(password + salt)` — 1 hash | P-256 ECIES with hardware-bound key |
| **Key length** | Effective entropy = password entropy | 256-bit hardware key (never leaves chip) |
| **Brute-force target** | User-chosen password | 2^256 key space — physically infeasible |
| **Offline attack possible** | Yes — extract Keychain, crack on GPU | No — decryption requires the physical SE chip |
| **Cost to crack 8-char password** | ~$0.10 in cloud GPU time | N/A — requires physical device |
| **Rate limiting** | None — offline attack, unlimited speed | Hardware-enforced (SE processes one op at a time) |

The fundamental difference: Kaspium's password protection is a **software lock** that can be attacked offline at GPU speeds. KaChat's SE wrapping is a **hardware lock** — the ciphertext is meaningless without the specific Secure Enclave chip that encrypted it. There is no password to guess; the 256-bit P-256 private key exists only inside the silicon.

### Practical Implications

If an attacker obtains a Kaspium Keychain dump (jailbreak, backup extraction):
- **No password set**: seed is plaintext — immediate access
- **Short password (< 8 chars)**: cracked in seconds to minutes
- **Strong password (12+ mixed chars)**: effectively safe against brute force
- **But**: most users choose weak passwords, and Kaspium does not enforce complexity

If an attacker obtains a KaChat Keychain dump:
- They get `KSE1` + algorithm byte + ECIES ciphertext
- Without the physical device's Secure Enclave, this data is **cryptographically useless**
- Even with the physical device, SE rate-limits operations and can require biometric auth
