> Archived document (2026-02-11): historical context only. Current references are listed in `docs/README.md`.

Overall: **yes, this updated variant is a good direction** for your scale and constraints. Switching to **Option B (per-device markers)** + “stable-point” writes is exactly how you keep CloudKit traffic smooth and avoid the **conflict → retry → burst** pattern that leads to throttling. ([Apple Developer][1])

That said, there are a few **important correctness fixes** in the Core Data bits, and a couple of tweaks that will further reduce throttling risk—especially since you’re already syncing message history via `NSPersistentCloudKitContainer` (which can itself be throttled). ([Apple Developer][2])

---

## What’s good

### ✅ Option B is a better throttling profile than Option A

* No `serverRecordChanged` loops because each device writes its own marker.
* Fewer “read-modify-write” operations.
* With ~10 active conv/day and 3 devices, you’re looking at ~30 marker updates/day/account — trivial.

### ✅ “Stable-point debounce” is the right write trigger

For read markers, “eventual is fine”, so flushing on:

* conversation exit
* app background
* 15–30s idle
  …reduces burstiness way more than a 2s debounce.

### ✅ Notification handling: “hint, not truth”

You explicitly state the right mental model: CloudKit notifications can be coalesced/dropped, so treat them as “wake up and process deltas”. ([Apple Developer][3])

---

## Must-fix issues in the implementation

### 1) **Your “unique constraint” is not a unique constraint**

You used `NSFetchIndexDescription` named `uniqueMarker`. That creates an **index**, not a **uniqueness constraint**.

To enforce uniqueness, you must set:

```swift
readMarkerEntity.uniquenessConstraints = [["conversationId", "deviceId"]]
```

If you keep multiple accounts in one store, make it:

```swift
readMarkerEntity.uniquenessConstraints = [["accountId", "conversationId", "deviceId"]]
```

(Indexes are still useful for speed, but they do *not* prevent duplicates.)

---

### 2) Multi-account handling: don’t rely on `walletAddress` predicates

In your text you recommend **one persistent store per app-account** (good). If you actually do that, then:

* you don’t need `walletAddress` on `CDReadMarker`
* you don’t need predicates like `(walletAddress == %@ OR walletAddress == nil)`

If you instead keep **one store for all accounts**, then add `accountId` as a first-class field everywhere, and make it part of uniqueness constraints and fetch predicates.

Pick one approach and keep it consistent—right now your code mixes both models.

---

### 3) Derived fields “local-only” isn’t automatic with `NSPersistentCloudKitContainer`

If `CDConversation.effectiveLastReadBlockTime` is a normal stored attribute in the same mirrored store, it will sync (unless you isolate it).

If you truly want “local-only”, you have a few options:

* make it **transient** (not persisted at all), and compute/cache in memory
* store it in a **separate local-only store** (separate configuration) that is *not* mirrored
* keep it persisted but accept it syncing (which is usually fine because it’s tiny)

Given your scale, I’d actually **keep it persisted locally** and not worry too much—just be aware it’s not automatically excluded.

---

## Remote change processing: tighten it up

You’re referencing the right Apple pattern: enable remote change notifications and consume relevant store changes. ([Apple Developer][3])
But your current `processRemoteChanges()` has a couple problems:

### 1) You never actually recompute

You collect `conversationsNeedingRecompute` and only log them. You need to call `recomputeEffectiveReadStatus()` for each.

### 2) Don’t assume you can load the changed object

`existingObject(with:)` can fail if it was deleted or not materialized yet. Safer pattern:

* from the history change, record the changed object ID
* try to fetch marker by that ID (if exists)
* if not, fall back to “recompute the conversation IDs that are currently visible/recently active”

### 3) Token storage key should be per-store, not `currentWalletAddress ?? "default"`

For multi-account, store the token keyed by **accountId/store identifier**. Otherwise you’ll cross-contaminate tokens when switching accounts.

Also: make sure you’ve enabled **persistent history tracking** and remote change notifications in your store description; otherwise this won’t work reliably.

Apple’s “consuming relevant store changes” doc is the canonical reference for the remote-change + persistent-history approach. ([Apple Developer][3])

---

## Throttling impact with this updated design (realistic assessment)

With your numbers, the risk of throttling becomes mostly about **synchronization overlap**:

* Message history segments syncing (your biggest traffic source)
* Read markers syncing at the same time
* App foreground/background causing batches

Two things to keep in mind:

1. **CloudKit can throttle NSPersistentCloudKitContainer too**, not just your manual ops. ([Apple Developer][2])
2. When throttled, the right behavior is always: **honor retryAfterSeconds** and don’t keep triggering more writes. ([Apple Developer][4])

Your stable-point flush + conflict-free markers dramatically reduces the chance you’ll hit throttles due to read sync alone.

---

## Small improvements I would still make

### A) Use a better ordering key than `blockTime` if you can

`blockTime` is “time-ish”, but in a DAG it’s not a perfect monotonic ordering key for “read up to here”.
If you already have a chain cursor (e.g., acceptance score / monotonic ordering key), use that as your `lastReadOrderKey`. This will make unread count logic more correct long-term.

### B) Batch recomputes

When multiple markers change (e.g., device restore), don’t recompute unread counts per-conversation immediately. Collect affected conversation IDs and recompute:

* only for conversations visible in chat list, or
* in a throttled background queue

### C) Don’t worry about record size here

Your read marker records are tiny and safely under CKRecord’s 1 MB non-asset cap. ([Apple Developer][5])

---

## Verdict

✅ **Conceptually good and scalable** for your scale and iOS/macOS-only constraint.
⚠️ Fix the Core Data uniqueness constraint and the “multi-account model inconsistency” (walletAddress vs per-store).
⚠️ Tighten remote-change processing so it actually recomputes and stores tokens per account/store.
✅ With those fixes, throttling risk from read sync should be **low**, and any throttling you do see will mostly be from your history sync bursts—handled by respecting retry-after and avoiding write storms. ([Apple Developer][1])

If you tell me whether you truly use “one store per account” today (sounds like you want that), I can rewrite the schema/code snippets accordingly (remove walletAddress, add account-scoped token keys, correct uniqueness constraints, and show a clean remote-change handler that only recomputes impacted conversations).

[1]: https://developer.apple.com/documentation/technotes/tn3162-understanding-cloudkit-throttles?utm_source=chatgpt.com "TN3162: Understanding CloudKit throttles"
[2]: https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer?utm_source=chatgpt.com "TN3163: Understanding the synchronization of ..."
[3]: https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes?utm_source=chatgpt.com "Consuming relevant store changes"
[4]: https://developer.apple.com/documentation/cloudkit/ckerrorretryafterkey?utm_source=chatgpt.com "CKErrorRetryAfterKey | Apple Developer Documentation"
[5]: https://developer.apple.com/documentation/cloudkit/ckrecord?utm_source=chatgpt.com "CKRecord | Apple Developer Documentation"
