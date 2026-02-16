# DPI Confidence Fallback Strategy (Epoch-Based)

Date: 2026-02-13

## Problem

False DPI positives happen when HTTP/2 requests fail because of temporary connectivity issues, app lifecycle interruptions, or stalled sync paths. Existing logic can switch to HTTP/1.1 too aggressively.

## Strategy

Per network epoch, track confidence that DPI is **not** present.

1. On epoch change, reset confidence to low (max suspicion baseline).
2. Increase no-DPI confidence when HTTP/2-path requests succeed.
3. Increase confidence more when successful response payload is at least 2 KB.
4. Increase confidence when a full sync completes successfully on HTTP/2 path.
5. Fallback decision:
- Low confidence: keep current behavior and allow HTTP/1.1 on first DPI-like failure.
- High confidence: treat first failure as likely network/transient issue.
- In high confidence mode, switch to HTTP/1.1 only after multiple HTTP/2 failures within a short window and only if system reports online.

## Current Tunables

- `largeResponseThresholdBytes = 2048`
- `confidenceGainHTTP2Success = 15`
- `confidenceGainLargeResponseBonus = 25`
- `confidenceGainSyncSuccess = 20`
- `highNoDpiConfidenceThreshold = 70`
- `confidentModeFailureWindow = 25s`
- `confidentModeFailuresBeforeHTTP1 = 2`

## Decision Notes

In high-confidence mode, decision path still uses HTTP/1.1 root probe as an extra gate before switching protocol for the epoch.

## Code Touchpoints

- `KaChat/Services/KaChatAPIClient.swift`
- `KaChat/Services/ChatService.swift`

