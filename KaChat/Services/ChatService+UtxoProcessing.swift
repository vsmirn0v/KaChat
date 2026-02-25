import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

// MARK: - UTXO notification handling, payment resolution, self-stash processing

extension ChatService {
    func handleUtxoChangeNotification(payload: Data) {
        guard let parsed = GrpcNotificationParser.parseUtxosChangedNotification(payload) else { return }
        enqueueUtxoNotification(parsed)
        processQueuedUtxoNotificationsIfNeeded()
    }

    func enqueueUtxoNotification(_ parsed: ParsedUtxosChangedNotification) {
        let txIds = Set(parsed.added.map(\.transactionId)).union(parsed.removed.map(\.transactionId))
        guard !txIds.isEmpty else { return }

        if let existingIndex = queuedUtxoNotifications.firstIndex(where: { !$0.txIds.isDisjoint(with: txIds) }) {
            let existing = queuedUtxoNotifications[existingIndex]
            let merged = ParsedUtxosChangedNotification(
                added: existing.parsed.added + parsed.added,
                removed: existing.parsed.removed + parsed.removed
            )
            let mergedTxIds = existing.txIds.union(txIds)
            queuedUtxoNotifications[existingIndex] = QueuedUtxoNotification(parsed: merged, txIds: mergedTxIds)
        } else {
            queuedUtxoNotifications.append(QueuedUtxoNotification(parsed: parsed, txIds: txIds))
        }
    }

    func processQueuedUtxoNotificationsIfNeeded() {
        guard !utxoFetchInFlight else { return }
        guard !queuedUtxoNotifications.isEmpty else { return }

        utxoFetchInFlight = true
        let queued = queuedUtxoNotifications.removeFirst()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.utxoFetchInFlight = false
                self.processQueuedUtxoNotificationsIfNeeded()
            }
            await self.processParsedUtxoChangeNotification(queued.parsed)
        }
    }

    func processParsedUtxoChangeNotification(_ parsed: ParsedUtxosChangedNotification) async {
        guard let wallet = WalletManager.shared.currentWallet else { return }
        let myAddress = wallet.publicAddress
        let privateKey = WalletManager.shared.getPrivateKey()

        // Collect contact addresses for quick lookup (exclude our own address)
        let contactAddresses = Set(activeContacts.map { $0.address }).subtracting([myAddress])

        // Build per-transaction address maps for sender inference
        var addedByTxId: [String: Set<String>] = [:]
        var removedByTxId: [String: Set<String>] = [:]
        for entry in parsed.added {
            if let address = entry.address {
                addedByTxId[entry.transactionId, default: []].insert(address)
            }
        }
        for entry in parsed.removed {
            if let address = entry.address {
                removedByTxId[entry.transactionId, default: []].insert(address)
            }
        }
        let allRemovedAddresses = Set(parsed.removed.compactMap { $0.address })

        // Log all UTXO notifications (added/removed) with amounts for debugging
        let groupedAdded = Dictionary(grouping: parsed.added, by: { $0.transactionId })
        let groupedRemoved = Dictionary(grouping: parsed.removed, by: { $0.transactionId })
        let allTxIds = Set(groupedAdded.keys).union(groupedRemoved.keys)
        for txId in allTxIds {
            let addedDesc = (groupedAdded[txId] ?? []).map { entry -> String in
                let addr = entry.address ?? "unknown"
                return "\(addr.suffix(10)):\(entry.amount)@\(entry.outputIndex)"
            }.joined(separator: ",")
            let removedDesc = (groupedRemoved[txId] ?? []).map { entry -> String in
                let addr = entry.address ?? "unknown"
                return "\(addr.suffix(10)):\(entry.amount)@\(entry.outputIndex)"
            }.joined(separator: ",")
            NSLog("[ChatService] UTXO notif %@ added=[%@] removed=[%@]",
                  String(txId.prefix(12)), addedDesc, removedDesc)
        }

        // Precompute txs that have both our output and a contact output but no spend info yet.
        var ambiguousDirectionTxIds = Set<String>()
        for (txId, addedAddresses) in addedByTxId {
            let hasMyOutput = addedAddresses.contains(myAddress)
            let hasContactOutput = !addedAddresses.intersection(contactAddresses).isEmpty
            let hasSpendInfo = !(removedByTxId[txId] ?? []).isEmpty
            if hasMyOutput && hasContactOutput && !hasSpendInfo {
                ambiguousDirectionTxIds.insert(txId)
            }
        }

        // Track txs we decided to resolve direction for, to skip other outputs in same batch.
        var deferredTxIds = Set<String>()
        var processedTxIds = Set<String>()

        // Fast-path is intentionally restricted to known local outgoing tx IDs.
        // Removed entries in UTXO notifications may reference previous outpoints and
        // are not reliable for generic sender/receiver inference.
        let txIdsForDirection = Set(groupedAdded.keys).union(groupedRemoved.keys)
        for txId in txIdsForDirection {
            if processedTxIds.contains(txId) { continue }
            guard isKnownOutgoingAttemptTxId(txId) else { continue }
            let addedEntries = groupedAdded[txId] ?? []
            let removedEntries = groupedRemoved[txId] ?? []
            if addedEntries.isEmpty || removedEntries.isEmpty { continue }

            let addedAddresses = Set(addedEntries.compactMap { $0.address })
            let removedAddresses = Set(removedEntries.compactMap { $0.address })

            let removedHasMy = removedAddresses.contains(myAddress)
            let removedContacts = removedAddresses.intersection(contactAddresses)
            let removedHasContact = !removedContacts.isEmpty
            let addedContacts = addedAddresses.intersection(contactAddresses)
            let addedHasContact = !addedContacts.isEmpty

            if removedHasMy && !removedHasContact && addedHasContact {
                // Outgoing payment from us to a known contact.
                if let receiver = addedContacts.first {
                    let amountToContact = addedEntries
                        .filter { $0.address == receiver }
                        .reduce(UInt64(0)) { $0 + $1.amount }
                    if amountToContact > 0 {
                        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                        let payment = PaymentResponse(
                            txId: txId,
                            sender: myAddress,
                            receiver: receiver,
                            amount: amountToContact,
                            message: nil,
                            blockTime: nowMs,
                            acceptingBlock: nil,
                            acceptingDaaScore: addedEntries.first?.blockDaaScore ?? 0,
                            messagePayload: nil
                        )
                        await processPayments([payment], isOutgoing: true, myAddress: myAddress, deliveryStatus: .pending)
                        processedTxIds.insert(txId)
                    }
                }
            }
        }

        // Process added UTXOs
        for entry in parsed.added {
            // Skip coinbase transactions
            if entry.isCoinbase { continue }

            let utxoAddress = entry.address ?? ""
            let txId = entry.transactionId

            if processedTxIds.contains(txId) {
                continue
            }

            if ambiguousDirectionTxIds.contains(txId) {
                if !deferredTxIds.contains(txId) {
                    deferredTxIds.insert(txId)
                    NSLog("[ChatService] Incoming UTXO %@ has outputs to us and contact without spend info - resolving direction",
                          String(txId.prefix(12)))
                    if selfStashFirstAttemptAt[txId] == nil {
                        selfStashFirstAttemptAt[txId] = Date()
                    }
                    Task { @MainActor [weak self] in
                        await self?.startMempoolResolveIfNeeded(
                            txId: txId,
                            myAddress: myAddress,
                            contactAddresses: contactAddresses,
                            blockDaaScore: entry.blockDaaScore,
                            privateKey: privateKey
                        )
                        await self?.resolveSelfStashCandidate(
                            txId: txId,
                            myAddress: myAddress,
                            blockDaaScore: entry.blockDaaScore,
                            privateKey: privateKey,
                            retryDelayNs: 5_000_000_000
                        )
                    }
                }
                continue
            }

            if deferredTxIds.contains(txId) && utxoAddress != myAddress {
                continue
            }

            // Skip if we already have this transaction
            if let existing = findLocalMessage(txId: txId) {
                if !(existing.isOutgoing && existing.messageType == .payment) {
                    continue
                }
            }

            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

            let txAddedAddresses = addedByTxId[txId, default: []]
            let txRemovedAddresses = removedByTxId[txId, default: []]
            let weAreSpendingInTx = txRemovedAddresses.contains(myAddress)

            if shouldDeferClassification(
                txId: txId,
                txAddedAddresses: txAddedAddresses,
                contactAddresses: contactAddresses
            ) {
                if !deferredTxIds.contains(txId) {
                    deferredTxIds.insert(txId)
                    NSLog("[ChatService] Deferring realtime classification for %@ while local send is in-flight",
                          String(txId.prefix(12)))
                }
                continue
            }

            // Case 1: UTXO is to our address - incoming payment or handshake
            if utxoAddress == myAddress && !weAreSpendingInTx {
                // Infer sender from addresses in the SAME transaction only
                let possibleSenders = txAddedAddresses.subtracting([myAddress]).intersection(contactAddresses)
                let onlySelfOutput = txAddedAddresses.count == 1 && txAddedAddresses.contains(myAddress)
                let hasContactOutput = !txAddedAddresses.intersection(contactAddresses).isEmpty
                if onlySelfOutput {
                    NSLog("[ChatService] Incoming UTXO %@ has only self output - resolving before showing payment",
                          String(txId.prefix(12)))
                    deferredTxIds.insert(txId)
                    if selfStashFirstAttemptAt[txId] == nil {
                        selfStashFirstAttemptAt[txId] = Date()
                    }
                    Task { @MainActor [weak self] in
                        await self?.startMempoolResolveIfNeeded(
                            txId: txId,
                            myAddress: myAddress,
                            contactAddresses: contactAddresses,
                            blockDaaScore: entry.blockDaaScore,
                            privateKey: privateKey
                        )
                        await self?.resolveSelfStashCandidate(
                            txId: txId,
                            myAddress: myAddress,
                            blockDaaScore: entry.blockDaaScore,
                            privateKey: privateKey,
                            retryDelayNs: 5_000_000_000
                        )
                    }
                    continue
                }
                if hasContactOutput && !weAreSpendingInTx {
                    NSLog("[ChatService] Incoming UTXO %@ has contact output without spend info - resolving direction",
                          String(txId.prefix(12)))
                    deferredTxIds.insert(txId)
                    if selfStashFirstAttemptAt[txId] == nil {
                        selfStashFirstAttemptAt[txId] = Date()
                    }
                    Task { @MainActor [weak self] in
                        await self?.startMempoolResolveIfNeeded(
                            txId: txId,
                            myAddress: myAddress,
                            contactAddresses: contactAddresses,
                            blockDaaScore: entry.blockDaaScore,
                            privateKey: privateKey
                        )
                        await self?.resolveSelfStashCandidate(
                            txId: txId,
                            myAddress: myAddress,
                            blockDaaScore: entry.blockDaaScore,
                            privateKey: privateKey,
                            retryDelayNs: 5_000_000_000
                        )
                    }
                    continue
                }
                let outputSender = onlySelfOutput ? nil : possibleSenders.first
                let removedSender = txRemovedAddresses.intersection(contactAddresses).first
                let inferredSender = outputSender ?? removedSender

                if let sender = inferredSender {
                    // Skip self-stash transactions (sender == receiver) - these are handled as contextual messages
                    if sender == myAddress {
                        NSLog("[ChatService] Skipping self-stash payment %@ - handled as contextual message",
                              String(txId.prefix(12)))
                        continue
                    }

                    if outputSender != nil && removedSender == nil && !weAreSpendingInTx {
                        NSLog("[ChatService] Incoming UTXO %@ has ambiguous sender (output-only) - resolving before showing payment",
                              String(txId.prefix(12)))
                        enqueueIncomingPaymentResolution(
                            txId: txId,
                            amount: entry.amount,
                            myAddress: myAddress,
                            blockDaaScore: entry.blockDaaScore,
                            privateKey: privateKey
                        )
                        continue
                    }

                    // We have handshake with this contact - show payment immediately
                    NSLog("[ChatService] Incoming payment from %@ (%.2f KAS) - showing immediately",
                          String(sender.suffix(10)), Double(entry.amount) / 100_000_000)

                    let payment = PaymentResponse(
                        txId: txId,
                        sender: sender,
                        receiver: myAddress,
                        amount: entry.amount,
                        message: nil,
                        blockTime: nowMs,
                        acceptingBlock: nil,
                        acceptingDaaScore: entry.blockDaaScore,
                        messagePayload: nil
                    )

                    trackIncomingUtxoForPushReliability(txId: txId, senderAddress: sender)
                    await processPayments([payment], isOutgoing: false, myAddress: myAddress, deliveryStatus: .pending)
                    enqueueIncomingPaymentResolution(
                        txId: txId,
                        amount: entry.amount,
                        myAddress: myAddress,
                        blockDaaScore: entry.blockDaaScore,
                        privateKey: privateKey,
                        senderHint: sender
                    )
                } else {
                    // Unknown sender - need to resolve from REST API
                    NSLog("[ChatService] Incoming payment from unknown sender (tx: %@) - resolving...", String(txId.prefix(12)))
                    enqueueIncomingPaymentResolution(
                        txId: txId,
                        amount: entry.amount,
                        myAddress: myAddress,
                        blockDaaScore: entry.blockDaaScore,
                        privateKey: privateKey
                    )
                }
            }
            // Case 2: UTXO is to a contact address
            else if contactAddresses.contains(utxoAddress) {
                if weAreSpendingInTx {
                    // If outputs include our own address but we have no pending outgoing message,
                    // defer direction resolution to avoid misclassifying incoming payments.
                    let hasMyOutputInTx = txAddedAddresses.contains(myAddress)
                    let pendingOutgoingForContact = conversations
                        .first(where: { $0.contact.address == utxoAddress })?
                        .messages.filter { $0.isOutgoing && $0.deliveryStatus == .pending } ?? []

                    if promoteKnownOutgoingAttempt(contactAddress: utxoAddress, newTxId: txId) {
                        NSLog("[ChatService] Outgoing tx matched tracked pending message: %@", String(txId.prefix(12)))
                        continue
                    }

                    if hasMyOutputInTx && pendingOutgoingForContact.isEmpty {
                        NSLog("[ChatService] Outgoing-looking tx %@ has self output without pending message - resolving direction",
                              String(txId.prefix(12)))
                        if selfStashFirstAttemptAt[txId] == nil {
                            selfStashFirstAttemptAt[txId] = Date()
                        }
                        Task { @MainActor [weak self] in
                            await self?.startMempoolResolveIfNeeded(
                                txId: txId,
                                myAddress: myAddress,
                                contactAddresses: contactAddresses,
                                blockDaaScore: entry.blockDaaScore,
                                privateKey: privateKey
                            )
                            await self?.resolveSelfStashCandidate(
                                txId: txId,
                                myAddress: myAddress,
                                blockDaaScore: entry.blockDaaScore,
                                privateKey: privateKey,
                                retryDelayNs: 5_000_000_000
                            )
                        }
                        continue
                    }

                    // Skip if there's a pending outgoing handshake/message for this contact
                    // (race condition: UTXO notification arrives before pending txId is updated)
                    let hasNonPaymentPending = pendingOutgoingForContact.contains { $0.messageType != .payment }
                    if hasNonPaymentPending {
                        NSLog("[ChatService] Skipping outgoing payment to %@ - non-payment message in flight",
                              String(utxoAddress.suffix(10)))
                        continue
                    }

                    // Own self-stash transactions: contextual messages we sent to a contact
                    // If we have this message locally (we sent it from this device), skip
                    // Otherwise, trigger CloudKit import (sent from another device with same wallet)
                    if utxoAddress == myAddress {
                        if findLocalMessage(txId: txId) != nil {
                            NSLog("[ChatService] Own self-stash %@ already exists locally - skipping",
                                  String(txId.prefix(12)))
                            continue
                        }

                        // Message sent from another device - trigger CloudKit import to get message text
                        // (indexer only has encrypted payload we can't decrypt)
                        NSLog("[ChatService] Own self-stash %@ not found locally - triggering CloudKit import for multi-device sync",
                              String(txId.prefix(12)))
                        Task { @MainActor [weak self] in
                            let importAfter = Date()
                            let didImport = await MessageStore.shared.fetchCloudKitChanges(
                                reason: "self-stash-missing-\(String(txId.prefix(12)))",
                                after: importAfter,
                                timeout: 12.0
                            )
                            self?.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
                            await self?.handleCloudKitImportResult(txId: txId, didImport: didImport)
                        }
                        continue
                    }

                    // We sent this - outgoing payment to contact
                    NSLog("[ChatService] Outgoing payment to %@ (%.2f KAS) - showing immediately",
                          String(utxoAddress.suffix(10)), Double(entry.amount) / 100_000_000)

                    let payment = PaymentResponse(
                        txId: txId,
                        sender: myAddress,
                        receiver: utxoAddress,
                        amount: entry.amount,
                        message: nil,
                        blockTime: nowMs,
                        acceptingBlock: nil,
                        acceptingDaaScore: entry.blockDaaScore,
                        messagePayload: nil
                    )

                    await processPayments([payment], isOutgoing: true, myAddress: myAddress)
                } else {
                    // Contact's self-stash - might be a message to us
                    // Check if sender is the same as receiver (self-stash pattern)
                    let contactIsSpending = txRemovedAddresses.contains(utxoAddress) || allRemovedAddresses.contains(utxoAddress)
                    if contactIsSpending {
                        if findLocalMessage(txId: txId) != nil {
                            continue
                        }
                        trackIncomingUtxoForPushReliability(txId: txId, senderAddress: utxoAddress)
                        // Skip if we already have a resolve in flight for this txId
                        guard !(await inFlightResolveTracker.contains(txId)) else {
                            continue
                        }
                        await inFlightResolveTracker.insert(txId)

                        NSLog("[ChatService] Self-stash from %@ detected (tx: %@) - resolving for message...",
                              String(utxoAddress.suffix(10)), String(txId.prefix(12)))

                        // Need to resolve TX to get payload for decryption
                        Task.detached { [weak self] in
                            await self?.resolveAndProcessSelfStash(
                                txId: txId,
                                contactAddress: utxoAddress,
                                myAddress: myAddress,
                                blockDaaScore: entry.blockDaaScore,
                                privateKey: privateKey
                            )
                            await self?.inFlightResolveTracker.remove(txId)
                        }
                    } else {
                        // Third party sent to contact - not relevant to us
                        // TODO: Fix realtimeUpdatesDisabled feature - re-enable spam detection when fixed
                        // recordIrrelevantTxNotification(contactAddress: utxoAddress)
                    }
                }
            }
            // Case 3: UTXO to unknown address (e.g., change) - skip silently
        }

        if !parsed.added.isEmpty {
            saveMessages()
        }

        // Refresh balance to reflect UTXO changes
        _ = try? await WalletManager.shared.refreshBalance()
    }

    func enqueueIncomingPaymentResolution(
        txId: String,
        amount: UInt64,
        myAddress: String,
        blockDaaScore: UInt64,
        privateKey: Data?,
        senderHint: String? = nil
    ) {
        incomingResolutionAmountHints[txId] = amount
        incomingResolutionPendingTxIds.insert(txId)
        incomingResolutionWarningTxIds.remove(txId)
        if let retryTask = resolveRetryTasks.removeValue(forKey: txId) {
            retryTask.cancel()
        }

        Task.detached { [weak self] in
            guard let self else { return }
            await self.runIncomingPaymentResolution(
                txId: txId,
                amount: amount,
                myAddress: myAddress,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey,
                senderHint: senderHint
            )
        }
    }

    func runIncomingPaymentResolution(
        txId: String,
        amount: UInt64,
        myAddress: String,
        blockDaaScore: UInt64,
        privateKey: Data?,
        senderHint: String? = nil
    ) async {
        guard !(await inFlightResolveTracker.contains(txId)) else {
            NSLog("[ChatService] Incoming resolve already in flight for %@", String(txId.prefix(12)))
            return
        }
        await inFlightResolveTracker.insert(txId)
        await resolveAndProcessIncomingPayment(
            txId: txId,
            amount: amount,
            myAddress: myAddress,
            blockDaaScore: blockDaaScore,
            privateKey: privateKey,
            senderHint: senderHint
        )
        await inFlightResolveTracker.remove(txId)
    }

    /// Resolve and process incoming payment when sender/payload may be incomplete.
    /// Keeps provisional UTXO fast-path payments pending until classification is finalized.
    func resolveAndProcessIncomingPayment(
        txId: String,
        amount: UInt64,
        myAddress: String,
        blockDaaScore: UInt64,
        privateKey: Data?,
        senderHint: String? = nil
    ) async {
        incomingResolutionAmountHints[txId] = amount
        incomingResolutionPendingTxIds.insert(txId)

        if let existing = findLocalMessage(txId: txId) {
            if existing.isOutgoing || existing.messageType != .payment {
                clearIncomingResolutionTracking(txId: txId)
                return
            }
        }

        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let attempt = resolveRetryCounts[txId, default: 0] + 1

        var payloadHint = mempoolPayloadByTxId[txId]
        if (payloadHint?.isEmpty ?? true),
           let mempoolEntry = await NodePoolService.shared.getMempoolEntry(txId: txId, attempt: attempt),
           !mempoolEntry.payload.isEmpty {
            payloadHint = mempoolEntry.payload
            mempoolPayloadByTxId[txId] = mempoolEntry.payload
        }

        let txInfo = await resolveTransactionInfo(txId: txId, ourAddress: myAddress)
        let infoSender = txInfo?.sender
        let fallbackSender = senderHint
        let senderFromInfoOrHint = (infoSender?.isEmpty == false ? infoSender : fallbackSender)
        let blockTimeMs = txInfo?.blockTimeMs ?? nowMs

        var payloadHex = payloadHint
        if (payloadHex?.isEmpty ?? true),
           let infoPayload = txInfo?.payload,
           !infoPayload.isEmpty {
            payloadHex = infoPayload
        }

        if let payloadHex, !payloadHex.isEmpty {
            if await handleIncomingSpecialPayload(
                txId: txId,
                payloadHex: payloadHex,
                senderAddress: senderFromInfoOrHint,
                myAddress: myAddress,
                blockTimeMs: blockTimeMs,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey
            ) {
                clearIncomingResolutionTracking(txId: txId)
                return
            }
        }

        // Fallback handshake check from indexer if payload is still missing from tx endpoints.
        if let handshake = await checkIndexerForHandshake(txId: txId, myAddress: myAddress) {
            NSLog("[ChatService] Handshake detected from indexer for %@", String(txId.prefix(12)))
            removeMessage(txId: txId)
            if let privateKey = privateKey {
                await processHandshakes([handshake], isOutgoing: false, myAddress: myAddress, privateKey: privateKey)
                saveMessages()
                saveConversationAliases()
            }
            clearIncomingResolutionTracking(txId: txId)
            return
        }

        guard let info = txInfo else {
            NSLog("[ChatService] Failed to resolve incoming payment %@ from mempool/indexer/REST - scheduling retry", String(txId.prefix(12)))
            scheduleResolveRetry(
                txId: txId,
                amount: amount,
                myAddress: myAddress,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey,
                senderHint: senderHint
            )
            return
        }

        var fullTx = (payloadHex?.isEmpty ?? true || info.sender == myAddress)
            ? await fetchKaspaFullTransaction(txId: txId, retries: 2, delayNs: 800_000_000)
            : nil

        if let fullTx,
           await handleKNSOperationTransactionIfNeeded(
            fullTx,
            myAddress: myAddress,
            source: "kns-utxo-incoming-resolve"
           ) {
            clearIncomingResolutionTracking(txId: txId)
            return
        }

        if (payloadHex?.isEmpty ?? true),
           let fullPayload = fullTx?.payload,
           !fullPayload.isEmpty {
            payloadHex = fullPayload
            let senderFromFullTx = deriveSenderFromFullTx(fullTx!, excluding: myAddress)
            if await handleIncomingSpecialPayload(
                txId: txId,
                payloadHex: fullPayload,
                senderAddress: senderFromInfoOrHint ?? senderFromFullTx,
                myAddress: myAddress,
                blockTimeMs: fullTx?.acceptingBlockTime ?? fullTx?.blockTime ?? blockTimeMs,
                blockDaaScore: fullTx?.acceptingBlockBlueScore ?? blockDaaScore,
                privateKey: privateKey
            ) {
                clearIncomingResolutionTracking(txId: txId)
                return
            }
        }

        // If sender is our address, this may still be an incoming payment if sender was mis-resolved.
        if info.sender == myAddress {
            if fullTx == nil {
                fullTx = await fetchKaspaFullTransaction(txId: txId, retries: 3, delayNs: 800_000_000)
            }

            if let fullTx,
               await handleKNSOperationTransactionIfNeeded(
                fullTx,
                myAddress: myAddress,
                source: "kns-utxo-incoming-self-sender"
               ) {
                clearIncomingResolutionTracking(txId: txId)
                return
            }

            if let fullTx,
               let derivedSender = deriveSenderFromFullTx(fullTx, excluding: myAddress) {
                NSLog("[ChatService] Sender mismatch for %@ - treating as incoming from %@",
                      String(txId.prefix(12)), String(derivedSender.suffix(10)))
                let resolvedAmount = amount > 0 ? amount : sumOutputsToAddress(fullTx.outputs, address: myAddress)
                incomingResolutionPendingTxIds.remove(txId)
                let incoming = PaymentResponse(
                    txId: txId,
                    sender: derivedSender,
                    receiver: myAddress,
                    amount: resolvedAmount,
                    message: nil,
                    blockTime: fullTx.acceptingBlockTime ?? fullTx.blockTime ?? nowMs,
                    acceptingBlock: fullTx.acceptingBlockHash,
                    acceptingDaaScore: fullTx.acceptingBlockBlueScore ?? blockDaaScore,
                    messagePayload: fullTx.payload
                )
                await processPayments([incoming], isOutgoing: false, myAddress: myAddress, deliveryStatus: .sent)
                clearIncomingResolutionTracking(txId: txId)
                return
            }

            if let fullTx {
                let contacts = Set(activeContacts.map { $0.address }).subtracting([myAddress])
                if let output = fullTx.outputs.first(where: { output in
                    guard let addr = output.scriptPublicKeyAddress else { return false }
                    return contacts.contains(addr)
                }) {
                    let receiver = output.scriptPublicKeyAddress ?? ""
                    incomingResolutionPendingTxIds.remove(txId)
                    let payment = PaymentResponse(
                        txId: txId,
                        sender: myAddress,
                        receiver: receiver,
                        amount: output.amount,
                        message: nil,
                        blockTime: fullTx.acceptingBlockTime ?? fullTx.blockTime ?? nowMs,
                        acceptingBlock: fullTx.acceptingBlockHash,
                        acceptingDaaScore: fullTx.acceptingBlockBlueScore ?? blockDaaScore,
                        messagePayload: fullTx.payload
                    )
                    await processPayments([payment], isOutgoing: true, myAddress: myAddress, deliveryStatus: .sent)
                    clearIncomingResolutionTracking(txId: txId)
                    return
                }
            }

            NSLog("[ChatService] Incoming payment %@ still ambiguous (sender=self) - scheduling retry",
                  String(txId.prefix(12)))
            scheduleResolveRetry(
                txId: txId,
                amount: amount,
                myAddress: myAddress,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey,
                senderHint: senderHint
            )
            return
        }

        // We still don't have a payload/fullTx. Keep pending and retry rather than misclassifying.
        if (payloadHex?.isEmpty ?? true) && fullTx == nil {
            NSLog("[ChatService] Incoming payment %@ missing payload/fullTx after resolution attempt - scheduling retry",
                  String(txId.prefix(12)))
            scheduleResolveRetry(
                txId: txId,
                amount: amount,
                myAddress: myAddress,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey,
                senderHint: senderHint
            )
            return
        }

        // Confirmed as regular payment.
        incomingResolutionPendingTxIds.remove(txId)
        let finalSender = isValidKaspaAddress(info.sender) ? info.sender : (senderFromInfoOrHint ?? info.sender)
        let payment = PaymentResponse(
            txId: txId,
            sender: finalSender,
            receiver: myAddress,
            amount: amount,
            message: nil,
            blockTime: fullTx?.acceptingBlockTime ?? fullTx?.blockTime ?? info.blockTimeMs,
            acceptingBlock: fullTx?.acceptingBlockHash,
            acceptingDaaScore: fullTx?.acceptingBlockBlueScore ?? blockDaaScore,
            messagePayload: payloadHex ?? info.payload
        )
        trackIncomingUtxoForPushReliability(txId: txId, senderAddress: finalSender)
        await processPayments([payment], isOutgoing: false, myAddress: myAddress, deliveryStatus: .sent)
        clearIncomingResolutionTracking(txId: txId)
    }

    func scheduleResolveRetry(
        txId: String,
        amount: UInt64,
        myAddress: String,
        blockDaaScore: UInt64,
        privateKey: Data?,
        senderHint: String? = nil
    ) {
        if let existing = findLocalMessage(txId: txId),
           !existing.isOutgoing,
           existing.messageType == .payment {
            incomingResolutionPendingTxIds.insert(txId)
        }
        incomingResolutionAmountHints[txId] = amount

        let current = resolveRetryCounts[txId, default: 0]
        if current >= incomingResolutionMaxAdditionalRetries {
            NSLog("[ChatService] Incoming payment %@ unresolved after %d retries - marking warning",
                  String(txId.prefix(12)), current)
            if let existing = findLocalMessage(txId: txId),
               !existing.isOutgoing,
               existing.messageType == .payment {
                markIncomingResolutionWarning(txId: txId)
            } else {
                clearIncomingResolutionTracking(txId: txId)
            }
            return
        }

        let nextAttempt = current + 1
        resolveRetryCounts[txId] = nextAttempt
        let delayNs = resolveRetryDelayNs(forAttempt: nextAttempt)

        if let task = resolveRetryTasks.removeValue(forKey: txId) {
            task.cancel()
        }

        resolveRetryTasks[txId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                _ = self.resolveRetryTasks.removeValue(forKey: txId)
            }

            await self.runIncomingPaymentResolution(
                txId: txId,
                amount: amount,
                myAddress: myAddress,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey,
                senderHint: senderHint
            )
        }
    }

    func resolveRetryDelayNs(forAttempt attempt: Int) -> UInt64 {
        let exponent = max(0, attempt - 1)
        let multiplier = UInt64(1) << min(exponent, 30)
        let rawDelay = incomingResolutionBaseDelayNs > UInt64.max / multiplier
            ? UInt64.max
            : incomingResolutionBaseDelayNs * multiplier
        return min(rawDelay, incomingResolutionMaxDelayNs)
    }

    func markIncomingResolutionWarning(txId: String) {
        incomingResolutionPendingTxIds.remove(txId)
        incomingResolutionWarningTxIds.insert(txId)
        resolveRetryCounts.removeValue(forKey: txId)
        if let task = resolveRetryTasks.removeValue(forKey: txId) {
            task.cancel()
        }

        guard let existing = findLocalMessage(txId: txId), !existing.isOutgoing, existing.messageType == .payment else {
            clearIncomingResolutionTracking(txId: txId)
            return
        }

        if updateIncomingPaymentDeliveryStatus(txId: txId, deliveryStatus: .warning) {
            saveMessages()
        }
    }

    func clearIncomingResolutionTracking(txId: String) {
        incomingResolutionPendingTxIds.remove(txId)
        incomingResolutionWarningTxIds.remove(txId)
        incomingResolutionAmountHints.removeValue(forKey: txId)
        resolveRetryCounts.removeValue(forKey: txId)
        if let task = resolveRetryTasks.removeValue(forKey: txId) {
            task.cancel()
        }
        mempoolPayloadByTxId.removeValue(forKey: txId)
    }

    func incomingAmountHint(txId: String) -> UInt64? {
        if let hint = incomingResolutionAmountHints[txId] {
            return hint
        }
        guard let existing = findLocalMessage(txId: txId), !existing.isOutgoing else { return nil }
        return parseKasAmountFromPaymentContent(existing.content)
    }

    func parseKasAmountFromPaymentContent(_ content: String) -> UInt64? {
        let pattern = "(?:Received|Sent)\\s+([0-9][0-9,]*(?:\\.[0-9]{1,8})?)\\s+KAS"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > 1,
              let amountRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        let normalized = content[amountRange].replacingOccurrences(of: ",", with: "")
        guard let kas = Double(normalized) else { return nil }
        return UInt64((kas * 100_000_000).rounded())
    }

    func updateIncomingPaymentDeliveryStatus(
        txId: String,
        deliveryStatus: ChatMessage.DeliveryStatus
    ) -> Bool {
        for index in conversations.indices {
            if let msgIndex = conversations[index].messages.firstIndex(where: { $0.txId == txId && !$0.isOutgoing }) {
                let existing = conversations[index].messages[msgIndex]
                if existing.deliveryStatus == deliveryStatus {
                    return false
                }
                let updated = ChatMessage(
                    id: existing.id,
                    txId: existing.txId,
                    senderAddress: existing.senderAddress,
                    receiverAddress: existing.receiverAddress,
                    content: existing.content,
                    timestamp: existing.timestamp,
                    blockTime: existing.blockTime,
                    acceptingBlock: existing.acceptingBlock,
                    isOutgoing: existing.isOutgoing,
                    messageType: existing.messageType,
                    deliveryStatus: deliveryStatus
                )
                conversations[index].messages[msgIndex] = updated
                return true
            }
        }
        return false
    }

    func handleIncomingSpecialPayload(
        txId: String,
        payloadHex: String,
        senderAddress: String?,
        myAddress: String,
        blockTimeMs: UInt64,
        blockDaaScore: UInt64,
        privateKey: Data?
    ) async -> Bool {
        if isHandshakePayload(payloadHex) {
            guard let senderAddress, !senderAddress.isEmpty, senderAddress != myAddress else {
                return false
            }
            NSLog("[ChatService] Incoming payment %@ resolved as handshake", String(txId.prefix(12)))
            removeMessage(txId: txId)
            let handshake = HandshakeResponse(
                txId: txId,
                sender: senderAddress,
                receiver: myAddress,
                blockTime: blockTimeMs,
                acceptingBlock: nil,
                acceptingDaaScore: blockDaaScore,
                messagePayload: payloadHex
            )
            if let privateKey = privateKey {
                await processHandshakes([handshake], isOutgoing: false, myAddress: myAddress, privateKey: privateKey)
                saveMessages()
                saveConversationAliases()
            }
            return true
        }

        if isContextualPayload(payloadHex) {
            NSLog("[ChatService] Incoming payment %@ resolved as contextual - replacing", String(txId.prefix(12)))
            removeMessage(txId: txId)
            if let privateKey,
               let senderAddress,
               shouldAttemptSelfStashDecryption(payloadHex: payloadHex, contactAddress: senderAddress),
               let decrypted = await decryptContextualMessageFromRawPayload(payloadHex, privateKey: privateKey) {
                let ts = Int64(blockTimeMs > 0 ? blockTimeMs : UInt64(Date().timeIntervalSince1970 * 1000))
                await addMessageFromPush(txId: txId, sender: senderAddress, content: decrypted, timestamp: ts)
            }
            return true
        }

        if isSelfStashPayload(payloadHex) {
            NSLog("[ChatService] Incoming payment %@ resolved as self-stash - removing", String(txId.prefix(12)))
            removeMessage(txId: txId)
            return true
        }

        return false
    }

    func retryIncomingWarningResolutionsOnSync(
        myAddress: String,
        privateKey: Data?
    ) async {
        var warningTxIds = incomingResolutionWarningTxIds
        for conversation in conversations {
            for message in conversation.messages where !message.isOutgoing && message.messageType == .payment && message.deliveryStatus == .warning {
                warningTxIds.insert(message.txId)
            }
        }
        incomingResolutionWarningTxIds.formUnion(warningTxIds)

        let candidates = warningTxIds.filter { txId in
            guard let message = findLocalMessage(txId: txId) else { return false }
            return !message.isOutgoing && message.messageType == .payment && message.deliveryStatus == .warning
        }

        guard !candidates.isEmpty else { return }
        NSLog("[ChatService] Retrying %d unresolved incoming payment(s) on sync", candidates.count)

        for txId in candidates.sorted() {
            guard let amount = incomingAmountHint(txId: txId), amount > 0 else {
                NSLog("[ChatService] Skipping warning tx %@ on sync retry - missing amount hint", String(txId.prefix(12)))
                continue
            }
            resolveRetryCounts.removeValue(forKey: txId)
            if let retryTask = resolveRetryTasks.removeValue(forKey: txId) {
                retryTask.cancel()
            }
            incomingResolutionWarningTxIds.remove(txId)
            incomingResolutionPendingTxIds.insert(txId)
            if updateIncomingPaymentDeliveryStatus(txId: txId, deliveryStatus: .pending) {
                saveMessages()
            }
            enqueueIncomingPaymentResolution(
                txId: txId,
                amount: amount,
                myAddress: myAddress,
                blockDaaScore: 0,
                privateKey: privateKey
            )
        }
    }

    func resolveSelfStashCandidate(
        txId: String,
        myAddress: String,
        blockDaaScore: UInt64,
        privateKey: Data?,
        retryDelayNs: UInt64 = 30_000_000_000
    ) async {
        let now = Date()
        if selfStashFirstAttemptAt[txId] == nil {
            selfStashFirstAttemptAt[txId] = now
        }
        let elapsed = now.timeIntervalSince(selfStashFirstAttemptAt[txId] ?? now)
        if mempoolResolvedTxIds.contains(txId) {
            clearSelfStashRetryState(txId: txId)
            return
        }
        if elapsed < 2.5 {
            let delayNs = UInt64(max(0.1, 2.5 - elapsed) * 1_000_000_000)
            scheduleSelfStashRetry(
                txId: txId,
                myAddress: myAddress,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey,
                delayNs: delayNs
            )
            return
        }

        if let fullTx = await fetchKaspaFullTransaction(txId: txId, retries: 3, delayNs: 800_000_000) {
            if await handleKNSOperationTransactionIfNeeded(
                fullTx,
                myAddress: myAddress,
                source: "kns-utxo-self-stash-candidate"
            ) {
                clearSelfStashRetryState(txId: txId)
                return
            }

            let inputAddresses = (fullTx.inputs ?? []).compactMap { $0.previousOutpointAddress }.filter { !$0.isEmpty }
            let outputAddresses = fullTx.outputs.compactMap { $0.scriptPublicKeyAddress }.filter { !$0.isEmpty }

            let allInputsSelf = !inputAddresses.isEmpty && inputAddresses.allSatisfy { $0 == myAddress }
            let allOutputsSelf = !outputAddresses.isEmpty && outputAddresses.allSatisfy { $0 == myAddress }
            let uniqueInputs = Set(inputAddresses)
            let uniqueOutputs = Set(outputAddresses)
            let hasSelfInput = uniqueInputs.contains(myAddress)
            let hasSelfOutput = uniqueOutputs.contains(myAddress)
            NSLog("[ChatService] Tx %@ inputs=%d (self=%d) outputs=%d (self=%d)",
                  String(txId.prefix(12)), uniqueInputs.count, hasSelfInput ? 1 : 0,
                  uniqueOutputs.count, hasSelfOutput ? 1 : 0)

            if allInputsSelf && allOutputsSelf {
                if findLocalMessage(txId: txId) != nil {
                    return
                }
                NSLog("[ChatService] Verified self-stash %@ - triggering CloudKit import", String(txId.prefix(12)))
                let importAfter = Date()
                let didImport = await MessageStore.shared.fetchCloudKitChanges(
                    reason: "self-stash-verified-\(String(txId.prefix(12)))",
                    after: importAfter,
                    timeout: 12.0
                )
                await MainActor.run {
                    self.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
                }
                await handleCloudKitImportResult(txId: txId, didImport: didImport)
                clearSelfStashRetryState(txId: txId)
                return
            }

            // If we are spending, treat as outgoing payment (change back to self is common).
            if allInputsSelf {
                let contacts = Set(activeContacts.map { $0.address }).subtracting([myAddress])
                let contactOutputs = fullTx.outputs.filter { output in
                    guard let addr = output.scriptPublicKeyAddress else { return false }
                    return contacts.contains(addr)
                }
                if let contactOutput = contactOutputs.max(by: { $0.amount < $1.amount }) {
                    let receiver = contactOutput.scriptPublicKeyAddress ?? ""
                    let payment = PaymentResponse(
                        txId: txId,
                        sender: myAddress,
                        receiver: receiver,
                        amount: contactOutput.amount,
                        message: nil,
                        blockTime: fullTx.acceptingBlockTime ?? fullTx.blockTime ?? UInt64(Date().timeIntervalSince1970 * 1000),
                        acceptingBlock: fullTx.acceptingBlockHash,
                        acceptingDaaScore: fullTx.acceptingBlockBlueScore ?? blockDaaScore,
                        messagePayload: fullTx.payload
                    )
                    await processPayments([payment], isOutgoing: true, myAddress: myAddress)
                } else {
                    NSLog("[ChatService] Resolved %@ as outgoing with no contact output - ignoring", String(txId.prefix(12)))
                }
                clearSelfStashRetryState(txId: txId)
                return
            }

            // Inputs are not all ours: treat as incoming payment to our address.
            let amountToMe = sumOutputsToAddress(fullTx.outputs, address: myAddress)
            guard amountToMe > 0 else {
                NSLog("[ChatService] Resolved %@ without output to us - ignoring", String(txId.prefix(12)))
                return
            }

            var sender = deriveSenderFromFullTx(fullTx, excluding: myAddress)
            if sender == nil {
                sender = await fetchAnyInputAddress(txId: txId, excludeAddress: myAddress)
            }
            guard let resolvedSender = sender else {
                NSLog("[ChatService] Resolved %@ without sender - scheduling retry", String(txId.prefix(12)))
                scheduleSelfStashRetry(
                    txId: txId,
                    myAddress: myAddress,
                    blockDaaScore: blockDaaScore,
                    privateKey: privateKey,
                    delayNs: retryDelayNs
                )
                return
            }

            if let existing = findLocalMessage(txId: txId) {
                if existing.isOutgoing {
                    NSLog("[ChatService] Removing outgoing message for %@ - resolved as incoming", String(txId.prefix(12)))
                    removeMessage(txId: txId)
                } else {
                    return
                }
            }

            let payment = PaymentResponse(
                txId: txId,
                sender: resolvedSender,
                receiver: myAddress,
                amount: amountToMe,
                message: nil,
                blockTime: fullTx.acceptingBlockTime ?? fullTx.blockTime ?? UInt64(Date().timeIntervalSince1970 * 1000),
                acceptingBlock: fullTx.acceptingBlockHash,
                acceptingDaaScore: fullTx.acceptingBlockBlueScore ?? blockDaaScore,
                messagePayload: fullTx.payload
            )
            await processPayments([payment], isOutgoing: false, myAddress: myAddress)
            clearSelfStashRetryState(txId: txId)
            return
        }

        scheduleSelfStashRetry(
            txId: txId,
            myAddress: myAddress,
            blockDaaScore: blockDaaScore,
            privateKey: privateKey,
            delayNs: retryDelayNs
        )
    }

    func clearSelfStashRetryState(txId: String) {
        selfStashRetryCounts.removeValue(forKey: txId)
        selfStashFirstAttemptAt.removeValue(forKey: txId)
        mempoolResolvedTxIds.remove(txId)
        mempoolPayloadByTxId.removeValue(forKey: txId)
        cloudKitImportFirstAttemptAt.removeValue(forKey: txId)
        cloudKitImportLastObservedAt.removeValue(forKey: txId)
        cloudKitImportRetryTokenByTxId.removeValue(forKey: txId)
    }


    func sumOutputsToAddress(_ outputs: [KaspaFullTxOutput], address: String) -> UInt64 {
        outputs.reduce(0) { partial, output in
            guard let addr = output.scriptPublicKeyAddress, addr == address else { return partial }
            return partial + output.amount
        }
    }

    func startMempoolResolveIfNeeded(
        txId: String,
        myAddress: String,
        contactAddresses: Set<String>,
        blockDaaScore: UInt64,
        privateKey: Data?
    ) async {
        if mempoolResolveInFlight.contains(txId) {
            return
        }
        mempoolResolveInFlight.insert(txId)
        defer { mempoolResolveInFlight.remove(txId) }

        NSLog("[ChatService] Mempool lookup start for %@", String(txId.prefix(12)))
        let entry = await NodePoolService.shared.getMempoolEntry(txId: txId, attempt: 1)
        if entry == nil {
            NSLog("[ChatService] Mempool lookup miss for %@", String(txId.prefix(12)))
            return
        }
        guard let entry else { return }
        if !entry.payload.isEmpty {
            mempoolPayloadByTxId[txId] = entry.payload
        }

        // Avoid REST if we can classify using mempool + our UTXO set
        if mempoolResolvedTxIds.contains(txId) {
            return
        }

        let outputsByAddress = Dictionary(grouping: entry.outputs, by: { $0.address })
        let hasMyOutput = outputsByAddress.keys.contains(myAddress)
        let contactOutputAddresses = outputsByAddress.keys.filter { contactAddresses.contains($0) }
        guard hasMyOutput && !contactOutputAddresses.isEmpty else {
            if hasMyOutput && contactOutputAddresses.isEmpty {
                let utxos = (try? await fetchCachedUtxos(for: myAddress)) ?? []
                let outpointKeys = Set(utxos.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" })
                let allInputsAreOurs = !entry.inputs.isEmpty && entry.inputs.allSatisfy { input in
                    outpointKeys.contains("\(input.txId):\(input.index)")
                }
                if allInputsAreOurs {
                    if !entry.payload.isEmpty {
                        let payload = entry.payload
                        if isContextualPayload(payload) || isSelfStashPayload(payload) {
                            NSLog("[ChatService] Mempool resolved %@ as self-stash (inputs=ours, outputs=self) - triggering CloudKit import",
                                  String(txId.prefix(12)))
                            let importAfter = Date()
                            let didImport = await MessageStore.shared.fetchCloudKitChanges(
                                reason: "self-stash-mempool-\(String(txId.prefix(12)))",
                                after: importAfter,
                                timeout: 12.0
                            )
                            await MainActor.run {
                                self.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
                            }
                            await handleCloudKitImportResult(txId: txId, didImport: didImport)
                        } else {
                            NSLog("[ChatService] Mempool resolved %@ as self-spend (inputs=ours, outputs=self) - ignoring",
                                  String(txId.prefix(12)))
                        }
                    } else {
                        NSLog("[ChatService] Mempool resolved %@ as self-spend (inputs=ours, outputs=self) - ignoring",
                              String(txId.prefix(12)))
                    }
                    mempoolResolvedTxIds.insert(txId)
                }
            }
            return
        }

        // If this is a known outgoing attempt, classify as outgoing directly.
        // The UTXO-based input check below will fail for our own transactions because
        // the inputs have already been spent and removed from our UTXO set by the time
        // the mempool resolve runs.
        let knownOutgoing = isKnownOutgoingAttemptTxId(txId)
        if knownOutgoing {
            NSLog("[ChatService] Mempool resolve %@ - known outgoing attempt, skipping UTXO input check",
                  String(txId.prefix(12)))
        }

        var hasMyInput = knownOutgoing
        if !hasMyInput {
            let utxos = (try? await fetchCachedUtxos(for: myAddress)) ?? []
            let outpointKeys = Set(utxos.map { "\($0.outpoint.transactionId):\($0.outpoint.index)" })
            hasMyInput = entry.inputs.contains { input in
                outpointKeys.contains("\(input.txId):\(input.index)")
            }
        }

        if hasMyInput {
            // Outgoing payment from us to a known contact
            if let receiver = contactOutputAddresses.first,
               let outputs = outputsByAddress[receiver] {
                let amountToContact = outputs.reduce(UInt64(0)) { $0 + $1.amount }
                if amountToContact > 0 {
                    NSLog("[ChatService] Mempool resolved %@ as outgoing to %@",
                          String(txId.prefix(12)), String(receiver.suffix(10)))
                    let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                    let payment = PaymentResponse(
                        txId: txId,
                        sender: myAddress,
                        receiver: receiver,
                        amount: amountToContact,
                        message: nil,
                        blockTime: nowMs,
                        acceptingBlock: nil,
                        acceptingDaaScore: blockDaaScore,
                        messagePayload: entry.payload
                    )
                    await processPayments([payment], isOutgoing: true, myAddress: myAddress, privateKey: privateKey, deliveryStatus: .sent)
                    mempoolResolvedTxIds.insert(txId)
                }
            }
            return
        }

        // Incoming payment to us; infer sender from contact output (change address)
        // Guard: don't reclassify as incoming if already correctly handled as outgoing
        if let existing = findLocalMessage(txId: txId), existing.isOutgoing && existing.messageType == .payment {
            NSLog("[ChatService] Mempool resolve %@ - already exists as outgoing payment, skipping incoming classification",
                  String(txId.prefix(12)))
            mempoolResolvedTxIds.insert(txId)
            return
        }
        if contactOutputAddresses.count == 1,
           let sender = contactOutputAddresses.first,
           let myOutputs = outputsByAddress[myAddress] {
            let amountToMe = myOutputs.reduce(UInt64(0)) { $0 + $1.amount }
            if amountToMe > 0 {
                NSLog("[ChatService] Mempool resolved %@ as incoming from %@",
                      String(txId.prefix(12)), String(sender.suffix(10)))
                let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                let payment = PaymentResponse(
                    txId: txId,
                    sender: sender,
                    receiver: myAddress,
                    amount: amountToMe,
                    message: nil,
                    blockTime: nowMs,
                    acceptingBlock: nil,
                    acceptingDaaScore: blockDaaScore,
                    messagePayload: entry.payload
                )
                await processPayments([payment], isOutgoing: false, myAddress: myAddress, privateKey: privateKey, deliveryStatus: .sent)
                mempoolResolvedTxIds.insert(txId)
            }
        }
    }

    func scheduleSelfStashRetry(
        txId: String,
        myAddress: String,
        blockDaaScore: UInt64,
        privateKey: Data?,
        delayNs: UInt64 = 30_000_000_000
    ) {
        let now = Date()
        if selfStashFirstAttemptAt[txId] == nil {
            selfStashFirstAttemptAt[txId] = now
        }
        let elapsed = now.timeIntervalSince(selfStashFirstAttemptAt[txId] ?? now)
        let current = selfStashRetryCounts[txId, default: 0]
        if elapsed >= 30.0 && current >= 1 {
            NSLog("[ChatService] Self-stash %@ unresolved after %.0fs - triggering full sync",
                  String(txId.prefix(12)), elapsed)
            Task { @MainActor in
                await fetchNewMessages()
            }
            selfStashRetryCounts.removeValue(forKey: txId)
            selfStashFirstAttemptAt.removeValue(forKey: txId)
            return
        }

        selfStashRetryCounts[txId] = current + 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            await self?.resolveSelfStashCandidate(
                txId: txId,
                myAddress: myAddress,
                blockDaaScore: blockDaaScore,
                privateKey: privateKey,
                retryDelayNs: delayNs
            )
        }
    }

    /// Resolve and process self-stash (contextual message) from contact
    /// Uses fast mempool RPC racing against REST API since sender is already known
    func resolveAndProcessSelfStash(
        txId: String,
        contactAddress: String,
        myAddress: String,
        blockDaaScore: UInt64,
        privateKey: Data?
    ) async {
        if findLocalMessage(txId: txId) != nil {
            return
        }
        guard let privateKey = privateKey else { return }

        // Race mempool RPC vs REST API for payload
        // For self-stash, we already know the sender - just need payload
        let payload = await resolvePayloadOnly(txId: txId)

        guard let payloadHex = payload, !payloadHex.isEmpty else {
            if findLocalMessage(txId: txId) != nil {
                return
            }
            NSLog("[ChatService] Failed to resolve payload for self-stash %@ - scheduling retry", String(txId.prefix(12)))
            scheduleSelfStashRetry(txId: txId, myAddress: myAddress, blockDaaScore: blockDaaScore, privateKey: privateKey)
            return
        }

        if findLocalMessage(txId: txId) != nil {
            return
        }

        guard shouldAttemptSelfStashDecryption(payloadHex: payloadHex, contactAddress: contactAddress) else {
            return
        }

        // Try to decrypt the payload
        if let decrypted = await decryptContextualMessageFromRawPayload(payloadHex, privateKey: privateKey) {
            await MainActor.run {
                // Skip if already processed
                if findLocalMessage(txId: txId) != nil { return }

                let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                NSLog("[ChatService] Decrypted message from %@ via fast resolve", String(contactAddress.suffix(10)))

                let message = ChatMessage(
                    txId: txId,
                    senderAddress: contactAddress,
                    receiverAddress: myAddress,
                    content: decrypted,
                    timestamp: Date(),
                    blockTime: nowMs,
                    acceptingBlock: nil,
                    isOutgoing: false,
                    messageType: messageType(for: decrypted)
                )

                addMessageToConversation(message, contactAddress: contactAddress)

                if nowMs > lastPollTime {
                    updateLastPollTime(nowMs)
                }

                saveMessages()
            }
        } else {
            // Decryption failed - this self-stash is not for us (different recipient)
            // TODO: Fix realtimeUpdatesDisabled feature - re-enable spam detection when fixed
            // await MainActor.run {
            //     recordIrrelevantTxNotification(contactAddress: contactAddress)
            // }
        }
    }

    func shouldAttemptSelfStashDecryption(payloadHex: String, contactAddress: String) -> Bool {
        guard let payloadData = Self.hexStringToData(payloadHex),
              let payloadString = String(data: payloadData, encoding: .utf8) else {
            NSLog("[ChatService] Raw payload: failed to decode hex to string")
            return false
        }

        guard let alias = Self.extractContextualAlias(fromRawPayloadString: payloadString) else {
            return false
        }

        // Check both legacy and deterministic aliases
        let expectedAliases = incomingAliases(for: contactAddress)
        if !expectedAliases.isEmpty {
            if expectedAliases.contains(alias) {
                return true
            }
            let expectedPrimary = primaryConversationAlias(for: contactAddress) ?? routingStates[contactAddress]?.deterministicMyAlias ?? "-"
            NSLog("[ChatService] Raw payload: alias mismatch for %@ (expected %@, got %@) - skipping",
                  String(contactAddress.suffix(10)), expectedPrimary, alias)
            return false
        }

        if aliasBelongsToAnotherContact(alias, excluding: contactAddress) {
            NSLog("[ChatService] Raw payload: alias belongs to another contact (%@) - skipping", alias)
            return false
        }

        // Unknown alias: allow decrypt attempt to avoid dropping messages for new contacts.
        return true
    }

    func primaryConversationAlias(for address: String) -> String? {
        if let primary = conversationPrimaryAliases[address] {
            return primary
        }
        return conversationAliases[address]?.sorted().first
    }

    func primaryOurAlias(for address: String) -> String? {
        if let primary = ourPrimaryAliases[address] {
            return primary
        }
        return ourAliases[address]?.sorted().first
    }

    func addConversationAlias(_ alias: String, for address: String, blockTime: UInt64?) {
        var set = conversationAliases[address] ?? []
        set.insert(alias)
        conversationAliases[address] = set

        if let time = blockTime {
            let current = conversationAliasUpdatedAt[address] ?? 0
            if time >= current {
                conversationPrimaryAliases[address] = alias
                conversationAliasUpdatedAt[address] = time
            }
        } else if conversationPrimaryAliases[address] == nil {
            conversationPrimaryAliases[address] = alias
        }

        // Keep routing state legacy set in sync; upgrade to hybrid if needed
        if routingStates[address] != nil {
            routingStates[address]?.legacyIncomingAliases.insert(alias)
            if routingStates[address]?.mode == .deterministicOnly {
                routingStates[address]?.mode = .hybrid
            }
        }
    }

    func addOurAlias(_ alias: String, for address: String, blockTime: UInt64?) {
        var set = ourAliases[address] ?? []
        set.insert(alias)
        ourAliases[address] = set

        if let time = blockTime {
            let current = ourAliasUpdatedAt[address] ?? 0
            if time >= current {
                ourPrimaryAliases[address] = alias
                ourAliasUpdatedAt[address] = time
            }
        } else if ourPrimaryAliases[address] == nil {
            ourPrimaryAliases[address] = alias
        }

        // Keep routing state legacy set in sync; upgrade to hybrid if needed
        if routingStates[address] != nil {
            routingStates[address]?.legacyOutgoingAliases.insert(alias)
            if routingStates[address]?.mode == .deterministicOnly {
                routingStates[address]?.mode = .hybrid
            }
        }
    }

    func aliasBelongsToAnotherContact(_ alias: String, excluding contactAddress: String) -> Bool {
        for (address, aliases) in conversationAliases where address != contactAddress {
            if aliases.contains(alias) {
                return true
            }
        }
        return false
    }

    /// Fast payload resolution: try mempool first, fall back to REST API
    /// Used for self-stash messages where sender is already known
    func resolvePayloadOnly(txId: String) async -> String? {
        let startTime = Date()

        if findLocalMessage(txId: txId) != nil {
            return nil
        }

        // Step 1: Single immediate mempool query to all active nodes
        NSLog("[ChatService] Mempool lookup start for self-stash %@", String(txId.prefix(12)))
        if let entry = await NodePoolService.shared.getMempoolEntry(txId: txId, attempt: 1) {
            if !entry.payload.isEmpty {
                mempoolPayloadByTxId[txId] = entry.payload
                if findLocalMessage(txId: txId) != nil {
                    return nil
                }
                let elapsed = Date().timeIntervalSince(startTime) * 1000
                NSLog("[ChatService] Payload resolved from mempool in %.0fms for %@",
                      elapsed, String(txId.prefix(12)))
                return entry.payload
            }
        }
        NSLog("[ChatService] Mempool lookup miss for self-stash %@", String(txId.prefix(12)))

        // Step 2: Fall back to REST API with polling
        guard let url = kaspaRestURL(path: "/transactions/\(txId)") else { return nil }

        for attempt in 1...30 {
            if findLocalMessage(txId: txId) != nil {
                return nil
            }
            // Exponential backoff: first 10 attempts = 500ms, then doubles (capped at 5s)
            let delayMs: UInt64
            if attempt <= 10 {
                delayMs = 500
            } else {
                let exponent = attempt - 11
                delayMs = min(UInt64(1000 * (1 << exponent)), 5000)
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    continue
                }

                // Parse just the payload field
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let payloadHex = json["payload"] as? String,
                   !payloadHex.isEmpty {
                    if findLocalMessage(txId: txId) != nil {
                        return nil
                    }
                    let elapsed = Date().timeIntervalSince(startTime) * 1000
                    NSLog("[ChatService] Payload resolved from REST in %.0fms (attempt %d) for %@",
                          elapsed, attempt, String(txId.prefix(12)))
                    return payloadHex
                }

                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            } catch {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }

        let elapsed = Date().timeIntervalSince(startTime) * 1000
        NSLog("[ChatService] Payload resolution timeout after %.0fms for %@",
              elapsed, String(txId.prefix(12)))
        return nil
    }

    /// Remove a message by txId (used when payment turns out to be handshake)
    func removeMessage(txId: String) {
        clearIncomingResolutionTracking(txId: txId)
        for i in 0..<conversations.count {
            if let msgIndex = conversations[i].messages.firstIndex(where: { $0.txId == txId }) {
                markConversationDirty(conversations[i].contact.address)
                conversations[i].messages.remove(at: msgIndex)
                saveMessages()
                return
            }
        }
    }

    func configureAPIIfNeeded() async {
        // KasiaAPIClient now reads from settings directly
        // No explicit configuration needed
        if !isConfigured {
            isConfigured = true
            NSLog("[ChatService] Configuring API with indexer URL: %@", apiClient.currentBaseURL ?? "unknown")

            // Only load messages if store is ready (don't block on fresh imports)
            if messageStore.isStoreLoaded {
                loadMessagesFromStoreIfNeeded(onlyIfEmpty: true)
            } else {
                NSLog("[ChatService] Store not loaded yet, skipping message load from store")
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        subscriptionRetryTask?.cancel()
        subscriptionRetryTask = nil
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = nil
        needsResubscriptionAfterSync = false

        // Clean up UTXO subscription
        if let token = utxoSubscriptionToken {
            NodePoolService.shared.removeNotificationHandler(token)
            utxoSubscriptionToken = nil
        }
        NodePoolService.shared.unsubscribeUtxosChanged()
        isUtxoSubscribed = false
        NSLog("[ChatService] Polling and UTXO subscription stopped")
    }

    func stopPollingTimerOnly() {
        pollTask?.cancel()
        pollTask = nil
        NSLog("[ChatService] Polling task stopped")
    }

    /// Called when entering a chat view - sets active conversation for unread tracking
    /// Local state is already synced on startup, real-time updates come from RPC notifications
}
