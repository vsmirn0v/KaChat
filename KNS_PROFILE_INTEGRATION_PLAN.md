# KNS Profile Integration Plan

## Goal
Integrate KNS domain profile data into KaChat so users and contacts show richer identity data (avatar + profile fields), and prepare a safe path for later on-chain profile edits.

## Constraints
- `docs.knsdomains.org` is outdated/unavailable.
- KNS profile write operations are done via text inscriptions (`op: addProfile`) and commit-reveal flow.
- Existing app currently supports KNS domain resolution/ownership lookups, but not profile read/write.

## Phase 1 (Now): Read-only profile integration

### 1) KNS service/model extensions
- Add profile models for:
  - Per-domain profile payload (`avatarUrl`, `bannerUrl`, `bio`, `x`, `website`, `telegram`, `discord`, `contactEmail`, `github`, `redirectUrl`).
  - Per-address selected profile (resolved from primary domain, fallback first domain).
- Add API fetch methods:
  - `GET /api/v1/domain/{assetId}/profile`
- Add caching + refresh throttling for profile data (similar to existing domain cache behavior).

### 2) ContactsManager integration
- Expose read accessors:
  - `getKNSProfile(for contact)`
- Extend existing KNS refresh flow to include profile refresh for all contacts.

### 3) UI integration
- Profile screen (`ProfileView`):
  - Show KNS avatar and key profile fields for current wallet (read-only).
- Chat list previews (`ConversationRow`):
  - Show contact KNS avatar when available, fallback to initials.
- Chat Info (`ChatInfoView`):
  - Show avatar/banner and all available KNS profile fields.
  - Keep existing domains section.

### 4) Non-goals in Phase 1
- No profile write/update support.
- No image upload signing flow.
- No commit/reveal inscription transaction builder.

## Phase 2: Profile write support (planned)

### Scope
- Enable editing KNS profile fields from KaChat Profile screen (wallet owner only).
- Support avatar/banner upload + field update inscriptions.
- Propagate successful updates to local profile cache and chat UI immediately.

### Reference behavior confirmed from KNS app bundle
- `addProfile` inscription payload format:
  - `{"op":"addProfile","id":"<assetId>","key":"<profileKey>","value":"<string>"}`
- Image upload flow:
  - Sign message `{"assetId":"<assetId>","uploadType":"avatar|banner"}` with wallet.
  - `POST /api/v1/upload/image` multipart form-data with fields:
    - `signMessage`
    - `signature`
    - `image`
  - Response contains uploaded URL used as `value` for `avatarUrl` / `bannerUrl`.
- After submit, app verifies indexing by polling `GET /api/v1/domain/{assetId}/profile` until field value matches.

### Workstream A: Service + model layer
1. Add mutation models:
   - `KNSProfileFieldKey` enum (`redirectUrl`, `avatarUrl`, `bannerUrl`, `bio`, `x`, `website`, `telegram`, `discord`, `contactEmail`, `github`)
   - `KNSProfileUpdateOperation` (`assetId`, `fieldKey`, `value`, `createdAt`, `status`, `txIds`)
2. Add KNS write API methods in `KNSService`:
   - `uploadProfileImage(assetId:uploadType:imageData:mimeType:signature:)`
   - `pollProfileField(assetId:key:expectedValue:timeout:)`
3. Add wallet signing helper (reuse existing key material flow):
   - `signArbitraryMessage(_:)` for KNS upload auth payload.

### Workstream B: Commit-reveal inscription engine
1. Add dedicated service: `KNSInscriptionsService` (or `KNSProfileWriteService`) with:
   - `buildAddProfilePayload(...) -> Data`
   - `submitAddProfile(...) -> CommitRevealResult`
2. Implement commit-reveal tx building (do not mix with chat payload format):
   - Build inscription script with `title: "kns"` and JSON body.
   - Derive script-hash address and commit output script.
   - Build/sign commit tx + reveal tx using current UTXO + signing stack.
3. Broadcast and confirmation flow:
   - submit commit -> wait acceptance
   - submit reveal -> wait acceptance
   - store tx ids + status for UI and retry.

### Workstream C: Profile UI editing
1. Profile screen editing UX (`ProfileView`):
   - Editable text fields with dirty-state detection.
   - Avatar/banner pickers (Photos) and upload progress.
   - Save button executes sequential mutation queue.
2. Mutation queue behavior:
   - Queue only changed fields.
   - Process sequentially (1 tx at a time) with clear per-item states:
     - queued -> signing -> submitting commit -> submitting reveal -> verifying -> done/failed
3. Error handling:
   - Per-field retry action.
   - Keep successful fields applied even if later fields fail.

### Workstream D: Cache + chat propagation
1. On successful verification:
   - Patch `KNSService.profileCache` for current wallet immediately.
   - Trigger `ContactsManager`/chat refresh hooks for avatar + profile field rebind.
2. Ensure updated avatar is visible in:
   - Profile header
   - Chat list row avatar (if current wallet shown anywhere)
   - Chat info where applicable.

### Workstream E: Safety and rollout
1. Guardrails:
   - Max field length validation per key.
   - URL/email sanity validation before inscription.
   - Prevent concurrent profile update sessions.
2. Feature flag:
   - Keep write flow behind runtime flag until testnet validation passes.
3. Telemetry:
   - Mutation start/success/failure counters and latency.

### Acceptance criteria
- Editing any supported field creates valid `addProfile` inscriptions and confirms on-chain.
- Avatar/banner upload signs auth message and stores returned URL on-chain.
- UI reflects final profile data without app restart.
- Failed field update surfaces explicit error and can be retried independently.
- No regression in Phase 1 read/display behavior.

## Phase 3: Hardening
- Add metrics/logging around KNS profile fetch latency/errors.
- Add retry/backoff tuning and stale-cache fallback behavior.
- Add regression tests for parsing/caching/update propagation in UI.
