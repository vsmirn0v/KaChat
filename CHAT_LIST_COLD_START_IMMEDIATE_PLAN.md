# Chat List Cold Start: Immediate Population Plan

## Problem

On cold app start, the chat list is initially empty and appears only after ~5-10 seconds.
Users perceive this as lag, even though data exists locally.

## Goal

Show conversations immediately from local persisted data, then refresh in background from CloudKit/indexer/RPC without blocking first paint.

## Root Cause Summary

1. Early local hydration is timing-sensitive:
   - `ChatService` attempts local load in init.
   - Wallet-specific store switch in `WalletManager` may complete after that attempt.
2. `startPolling()` performs multi-phase startup work (handshake/subscription/CloudKit/indexer), and local visibility can effectively wait behind these phases.
3. UI currently treats `conversations.isEmpty` as "No Conversations Yet" immediately, which shows a misleading empty state during startup hydration.
4. Local load path currently fetches/decrypts all messages; this is correct but can be heavy on large histories.

## Plan

### Phase 1: Deterministic Immediate Local Hydration (Low Risk, High Impact)

1. Trigger local hydration right after wallet store switch:
   - After `MessageStore.setCurrentWallet(...)` finishes in wallet load flow, call:
     - `ChatService.shared.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)`
2. In `ChatService.startPolling()`, run local hydration as startup Phase 0 before network phases.
3. Ensure this hydration is non-blocking for the rest of sync (background sync still proceeds).

Expected result: chat list appears from local data almost immediately on cold start.

### Phase 2: Startup UI State (Prevent False Empty State)

1. Add a startup hydration flag in `ChatService` (e.g., `isInitialChatHydrating`).
2. In `ChatListView`, while hydrating and conversations are still empty:
   - show loading/skeleton state (or "Loading chats..."),
   - do not show "No Conversations Yet" yet.
3. After hydration completes:
   - if still empty, show actual empty state.

Expected result: no misleading empty-state flash during startup.

### Phase 3: Fast Conversation Shells (Optional Performance Optimization)

If Phase 1+2 are still not fast enough on large datasets:

1. Add lightweight store query for chat-list metadata only:
   - contact address,
   - unread count,
   - last message timestamp,
   - last message preview (if safely available).
2. Build `Conversation` shells for list display without loading full message arrays.
3. Lazy-load per-conversation message windows when chat opens / background refinement runs.

Expected result: constant-time first paint behavior for very large local histories.

## Instrumentation and Acceptance Criteria

### Metrics to Log

1. `t_app_active` (or first app frame)
2. `t_wallet_store_ready`
3. `t_first_local_chat_list_non_empty`
4. `t_initial_sync_complete`

### Targets

1. First non-empty chat list:
   - <= 500ms typical dataset
   - <= 1.5s p95
2. No transient empty-state flash when local conversations exist.

## Rollout Strategy

1. Implement Phase 1 + 2 first.
2. Validate on:
   - local-only history,
   - CloudKit-enabled history,
   - large message dataset,
   - app relaunch after terminate.
3. Add Phase 3 only if metrics still miss targets.
