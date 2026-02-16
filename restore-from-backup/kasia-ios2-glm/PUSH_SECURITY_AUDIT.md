# Push Security Audit and Action Plan

Date: 2026-02-11
Scope: `external/kasia-indexer` push registration and dispatch service, plus iOS push client signing flow.
Environment: Internet-reachable service behind nginx reverse proxy with TLS termination.
Security model: Crypto-native (no classical username/password auth).

## Executive Summary

Option 2 (crypto request auth) is now implemented in code and should be treated as the baseline path:

- Server now supports challenge-based signed push mutation auth (`/v1/push/challenge`).
- Register/update/unregister support signed `auth` envelopes with Schnorr verification.
- Signed payload is bound to method/path/token hash/address set/alias set/timestamps and nonce.
- Nonce replay protection is server-side (single-use + TTL).
- Device token registrations can be bound to wallet key/address and enforced on update/unregister.
- `PUSH_AUTH_MODE` supports staged rollout: `legacy`, `mixed`, `strict`.
- iOS client now builds and sends signed auth for register/update and attempts signed unregister.

This closes the largest unauthenticated mutation risk, but rollout/config and attestation are still open items.

## Current Implemented Controls (Observed)

### Request auth and replay

- Domain-separated signed preimage: `kasia-push-auth:v1`.
- Signature algorithm: secp256k1 Schnorr over SHA-256 preimage digest.
- Replay resistance: server-issued nonce, TTL, single-use consume.
- Timing window checks (`timestamp_ms`, `expires_at_ms`, skew window).

### Wallet and token binding

- `wallet_address` must match derivation from `wallet_pubkey`.
- Registration can persist wallet binding on token.
- Update/unregister enforce binding consistency for bound tokens.

### Input hardening

- `ios` platform allowlist.
- max watched addresses / aliases and entry length limits.
- token normalization and bounds checks.

### Push filtering path

- Alias and primary receiver filters are active in dispatcher.
- Alias/primary cache lock failures are now fail-closed (security-first filtering behavior).
- Self-stash alias parsing is now explicit and tested in actor layer.

### APNs error handling

- APNs auth/JWT generation failures are treated separately from invalid device tokens.
- Invalid-token strike counters are only used for APNs token-specific errors.

## Remaining Security Risks

1. Mixed mode can still allow unsigned mutations.
- If `PUSH_AUTH_MODE=mixed`, unsigned clients remain a takeover/abuse surface.

2. App Attest path is implemented, but verifier hardening is still needed.
- Strict mode now enforces App Attest enrollment/assertion for push mutations.
- Remaining hardening: full certificate chain anchoring to Apple root + stricter attestation telemetry.

3. Edge abuse controls depend on nginx policy quality.
- Missing or weak body/rate limits materially increase DoS and churn risk.

## Recommended Actions

### P0 (immediate)

1. Set production rollout to `PUSH_AUTH_MODE=mixed` only for migration window, then switch to `strict` by a dated cutover.
2. Add nginx limits for `/v1/push/*`:
- request body limit (`<= 64KB`)
- per-IP rate limits
- burst caps on register/update

### P1 (1-2 weeks)

1. Harden App Attest verifier:
- add full certificate chain/root validation and stronger extension checks.
2. Add DeviceCheck server-side verification as secondary abuse signal (not primary auth gate).
3. Add explicit metrics for enrollment vs assertion failures:
- app_attest_enroll_fail_total
- app_attest_assertion_fail_total
4. Add security metrics and alerts:
- signature failures
- nonce replay rejects
- attestation rejects
- rate-limit rejects
- unregister spikes

### P2 (2-4 weeks)

1. Enforce strict mode globally and disable legacy/mixed in production.
2. Add key rotation and binding migration procedures.
3. Add incident runbook for push abuse / replay / APNs outage scenarios.

## Rollout Plan

1. Deploy server + client with signed flow enabled and `PUSH_AUTH_MODE=mixed`.
2. Track unsigned request volume and auth reject reasons daily.
3. Cut over to `PUSH_AUTH_MODE=strict` once unsigned volume is negligible.
4. Keep strict mode App Attest mandatory and monitor reject rates during rollout.

## Verification Checklist

- Rust tests pass for push auth canonicalization/nonce/signature logic.
- Rust tests pass for push registry binding and limits.
- Actor tests pass for self-stash alias parsing.
- OpenAPI includes challenge/auth request schemas.
- iOS client sends signed auth envelope for register/update and signed unregister when possible.

## Recommended Defaults

- `PUSH_AUTH_MODE`: `strict` (after migration)
- Nonce TTL: 60s
- Signed request validity window: 60s
- Max watched addresses: 256
- Max aliases: 256
- nginx body limit: 64KB
- Start rate limit: 30 req/min/IP with small burst; tune from telemetry

## Final Position

For this crypto project, the right model is request-level cryptographic authorization with replay defense and device attestation. Password/session auth is not required, but strict signature enforcement plus App Attest gating should be the end state for internet-facing push mutation endpoints.
