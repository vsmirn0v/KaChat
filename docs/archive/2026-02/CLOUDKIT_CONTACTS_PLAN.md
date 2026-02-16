> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

# CloudKit Contacts Plan

## Recommendation
Use a **separate Core Data + CloudKit store for contacts** (not the message store). This reduces risk and isolates sync concerns.

## Rationale
- Contacts are low‑churn and small; keeping them separate avoids impacting the message store.
- CloudKit Core Data doesn’t support unique constraints; a dedicated store lets us design around that cleanly.
- Easier to migrate and roll back without touching message history.

## High‑level Design
- New `ContactsStore` with its own **NSPersistentCloudKitContainer** and store file (e.g., `Contacts.sqlite`).
- Sync enabled when iCloud messages setting is enabled (or add a dedicated toggle later if needed).
- Existing UserDefaults contacts remain a **migration source and fallback**.

## Data Model
Create `ContactsStore.xcdatamodeld` with entity `CDContact`:
- `address` (String, required)
- `alias` (String, default "")
- `addedAt` (Date, default now)
- `lastMessageAt` (Date?, optional)
- `isAutoAdded` (Bool, default false)
- `notificationsMuted` (Bool, default false)
- `realtimeUpdatesDisabled` (Bool, default false)
- `updatedAt` (Date, default now)
- `isDeleted` (Bool, default false) – tombstone

**CloudKit rule**: all attributes optional or with defaults.

## Merge Policy / Conflict Resolution
- Use `updatedAt` as the conflict winner (last‑write‑wins).
- For KNS auto‑updates: only overwrite when alias is empty/auto or ends with `.kas`.

## Migration Plan
1) On first run, read UserDefaults contacts and insert into ContactsStore.
2) Set `contacts_migrated_to_coredata` flag.
3) After migration, ContactsManager reads from ContactsStore.
4) If CloudKit unavailable, keep local persistent store active.

## Deletions
- Soft delete by setting `isDeleted = true`.
- Keep tombstones for 30 days, then purge.

## Integration Updates
- ContactsManager becomes a wrapper over ContactsStore queries.
- Push registration & UTXO subscriptions listen to ContactsStore changes (debounced).
- Existing UI reads from ContactsManager (no UI changes required).

## Testing Checklist
- Create/edit/delete contact on device A → verify sync to device B.
- Alias update on device B → verify conflict resolution.
- KNS update only affects `.kas` aliases.
- Migration from UserDefaults works once and is idempotent.

## Tradeoffs
- Pros: isolated sync, safer failure modes, clean migration.
- Cons: extra store, additional background activity.
