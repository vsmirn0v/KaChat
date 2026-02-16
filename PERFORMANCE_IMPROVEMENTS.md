# Performance Improvements (KaChat/)

This file captures the current performance findings and the first implementation pass so context is not lost during compaction.

## Prioritized Hotspots

1. `ChatService` conversation updates do full `dedupe+sort` on every update.
   - File: `KaChat/Services/ChatService.swift`
   - Hot path: `updateConversation(...)` currently normalizes messages even when only unread count or one field changes.
   - Impact: O(n log n) per update and extra `@Published` churn.

2. `MessageBubbleView` reparses media JSON/base64/image data during render.
   - File: `KaChat/Views/Chat/MessageBubbleView.swift`
   - Hot path: `mediaFile`, `mediaImage`, `fileData` are recomputed inside `body`.
   - Impact: expensive decode work during scrolling and redraws.

3. `ChatListView` recomputes filtering/sorting/search on each render.
   - File: `KaChat/Views/Chat/ChatListView.swift`
   - Hot path: computed `filteredConversations` includes filtering, sorting, and message-content search.
   - Impact: repeated list-wide work, especially while typing.

## Additional Opportunities (implemented in this pass)

- [x] Cache/centralize formatter and detector instances in more views/services.
- [x] Reduce `AppSettings.load()` calls in hot paths by passing in-memory settings.
- [x] Avoid O(conversations * contacts) scans in contact sync paths.
- [x] Reduce full snapshot rebuild frequency in `ChatDetailView`.

## Implemented In This Pass

- [x] Top 1: remove always-on message normalization in `ChatService.updateConversation`.
- [x] Top 2: add media parse/decode caches in `MessageBubbleView`.
- [x] Top 3: memoize/debounce chat list filtering in `ChatListView`.
- [x] CloudKit/Catalyst stabilization: stop `remote-change` forced import waits in `ChatService`; process local remote-store changes directly.
- [x] CloudKit request throttling: enforce minimum import-request interval in `MessageStore.fetchCloudKitChanges` (8s on Catalyst, 2s elsewhere).
- [x] App-active Catalyst import timeout tuning: use 12s timeout in `KaChatApp` for `fetchCloudKitChanges(reason: "app-active")`.
- [x] Remote-push reliability gate: debounce app-active/subscription-restart catch-up syncs to 10 minutes when APNs delivery is healthy; auto-fallback + re-register after 3 consecutive txId misses.
