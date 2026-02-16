# Migrations Cleanup Plan (Fresh App Relaunch)

## Goal
Remove all legacy migration/compatibility code paths from the app and notification extension so the codebase assumes clean installs only.

## Scope
- `KaChat` target
- `KaChatNotificationService` target
- UserDefaults keys, Keychain fallbacks, Codable legacy decoding, routing compatibility logic

## Out of Scope
- Protocol-level changes unrelated to migration cleanup
- Backend/API behavior changes unless required to remove migration fallbacks

## Baseline (Before Changes)
1. Create a backup branch and tag current state.
2. Run a full build for app + notification extension.
3. Capture smoke-test baseline:
   - Onboarding/import/create wallet
   - Sending/receiving message
   - Push registration and push receive
   - Cold launch and wallet switch

## Legacy/Migration Targets
1. Contacts legacy storage migration
   - `KaChat/Services/ContactsManager.swift`
   - Remove `kachat_contacts` migration to `kachat_contacts_wallet_*`.

2. Chat legacy message cache migration
   - `KaChat/Services/ChatService.swift`
   - Remove `migrateLegacyMessagesIfNeeded()` and `kachat_messages` upgrade path.

3. Alias compatibility and deterministic migration flag
   - `KaChat/Services/ChatService.swift`
   - `KaChat/Models/Models.swift`
   - Remove:
     - Legacy alias decode fallback (`[String: String]` map)
     - `kachat_deterministic_migration_done`
     - `legacyOnly` / `hybrid` modes and legacy alias sets if fully deterministic-only.

4. Read marker migration
   - `KaChat/Services/MessageStore.swift`
   - `KaChat/Services/ReadStatusSyncManager.swift`
   - `KaChat/App/KaChatApp.swift`
   - Remove `MessageStore.didMigrateToReadMarkers` flow and one-time migration trigger.

5. Keychain legacy private key migration/fallback
   - `KaChat/Services/KeychainService.swift`
   - Remove:
     - `migrateLegacyPrivateKey()`
     - legacy access-group fallback load/save/delete paths
     - legacy storage status diagnostics tied to migration.

6. Notification extension keychain legacy fallback
   - `KaChatNotificationService/NotificationService.swift`
   - Remove fallback read of unsuffixed private-key account.

7. Push token migration fallback
   - `KaChat/Services/PushNotificationManager.swift`
   - Remove UserDefaults token migration from `push_device_token`.

8. Node pool old-format migration
   - `KaChat/Services/NodePool/NodePoolService.swift`
   - `KaChat/Services/NodePool/NodeRegistry.swift`
   - `KaChat/Models/Models.swift`
   - Remove migration from `grpcEndpointPool` old format into `NodeRegistry`.

9. AppSettings legacy decode keys
   - `KaChat/Models/Models.swift`
   - Remove decode compatibility for:
     - `customIndexerURL`
     - `autoRefreshGrpcPool`
     - `notificationsEnabled`
     - `backgroundFetchEnabled`
     - `pushNotificationsEnabled`
     - `"localBackgroundFetch"` legacy mode alias.

10. Misc Codable compatibility bridges
   - `KaChat/Models/Models.swift`
   - `KaChat/Services/SharedDataManager.swift`
   - Remove legacy fields/branches where old persisted payloads no longer need support.

## Execution Phases

### Phase 1: Remove one-time migration runners and flags (lowest risk)
1. Remove migration flag keys and trigger points:
   - `kachat_deterministic_migration_done`
   - `MessageStore.didMigrateToReadMarkers`
2. Remove startup migration invocation in app lifecycle and managers.
3. Keep current canonical data paths unchanged.

Exit criteria:
- App compiles.
- Clean install flow unaffected.

### Phase 2: Remove fallback reads and legacy decode branches
1. Remove legacy UserDefaults migration branches in contacts/chat/push.
2. Remove Keychain legacy read/write fallback code.
3. Remove notification extension legacy private-key fallback.
4. Remove old Codable decode keys/branches in settings/models.

Exit criteria:
- No references to `legacy`, `migrat`, `didMigrate` in runtime paths except comments/docs intentionally kept.
- Push + extension decrypt still function on clean install.

### Phase 3: Remove compatibility routing states and old node format bridges
1. Simplify alias routing model to deterministic-only.
2. Remove old alias sets and compatibility selection branches.
3. Remove `grpcEndpointPool` migration path and old endpoint model compatibility fields if unused.

Exit criteria:
- Chat send/receive succeeds using deterministic aliases only.
- Node pool initialization works without old format migration.

### Phase 4: Cleanup dead keys/constants and diagnostics
1. Delete unused key constants and stale reset-list entries.
2. Remove migration-focused diagnostic logs.
3. Update docs/comments to reflect no migration support.

Exit criteria:
- `rg -n "migrat|legacy|backward|compat"` on app source only returns intentional protocol references.

## Validation Checklist
1. Build:
   - App target
   - Notification extension target
2. Runtime smoke:
   - Fresh install onboarding
   - Create/import wallet
   - Send/receive contextual message
   - Push registration/unregistration
   - Push notification decrypt in extension
   - Relaunch and wallet switch
3. Data checks:
   - Confirm no old migration keys are written on first launch.
   - Confirm keychain contains only current-format entries.
4. Regression checks:
   - Settings persistence
   - Contacts persistence
   - Read/unread synchronization behavior

## Risk Notes
1. This intentionally drops upgrade compatibility for old local data.
2. Existing users with legacy persisted data may lose automatic carry-forward behavior.
3. Rollout should match relaunch strategy (new app identity / clean-state expectation).

## Suggested Commit Sequence
1. `cleanup: remove one-time migration runners and flags`
2. `cleanup: remove legacy keychain and userdefaults fallbacks`
3. `cleanup: deterministic-only routing and node format simplification`
4. `cleanup: remove dead keys/constants and update docs`

