# Performance Improvement Plan

## Scope
Project: `KaChat.xcodeproj`  
Targets: `Kasia`, `KaChatNotificationService`  
Focus areas: build performance, startup/runtime overhead from project structure and dependency graph.

## Current State Summary
- Build config baseline is mostly good:
  - Parallel target builds enabled.
  - Debug uses `-Onone` and `ONLY_ACTIVE_ARCH=YES`.
  - Release uses whole-module optimization.
- Main cost drivers:
  - Large compile graph (especially generated gRPC/protobuf files in app target).
  - Very large Swift source files causing broad incremental rebuild invalidation.
  - Heavy SwiftPM dependency tree through grpc stack.
- Potential config gap:
  - Ensure `ENABLE_DEBUG_DYLIB=NO` for shipping/archive builds.

## Goals
1. Reduce local incremental Debug build times.
2. Reduce clean CI build times.
3. Reduce app startup and binary/load overhead where safe.
4. Keep behavior and release risk low via phased rollout.

## Baseline Metrics (capture before changes)
Record these before each phase:
- Clean Debug build time (`xcodebuild ... -configuration Debug`).
- Incremental Debug build time after touching a frequently edited file.
- Clean Release build time.
- App cold launch time (device/simulator, same scenario).
- App size (`Kasia.app` + embedded frameworks for Release build).

## Phase 1: Fast Wins (Low Risk)
1. Debug resources
- Set `BUILD_ACTIVE_RESOURCES_ONLY=YES` for Debug.
- Expected impact: faster Debug builds when asset/resource set is large.

2. CI-specific build flags
- In CI builds only:
  - Set `COMPILER_INDEX_STORE_ENABLE=NO`.
  - Use explicit dependency resolution step, then build with automatic package resolution disabled.
- Expected impact: faster CI compilation, more deterministic build behavior.

3. Release/archive debug dylib hardening
- Explicitly set `ENABLE_DEBUG_DYLIB=NO` for Release/Archive path.
- Validate archive output to confirm no debug dylib artifacts.
- Expected impact: cleaner shipping artifact; avoids accidental runtime overhead.

## Phase 2: Medium Impact Refactors
1. Isolate generated API code
- Move `KaChat/Generated/*.swift` into a dedicated local Swift package/module.
- Keep app target depending on that module instead of compiling generated files directly.
- Expected impact: improved incremental builds and clearer dependency boundaries.

2. Split very large Swift files
Prioritize files with highest churn and size:
- `KaChat/Services/ChatService.swift`
- `KaChat/Services/MessageStore.swift`
- `KaChat/Views/Chat/ChatDetailView.swift`
- `KaChat/Views/Settings/SettingsView.swift`

Refactor approach:
- Extract feature-focused extensions and helper types.
- Separate protocol/implementation boundaries to localize recompilation.
- Avoid behavior changes in first split pass.

Expected impact:
- Smaller invalidation scope on edits.
- Better maintainability and lower merge conflict rate.

## Phase 3: Strategic Dependency Optimization
1. Narrow grpc-swift products
- Replace umbrella `GRPC` product with minimum required products (if supported by current code usage).
- Measure compile time and binary size delta.

2. Platform matrix review (Catalyst)
- If Mac Catalyst is not shipped, disable Catalyst support for app/extension targets.
- Expected impact: reduced build matrix complexity and less platform-specific overhead.

## Validation Checklist Per Phase
- Build succeeds for Debug and Release.
- Smoke test passes for messaging, node connectivity, push handling, wallet actions.
- No regressions in extension behavior (`KaChatNotificationService`).
- Metrics captured and compared to baseline.

## Rollout Order
1. Phase 1 (all items).
2. Re-measure and decide whether Phase 2 is still required for target build-time reduction.
3. Implement Phase 2 incrementally (one area at a time, re-measure after each).
4. Execute Phase 3 only with measurable benefit and clear ownership.

## Ownership Suggestions
- Build/config updates: project maintainer.
- Large-file modularization: feature owners (Chat, Storage, Settings).
- Dependency narrowing/Catalyst decision: architecture owner + release owner.

## Exit Criteria
- 20-30% faster incremental Debug builds on common edit paths, or documented reasons if not achievable.
- Measurable CI build reduction.
- No startup regression.
- No user-visible regressions in smoke test matrix.
