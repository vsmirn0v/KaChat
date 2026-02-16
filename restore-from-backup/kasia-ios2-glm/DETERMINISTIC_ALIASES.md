# Deterministic Aliases Migration Plan (iOS)

## Scope
This document analyzes the deterministic alias approach implemented in `external/Kasia` on branch `meztec-staging-mods-2`, maps gaps in the current iOS app, and proposes a migration plan that:

1. Keeps existing legacy chats working.
2. Moves new and upgraded chats to deterministic aliases.
3. Allows full removal of legacy aliases later.
4. Leaves handshakes as contact-sharing/on-chain signaling only.

## 1) What changed in web (`external/Kasia`)

### 1.1 Deterministic asymmetric aliases replaced negotiated aliases
Web now derives aliases from keys + contact address instead of exchanging aliases in handshakes.

- New crypto functions in Rust:
  - `derive_my_alias(my_private_key, their_address)`
  - `derive_their_alias(my_private_key, their_address)`
  - File: `external/KaChat/cipher/src/lib.rs`
- Algorithm (exact behavior):
  - Compute ECDH shared secret with peer pubkey.
  - HKDF-SHA256 with:
    - `ikm = shared_secret`
    - `info = "chat" || shared_secret || context_pubkey`
    - output length = 6 bytes (12 hex chars)
  - `context_pubkey` is:
    - `my x-only pubkey` for `myAlias`
    - `their x-only pubkey` for `theirAlias`

### 1.2 Handshakes no longer carry alias as protocol source of truth
- `HandshakePayload.alias` and `HandshakePayload.theirAlias` were made optional/deprecated.
- File: `external/KaChat/src/types/messaging.types.ts`
- Conversation creation/activation derives aliases by address, not by handshake alias payload.
- File: `external/KaChat/src/service/conversation-manager-service.ts`

### 1.3 Send/receive semantics were clarified
- Send path uses `theirAlias`.
- Receive/watch path monitors `myAlias`.
- Files:
  - `external/KaChat/src/components/MessagesPane/Composing/Directs/DirectComposer.tsx`
  - `external/KaChat/src/service/conversation-manager-service.ts`
  - `external/KaChat/src/service/block-processor-service.ts`

### 1.4 Discrete (no-handshake) conversation mode added
- Conversation can be created active immediately with deterministic aliases.
- Handshake can remain optional signaling/payment action.
- Files:
  - `external/KaChat/src/service/conversation-manager-service.ts`
  - `external/KaChat/src/store/messaging.store.ts`

## 2) Current iOS behavior (gap analysis)

The iOS app is still alias-exchange/legacy-first and will not correctly interoperate with alias-less deterministic handshakes without changes.

### 2.1 iOS still generates random aliases
- Random alias generator (`generateAlias`) is still primary for chat routing.
- File: `KaChat/Services/ChatService.swift:4032`

### 2.2 Handshake payload currently requires alias and expects it on decrypt
- `HandshakePayload.alias` is non-optional.
- File: `KaChat/Models/Models.swift:486`
- Handshake send encodes alias into payload.
- File: `KaChat/Services/KasiaTransactionBuilder.swift:482`
- Incoming handshake decrypt assumes alias exists; fallback takes first 12 chars of plaintext.
  - This will corrupt alias extraction for alias-less JSON payloads.
- File: `KaChat/Services/ChatService.swift:7768`

### 2.3 Routing model is still legacy split (`ourAliases` / `conversationAliases`)
- Incoming fetch uses `conversationAliases`.
- Outgoing send uses `ourAliases`.
- Files:
  - `KaChat/Services/ChatService.swift:3338`
  - `KaChat/Services/ChatService.swift:5663`
  - `KaChat/Services/ChatService.swift:5734`

### 2.4 Handshake and self-stash are used as alias authority
- Alias state is extracted from handshakes and saved handshake stash.
- Files:
  - `KaChat/Services/ChatService.swift:5031`
  - `KaChat/Services/ChatService.swift:5553`
  - `KaChat/Services/KasiaTransactionBuilder.swift:329`

### 2.5 UI state is handshake/alias-presence driven
- Message composer unlock depends on handshake presence + alias maps.
- File: `KaChat/Views/Chat/ChatDetailView.swift:195`

## 3) Target iOS model

### 3.1 Conversation routing state (new canonical source)
Per contact, keep explicit routing state:

```swift
enum AliasMode: String, Codable {
    case legacyOnly
    case hybrid
    case deterministicOnly
}

struct ConversationRoutingState: Codable {
    let contactAddress: String
    let deterministicMyAlias: String      // deterministic, incoming
    let deterministicTheirAlias: String   // deterministic, outgoing
    var legacyIncomingAliases: Set<String>
    var legacyOutgoingAliases: Set<String>
    var mode: AliasMode
    var peerSupportsDeterministic: Bool
    var lastLegacyIncomingAtMs: UInt64?
    var lastDeterministicIncomingAtMs: UInt64?
}
```

### 3.2 Runtime routing rules
- Incoming watch/fetch aliases:
  - `deterministicMyAlias` always.
  - `legacyIncomingAliases` while mode is `legacyOnly` or `hybrid`.
- Outgoing alias selection:
  - `legacyOnly`: primary legacy outgoing alias.
  - `hybrid`: legacy outgoing until deterministic capability is confirmed; then deterministic.
  - `deterministicOnly`: always `deterministicTheirAlias`.

### 3.3 Handshake role (target)
Handshake should become contact-sharing/on-chain signal only:

- Keep: `type`, `timestamp`, `version`, `isResponse`.
- Remove as required fields: `alias`, `theirAlias`, `conversation_id`.
- Alias derivation should never depend on handshake body.

### 3.4 Self-stash role (target)
Self-stash should persist contact linkage/cross-device intent only.

- Keep partner address + response flag.
- Do not require alias fields for new writes.
- Derive aliases from keys + partner address on restore.

## 4) Migration strategy (keep old chats working)

### 4.1 One-time local migration on app startup
For every known contact:

1. Derive deterministic pair from local private key + contact address.
2. Read existing alias maps (`conversationAliases`, `ourAliases`) into legacy sets.
3. Create `ConversationRoutingState`.
4. Choose initial mode:
   - `hybrid` if legacy aliases exist.
   - `deterministicOnly` for new contacts with no legacy data.

### 4.2 Hybrid mode behavior (compatibility phase)
Hybrid mode preserves old chats and old peers while enabling deterministic migration.

- Incoming:
  - Fetch both deterministic and legacy aliases.
- Outgoing:
  - Default to legacy alias initially for established legacy chats.
  - Switch to deterministic when capability evidence appears.

### 4.3 Capability evidence to switch outgoing to deterministic
Set `peerSupportsDeterministic = true` when one of these is observed:

1. Received contextual message on deterministic incoming alias.
2. Received handshake payload from peer with no alias fields.
3. Received explicit capability hint in handshake payload (for example `supportsDeterministicAliases: true`).
4. User manually toggles contact to deterministic mode.

When true, set mode to `deterministicOnly` (or keep `hybrid` for retention window).

Important:
- Do not rely on `version >= 2` as the primary capability signal during migration.
- Current web deterministic flow still emits handshake `version: 1` and rejects versions above its protocol max.

### 4.4 Hybrid write policy (required for old-client compatibility)
During compatibility phase, handshake/self-stash writes must remain old-client-safe:

- Keep transport envelope as `ciph_msg:1:handshake:` / `ciph_msg:1:self_stash:`.
- Keep handshake payload `version` within legacy-accepted range during hybrid (currently `1`).
- For unknown/legacy peers, include compatibility alias fields in handshake payload:
  - `alias` must be the sender's actual outgoing alias for that peer.
  - If sender is already deterministic for that peer, `alias` must be `deterministicTheirAlias` (outgoing alias), not `deterministicMyAlias`.
- Decode both camelCase and snake_case forms for shared fields (`isResponse`/`is_response`, `conversationId`/`conversation_id`), and keep encode behavior explicit while mixed clients exist.
- Never treat received handshake alias fields as deterministic source of truth; they are compatibility hints only.

### 4.5 Legacy chat continuity guarantees
This approach keeps old chats usable because:

- Legacy incoming aliases remain watched/fetched in hybrid mode.
- Existing message history is untouched.
- Legacy outgoing alias can remain active until peer upgrade is observed.
- Older iOS clients can reject unknown incoming aliases when a legacy alias set already exists; deterministic outgoing should only be enabled after deterministic alias is known on the peer side.

## 5) Plan to fully ditch old aliases later

### 5.1 Sunset stages

1. Stage A (default hybrid): read+write both systems as needed.
2. Stage B (deterministic write-only):
   - Stop creating new legacy aliases.
   - Stop writing compatibility alias fields to handshake payloads for peers marked deterministic (continue for unknown/legacy peers).
   - Keep legacy-compatible self-stash writes until client-version cutoff is reached.
3. Stage C (legacy read-only timeout):
   - Keep reading legacy aliases for contacts with recent legacy traffic only.
4. Stage D (full removal):
   - Remove legacy alias maps and migration code.
   - Handshakes remain contact-sharing signals only.

### 5.2 Operational cutoff suggestion
Use a feature flag + migration date:

- `derived_aliases_mode = hybrid | deterministic_write_only | deterministic_only`
- When set to `deterministic_only`, disable legacy alias send/fetch paths globally.

## 6) Concrete implementation plan (iOS)

## Phase 0: Foundation and compatibility
1. Add deterministic derivation utility matching web algorithm exactly.
2. Add fixed cross-platform test vectors (same inputs must match web outputs).
3. Make handshake decoders tolerant to both old and new payload forms.

Files:
- `KaChat/Utilities/DeterministicAlias.swift` (new)
- `KaChat/Utilities/KasiaCipher.swift` (reuse ECDH helpers or expose shared-secret helper)
- `KaChat/Models/Models.swift` (optional/deprecated handshake alias fields; dual key decoding)

## Phase 1: Introduce routing state and migration
1. Add `ConversationRoutingState` storage (UserDefaults or MessageStore).
2. Migrate existing `conversationAliases` + `ourAliases` into legacy buckets.
3. Derive deterministic aliases for every contact during migration.
4. Keep legacy keys readable during transition.

Files:
- `KaChat/Services/ChatService.swift`
- `KaChat/Models/Models.swift`

## Phase 2: Switch runtime send/receive logic
1. Incoming fetch/watch should use routing alias union by mode.
2. Outgoing send should select alias via routing mode (not `generateAlias()`).
3. Remove random alias generation from normal flow.
4. Update push watched alias export to include deterministic incoming aliases.

Files:
- `KaChat/Services/ChatService.swift`
- `KaChat/Services/PushNotificationManager.swift`

## Phase 3: Handshake and self-stash semantics
1. Update handshake builder to support hybrid-compatible writes:
   - compatibility mode: include alias field(s) for unknown/legacy peers;
   - deterministic mode: alias-less payload only for peers confirmed deterministic.
2. Keep parser for both alias-bearing and alias-less handshake payloads.
3. Add dual-key decode support for camelCase and snake_case handshake fields.
4. Update self-stash writer to support staged transition (dual-write first, alias-less only after cutoff).
5. Update self-stash restore to derive aliases from partner address.

Files:
- `KaChat/Services/KasiaTransactionBuilder.swift`
- `KaChat/Services/ChatService.swift`
- `KaChat/Models/Models.swift`

## Phase 4: UI behavior and discrete mode
1. Decouple composer unlock from legacy alias availability.
2. Use routing mode/status instead of handshake message count heuristic.
3. Optional: add explicit discrete conversation action (no handshake tx).

Files:
- `KaChat/Views/Chat/ChatDetailView.swift`
- `KaChat/Views/Contacts/AddContactView.swift` (optional UX entry point)

## Phase 5: Legacy removal (future)
1. Add feature flag for deterministic-only mode.
2. Add cleanup job to purge stale legacy aliases after retention window.
3. Remove legacy code paths and keys.

Files:
- `KaChat/Services/ChatService.swift`
- `KaChat/Views/Settings/SettingsView.swift` (if exposing debug toggle)

## 7) Important interoperability notes

1. iOS currently encodes some handshake fields as snake_case (`is_response`, `conversation_id`) while web uses camelCase (`isResponse`, `conversationId`). Decoder/encoder compatibility should be explicit during migration.
2. Incoming handshake decryption fallback (`String(decrypted.prefix(12))`) should be removed or limited to strict legacy format only.
3. During hybrid phase, deterministic outgoing should not be forced for legacy-only peers until capability is detected, or messages may silently not reach old clients.
4. Web's conversation manager currently enforces protocol version max `1`; sending handshake `version > 1` can fail on older web clients.
5. Keep protocol envelope prefixes at `ciph_msg:1:*` during compatibility period; changing envelope version is a separate migration.
6. If compatibility alias is emitted in handshake, it must match sender runtime routing choice for that peer (legacy outgoing alias in legacy mode, deterministic outgoing alias in deterministic mode).
7. Older iOS chat filtering may skip messages for aliases not present in the contact's known alias set once that set exists; this makes pre-seeding deterministic alias knowledge a prerequisite before flipping outgoing mode.
8. Alias-less self-stash writes are not backward-compatible with older iOS restore logic that expects at least contact + our alias; keep staged self-stash compatibility writes until cutoff.

## 8) Test plan

### Unit tests
1. Deterministic alias derivation vectors:
   - iOS output must match web/Rust for fixed key+address cases.
2. Handshake decode matrix:
   - Legacy payload with alias.
   - New payload without alias.
   - camelCase and snake_case variants.
   - `version: 1` deterministic handshake payload with and without alias compatibility fields.
3. Routing selection tests:
   - `legacyOnly`, `hybrid`, `deterministicOnly` send/receive alias sets.
4. Capability detection tests:
   - Should not require `version >= 2`.
   - Should switch on deterministic incoming alias evidence.

### Integration tests
1. Existing legacy chat migrates to hybrid and still receives old-alias messages.
2. New conversation works deterministically with no alias in handshake.
3. At deterministic-only stage, self-stash restore reconstructs routing state without alias fields.
4. Push registration includes deterministic incoming alias set.
5. Hybrid handshake compatibility write (`alias` present, `version: 1`) is accepted by old iOS and old web clients.
6. Old iOS peer continues receiving after local side flips to deterministic only after deterministic alias is known.

### End-to-end matrix
1. New iOS <-> web deterministic branch.
2. New iOS <-> old iOS (hybrid fallback expected).
3. Deterministic-only mode against old peer (expected limitation, explicit UX warning).

## 9) Recommended rollout

1. Ship Phase 0-3 behind `deterministic_aliases_mode=hybrid`.
2. Observe telemetry/logging for deterministic capability adoption.
3. Enable deterministic write-only.
4. Move to deterministic-only after announced cutoff and retention window.

This gives a safe migration path: old chats continue working, new deterministic routing is introduced immediately, and legacy aliases can be fully retired later without reintroducing handshake alias coupling.
