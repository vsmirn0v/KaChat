# Chat History V2 Plan (iOS 17)

## Goal
Deliver chat history scrolling that feels like one continuous timeline:
- No visible jump when loading older pages.
- No user position loss during background pagination.
- No jitter from pending/sent status transitions.
- Reliable behavior on iOS 17 (without iOS 18-only APIs).

## Current Failure Points
Observed in current implementation:
- Unstable row identity in chat list:
  - `ForEach(..., id: \.element.txId)` in `KaChat/Views/Chat/ChatDetailView.swift:258`.
  - `txId` changes on pending -> sent updates in `KaChat/Services/ChatService.swift:4924`.
- Repeated programmatic scroll corrections:
  - Initial retries at multiple delays in `KaChat/Views/Chat/ChatDetailView.swift:668` and `KaChat/Views/Chat/ChatDetailView.swift:682`.
  - Duplicate viewport preserve calls in `KaChat/Views/Chat/ChatDetailView.swift:730`.
- Window-shift behavior while scrolled up:
  - `displayedMessages` is suffix-based (`KaChat/Views/Chat/ChatDetailView.swift:178`).
  - New arrivals can move the window and displace user viewport.
- Fragile top pagination trigger:
  - Custom KVO observer hunts for a scroll view in hierarchy (`KaChat/Views/Chat/ChatDetailView.swift:2184`).
  - Threshold-based trigger and frequent offset reactions increase chance of re-entrant pagination.
- Offset-based persistence paging:
  - Uses `fetchOffset` in `KaChat/Services/MessageStore.swift:512`.
  - Offset is sensitive to concurrent inserts and live updates.

## Design Decisions (V2)
- UI identity is `ChatMessage.id` (stable UUID), not `txId`.
- `txId` remains network/business identity only.
- No multi-retry `scrollTo` loops after initial placement.
- Preserve viewport with one anchor correction per prepend event.
- Move paging from offset model to cursor/keyset model.
- Keep warm backlog (background prefetch) before user hits top edge.

## External Reference Patterns
Patterns we mirror from proven implementations:
- Telegram transactional list updates with stationary anchor:
  - `stationaryItemRange` use in `external/Telegram-iOS/submodules/TelegramUI/Sources/PreparedChatHistoryViewTransition.swift:108`.
  - Applied in transactions in `external/Telegram-iOS/submodules/TelegramUI/Sources/ChatHistoryListNode.swift:4191`.
  - Anchor fixing in `external/Telegram-iOS/submodules/Display/Source/ListViewIntermediateState.swift:412`.
- Telegram background preloading window:
  - `preloadPages` and invisible inset in `external/Telegram-iOS/submodules/Display/Source/ListView.swift:224`.
- Apple list guidance:
  - Stable identifiers, diff-driven updates, and prefetch lead time.

## Phased Implementation Plan

## Phase 0: Instrumentation and Safety Switches
Purpose: measure before/after and reduce blind regressions.
- Add scroll diagnostics:
  - Anchor ID before/after prepend.
  - Anchor Y delta after pagination merge.
  - Programmatic scroll count per minute.
  - Pagination request overlap count.
- Add feature flags:
  - `chat_history_v2_identity`.
  - `chat_history_v2_anchor_preserve`.
  - `chat_history_v2_cursor_paging`.
- Add test fixture with long conversation:
  - 5k+ mixed messages, variable bubble heights, pending transitions.

## Phase 1: Immediate Jitter Killers (Low Risk, High Impact)
Purpose: remove known jump sources without large architecture changes.
- Stable row identity:
  - Change chat list `ForEach` to key by `message.id` in `KaChat/Views/Chat/ChatDetailView.swift`.
  - Track viewport/top-visible anchors by UUID instead of txId where possible.
- Remove repeated forced scrolling:
  - Replace initial retry fanout with one guarded initial positioning pass.
  - Remove duplicate delayed preserve calls in `preserveViewport`.
- Prevent scroll tug-of-war:
  - Do not auto-scroll while user drag/deceleration is active (except explicit jump-to-bottom action).
- Deterministic ordering:
  - Enforce stable sort tie-breakers in both `ChatDetailView` snapshot and `ChatService` dedupe paths.
  - Suggested order: `blockTime`, `timestamp`, `id`.
- Window stability while user is scrolled up:
  - If not bottom-pinned, increase `loadedMessageCount` when new tail messages arrive so the visible range does not shift.

Exit criteria:
- Pending -> sent transition never causes remove+insert visual jump.
- No visible "snap back" during initial load and top-page prepend.

## Phase 2: Paging Model Upgrade (Core Stability)
Purpose: remove offset fragility under live updates.
- Replace offset paging with cursor/keyset paging in `MessageStore`:
  - Query by "older than oldest loaded message" boundary.
  - Cursor fields: `(blockTime, timestamp, txId/id)` tie-break combination.
- Update `ChatService.loadOlderMessagesPageAsync` contract:
  - Input: oldest loaded cursor.
  - Output: older slice + new oldest cursor + hasMore.
- Coalesce in-flight requests:
  - Single older-page task per conversation.
  - Drop/merge duplicate top-trigger calls while one request is active.
- Prefetch window:
  - Keep 2-3 pages hidden backlog when user approaches top.
  - Trigger proactively, not only at hard top threshold.

Exit criteria:
- Continuous upward scroll across many pages without losing visual position.
- No duplicate/no-op page fetch bursts.

## Phase 3: List Engine Hardening Path
Purpose: decide long-term platform for maximum smoothness on iOS 17.
- Evaluate two paths:
  - Keep SwiftUI `ScrollView` with V2 anchor protocol.
  - Migrate chat timeline surface to `UICollectionView` + diffable + batch updates (+ optional ChatLayout).
- Decision gate:
  - If Phase 1+2 still shows measurable jitter/frame drops on long histories, move to UIKit timeline surface.

Exit criteria:
- 60fps-like perceived smoothness on target devices under long-history stress.

## Verification Plan
- Manual scenarios:
  - Open chat at bottom, receive live messages while reading old history.
  - Scroll to top continuously and trigger multiple older page loads.
  - Send messages with pending -> sent promotion repeatedly.
  - Mix text/audio/payment rows with diverse heights.
- Automated checks:
  - Unit tests for cursor paging boundaries.
  - Deterministic ordering tests for equal timestamps.
  - UI tests validating anchor delta within threshold after prepend.

Acceptance thresholds:
- Anchor delta after prepend: <= 2 pt median, <= 6 pt p99.
- Unexpected programmatic scroll events: 0 during passive read.
- Duplicate top-page request overlap: 0.
- No hard viewport reset in any scenario above.

## Risks and Mitigations
- Risk: changing identity can expose hidden dedupe inconsistencies.
  - Mitigation: deterministic order + dedupe tests before enabling flag globally.
- Risk: cursor migration bugs in historical fetch.
  - Mitigation: temporary dual-run checks (offset and cursor in debug builds) and compare page contents.
- Risk: SwiftUI limitations remain for extreme history.
  - Mitigation: keep UIKit migration path ready behind feature gate.

## Rollout
- Stage 1: ship Phase 1 under flag for internal builds.
- Stage 2: enable Phase 2 for a subset of users/builds; monitor metrics.
- Stage 3: decide on Phase 3 based on measured jitter and frame pacing.

## Out of Scope for V2
- iOS 18-only scroll APIs (`ScrollPosition`, etc.) as primary mechanism.
- Reworking chat protocol/domain payload model.

