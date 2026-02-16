currently fetch of new messages always happens after utxo subscription and effectively each time app goes to foreground.
  this is ok if remote push notifications are disabled, but too resource heavy for backend if we already have reliable way
  to deliver messages to user. let's optimize that, suggested algo: keep track if last received message got also push
  notification from server. when remote push enabled and status of registration is successful, if last message received
  via utxo notification channel longer than 1 minutes ago did not receive corresponding push notification, we consider
  push channel unreliable. if last message received longer than 1 minute ago also received remote push notification, we
  consider remote push channel reliable. if remote push channel is reliable, defer periodic fetch syncs and debounce them
  for some significant time interval - please suggest one. if unreliable, then check if 3 consecutive received messages
  longer than 1 minute ago did not have corresponding remote push notification and if true, consider push channel
  unreliable, re-register via push service,  and start fetching as per current design on each utxo subscription and the
  moment we discovered push channel as unreliable. then monitor if at least 1 new message have corresponding push
  notification, then mark push channel as reliable again immediately and defer fetch syncs to decided previously time.
  think hard if this algo can be improved/streamlined and prepare implementation plan


• I’ll map the current message sync flow first so the plan is concrete against your codebase, focusing on where UTXO
  subscription triggers fetches and where push registration/delivery status is tracked. Then I’ll propose a streamlined
  reliability state machine with integration points.

• Ran pwd && ls -la
  └ /Users/vsmirnov/docs/github/kasia-ios2-glm
    total 512
    … +27 lines
    drwxr-xr-x   4 vsmirnov  staff    128 Feb 12 21:51 web_site
    -rw-r--r--@  1 vsmirnov  staff  15187 Feb  2 00:16 x

• Explored
  └ Search utxo|UTXO|push|notification|fetch|sync|foreground|didBecomeActive|applicationDidBecomeActive|
sceneDidBecomeActive|
           registerForRemoteNotifications|APNS|remote in .

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• I found the repo structure, and the first broad search was too noisy due to external dependencies. I’m narrowing to
  KaChat/ now to isolate the exact sync trigger, push registration state, and UTXO callback paths we need for your
  algorithm.

• Explored
  └ Search Subscription restarted|utxo|UtxoSubscription|fetchNewMessages|fetch sync|foreground|didBecomeActive|
           sceneDidBecomeActive|PushNotificationManager|remote push|push registration|registerForRemoteNotifications|
           didReceiveRemoteNotification|apns|device token|notification in KaChat
    List KaChat
    Search ChatService|Push|Notification|Utxo|App|KaChatApp|MessageStore|Subscription|Sync|Foreground|Scene|AppDelegate

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• I located the key files: ChatService, PushNotificationManager, and KaChatApp. Next I’m reading the exact methods that
  trigger fetch on subscription restart/foreground so I can anchor a concrete, low-risk implementation plan.

• Explored
  └ Read ChatService.swift

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• I now have the UTXO side. I’m inspecting PushNotificationManager and app lifecycle hooks to see what push-delivery
  signals already exist and where we can attach reliability scoring with minimal churn.

• Explored
  └ Read PushNotificationManager.swift, KaChatApp.swift
    Search recentlyHandledPushes|handleRemoteNotification|txId|pending messages|processPendingMessages|sender|payment|
message
           in PushNotificationManager.swift
    Read PushNotificationManager.swift, ChatService.swift
    Search notificationMode|remotePush|push in ChatService.swift
    Read ChatService.swift

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• I found the key mechanism: on resume, setupUtxoSubscription() treats it as a restart and immediately calls
  fetchNewMessages(), which explains the backend load spike on every foreground in remote-push mode. I’m now checking the
  fetchMessageByTxId / fetchPaymentByTxId paths to ensure the fallback behavior in your proposal can stay precise and
  cheap.

• Explored
  └ Read ChatService.swift
    Search fetchNewMessages\(|await fetchNewMessages\(|ChatService\.shared\.fetchNewMessages\( in ChatService.swift
    Read ChatService.swift
    Search rpcSubscriptionsRestored|rpcReconnected|Notification.Name\( in KaChat
    Search rpcSubscriptionsRestored|rpcReconnected|post\(name: \.rpc|post\(\.rpc in Services
    Read SharedDataManager.swift
    Search class SharedDataManager|getStoredMessages|getPendingMessages|addPendingMessage|syncContactsForExtension|txId|
sender
           in KaChat
    Read NotificationService.swift

─ Worked for 1m 06s ───────────────────────────────────────────────────────────────────────────────────────────────────────

• I found an extra optimization opportunity: you currently do two full fetches on foreground in remote-push mode (one in
  scenePhase .active, then another after UTXO resubscribe restart). I’m checking the subscription manager restart semantics
  next so the plan can safely eliminate redundant fetches without losing data.

• Explored
  └ Read UtxoSubscriptionManager.swift, NodePoolService.swift
    Search func subscribeUtxosChanged|unsubscribeUtxosChanged|resubscribe in NodePoolService.swift
    Read NodePoolService.swift
    Search func subscribe\(|resyncUtxoState|state == \.subscribed|unsubscribe\( in UtxoSubscriptionManager.swift
    Read UtxoSubscriptionManager.swift
    Search lastSuccessfulSyncDate|endSyncBlockTime\(|syncSucceeded|lastPollTime in ChatService.swift
    Read ChatService.swift, Models.swift
    Search backgroundFetchEnabled|pushNotificationsEnabled|notificationsEnabled in Models.swift
    Read Models.swift

─ Worked for 2m 00s ───────────────────────────────────────────────────────────────────────────────────────────────────────

• Current behavior is doing redundant sync work in remote-push mode:

  1. KaChat/App/KaChatApp.swift:86 always runs fetchNewMessages() on .active.
  2. KaChat/Services/ChatService.swift:864 runs another fetchNewMessages() after UTXO resubscribe restart.
  3. In remote-push mode that happens on most foregrounds (KaChat/App/KaChatApp.swift:112, KaChat/Services/
     ChatService.swift:938).

  Suggested debounce interval for reliable push: 10 minutes.

  Improved/streamlined algorithm

  1. Use a small state machine instead of separate ad-hoc checks:

  - disabled (push mode off or not registered/authorized)
  - unknown (not enough evidence yet)
  - reliable
  - unreliable

  2. Track tx-level evidence with a 60s grace:

  - On incoming UTXO message candidate (only messages expected to generate push), create observation txId -> utxoSeenAt.
  - If matching push is seen within 60s (or was seen shortly before), mark hit.
  - If no push after 60s, mark miss.

  3. Transition rules:

  - unknown -> reliable on first hit.
  - reliable -> unreliable after 3 consecutive misses.
  - unreliable -> reliable immediately on first hit (your recovery condition).
  - Only count messages where push is actually expected (incoming, contact notification mode not off, push registered).

  4. Fetch policy:

  - If state is reliable, suppress immediate catch-up fetches and run at most once per 10 min.
  - If state is unreliable or disabled, keep current behavior (fetch on app active/resubscribe) and do immediate fetch when
    unreliability is detected.
  - Force push re-registration when entering unreliable (with cooldown, e.g. 10 min).

  Implementation plan

  1. Add reliability tracker in ChatService:

  - New state + counters + maps (recentPushTx, pendingUtxoObservations, consecutiveMisses, lastForcedReregisterAt).
  - Persist minimal state in UserDefaults so app restarts don’t reset learning.

  2. Add push evidence hooks in PushNotificationManager:

  - In handleRemoteNotification(...) record push receipt early by txId.
  - In processPendingMessages() also record receipts for extension-stored/pending tx IDs.

  3. Add UTXO evidence hooks in ChatService:

  - In processParsedUtxoChangeNotification(...) record incoming tx observations when sender/contact is known and push is
    expected.
  - Evaluate observations at +60s; classify hit/miss.

  4. Gate heavy sync triggers:

  - Replace unconditional app-active fetch in KaChatApp with ChatService.maybeRunCatchUpSync(trigger: .appActive).
  - In setupUtxoSubscription() run restart catch-up only when policy says needed (unreliable/disabled/stale >10m), not on
    every foreground resume.

  5. Re-registration path:

  - Add PushNotificationManager.forceReregisterIfNeeded(reason:).
  - Call on transition to unreliable (cooldown protected).

  6. Safety/verification:

  - Add verbose logs for state transitions and skip reasons.
  - Validate scenarios: push healthy, push missing 3 times, recovery on first hit, contact notifications off, outgoing tx
    ignored.

  If you want, I can implement this in code now in one pass (state machine + gating + reregister hook).


› yes go and update any md files on changes


• I’ll implement the reliability state machine and fetch gating now across ChatService, PushNotificationManager, and app
  lifecycle, then update the markdown docs to reflect the new behavior and tuning constants. I’m checking current working-
  tree state first before edits.

• Explored
  └ List ls -la
    Read ChatService.swift
    Search handleIncomingSpecialPayload\(|processIncomingContextualPayload|processIncomingHandshake|special payload in
           ChatService.swift
    Read ChatService.swift

─ Worked for 2m 36s ───────────────────────────────────────────────────────────────────────────────────────────────────────

• I confirmed the right touch points and I’m now editing ChatService to add a push reliability state machine plus a unified
  maybeRunCatchUpSync(...) gate, then wiring PushNotificationManager to feed tx-level push evidence into it. After code
  compiles, I’ll patch PUSH_NOTIFICATIONS.md and CLAUDE.md.

• Explored
  └ Search Subscription restarted|remote push|UTXO subscription|fetch on|foreground|push in CLAUDE.md
    Read CLAUDE.md, PUSH_NOTIFICATIONS.md, ChatService.swift

• Edited KaChat/Services/ChatService.swift (+40 -0)
     29
     30 +enum CatchUpSyncTrigger: String {
     31 +    case appActive = "app-active"
     32 +    case subscriptionRestart = "subscription-restart"
     33 +    case rpcSubscriptionsRestored = "rpc-subscriptions-restored"
     34 +    case pushMarkedUnreliable = "push-marked-unreliable"
     35 +}
     36 +
     37  @MainActor
        ⋮
    100
    101 +    private enum PushReliabilityState: String {
    102 +        case disabled
    103 +        case unknown
    104 +        case reliable
    105 +        case unreliable
    106 +    }
    107 +
    108 +    private struct PendingPushObservation {
    109 +        let txId: String
    110 +        let senderAddress: String
    111 +        let observedAt: Date
    112 +    }
    113 +
    114      /// Computed connection status based on node subscription state
        ⋮
    199      private let deterministicMigrationDoneKey = "kachat_deterministic_migration_done"
    200 +    private let pushReliabilityStateKey = "kachat_push_reliability_state"
    201 +    private let pushConsecutiveMissesKey = "kachat_push_consecutive_misses"
    202 +    private let pushLastCatchUpSyncAtKey = "kachat_push_last_catchup_sync_at"
    203 +    private let pushLastReregisterAtKey = "kachat_push_last_reregister_at"
    204      private let syncReorgBufferMs: UInt64 = 600_000
        ⋮
    255      private var needsResubscriptionAfterSync = false
    256 +    private var catchUpSyncInFlight = false
    257 +
    258 +    // Push-channel reliability tracking (UTXO txId -> matching APNs delivery).
    259 +    private var pushReliabilityState: PushReliabilityState = .disabled
    260 +    private var pushConsecutiveMisses = 0
    261 +    private var pendingPushObservations: [String: PendingPushObservation] = [:]
    262 +    private var pushObservationTasks: [String: Task<Void, Never>] = [:]
    263 +    private var pushSeenByTxId: [String: Date] = [:]
    264 +    private var lastCatchUpSyncAt: Date?
    265 +    private var lastPushReregisterAt: Date?
    266 +    private let pushObservationGraceInterval: TimeInterval = 60
    267 +    private let pushLeadMatchTolerance: TimeInterval = 30
    268 +    private let pushObservationRetention: TimeInterval = 600
    269 +    private let reliablePushCatchUpDebounce: TimeInterval = 600
    270 +    private let pushReregisterCooldown: TimeInterval = 600
    271
        ⋮
    340          loadDeclinedContacts()
    341 +        loadPushReliabilityState()
    342          observeContacts()

• Edited KaChat/Services/ChatService.swift (+1 -1)
    417              Task { @MainActor in
    418 -                await self?.fetchNewMessages()
    418 +                await self?.maybeRunCatchUpSync(trigger: .rpcSubscriptionsRestored)
    419              }

• Edited KaChat/Services/ChatService.swift (+1 -0)
    8251                  self?.saveMessages()
    8252 +                self?.refreshPushReliabilityPrerequisites()
    8253              }

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• I’ve started wiring the new flow in ChatService; next I’m adding the core APIs (recordRemotePushDelivery,
  maybeRunCatchUpSync) and state transitions before switching all call sites to use them.

• Edited KaChat/Services/ChatService.swift (+56 -0)
    731
    732 +    func recordRemotePushDelivery(txId: String, sender: String, messageType: String?) {
    733 +        let normalizedTxId = txId.trimmingCharacters(in: .whitespacesAndNewlines)
    734 +        guard !normalizedTxId.isEmpty else { return }
    735 +
    736 +        prunePushReliabilityCaches(now: Date())
    737 +        pushSeenByTxId[normalizedTxId] = Date()
    738 +
    739 +        guard let observation = pendingPushObservations.removeValue(forKey: normalizedTxId) else {
    740 +            return
    741 +        }
    742 +        if let task = pushObservationTasks.removeValue(forKey: normalizedTxId) {
    743 +            task.cancel()
    744 +        }
    745 +
    746 +        NSLog("[ChatService] Push/UTXO matched tx=%@ sender=%@ type=%@",
    747 +              String(normalizedTxId.prefix(12)),
    748 +              String(sender.suffix(10)),
    749 +              messageType ?? "unknown")
    750 +        applyPushObservationOutcome(
    751 +            txId: normalizedTxId,
    752 +            senderAddress: observation.senderAddress,
    753 +            didReceivePush: true
    754 +        )
    755 +    }
    756 +
    757 +    func maybeRunCatchUpSync(trigger: CatchUpSyncTrigger, force: Bool = false) async {
    758 +        refreshPushReliabilityPrerequisites()
    759 +
    760 +        let shouldDebounce = !force &&
    761 +            isPushChannelOperational() &&
    762 +            pushReliabilityState == .reliable
    763 +
    764 +        if shouldDebounce,
    765 +           let last = lastCatchUpSyncAt,
    766 +           Date().timeIntervalSince(last) < reliablePushCatchUpDebounce {
    767 +            NSLog("[ChatService] Skipping catch-up sync (%@) - push reliable and debounce active",
    768 +                  trigger.rawValue)
    769 +            return
    770 +        }
    771 +
    772 +        if catchUpSyncInFlight {
    773 +            NSLog("[ChatService] Skipping catch-up sync (%@) - catch-up already in flight",
    774 +                  trigger.rawValue)
    775 +            return
    776 +        }
    777 +
    778 +        catchUpSyncInFlight = true
    779 +        defer { catchUpSyncInFlight = false }
    780 +
    781 +        NSLog("[ChatService] Running catch-up sync (%@), pushState=%@ force=%@",
    782 +              trigger.rawValue, pushReliabilityState.rawValue, force ? "true" : "false")
    783 +        await fetchNewMessages()
    784 +        lastCatchUpSyncAt = Date()
    785 +        persistPushReliabilityState()
    786 +    }
    787 +
    788      /// Start message sync - uses RPC notifications when available, polling as fallback

• Edited KaChat/Services/ChatService.swift (+2 -2)
    961              if isRestart {
    962 -                NSLog("[ChatService] Subscription restarted - syncing to catch missed messages/payments")
    962 +                NSLog("[ChatService] Subscription restarted - evaluating catch-up sync policy")
    963                  Task {
    964 -                    await self.fetchNewMessages()
    964 +                    await self.maybeRunCatchUpSync(trigger: .subscriptionRestart)
    965                  }

• Edited KaChat/Services/ChatService.swift (+2 -0)
    2093
    2094 +                    trackIncomingUtxoForPushReliability(txId: txId, senderAddress: sender)
    2095                      await processPayments([payment], isOutgoing: false, myAddress: myAddress, deliveryStatus: .pe
          nding)
         ⋮
    2216                          }
    2217 +                        trackIncomingUtxoForPushReliability(txId: txId, senderAddress: utxoAddress)
    2218                          // Skip if we already have a resolve in flight for this txId

• Edited KaChat/Services/ChatService.swift (+1 -0)
    2510          )
    2511 +        trackIncomingUtxoForPushReliability(txId: txId, senderAddress: finalSender)
    2512          await processPayments([payment], isOutgoing: false, myAddress: myAddress, deliveryStatus: .sent)

• Edited KaChat/Services/ChatService.swift (+251 -0)
    8314
    8315 +    private func loadPushReliabilityState() {
    8316 +        if let raw = userDefaults.string(forKey: pushReliabilityStateKey),
    8317 +           let parsed = PushReliabilityState(rawValue: raw) {
    8318 +            pushReliabilityState = parsed
    8319 +        } else {
    8320 +            pushReliabilityState = .disabled
    8321 +        }
    8322 +        pushConsecutiveMisses = max(0, userDefaults.integer(forKey: pushConsecutiveMissesKey))
    8323 +
    8324 +        if let ts = userDefaults.object(forKey: pushLastCatchUpSyncAtKey) as? Double {
    8325 +            lastCatchUpSyncAt = Date(timeIntervalSince1970: ts)
    8326 +        } else {
    8327 +            lastCatchUpSyncAt = nil
    8328 +        }
    8329 +
    8330 +        if let ts = userDefaults.object(forKey: pushLastReregisterAtKey) as? Double {
    8331 +            lastPushReregisterAt = Date(timeIntervalSince1970: ts)
    8332 +        } else {
    8333 +            lastPushReregisterAt = nil
    8334 +        }
    8335 +
    8336 +        refreshPushReliabilityPrerequisites()
    8337 +    }
    8338 +
    8339 +    private func persistPushReliabilityState() {
    8340 +        userDefaults.set(pushReliabilityState.rawValue, forKey: pushReliabilityStateKey)
    8341 +        userDefaults.set(pushConsecutiveMisses, forKey: pushConsecutiveMissesKey)
    8342 +        if let lastCatchUpSyncAt {
    8343 +            userDefaults.set(lastCatchUpSyncAt.timeIntervalSince1970, forKey: pushLastCatchUpSyncAtKey)
    8344 +        } else {
    8345 +            userDefaults.removeObject(forKey: pushLastCatchUpSyncAtKey)
    8346 +        }
    8347 +        if let lastPushReregisterAt {
    8348 +            userDefaults.set(lastPushReregisterAt.timeIntervalSince1970, forKey: pushLastReregisterAtKey)
    8349 +        } else {
    8350 +            userDefaults.removeObject(forKey: pushLastReregisterAtKey)
    8351 +        }
    8352 +    }
    8353 +
    8354 +    private func isPushChannelOperational() -> Bool {
    8355 +        let settings = currentSettings
    8356 +        guard settings.notificationMode == .remotePush else { return false }
    8357 +
    8358 +        let pushManager = PushNotificationManager.shared
    8359 +        let status = pushManager.permissionStatus
    8360 +        guard status == .authorized || status == .provisional else { return false }
    8361 +        guard pushManager.isRegistered else { return false }
    8362 +
    8363 +        return true
    8364 +    }
    8365 +
    8366 +    private func refreshPushReliabilityPrerequisites() {
    8367 +        if !isPushChannelOperational() {
    8368 +            if pushReliabilityState != .disabled {
    8369 +                NSLog("[ChatService] Push reliability disabled (push mode not operational)")
    8370 +            }
    8371 +            pushReliabilityState = .disabled
    8372 +            pushConsecutiveMisses = 0
    8373 +            for task in pushObservationTasks.values {
    8374 +                task.cancel()
    8375 +            }
    8376 +            pushObservationTasks.removeAll()
    8377 +            pendingPushObservations.removeAll()
    8378 +            persistPushReliabilityState()
    8379 +            return
    8380 +        }
    8381 +
    8382 +        if pushReliabilityState == .disabled {
    8383 +            pushReliabilityState = .unknown
    8384 +            pushConsecutiveMisses = 0
    8385 +            NSLog("[ChatService] Push reliability moved to unknown (operational)")
    8386 +            persistPushReliabilityState()
    8387 +        }
    8388 +    }
    8389 +
    8390 +    private func prunePushReliabilityCaches(now: Date) {
    8391 +        let cutoff = now.addingTimeInterval(-pushObservationRetention)
    8392 +        pushSeenByTxId = pushSeenByTxId.filter { $0.value >= cutoff }
    8393 +
    8394 +        let staleObservations = pendingPushObservations.values
    8395 +            .filter { $0.observedAt < cutoff }
    8396 +            .map(\.txId)
    8397 +        for txId in staleObservations {
    8398 +            pendingPushObservations.removeValue(forKey: txId)
    8399 +            if let task = pushObservationTasks.removeValue(forKey: txId) {
    8400 +                task.cancel()
    8401 +            }
    8402 +        }
    8403 +    }
    8404 +
    8405 +    private func shouldTrackPushReliability(for senderAddress: String) -> Bool {
    8406 +        let normalized = senderAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    8407 +        guard !normalized.isEmpty else { return false }
    8408 +
    8409 +        let settings = currentSettings
    8410 +        guard settings.notificationMode == .remotePush else { return false }
    8411 +
    8412 +        let eligible = Set(pushEligibleConversationAddresses(settings: settings))
    8413 +        guard eligible.contains(normalized) else { return false }
    8414 +
    8415 +        let contact = contactsManager.getContact(byAddress: normalized)
    8416 +        return settings.shouldDeliverIncomingNotification(for: contact)
    8417 +    }
    8418 +
    8419 +    private func trackIncomingUtxoForPushReliability(txId: String, senderAddress: String) {
    8420 +        refreshPushReliabilityPrerequisites()
    8421 +        guard pushReliabilityState != .disabled else { return }
    8422 +        guard shouldTrackPushReliability(for: senderAddress) else { return }
    8423 +
    8424 +        let normalizedTxId = txId.trimmingCharacters(in: .whitespacesAndNewlines)
    8425 +        guard !normalizedTxId.isEmpty else { return }
    8426 +
    8427 +        let now = Date()
    8428 +        prunePushReliabilityCaches(now: now)
    8429 +
    8430 +        if let pushSeenAt = pushSeenByTxId[normalizedTxId],
    8431 +           pushSeenAt.timeIntervalSince(now) >= -pushLeadMatchTolerance {
    8432 +            applyPushObservationOutcome(
    8433 +                txId: normalizedTxId,
    8434 +                senderAddress: senderAddress,
    8435 +                didReceivePush: true
    8436 +            )
    8437 +            return
    8438 +        }
    8439 +
    8440 +        if pendingPushObservations[normalizedTxId] != nil {
    8441 +            return
    8442 +        }
    8443 +
    8444 +        pendingPushObservations[normalizedTxId] = PendingPushObservation(
    8445 +            txId: normalizedTxId,
    8446 +            senderAddress: senderAddress,
    8447 +            observedAt: now
    8448 +        )
    8449 +        schedulePushObservationEvaluation(for: normalizedTxId)
    8450 +    }
    8451 +
    8452 +    private func schedulePushObservationEvaluation(for txId: String) {
    8453 +        if let task = pushObservationTasks.removeValue(forKey: txId) {
    8454 +            task.cancel()
    8455 +        }
    8456 +        let delayNs = UInt64(pushObservationGraceInterval * 1_000_000_000)
    8457 +        pushObservationTasks[txId] = Task { [weak self] in
    8458 +            try? await Task.sleep(nanoseconds: delayNs)
    8459 +            await self?.evaluatePendingPushObservation(txId: txId)
    8460 +        }
    8461 +    }
    8462 +
    8463 +    private func evaluatePendingPushObservation(txId: String) {
    8464 +        refreshPushReliabilityPrerequisites()
    8465 +        guard pushReliabilityState != .disabled else { return }
    8466 +
    8467 +        guard let observation = pendingPushObservations.removeValue(forKey: txId) else {
    8468 +            pushObservationTasks.removeValue(forKey: txId)
    8469 +            return
    8470 +        }
    8471 +
    8472 +        if let task = pushObservationTasks.removeValue(forKey: txId) {
    8473 +            task.cancel()
    8474 +        }
    8475 +
    8476 +        guard shouldTrackPushReliability(for: observation.senderAddress) else {
    8477 +            return
    8478 +        }
    8479 +
    8480 +        let didReceivePush: Bool
    8481 +        if let pushSeenAt = pushSeenByTxId[txId] {
    8482 +            didReceivePush = pushSeenAt.timeIntervalSince(observation.observedAt) >= -pushLeadMatchTolerance
    8483 +        } else {
    8484 +            didReceivePush = false
    8485 +        }
    8486 +
    8487 +        applyPushObservationOutcome(
    8488 +            txId: txId,
    8489 +            senderAddress: observation.senderAddress,
    8490 +            didReceivePush: didReceivePush
    8491 +        )
    8492 +    }
    8493 +
    8494 +    private func applyPushObservationOutcome(
    8495 +        txId: String,
    8496 +        senderAddress: String,
    8497 +        didReceivePush: Bool
    8498 +    ) {
    8499 +        refreshPushReliabilityPrerequisites()
    8500 +        guard pushReliabilityState != .disabled else { return }
    8501 +
    8502 +        if didReceivePush {
    8503 +            pushConsecutiveMisses = 0
    8504 +            if pushReliabilityState != .reliable {
    8505 +                transitionPushReliabilityState(
    8506 +                    to: .reliable,
    8507 +                    reason: "push matched tx \(String(txId.prefix(12))) from \(String(senderAddress.suffix(10)))"
    8508 +                )
    8509 +            } else {
    8510 +                persistPushReliabilityState()
    8511 +            }
    8512 +            return
    8513 +        }
    8514 +
    8515 +        pushConsecutiveMisses += 1
    8516 +        NSLog("[ChatService] Push miss for tx=%@ sender=%@ misses=%d",
    8517 +              String(txId.prefix(12)),
    8518 +              String(senderAddress.suffix(10)),
    8519 +              pushConsecutiveMisses)
    8520 +        if pushConsecutiveMisses >= 3 {
    8521 +            transitionPushReliabilityState(
    8522 +                to: .unreliable,
    8523 +                reason: "3 consecutive push misses"
    8524 +            )
    8525 +        } else {
    8526 +            persistPushReliabilityState()
    8527 +        }
    8528 +    }
    8529 +
    8530 +    private func transitionPushReliabilityState(to newState: PushReliabilityState, reason: String) {
    8531 +        guard pushReliabilityState != newState else { return }
    8532 +        let oldState = pushReliabilityState
    8533 +        pushReliabilityState = newState
    8534 +        if newState == .reliable || newState == .disabled {
    8535 +            pushConsecutiveMisses = 0
    8536 +        }
    8537 +        persistPushReliabilityState()
    8538 +
    8539 +        NSLog("[ChatService] Push reliability state %@ -> %@ (%@)",
    8540 +              oldState.rawValue,
    8541 +              newState.rawValue,
    8542 +              reason)
    8543 +
    8544 +        if newState == .unreliable {
    8545 +            Task { [weak self] in
    8546 +                await self?.handlePushMarkedUnreliable(reason: reason)
    8547 +            }
    8548 +        }
    8549 +    }
    8550 +
    8551 +    private func handlePushMarkedUnreliable(reason: String) async {
    8552 +        await maybeRunCatchUpSync(trigger: .pushMarkedUnreliable, force: true)
    8553 +
    8554 +        let now = Date()
    8555 +        if let lastPushReregisterAt,
    8556 +           now.timeIntervalSince(lastPushReregisterAt) < pushReregisterCooldown {
    8557 +            NSLog("[ChatService] Skipping push re-register - cooldown active")
    8558 +            return
    8559 +        }
    8560 +
    8561 +        lastPushReregisterAt = now
    8562 +        persistPushReliabilityState()
    8563 +        await PushNotificationManager.shared.forceReregister(reason: reason)
    8564 +    }
    8565 +
    8566      private func handleCloudKitImportResult(txId: String, didImport: Bool) async {

• Explored
  └ Read ChatService.swift

• Edited KaChat/Services/ChatService.swift (+15 -0)
    506          cachedUtxosTimestamp = nil
    507 +        catchUpSyncInFlight = false
    508 +        pushReliabilityState = .disabled
    509 +        pushConsecutiveMisses = 0
    510 +        pendingPushObservations.removeAll()
    511 +        for task in pushObservationTasks.values {
    512 +            task.cancel()
    513 +        }
    514 +        pushObservationTasks.removeAll()
    515 +        pushSeenByTxId.removeAll()
    516 +        lastCatchUpSyncAt = nil
    517 +        lastPushReregisterAt = nil
    518          resolveRetryCounts = [:]
        ⋮
    540          userDefaults.removeObject(forKey: deterministicMigrationDoneKey)
    541 +        userDefaults.removeObject(forKey: pushReliabilityStateKey)
    542 +        userDefaults.removeObject(forKey: pushConsecutiveMissesKey)
    543 +        userDefaults.removeObject(forKey: pushLastCatchUpSyncAtKey)
    544 +        userDefaults.removeObject(forKey: pushLastReregisterAtKey)
    545          routingStates = [:]

─ Worked for 1m 50s ───────────────────────────────────────────────────────────────────────────────────────────────────────

• Core reliability helpers are in place. I’m now switching lifecycle and subscription restart call sites to the gated
  catch-up method so foreground/resubscribe no longer always force full fetch when push is healthy.

• Edited KaChat/App/KaChatApp.swift (+1 -1)
    104                  // Now fetch from indexer (will preserve CloudKit content)
    105 -                await ChatService.shared.fetchNewMessages()
    105 +                await ChatService.shared.maybeRunCatchUpSync(trigger: .appActive)
    106

• Edited KaChat/Services/PushNotificationManager.swift (+47 -0)
    177
    178 +    /// Force re-registration with the indexer when push reliability appears degraded.
    179 +    func forceReregister(reason: String) async {
    180 +        let settings = AppSettings.load()
    181 +        guard settings.notificationMode == .remotePush else { return }
    182 +        guard permissionStatus == .authorized || permissionStatus == .provisional else {
    183 +            NSLog("[Push] Skipping forced re-registration - permission not granted")
    184 +            return
    185 +        }
    186 +        guard registrationContinuation == nil else {
    187 +            NSLog("[Push] Skipping forced re-registration - explicit registration flow in progress")
    188 +            return
    189 +        }
    190 +
    191 +        if deviceToken == nil {
    192 +            pendingRegistration = true
    193 +            UIApplication.shared.registerForRemoteNotifications()
    194 +            NSLog("[Push] Forced re-registration requested (%@), refreshing APNs token", reason)
    195 +            return
    196 +        }
    197 +
    198 +        do {
    199 +            try await registerWithIndexer()
    200 +            NSLog("[Push] Forced re-registration succeeded (%@)", reason)
    201 +        } catch {
    202 +            lastError = error.localizedDescription
    203 +            NSLog("[Push] Forced re-registration failed (%@): %@",
    204 +                  reason,
    205 +                  error.localizedDescription)
    206 +        }
    207 +    }
    208 +
    209      /// Called from AppDelegate when APNs token received
        ⋮
    642                     let timestamp = msg["timestamp"] as? Int64 {
    643 +                    ChatService.shared.recordRemotePushDelivery(
    644 +                        txId: txId,
    645 +                        sender: sender,
    646 +                        messageType: "contextual"
    647 +                    )
    648                      await ChatService.shared.addMessageFromPush(
        ⋮
    666              for pending in pendingMessages {
    667 +                ChatService.shared.recordRemotePushDelivery(
    668 +                    txId: pending.txId,
    669 +                    sender: pending.sender,
    670 +                    messageType: pending.type
    671 +                )
    672                  let fetched: Bool
        ⋮
    702
    703 +        ChatService.shared.recordRemotePushDelivery(
    704 +            txId: txId,
    705 +            sender: sender,
    706 +            messageType: messageType
    707 +        )
    708 +
    709          pruneRecentlyHandledPushes()

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• I’ve wired push evidence into PushNotificationManager and replaced foreground fetch with gated catch-up. Next I’m running
  a project build to catch any compile issues from the new APIs and state fields before updating docs.

↳ Interacted with background terminal · xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination 'generic/
platform=iOS Simulator' build
  └ (waited)

• Ran xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination 'generic/platform=iOS Simulator' build
  └ Command line invocation:
        /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination
    … +2039 lines
        Building project KaChat with scheme KaChat
    (2 failures)

⚠ Heads up, you have less than 5% of your weekly limit left. Run /status for a breakdown.

• Explored
  └ Search maybeRunCatchUpSync|RPC subscriptions restored|Subscription restarted|app-active in ChatService.swift

• Edited KaChat/App/KaChatApp.swift (+1 -1)
    103                  }
    104 -                // Now fetch from indexer (will preserve CloudKit content)
    104 +                // Run catch-up sync with push-reliability gating.
    105                  await ChatService.shared.maybeRunCatchUpSync(trigger: .appActive)

• Edited CLAUDE.md (+5 -1)
    167  - Automatic failover with state resync via `GetUtxosByAddresses`
    168 -- Triggers message/payment sync on subscription restart
    168 +- Triggers catch-up sync on restart/reconnect unless remote push channel is currently marked reliable (then deboun
         ced)
    169
        ⋮
    185  - App Group (`group.com.kachat.app`) shares keys/contacts between main app and extension
    186 +- Push reliability is scored by txId correlation between UTXO-notified incoming messages and APNs receipt:
    187 +  - 3 consecutive misses (after 60s grace each) -> `unreliable`, force re-register + immediate catch-up sync
    188 +  - First matched hit -> `reliable` again
    189 +  - When `reliable`, app-active/restart catch-up syncs are debounced (10 minutes)
    190

• Edited PUSH_NOTIFICATIONS.md (+15 -0)
     6
     7 +## Runtime Reliability Gate (Implemented)
     8 +
     9 +Foreground catch-up sync is no longer unconditionally executed after UTXO resubscription in remote-push mode.
    10 +
    11 +Current app behavior:
    12 +- Track incoming UTXO txIds that should have push delivery (eligible watched chats only).
    13 +- Correlate each txId with APNs receipt in-app/extension flow using a 60-second grace window.
    14 +- Reliability transitions:
    15 +  - `reliable` -> `unreliable` after 3 consecutive misses.
    16 +  - `unreliable` -> `reliable` on first matched txId hit.
    17 +- On transition to `unreliable`:
    18 +  - Force push re-registration with indexer.
    19 +  - Run immediate catch-up sync.
    20 +- While `reliable`, app-active and UTXO-subscription-restart catch-up syncs are debounced to 10 minutes to reduce b
        ackend load.
    21 +
    22  ## The Encryption Challenge

• Explored
  └ Read PERFORMANCE_IMPROVEMENTS.md

• Edited PERFORMANCE_IMPROVEMENTS.md (+1 -0)
    36  - [x] App-active Catalyst import timeout tuning: use 12s timeout in `KaChatApp` for `fetchCloudKitChanges(reason: "a
        pp-active")`.
    37 +- [x] Remote-push reliability gate: debounce app-active/subscription-restart catch-up syncs to 10 minutes when APNs
         delivery is healthy; auto-fallback + re-register after 3 consecutive txId misses.

• Explored
  └ Search recordRemotePushDelivery|maybeRunCatchUpSync|trackIncomingUtxoForPushReliability|forceReregister|
           pushReliabilityState|refreshPushReliabilityPrerequisites in ChatService.swift
    Read ChatService.swift, PushNotificationManager.swift

─ Worked for 3m 24s ───────────────────────────────────────────────────────────────────────────────────────────────────────

• The core changes are complete and compile-phase validated; I’m doing a final pass over line references and updated docs
  so I can give you a precise change summary with exact file pointers.

• Explored
  └ Read KaChatApp.swift, ChatService.swift, PushNotificationManager.swift, PUSH_NOTIFICATIONS.md, CLAUDE.md,
         PERFORMANCE_IMPROVEMENTS.md

───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

• Implemented the optimization end-to-end with a streamlined reliability state machine and gated catch-up syncs.

  What changed

  - Added push reliability scoring in ChatService based on txId correlation between UTXO events and push delivery, with:
      - 60s grace window
      - reliable after first hit
      - unreliable after 3 consecutive misses
      - immediate recovery to reliable on next hit
        See KaChat/Services/ChatService.swift:747, KaChat/Services/ChatService.swift:772, KaChat/Services/
        ChatService.swift:8330, KaChat/Services/ChatService.swift:8434, KaChat/Services/ChatService.swift:8545.
  - Added gated catch-up sync entrypoint:
      - maybeRunCatchUpSync(trigger:)
      - debounces catch-up to 10 minutes when push is reliable
      - runs immediate catch-up when push becomes unreliable
        See KaChat/Services/ChatService.swift:772, KaChat/Services/ChatService.swift:8566.
  - Replaced unconditional restart/foreground fetch paths:
      - UTXO restart now calls gated catch-up instead of direct fetch
        KaChat/Services/ChatService.swift:977
      - app foreground now calls gated catch-up instead of direct fetch
        KaChat/App/KaChatApp.swift:105
      - RPC subscription restore path also uses gated catch-up
        KaChat/Services/ChatService.swift:418
  - Wired push evidence into reliability tracker:
      - remote push handling
      - extension-stored messages
      - pending-push fetch queue
        See KaChat/Services/PushNotificationManager.swift:643, KaChat/Services/PushNotificationManager.swift:667, KaChat/
        Services/PushNotificationManager.swift:703.
  - Added forced push re-registration API and trigger on unreliable transition:
      - PushNotificationManager.forceReregister(reason:)
        KaChat/Services/PushNotificationManager.swift:179
      - invoked from unreliable transition handler
        KaChat/Services/ChatService.swift:8578.
  - Added UTXO-side tracking calls for incoming candidates:
      - payment fast-path and resolved incoming path
        KaChat/Services/ChatService.swift:2109, KaChat/Services/ChatService.swift:2526
      - contact self-stash incoming path
        KaChat/Services/ChatService.swift:2232.

  Docs updated

  - CLAUDE.md:168
  - CLAUDE.md:186
  - PUSH_NOTIFICATIONS.md:7
  - PERFORMANCE_IMPROVEMENTS.md:37

  Validation

  - Ran: xcodebuild -project KaChat.xcodeproj -scheme KaChat -destination 'generic/platform=iOS Simulator' build
  - Result: compile passed through app sources; build failed at link stage due existing simulator artifact issue (YbridOpus
    missing arm64 in xcframework), not from these changes.

  1. If you want, I can add a small diagnostics UI/log surface for current push reliability state (disabled/unknown/
     reliable/unreliable) to make field testing easier.
  2. I can also tune thresholds (e.g. 2 misses instead of 3, or debounce 5/15 min) behind constants if you want quicker
     iteration.