# 1 KAS Gift — One Per Device

Gift each new user 1 KAS, limited to one claim per physical device.

## Core Mechanism: Apple DeviceCheck

Apple's **DeviceCheck** framework provides **2 persistent bits per device per developer** stored on Apple's servers:

- Survive app uninstall/reinstall
- Survive factory reset
- Tied to hardware, not iCloud account
- Cannot be spoofed without Apple's server-side key
- Opaque — the device never sees the bit values

### Claim Flow

```
Device                        Gift Server                     Apple
  │                                │                            │
  │─── DCDevice.generateToken() ──▶│                            │
  │    + walletAddress             │                            │
  │    + attestation               │                            │
  │                                │── query_two_bits(token) ──▶│
  │                                │◀── { bit0: false, bit1 } ──│
  │                                │                            │
  │                                │  bit0 == false → not claimed
  │                                │                            │
  │                                │── update_two_bits(token,   │
  │                                │     bit0: true) ──────────▶│
  │                                │                            │
  │◀── send 1 KAS to wallet ──────│                            │
```

If `bit0 == true` on query → already claimed → reject.

### Bit Allocation

| Bit | Purpose |
|-----|---------|
| bit0 | `true` = device has claimed the 1 KAS gift |
| bit1 | Reserved for future use |

## Hardening: App Attest

Use **DCAppAttestService** to verify each claim request:

- Request comes from a **real device** (not simulator/emulator)
- The **app binary is genuine** (not repackaged/tampered)
- Each attestation includes a **one-time challenge nonce** from the server (prevents replay)

### Attestation Flow

1. Client requests a challenge nonce from the gift server
2. Client generates an attestation key via `DCAppAttestService.generateKey()`
3. Client attests the key with the nonce via `attestKey(_:clientDataHash:)`
4. Client sends the attestation + device token + wallet address to the gift server
5. Server verifies attestation with Apple, then proceeds with DeviceCheck flow

## Threat Model

| Attack | Blocked by |
|--------|------------|
| Reinstall app | DeviceCheck (bits persist across installs) |
| Factory reset | DeviceCheck (tied to hardware) |
| New iCloud account | DeviceCheck (not account-based) |
| Emulator / simulator | App Attest |
| Modified / repackaged app | App Attest |
| Replay captured request | App Attest challenge nonce |
| Multiple wallets same device | DeviceCheck (1 claim per device regardless of wallet) |
| Scripted bulk claims | Rate limiting + App Attest |

### Residual Risk

Someone with **many physical iPhones** can claim once per device. Cost of acquiring devices far exceeds 1 KAS, making this economically unviable to exploit at scale.

## Server-Side Requirements

The gift server (endpoint on kasia-indexer or standalone service) needs:

1. **Apple DeviceCheck private key** — generated in App Store Connect → Keys
2. **Challenge nonce endpoint** — `GET /gift/challenge` returns a one-time nonce
3. **Claim endpoint** — `POST /gift/claim` accepts `{ deviceToken, walletAddress, attestation }`
4. **Apple DeviceCheck API calls** — query and update bits via server-to-server JWT auth
5. **App Attest verification** — validate attestation object against Apple's servers
6. **KAS wallet** — server-side wallet to send 1 KAS to the claimed address

### Secondary Checks (Defense in Depth)

- **Wallet address uniqueness** — one claim per address (cheap server-side check)
- **IP rate limiting** — e.g., 3 claims per IP per day
- **Minimum app version** — reject requests from versions without App Attest
- **Logging** — record all claim attempts (IP, wallet, timestamp, result) for anomaly detection

## Client-Side Implementation

### Key Components

- `DCDevice.current.generateToken()` — produces the DeviceCheck token
- `DCAppAttestService.shared` — attestation key generation and signing
- Gift claim UI — button in onboarding or settings, shown only if unclaimed locally
- Local flag in Keychain — cache claim status to avoid unnecessary server calls (not a security boundary, just UX)

### Bundle Requirements

- Capability: **DeviceCheck** must be enabled in the app's entitlements
- Capability: **App Attest** must be enabled
