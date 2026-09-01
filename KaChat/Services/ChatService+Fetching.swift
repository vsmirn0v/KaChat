import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

// MARK: - Handshake/message/payment fetching from APIs, processing

extension ChatService {
    func checkIndexerForHandshake(txId: String, myAddress: String) async -> HandshakeResponse? {
        // Query recent incoming handshakes from the indexer
        // Use a 60-second lookback window to narrow the search
        let recentBlockTime = UInt64(max(0, Date().timeIntervalSince1970 * 1000 - 60_000))

        // Try up to 3 times with delays (indexer may need time to index the transaction)
        for attempt in 1...3 {
            do {
                let handshakes = try await apiClient.getHandshakesByReceiver(
                    address: myAddress, limit: 20, blockTime: recentBlockTime
                )
                if let match = handshakes.first(where: { $0.txId == txId }) {
                    return match
                }
            } catch {
                if ChatService.handleDpiPaginationFailure(error, context: "handshake lookup") {
                    return nil
                }
                AppLog.log("[ChatService] Indexer handshake check attempt %d failed: %@", attempt, error.localizedDescription)
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s between retries
            }
        }

        return nil
    }

    func fetchIncomingHandshakes(for address: String, blockTime: UInt64) async throws -> [HandshakeResponse] {
        let key = "in|\(address)|\(blockTime)|50"
        if let existing = handshakeFetchTasks[key] {
            AppLog.log("[ChatService] Handshake fetch in-flight, reusing task (%@)", String(address.suffix(10)))
            return try await existing.value
        }
        let task = Task { [apiClient] in
            do {
                return try await apiClient.getHandshakesByReceiver(address: address, limit: 50, blockTime: blockTime)
            } catch {
                if ChatService.handleDpiPaginationFailure(error, context: "incoming handshakes") {
                    return []
                }
                throw error
            }
        }
        handshakeFetchTasks[key] = task
        defer { handshakeFetchTasks[key] = nil }
        return try await task.value
    }

    func fetchOutgoingHandshakes(for address: String, blockTime: UInt64) async throws -> [HandshakeResponse] {
        let key = "out|\(address)|\(blockTime)|50"
        if let existing = handshakeFetchTasks[key] {
            AppLog.log("[ChatService] Handshake fetch in-flight, reusing task (%@)", String(address.suffix(10)))
            return try await existing.value
        }
        let task = Task { [apiClient] in
            do {
                return try await apiClient.getHandshakesBySender(address: address, limit: 50, blockTime: blockTime)
            } catch {
                if ChatService.handleDpiPaginationFailure(error, context: "outgoing handshakes") {
                    return []
                }
                throw error
            }
        }
        handshakeFetchTasks[key] = task
        defer { handshakeFetchTasks[key] = nil }
        return try await task.value
    }

    func fetchIncomingPayments(for address: String, blockTime: UInt64) async throws -> [PaymentResponse] {
        let key = "in|\(address)|\(blockTime)"
        if let existing = paymentFetchTasks[key] {
            AppLog.log("[ChatService] Payment fetch in-flight, reusing task (%@)", String(address.suffix(10)))
            return try await existing.value
        }
        AppLog.log("[ChatService] === FETCH INCOMING PAYMENTS START === address=%@, blockTime=%llu", String(address.suffix(10)), blockTime)
        let task = Task { [self] in
            // Fetch from Kaspa API instead of indexer
            let result = try await fetchPaymentsFromKaspaAPI(for: address, blockTime: blockTime, incoming: true)
            AppLog.log("[ChatService] === FETCH INCOMING PAYMENTS DONE === count=%d", result.count)
            return result
        }
        paymentFetchTasks[key] = task
        defer { paymentFetchTasks[key] = nil }
        do {
            return try await task.value
        } catch {
            AppLog.log("[ChatService] === FETCH INCOMING PAYMENTS ERROR === %@", error.localizedDescription)
            throw error
        }
    }

    func fetchOutgoingPayments(for address: String, blockTime: UInt64) async throws -> [PaymentResponse] {
        let key = "out|\(address)|\(blockTime)"
        if let existing = paymentFetchTasks[key] {
            AppLog.log("[ChatService] Payment fetch in-flight, reusing task (%@)", String(address.suffix(10)))
            return try await existing.value
        }
        AppLog.log("[ChatService] === FETCH OUTGOING PAYMENTS START === address=%@, blockTime=%llu", String(address.suffix(10)), blockTime)
        let task = Task { [self] in
            // Fetch from Kaspa API instead of indexer
            let result = try await fetchPaymentsFromKaspaAPI(for: address, blockTime: blockTime, incoming: false)
            AppLog.log("[ChatService] === FETCH OUTGOING PAYMENTS DONE === count=%d", result.count)
            return result
        }
        paymentFetchTasks[key] = task
        defer { paymentFetchTasks[key] = nil }
        do {
            return try await task.value
        } catch {
            AppLog.log("[ChatService] === FETCH OUTGOING PAYMENTS ERROR === %@", error.localizedDescription)
            throw error
        }
    }

    func applyMessageRetention(to blockTime: UInt64) -> UInt64 {
        guard let cutoff = messageRetentionCutoffMs() else { return blockTime }
        return max(blockTime, cutoff)
    }

    func messageRetentionCutoffMs() -> UInt64? {
        let retention = SettingsViewModel.loadSettings().messageRetention
        guard let days = retention.days, days > 0 else { return nil }
        let seconds = Double(days) * 86_400.0
        let cutoff = Date().addingTimeInterval(-seconds).timeIntervalSince1970 * 1000
        return UInt64(max(0, cutoff))
    }

    /// Fetch payments directly from Kaspa REST API by scanning all transactions
    /// Payments are regular Kaspa transactions - payload is optional for encrypted message
    func fetchPaymentsFromKaspaAPI(for address: String, blockTime: UInt64, incoming: Bool) async throws -> [PaymentResponse] {
        let direction = incoming ? "INCOMING" : "OUTGOING"
        AppLog.log("[ChatService] fetchPaymentsFromKaspaAPI START - direction=%@, address=%@", direction, String(address.suffix(10)))

        // Fetch all transactions with pagination
        let transactions = await fetchFullTransactionsPaginated(for: address, stopAtBlockTime: blockTime)
        AppLog.log("[ChatService] Fetched total %d transactions from Kaspa API", transactions.count)

        var knsHandledCount = 0
        for transaction in transactions where isKNSRevealTransaction(transaction) {
            if await handleKNSOperationTransactionIfNeeded(
                transaction,
                myAddress: address,
                source: "kns-kaspa-rest-\(incoming ? "incoming" : "outgoing")"
            ) {
                knsHandledCount += 1
            }
        }
        if knsHandledCount > 0 {
            AppLog.log("[ChatService] Processed %d KNS reveal tx(s) during %@ payment fetch", knsHandledCount, direction)
        }

        var payments: [PaymentResponse] = []
        var skippedOld = 0
        var skippedDirection = 0
        var skippedSuppressed = 0

        for tx in transactions {
            if isSuppressedPaymentTxId(tx.transactionId) {
                skippedSuppressed += 1
                continue
            }

            // Get block time directly from transaction
            let txBlockTime = tx.blockTime ?? 0

            // Skip transactions older than our filter time
            if blockTime > 0 && txBlockTime > 0 && txBlockTime <= blockTime {
                skippedOld += 1
                continue
            }

            // Check if we are the sender by looking at inputs
            var weAreSender = false
            var senderAddress = ""
            if let inputs = tx.inputs {
                for input in inputs {
                    if let inputAddr = input.previousOutpointAddress, !inputAddr.isEmpty {
                        if inputAddr == address {
                            weAreSender = true
                        } else if senderAddress.isEmpty {
                            senderAddress = inputAddr
                        }
                    }
                }
            }

            // Analyze outputs
            var totalToUs: UInt64 = 0
            var totalToOthers: UInt64 = 0
            var recipientAddress = ""
            var recipientAmount: UInt64 = 0

            for output in tx.outputs {
                if let addr = output.scriptPublicKeyAddress, !addr.isEmpty {
                    if addr == address {
                        totalToUs += output.amount
                    } else {
                        totalToOthers += output.amount
                        // For outgoing: track recipient (non-change output)
                        // Usually the payment is smaller than change, but we want the non-sender address
                        if addr != senderAddress {
                            // This is likely the actual recipient, not change back to sender
                            if recipientAddress.isEmpty || output.amount < recipientAmount {
                                // Prefer smaller amounts as actual payments (larger is usually change)
                                recipientAddress = addr
                                recipientAmount = output.amount
                            }
                        } else if recipientAddress.isEmpty {
                            // Fallback: use sender's change address if no other recipient
                            recipientAddress = addr
                            recipientAmount = output.amount
                        }
                    }
                }
            }

            // Determine transaction direction based on inputs
            // Incoming: we receive funds AND we are NOT the sender
            // Outgoing: we are the sender AND there are outputs to others
            let isIncomingTx = totalToUs > 0 && !weAreSender
            let isOutgoingTx = weAreSender && totalToOthers > 0

            // Filter based on requested direction
            if incoming && !isIncomingTx {
                skippedDirection += 1
                continue
            }
            if !incoming && !isOutgoingTx {
                skippedDirection += 1
                continue
            }

            var sender = ""
            var receiver = ""
            var amount: UInt64 = 0

            if isIncomingTx && incoming {
                // We received payment - amount is what was sent to us
                receiver = address
                amount = totalToUs
                sender = senderAddress.isEmpty ? "pending_resolution" : senderAddress

                // Skip self-stash transactions (sender == receiver) - these are handled as contextual messages
                if sender == address {
                    AppLog.log("[ChatService] Skipping self-stash payment %@ - handled as contextual message",
                          String(tx.transactionId.prefix(12)))
                    continue
                }
            } else if isOutgoingTx && !incoming {
                // We sent payment - use pre-computed recipient from output analysis above
                sender = address
                if !recipientAddress.isEmpty {
                    receiver = recipientAddress
                    amount = recipientAmount
                } else {
                    // Fallback: find any output that's NOT our change
                    for output in tx.outputs {
                        if let addr = output.scriptPublicKeyAddress, !addr.isEmpty, addr != address {
                            receiver = addr
                            amount = output.amount
                            break
                        }
                    }
                }
            }

            // Skip if we couldn't determine the other party
            if receiver.isEmpty {
                continue
            }

            // Get optional payload (may contain encrypted message)
            let messagePayload = tx.payload
            if let payload = messagePayload, !payload.isEmpty {
                let isContextual = isContextualPayload(payload)
                let isSelfStash = isSelfStashPayload(payload)
                if isContextual || isSelfStash {
                    AppLog.log("[ChatService] Skipping non-payment tx %@ (isContextual: %d, isSelfStash: %d, payload prefix: %@)",
                          String(tx.transactionId.prefix(12)),
                          isContextual ? 1 : 0,
                          isSelfStash ? 1 : 0,
                          String(payload.prefix(44)))
                    continue
                }
            }

            // Verify Schnorr signatures on incoming payments from REST API
            if incoming, let inputs = tx.inputs {
                let verificationInputs = inputs.compactMap { input -> KasiaTransactionBuilder.VerificationInput? in
                    guard let hash = input.previousOutpointHash,
                          let idxStr = input.previousOutpointIndex,
                          let idx = UInt32(idxStr),
                          let sigScript = input.signatureScript,
                          let addr = input.previousOutpointAddress,
                          let amt = input.previousOutpointAmount else { return nil }
                    return KasiaTransactionBuilder.VerificationInput(
                        previousOutpointHash: hash,
                        previousOutpointIndex: idx,
                        signatureScript: sigScript,
                        previousOutpointAddress: addr,
                        previousOutpointAmount: amt,
                        sequence: input.sequence?.value ?? 0,
                        sigOpCount: input.sigOpCount?.value ?? 1
                    )
                }
                let verificationOutputs = tx.outputs.map { output in
                    KasiaTransactionBuilder.VerificationOutput(
                        amount: output.amount,
                        scriptPublicKey: output.scriptPublicKey ?? ""
                    )
                }
                let txVersion = tx.version ?? 0
                let txLockTime = tx.lockTime?.value ?? 0
                let txGas = tx.gas?.value ?? 0
                let subnetData = CryptoUtils.hexToData(tx.subnetworkId ?? "") ?? Data(repeating: 0, count: 20)
                let payloadData = CryptoUtils.hexToData(tx.payload ?? "") ?? Data()

                if !verificationInputs.isEmpty {
                    let sigsValid = KasiaTransactionBuilder.verifyTransactionSignatures(
                        inputs: verificationInputs,
                        outputs: verificationOutputs,
                        version: txVersion,
                        lockTime: txLockTime,
                        subnetworkId: subnetData,
                        gas: txGas,
                        payload: payloadData
                    )
                    if !sigsValid {
                        AppLog.log("[ChatService] WARNING: Skipping payment %@ - Schnorr signature verification FAILED",
                              String(tx.transactionId.prefix(16)))
                        continue
                    }
                }
            }

            let payment = PaymentResponse(
                txId: tx.transactionId,
                sender: sender,
                receiver: receiver,
                amount: amount,
                message: nil,
                blockTime: txBlockTime,
                acceptingBlock: tx.acceptingBlockHash,
                acceptingDaaScore: tx.acceptingBlockBlueScore,
                messagePayload: messagePayload
            )

            payments.append(payment)
            let dirStr = incoming ? "IN" : "OUT"
            AppLog.log("[ChatService] Found payment [%@]: %@... amount=%llu sompi", dirStr, String(tx.transactionId.prefix(16)), amount)
        }

        let dirStr = incoming ? "incoming" : "outgoing"
        AppLog.log(
            "[ChatService] fetchPaymentsFromKaspaAPI DONE - found %d %@ payments (skipped: %d old, %d wrong direction, %d suppressed)",
            payments.count,
            dirStr,
            skippedOld,
            skippedDirection,
            skippedSuppressed
        )
        return payments
    }

    /// Fetch full transactions with automatic pagination
    /// - Parameters:
    ///   - address: Kaspa address to fetch transactions for
    ///   - stopAtBlockTime: Stop fetching when we find transactions older than this (0 = fetch all)
    ///   - pageSize: Number of transactions per page (default: 50)
    ///   - maxTransactions: Maximum total transactions to fetch (default: 10000)
    /// - Returns: Array of all fetched transactions
    func fetchFullTransactionsPaginated(
        for address: String,
        stopAtBlockTime: UInt64 = 0,
        pageSize: Int = 50,
        maxTransactions: Int = 10000
    ) async -> [KaspaFullTransactionResponse] {
        var allTransactions: [KaspaFullTransactionResponse] = []
        var offset = 0
        var pageCount = 0

        while allTransactions.count < maxTransactions {
            guard let url = kaspaRestURL(
                path: "/addresses/\(address)/full-transactions",
                queryItems: [
                    URLQueryItem(name: "limit", value: "\(pageSize)"),
                    URLQueryItem(name: "offset", value: "\(offset)"),
                    URLQueryItem(name: "resolve_previous_outpoints", value: "light")
                ]
            ) else {
                AppLog.log("[ChatService] Invalid URL for fetching transactions")
                break
            }

            if pageCount == 0 {
                AppLog.log("[ChatService] Kaspa API URL: %@", url.absoluteString)
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    AppLog.log("[ChatService] Kaspa API returned non-2xx status")
                    break
                }

                let transactions = try JSONDecoder().decode([KaspaFullTransactionResponse].self, from: data)

                if transactions.isEmpty {
                    break
                }

                allTransactions.append(contentsOf: transactions)

                // Check if we've reached transactions older than our stop time
                if stopAtBlockTime > 0 {
                    // Find the oldest transaction in this batch
                    let oldestBlockTime = transactions.compactMap { $0.blockTime }.min() ?? 0
                    if oldestBlockTime > 0 && oldestBlockTime <= stopAtBlockTime {
                        AppLog.log("[ChatService] Pagination: reached transactions older than stopAtBlockTime, stopping")
                        break
                    }
                }

                // If we got fewer than pageSize, we've reached the end
                if transactions.count < pageSize {
                    break
                }

                // Continue to next page
                offset += pageSize
                pageCount += 1

                if pageCount > 0 {
                    AppLog.log("[ChatService] Pagination: fetched page %d, total transactions: %d, offset: %d",
                          pageCount + 1, allTransactions.count, offset)
                }

            } catch {
                AppLog.log("[ChatService] Pagination error: %@", error.localizedDescription)
                break
            }
        }

        if allTransactions.count >= maxTransactions {
            AppLog.log("[ChatService] Pagination: reached max transactions limit (%d)", maxTransactions)
        }

        return allTransactions
    }

    func processHandshakes(_ handshakes: [HandshakeResponse], isOutgoing: Bool, myAddress: String, privateKey: Data?) async {
        for handshake in handshakes {
            // Stop if the user switched/imported a different wallet mid-loop - the remaining
            // handshakes belong to `myAddress`, not the now-active wallet. See isActiveWallet.
            guard isActiveWallet(myAddress) else { return }
            let resolvedSender = await resolveSenderAddress(
                sender: handshake.sender,
                txId: handshake.txId,
                receiver: handshake.receiver
            )
            let contactAddress = isOutgoing ? handshake.receiver : (resolvedSender ?? handshake.sender)
            if contactAddress.isEmpty {
                AppLog.log("%@", "[ChatService] Skipping handshake \(handshake.txId) - missing sender")
                continue
            }
            // A deleted contact's address is tombstoned - an incoming handshake from them (e.g.
            // a re-sync of their full history) must not silently recreate the conversation.
            if !isOutgoing, contactsManager.isAddressDeleted(contactAddress) {
                continue
            }

            if !isOutgoing {
                clearDeclined(contactAddress)
            }

            // Auto-add contact if not exists
            let existingContact = contactsManager.getContact(byAddress: contactAddress)
            _ = contactsManager.getOrCreateContact(address: contactAddress)
            if existingContact == nil {
                AppLog.log("%@", "[ChatService] Discovered NEW contact from handshake: \(contactAddress.suffix(10))")
            }

            // Try to decrypt handshake payload to extract alias
            var content = "[Handshake]"
            var extractedAlias: String?
            var extractedConversationId: String?

            if let privKey = privateKey, !isOutgoing {
                // For incoming handshakes, decrypt to get sender's alias (runs on background thread)
                if let decrypted = await decryptHandshakePayload(handshake.messagePayload, privateKey: privKey) {
                    // A handshake sent back in answer to ours is an ACCEPTANCE, and saying
                    // "Request to communicate" for it told the person who started the exchange
                    // that the other side was asking THEM - the exact opposite of what happened,
                    // and no sign anywhere that the handshake had completed.
                    content = decrypted.isResponse == true
                        ? "[Request accepted]"
                        : "[Request to communicate]"
                    extractedAlias = decrypted.alias  // may be nil for deterministic handshakes
                    extractedConversationId = decrypted.conversationId
                    if let alias = decrypted.alias {
                        AppLog.log("%@", "[ChatService] Extracted alias '\(alias)' from handshake by \(contactAddress)")
                    } else {
                        AppLog.log("%@", "[ChatService] Received alias-less (deterministic) handshake from \(contactAddress)")
                    }
                }
            } else {
                // For outgoing handshakes, we know our own alias
                content = decodeMessagePayload(handshake.messagePayload) ?? "[Handshake sent]"
            }

            // The resolve/decrypt awaits above may have spanned a wallet switch; re-check before
            // mutating shared alias/conversation state for this handshake.
            guard isActiveWallet(myAddress) else { return }

            // Store the alias for this contact
            if let alias = extractedAlias {
                addConversationAlias(alias, for: contactAddress, blockTime: handshake.blockTime)
            } else if !isOutgoing {
                // Alias-less handshake = peer uses deterministic aliases.
                //
                // There is no random alias to register for this contact, so for a BRAND-NEW
                // stranger the optional-chained assignment below was a silent no-op:
                // `routingStates[contactAddress]` doesn't exist yet, and an incoming handshake
                // by itself never created one. That left the contact outside the
                // `routingStates ∪ conversationAliases` address set that `fetchContextualMessages`
                // sweeps (see its `allContactAddresses`), and outside
                // `fetchContextualMessagesFromContact`'s `incomingAliases` guard - so every
                // message they sent us before we accepted was never even QUERIED.
                //
                // Nothing has to be waited for: a deterministic alias derives from our own seed
                // plus their address (DeterministicAlias.deriveMyAlias/deriveTheirAlias), so the
                // routing state can be created the moment their handshake lands. Their messages
                // are then fetched and stored like any other; ChatDetailView still hides them
                // behind `awaitingMyAcceptance` until we accept.
                ensureRoutingState(for: contactAddress, privateKey: privateKey)
                routingStates[contactAddress]?.peerSupportsDeterministic = true
            }
            if let convId = extractedConversationId {
                conversationIds[contactAddress] = convId
            }

            // If a payment message with this txId already exists, remove it first
            // (handles UTXO notification initially classifying a handshake as payment)
            if let existingMsg = await findLocalMessage(txId: handshake.txId), existingMsg.messageType == .payment {
                AppLog.log("[ChatService] Replacing misclassified payment with handshake for tx %@", String(handshake.txId.prefix(12)))
                removeMessage(txId: handshake.txId)
            }

            let message = ChatMessage(
                txId: handshake.txId,
                senderAddress: resolvedSender ?? handshake.sender,
                receiverAddress: handshake.receiver,
                content: content,
                timestamp: Date(timeIntervalSince1970: TimeInterval((handshake.blockTime ?? 0) / 1000)),
                blockTime: handshake.blockTime ?? 0,
                acceptingBlock: handshake.acceptingBlock,
                isOutgoing: isOutgoing,
                messageType: .handshake
            )

            addMessageToConversation(message, contactAddress: contactAddress)

            // Update last poll time
            if let blockTime = handshake.blockTime, blockTime > lastPollTime {
                updateLastPollTime(blockTime)
            }
        }
    }

    /// Reclassify payment messages that should be handshakes.
    /// After self-stash recovery, we know which contacts have handshakes via ourAliases/conversationAliases.
    /// If a conversation has alias data but no handshake message, the earliest payment is the handshake.
    func reclassifyMisidentifiedHandshakes() {
        var reclassified = 0

        for (contactAddress, aliases) in ourAliases where !aliases.isEmpty {
            guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else { continue }
            let conv = conversations[convIndex]

            // Check if outgoing handshake message exists
            let hasOutgoingHandshake = conv.messages.contains { $0.messageType == .handshake && $0.isOutgoing }
            if !hasOutgoingHandshake {
                // Find the earliest outgoing payment — it's the handshake
                if let earliestPayment = conv.messages
                    .filter({ $0.messageType == .payment && $0.isOutgoing })
                    .min(by: { $0.blockTime < $1.blockTime }) {
                    AppLog.log("[ChatService] Reclassifying outgoing payment %@ as handshake for %@",
                          String(earliestPayment.txId.prefix(12)), String(contactAddress.suffix(10)))
                    replaceMessageType(txId: earliestPayment.txId, contactAddress: contactAddress, newType: .handshake, newContent: "[Handshake sent]")
                    reclassified += 1
                }
            }
        }

        for contactAddress in conversationAliases.keys {
            guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else { continue }
            let conv = conversations[convIndex]

            // Check if incoming handshake message exists
            let hasIncomingHandshake = conv.messages.contains { $0.messageType == .handshake && !$0.isOutgoing }
            if !hasIncomingHandshake {
                // Find the earliest incoming payment — it's the handshake
                if let earliestPayment = conv.messages
                    .filter({ $0.messageType == .payment && !$0.isOutgoing })
                    .min(by: { $0.blockTime < $1.blockTime }) {
                    let content = "[Request to communicate]"
                    AppLog.log("[ChatService] Reclassifying incoming payment %@ as handshake for %@",
                          String(earliestPayment.txId.prefix(12)), String(contactAddress.suffix(10)))
                    replaceMessageType(txId: earliestPayment.txId, contactAddress: contactAddress, newType: .handshake, newContent: content)
                    reclassified += 1
                }
            }
        }

        if reclassified > 0 {
            AppLog.log("[ChatService] Reclassified %d payment(s) as handshake(s)", reclassified)
        }

        // Ensure aliases are set for contacts with completed handshake exchange.
        // With deterministic aliases, we can derive the correct alias from the private key.
        // Falls back to random alias only if no private key is available.
        for conversation in conversations {
            let addr = conversation.contact.address
            let hasOutgoing = conversation.messages.contains { $0.messageType == .handshake && $0.isOutgoing }
            let hasIncoming = conversation.messages.contains { $0.messageType == .handshake && !$0.isOutgoing }
            let hasRouting = routingStates[addr] != nil
            if hasOutgoing && hasIncoming && !hasRouting && (ourAliases[addr]?.isEmpty ?? true) {
                let fallbackAlias = generateAlias()
                addOurAlias(fallbackAlias, for: addr, blockTime: nil)
                AppLog.log("[ChatService] Generated fallback alias for %@ (self-stash unavailable)", String(addr.suffix(10)))
            }
        }
    }

    /// Replace a message's type and content in a conversation
    func replaceMessageType(txId: String, contactAddress: String, newType: ChatMessage.MessageType, newContent: String) {
        guard let convIndex = conversations.firstIndex(where: { $0.contact.address == contactAddress }) else { return }
        updateConversation(at: convIndex) { conversation in
            if let msgIndex = conversation.messages.firstIndex(where: { $0.txId == txId }) {
                let old = conversation.messages[msgIndex]
                conversation.messages[msgIndex] = ChatMessage(
                    txId: old.txId,
                    senderAddress: old.senderAddress,
                    receiverAddress: old.receiverAddress,
                    content: newContent,
                    timestamp: old.timestamp,
                    blockTime: old.blockTime,
                    acceptingBlock: old.acceptingBlock,
                    isOutgoing: old.isOutgoing,
                    messageType: newType
                )
            }
        }
    }

    func resolveSenderAddress(sender: String, txId: String, receiver: String) async -> String? {
        if isValidKaspaAddress(sender) {
            return sender
        }
        guard let derived = await fetchSenderAddressFromTransaction(txId: txId, receiver: receiver) else {
            return nil
        }
        return derived
    }

    func isValidKaspaAddress(_ address: String) -> Bool {
        return KaspaAddress.isValid(address)
    }

    /// Check if a payload hex string contains handshake data
    /// Handshake payloads start with hex("ciph_msg:1:handshake:") after the OP_RETURN prefix
    /// Does this payload start with any of `prefixes`?
    ///
    /// Compares HEX against hex, and never decodes the payload as text. The version this replaced
    /// read a fixed 21 bytes and ran `String(data:encoding:.utf8)` over them - but
    /// `kchat:1:handshake:` is only 18 bytes, so bytes 19-21 were raw ciphertext, and random bytes
    /// are usually not valid UTF-8. The decode returned nil, the payload was declared "not a
    /// handshake", and the transaction fell through to the payment pipeline: a request to
    /// communicate arriving as "Received 0.2 KAS", with a payment notification to match.
    ///
    /// Measured over 1,000 synthetic handshakes, the old form recognised 14% of them.
    nonisolated static func payloadHasPrefix(_ payloadHex: String, _ prefixes: [String]) -> Bool {
        var hex = payloadHex.lowercased()
        // OP_RETURN wrapper (6a + length byte), same allowance the old helper made.
        if hex.hasPrefix("6a"), hex.count >= 4 {
            hex = String(hex.dropFirst(4))
        }
        for prefix in prefixes {
            let prefixHex = prefix.utf8.map { String(format: "%02x", $0) }.joined()
            if hex.hasPrefix(prefixHex) { return true }
        }
        return false
    }

    func isHandshakePayload(_ payloadHex: String) -> Bool {
        Self.payloadHasPrefix(payloadHex, ["kchat:1:handshake:", "ciph_msg:1:handshake:"])
    }

    func isContextualPayload(_ payloadHex: String) -> Bool {
        let matches = Self.payloadHasPrefix(payloadHex, ["kchat:1:comm:", "ciph_msg:1:comm:"])
        if !matches, Self.payloadHasPrefix(payloadHex, ["kchat:", "ciph_msg:"]) {
            // Log near-miss for debugging
            AppLog.log("[ChatService] Payload is a KaChat root but not comm")
        }
        return matches
    }

    func isSelfStashPayload(_ payloadHex: String) -> Bool {
        let matches = Self.payloadHasPrefix(payloadHex, ["kchat:1:self_stash:", "ciph_msg:1:self_stash:"])
        if !matches, Self.payloadHasPrefix(payloadHex, ["kchat:", "ciph_msg:"]) {
            // Log near-miss for debugging
            AppLog.log("[ChatService] Payload is a KaChat root but not self_stash")
        }
        return matches
    }

    func isKNSRevealSignatureScript(_ signatureScriptHex: String) -> Bool {
        let lowered = signatureScriptHex.lowercased()
        guard lowered.contains("036b6e73") else { return false } // push "kns"

        let hasKnownOp =
            lowered.contains("226f70223a2261646450726f66696c6522") || // "op":"addProfile"
            lowered.contains("226f70223a2263726561746522") || // "op":"create"
            lowered.contains("226f70223a227472616e7366657222") // "op":"transfer"
        guard hasKnownOp else { return false }

        let hasKnownProtocolField =
            lowered.contains("2270223a22646f6d61696e22") || // "p":"domain"
            lowered.contains("226b6579223a") || // "key":
            lowered.contains("226964223a") // "id":
        return hasKnownProtocolField
    }

    func isKNSRevealTransaction(_ transaction: KaspaFullTransactionResponse) -> Bool {
        guard let inputs = transaction.inputs, !inputs.isEmpty else { return false }
        for input in inputs {
            guard let signatureScript = input.signatureScript, !signatureScript.isEmpty else { continue }
            if isKNSRevealSignatureScript(signatureScript) {
                return true
            }
        }
        return false
    }

    func suppressedKNSPaymentTxIds(from transactions: [KaspaFullTransactionResponse]) -> Set<String> {
        guard !transactions.isEmpty else { return [] }

        var revealTxIds = Set<String>()
        var commitTxIds = Set<String>()

        for transaction in transactions {
            let txId = transaction.transactionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !txId.isEmpty else { continue }
            guard isKNSRevealTransaction(transaction) else { continue }

            revealTxIds.insert(txId)
            if let inputs = transaction.inputs {
                for input in inputs {
                    guard let rawHash = input.previousOutpointHash else { continue }
                    let previousHash = rawHash
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !previousHash.isEmpty else { continue }
                    commitTxIds.insert(previousHash)
                }
            }
        }

        return revealTxIds.union(commitTxIds)
    }

    @discardableResult
    func suppressKNSPaymentTxIfNeeded(_ transaction: KaspaFullTransactionResponse, source: String) -> Bool {
        let suppressed = suppressedKNSPaymentTxIds(from: [transaction])
        guard !suppressed.isEmpty else { return false }
        registerSuppressedPaymentTxIds(Array(suppressed), reason: source)
        return suppressed.contains(transaction.transactionId.lowercased())
    }

    func decodeKNSRevealOperationJSON(signatureScriptHex: String) -> [String: Any]? {
        let lowered = signatureScriptHex.lowercased()
        guard let startRange = lowered.range(of: "7b22") else { return nil } // {"...
        guard let endRange = lowered.range(
            of: "7d",
            options: .backwards,
            range: startRange.lowerBound..<lowered.endIndex
        ) else { return nil }

        let jsonHex = String(lowered[startRange.lowerBound..<endRange.upperBound])
        guard jsonHex.count % 2 == 0,
              let jsonData = Data(hexString: jsonHex),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        return object
    }

    func parseKNSTransferOperation(from transaction: KaspaFullTransactionResponse) -> (domainId: String, recipientAddress: String?)? {
        guard let inputs = transaction.inputs, !inputs.isEmpty else { return nil }

        for input in inputs {
            guard let signatureScript = input.signatureScript, !signatureScript.isEmpty else { continue }
            guard isKNSRevealSignatureScript(signatureScript) else { continue }
            guard let operationJSON = decodeKNSRevealOperationJSON(signatureScriptHex: signatureScript) else { continue }

            guard let op = operationJSON["op"] as? String,
                  op.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "transfer" else {
                continue
            }

            if let proto = operationJSON["p"] as? String,
               proto.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "domain" {
                continue
            }

            guard let rawDomainId = operationJSON["id"] as? String else { continue }
            let domainId = rawDomainId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !domainId.isEmpty else { continue }

            let recipientAddress = (operationJSON["to"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (domainId: domainId, recipientAddress: recipientAddress)
        }

        return nil
    }

    @discardableResult
    func handleKNSOperationTransactionIfNeeded(
        _ transaction: KaspaFullTransactionResponse,
        myAddress: String,
        source: String
    ) async -> Bool {
        let suppressed = suppressedKNSPaymentTxIds(from: [transaction])
        guard !suppressed.isEmpty else { return false }

        registerSuppressedPaymentTxIds(Array(suppressed), reason: source)

        if let transfer = parseKNSTransferOperation(from: transaction) {
            await ingestKNSTransferMessage(
                transaction: transaction,
                domainId: transfer.domainId,
                recipientAddress: transfer.recipientAddress,
                myAddress: myAddress,
                source: source
            )
        }

        let normalizedTxId = transaction.transactionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return suppressed.contains(normalizedTxId)
    }

    @discardableResult
    func addKNSTransferMessageFromHintIfNeeded(
        txId: String,
        myAddress: String,
        blockTimeMs: UInt64? = nil,
        acceptingBlock: String? = nil
    ) async -> Bool {
        guard let hint = knsTransferChatHint(for: txId) else { return false }

        if let existing = await findLocalMessage(txId: txId) {
            if existing.messageType == .payment {
                removeMessage(txId: txId)
            } else {
                removeKNSTransferChatHint(for: txId)
                return true
            }
        }

        let resolvedBlockTime = {
            let provided = blockTimeMs ?? 0
            return provided > 0 ? provided : hint.timestampMs
        }()
        let isOutgoing = hint.isOutgoing
        let senderAddress = isOutgoing ? myAddress : hint.counterpartyAddress
        let receiverAddress = isOutgoing ? hint.counterpartyAddress : myAddress
        let content = localizedKNSTransferMessage(
            domainName: hint.domainName,
            isOutgoing: isOutgoing
        )

        let message = ChatMessage(
            txId: txId,
            senderAddress: senderAddress,
            receiverAddress: receiverAddress,
            content: content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(resolvedBlockTime) / 1000.0),
            blockTime: resolvedBlockTime,
            acceptingBlock: acceptingBlock,
            isOutgoing: isOutgoing,
            messageType: .contextual,
            deliveryStatus: .sent
        )
        addMessageToConversation(message, contactAddress: hint.counterpartyAddress)
        if resolvedBlockTime > lastPollTime {
            updateLastPollTime(resolvedBlockTime)
        }
        removeKNSTransferChatHint(for: txId)
        AppLog.log(
            "[ChatService] Added KNS transfer message from hint tx=%@ domain=%@",
            String(txId.prefix(12)),
            hint.domainName
        )
        return true
    }

    func ingestKNSTransferMessage(
        transaction: KaspaFullTransactionResponse,
        domainId: String,
        recipientAddress: String?,
        myAddress: String,
        source: String
    ) async {
        let txId = transaction.transactionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txId.isEmpty else { return }

        let blockTimeMs = transaction.acceptingBlockTime ?? transaction.blockTime ?? currentTimeMs()
        if await addKNSTransferMessageFromHintIfNeeded(
            txId: txId,
            myAddress: myAddress,
            blockTimeMs: blockTimeMs,
            acceptingBlock: transaction.acceptingBlockHash
        ) {
            return
        }

        if let existing = await findLocalMessage(txId: txId) {
            if existing.messageType == .payment {
                removeMessage(txId: txId)
            } else {
                return
            }
        }

        let myNormalized = myAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let recipient = recipientAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !recipient.isEmpty else {
            AppLog.log("[ChatService] KNS transfer %@ missing recipient in payload (%@)", String(txId.prefix(12)), source)
            return
        }

        // Are we actually a party to this transfer?
        //
        // `isOutgoing` used to be nothing but `recipient != me`, which is true for EVERY person
        // on earth who is not the recipient. A KNS transfer is a public on-chain inscription
        // naming its recipient in plaintext, so any third party whose client so much as looked at
        // that transaction concluded "not addressed to me, therefore I must have sent it" and
        // filed "Sent <domain> domain" into a chat with the recipient - a stranger they had never
        // messaged. That is a real leak: it told an uninvolved person who received which domain
        // from whom. Reported from the field, seen by someone with no connection to either party.
        //
        // Being the recipient, or having signed one of the inputs, is what makes this ours.
        // Anything else is somebody else's transfer and must be ignored outright.
        let myAddresses: Set<String> = {
            var set: Set<String> = [myNormalized]
            for address in WalletManager.shared.allSpendingAddresses() {
                let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty { set.insert(trimmed) }
            }
            return set
        }()
        let weAreRecipient = myAddresses.contains(recipient.lowercased())
        let weSigned = (transaction.inputs ?? []).contains { input in
            guard let address = input.previousOutpointAddress?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                !address.isEmpty else { return false }
            return myAddresses.contains(address)
        }
        guard weAreRecipient || weSigned else {
            AppLog.log("[ChatService] KNS transfer %@ is not ours (recipient=%@) - ignoring (%@)",
                  String(txId.prefix(12)), String(recipient.suffix(10)), source)
            removeKNSTransferChatHint(for: txId)
            return
        }

        // Our own sends are normally rendered from the hint recorded at submit time
        // (`addKNSTransferMessageFromHintIfNeeded`); this covers a send whose hint is gone, e.g.
        // after a reinstall, where the inputs prove authorship instead.
        let isOutgoing = !weAreRecipient
        let contactAddress: String? = {
            if isOutgoing {
                return recipient
            }
            if let sender = deriveSenderFromFullTx(transaction, excluding: myAddress),
               !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return sender
            }
            for output in transaction.outputs {
                guard let outputAddress = output.scriptPublicKeyAddress?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !outputAddress.isEmpty else { continue }
                let normalizedOutput = outputAddress.lowercased()
                if normalizedOutput != myNormalized && normalizedOutput != recipient.lowercased() {
                    return outputAddress
                }
            }
            for output in transaction.outputs {
                guard let outputAddress = output.scriptPublicKeyAddress?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !outputAddress.isEmpty else { continue }
                if outputAddress.lowercased() != myNormalized {
                    return outputAddress
                }
            }
            return nil
        }()

        guard let contactAddress,
              !contactAddress.isEmpty,
              contactAddress.lowercased() != myNormalized,
              isValidKaspaAddress(contactAddress) else {
            AppLog.log("[ChatService] KNS transfer %@ has unresolved counterparty (%@)", String(txId.prefix(12)), source)
            return
        }

        let domainName = await resolveKNSTransferDomainName(
            domainId: domainId,
            myAddress: myAddress,
            counterpartyAddress: contactAddress
        )
        let content: String
        if let domainName, !domainName.isEmpty {
            content = localizedKNSTransferMessage(
                domainName: domainName,
                isOutgoing: isOutgoing
            )
        } else {
            content = localizedKNSTransferMessage(
                domainName: nil,
                isOutgoing: isOutgoing
            )
        }

        let message = ChatMessage(
            txId: txId,
            senderAddress: isOutgoing ? myAddress : contactAddress,
            receiverAddress: isOutgoing ? contactAddress : myAddress,
            content: content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(blockTimeMs) / 1000.0),
            blockTime: blockTimeMs,
            acceptingBlock: transaction.acceptingBlockHash,
            isOutgoing: isOutgoing,
            messageType: .contextual,
            deliveryStatus: .sent
        )
        addMessageToConversation(message, contactAddress: contactAddress)
        if blockTimeMs > lastPollTime {
            updateLastPollTime(blockTimeMs)
        }
        removeKNSTransferChatHint(for: txId)
        AppLog.log(
            "[ChatService] Added KNS transfer message tx=%@ direction=%@ domain=%@ source=%@",
            String(txId.prefix(12)),
            isOutgoing ? "outgoing" : "incoming",
            domainName ?? domainId,
            source
        )
    }

    func resolveKNSTransferDomainName(
        domainId: String,
        myAddress: String,
        counterpartyAddress: String?
    ) async -> String? {
        let trimmedDomainId = domainId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomainId.isEmpty else { return nil }

        if let ownCached = cachedDomainNameForAssetId(trimmedDomainId, ownerAddress: myAddress) {
            return ownCached
        }
        if let counterpartyAddress,
           let counterpartyCached = cachedDomainNameForAssetId(trimmedDomainId, ownerAddress: counterpartyAddress) {
            return counterpartyCached
        }
        if let anyCached = cachedDomainNameForAssetId(trimmedDomainId, ownerAddress: nil) {
            return anyCached
        }
        for attempt in 1...3 {
            if let resolved = await KNSService.shared.resolveDomainName(assetId: trimmedDomainId) {
                return resolved
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        return nil
    }

    func cachedDomainNameForAssetId(_ assetId: String, ownerAddress: String?) -> String? {
        let normalizedAssetId = assetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAssetId.isEmpty else { return nil }

        if let ownerAddress {
            let normalizedOwner = ownerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if let info = KNSService.shared.domainCache[normalizedOwner],
               let domain = info.allDomains.first(where: { $0.inscriptionId == normalizedAssetId }) {
                return domain.fullName
            }
            return nil
        }

        for info in KNSService.shared.domainCache.values {
            if let domain = info.allDomains.first(where: { $0.inscriptionId == normalizedAssetId }) {
                return domain.fullName
            }
        }
        return nil
    }


    func fetchSenderAddressFromTransaction(txId: String, receiver: String) async -> String? {
        // Try full-transaction endpoint first for better data
        guard let url = kaspaRestURL(
            path: "/transactions/\(txId)",
            queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
        ) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            // Try to decode as full transaction first
            if let fullTx = try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data) {
                // First try to get sender from resolved input addresses
                if let inputs = fullTx.inputs {
                    for input in inputs {
                        if let inputAddr = input.previousOutpointAddress, !inputAddr.isEmpty, inputAddr != receiver {
                            return inputAddr
                        }
                    }
                }
                // Fallback: get from outputs, excluding the receiver
                let addresses = fullTx.outputs.compactMap { $0.scriptPublicKeyAddress }
                    .filter { !$0.isEmpty && $0 != receiver }
                if let sender = addresses.first {
                    return sender
                }
            }

            // Fallback to simple response
            let decoded = try JSONDecoder().decode(KaspaTransactionResponse.self, from: data)
            let addresses = decoded.outputs.compactMap { $0.scriptPublicKeyAddress }
                .filter { !$0.isEmpty }
            if !receiver.isEmpty {
                if let other = addresses.first(where: { $0 != receiver }) {
                    return other
                }
            }
            return addresses.first
        } catch {
            AppLog.log("%@", "[ChatService] Failed to fetch tx \(txId): \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolve transaction info for incoming payments/handshakes
    /// Requires REST API because we need sender address from resolved inputs
    /// (Mempool entries don't include sender address - see MESSAGING.md)
    func resolveTransactionInfo(txId: String, ourAddress: String) async -> TransactionResolveInfo? {
        if let indexerInfo = await resolveTransactionInfoFromIndexer(txId: txId, ourAddress: ourAddress) {
            return indexerInfo
        }
        if let restInfo = await resolveTransactionInfoFromKaspaRest(txId: txId, ourAddress: ourAddress) {
            return restInfo
        }
        return nil
    }

    func resolveTransactionInfoFromIndexer(txId: String, ourAddress: String) async -> TransactionResolveInfo? {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let baseStart = lastPollTime > 300_000 ? lastPollTime - 300_000 : lastPollTime
        let startCandidates: [UInt64] = baseStart > 0 ? [baseStart, 0] : [0]
        var attempt = 0

        for startBlockTime in startCandidates {
            for _ in 0..<2 {
                attempt += 1
                do {
                    let payments = try await apiClient.getPaymentsByReceiverOnce(
                        address: ourAddress,
                        limit: 100,
                        blockTime: startBlockTime
                    )
                    if let payment = payments.first(where: { $0.txId == txId }) {
                        let blockTimeMs = payment.blockTime ?? nowMs
                        if payment.sender == ourAddress {
                            if let fullTx = await fetchKaspaFullTransaction(txId: txId, retries: 1, delayNs: 500_000_000),
                               let derivedSender = deriveSenderFromFullTx(fullTx, excluding: ourAddress) {
                                AppLog.log("[ChatService] Indexer sender mismatch for %@ - using full tx sender %@",
                                      String(txId.prefix(12)), String(derivedSender.suffix(10)))
                                return TransactionResolveInfo(
                                    sender: derivedSender,
                                    blockTimeMs: fullTx.acceptingBlockTime ?? fullTx.blockTime ?? blockTimeMs,
                                    payload: fullTx.payload ?? payment.messagePayload
                                )
                            }
                        }
                        AppLog.log("[ChatService] Resolved tx %@ from indexer (attempt %d, start=%llu)",
                              String(txId.prefix(12)), attempt, startBlockTime)
                        return TransactionResolveInfo(
                            sender: payment.sender,
                            blockTimeMs: blockTimeMs,
                            payload: payment.messagePayload
                        )
                    }
                } catch {
                    AppLog.log("[ChatService] Indexer resolve failed for %@ (attempt %d): %@",
                          String(txId.prefix(12)), attempt, error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }

        return nil
    }

    func resolveTransactionInfoFromKaspaRest(txId: String, ourAddress: String) async -> TransactionResolveInfo? {
        // Use actor to safely share cancellation state
        actor ResolutionState {
            var isResolved = false
            var result: TransactionResolveInfo?

            func trySetResult(_ info: TransactionResolveInfo) -> Bool {
                guard !isResolved else { return false }
                isResolved = true
                result = info
                return true
            }

            func checkResolved() -> Bool { isResolved }
            func getResult() -> TransactionResolveInfo? { result }
        }

        let state = ResolutionState()

        // REST API polling - required because we need sender address from resolved inputs
        // Mempool entries don't include previousOutpointAddress, so we must use REST API
        let restTask = Task {
            guard let url = kaspaRestURL(
                path: "/transactions/\(txId)",
                queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
            ) else { return }
            AppLog.log("[ChatService] Kaspa REST resolve request: %@", url.absoluteString)

            // Initial delay to give indexer time to process
            try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1500ms

            let maxAttempts = 8
            let pollIntervalNs: UInt64 = 700_000_000  // 700ms

            for attempt in 1...maxAttempts {
                if await state.checkResolved() { return }

                do {
                    let (data, response) = try await URLSession.shared.data(from: url)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        try? await Task.sleep(nanoseconds: pollIntervalNs)
                        continue
                    }

                    if httpResponse.statusCode == 404 || httpResponse.statusCode >= 500 {
                        try? await Task.sleep(nanoseconds: pollIntervalNs)
                        continue
                    }

                    guard (200...299).contains(httpResponse.statusCode) else { continue }

                    let fullTx = try JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data)

                    var sender: String?
                    if let inputs = fullTx.inputs {
                        for input in inputs {
                            if let inputAddr = input.previousOutpointAddress, !inputAddr.isEmpty, inputAddr != ourAddress {
                                sender = inputAddr
                                break
                            }
                        }
                    }

                    guard let senderAddress = sender else {
                        try? await Task.sleep(nanoseconds: pollIntervalNs)
                        continue
                    }

                    let blockTimeMs = fullTx.acceptingBlockTime ?? fullTx.blockTime ?? UInt64(Date().timeIntervalSince1970 * 1000)

                    let info = TransactionResolveInfo(
                        sender: senderAddress,
                        blockTimeMs: blockTimeMs,
                        payload: fullTx.payload
                    )

                    if await state.trySetResult(info) {
                        AppLog.log("[ChatService] Resolved tx %@ from REST API on attempt %d", String(txId.prefix(12)), attempt)
                        return
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: pollIntervalNs)
                }
            }
        }

        // Wait for REST API to complete with a result or timeout
        let timeout: UInt64 = 12_000_000_000  // 12 seconds max
        let startTime = DispatchTime.now()

        while true {
            if let result = await state.getResult() {
                restTask.cancel()
                return result
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
            if elapsed > timeout {
                AppLog.log("[ChatService] Transaction resolution timeout for %@", String(txId.prefix(12)))
                restTask.cancel()
                return nil
            }

            try? await Task.sleep(nanoseconds: 50_000_000)  // Check every 50ms
        }
    }

    func fetchKaspaFullTransaction(
        txId: String,
        retries: Int,
        delayNs: UInt64
    ) async -> KaspaFullTransactionResponse? {
        guard let url = kaspaRestURL(
            path: "/transactions/\(txId)",
            queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
        ) else { return nil }
        AppLog.log("[ChatService] Kaspa REST full tx request: %@", url.absoluteString)

        for attempt in 1...max(1, retries) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                let fullTx = try JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data)
                AppLog.log("[ChatService] Kaspa REST full tx resolved for %@ on attempt %d",
                      String(txId.prefix(12)), attempt)
                return fullTx
            } catch {
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }

        return nil
    }

    func deriveSenderFromFullTx(_ fullTx: KaspaFullTransactionResponse, excluding address: String) -> String? {
        if let inputs = fullTx.inputs {
            for input in inputs {
                if let inputAddr = input.previousOutpointAddress, !inputAddr.isEmpty, inputAddr != address {
                    return inputAddr
                }
            }
        }
        return nil
    }

    /// Fetch any input address from a transaction (fallback when normal resolution fails)
    /// This tries the REST API without retries, just to get ANY input address
    func fetchAnyInputAddress(txId: String, excludeAddress: String) async -> String? {
        guard let url = kaspaRestURL(
            path: "/transactions/\(txId)",
            queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
        ) else { return nil }

        do {
            AppLog.log("[ChatService] Kaspa REST fetchAnyInputAddress: %@", url.absoluteString)
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let inputs = json["inputs"] as? [[String: Any]] else {
                return nil
            }

            // Get any input address that's not our own
            for input in inputs {
                if let addr = input["previous_outpoint_address"] as? String,
                   !addr.isEmpty,
                   addr != excludeAddress {
                    return addr
                }
            }
            return nil
        } catch {
            AppLog.log("[ChatService] fetchAnyInputAddress failed for %@: %@", String(txId.prefix(16)), error.localizedDescription)
            return nil
        }
    }

    func fetchSavedHandshakes(myAddress: String, privateKey: Data?) async throws {
        guard let privKey = privateKey else {
            AppLog.log("[ChatService] Cannot fetch saved handshakes - no private key")
            return
        }

        let savedHandshakes: [SelfStashResponse]
        do {
            savedHandshakes = try await apiClient.getSelfStash(owner: myAddress, scope: "saved_handshake")
        } catch {
            if ChatService.handleDpiPaginationFailure(error, context: "saved handshakes") {
                return
            }
            throw error
        }
        AppLog.log("[ChatService] Fetched %d saved handshakes from self-stash", savedHandshakes.count)

        for stash in savedHandshakes {
            guard let stashedData = stash.stashedData else { continue }
            // Decrypt the stashed data on background thread to get our alias and contact info
            if let savedData = await decryptSelfStash(stashedData, privateKey: privKey) {
                let contact = savedData.contactAddress
                let alias = savedData.ourAlias
                if !contact.isEmpty && !alias.isEmpty {
                    AppLog.log("[ChatService] Saved handshake: contact=%@, ourAlias=%@, theirAlias=%@",
                          String(contact.suffix(10)), alias, savedData.theirAlias ?? "nil")
                    addOurAlias(alias, for: contact, blockTime: stash.blockTime)
                    if let theirAlias = savedData.theirAlias, !theirAlias.isEmpty {
                        addConversationAlias(theirAlias, for: contact, blockTime: stash.blockTime)
                    }
                    // Also derive and store deterministic routing state from partner address
                    ensureRoutingState(for: contact, privateKey: privKey)
                } else if !contact.isEmpty {
                    // Even if legacy alias is empty, derive deterministic from address
                    ensureRoutingState(for: contact, privateKey: privKey)
                } else {
                    AppLog.log("[ChatService] Saved handshake missing contact or alias")
                }
            }
        }
    }

    /// Per-phase retry budget for fetches running INSIDE a sync cycle. `fetchNewMessages`
    /// holds `isSyncInProgress` (which gates the foreground contact sweep) and, via
    /// `maybeRunCatchUpSync`, `catchUpSyncInFlight` for the whole cycle INCLUDING every retry
    /// backoff sleep - so a phase burning the default 8-attempt budget (~60s of sleeps) on a
    /// persistently failing endpoint starves the sweep for a minute per cycle, every cycle.
    /// 3 attempts = initial try + 1s + 2s backoff: enough to absorb a transient blip, cheap
    /// enough (~3s) that a broken endpoint barely delays the cycle. The cycle cadence itself
    /// (catch-up syncs, fallback poll, sweep) is the real retry loop for persistent failures;
    /// un-advanced per-object cursors mean nothing is lost by giving up early. Chosen over
    /// releasing `isSyncInProgress` across backoff sleeps (the flag also drives Core Data
    /// write batching and resubscription deferral, so toggling it mid-cycle would change save
    /// semantics) and over exempting the sweep from the gate (which would let the sweep and
    /// the full contextual fetch hit the indexer concurrently in the healthy case too).
    /// Bootstrap handshake fetches keep the default 8: nothing else can deliver until they
    /// succeed, and the sweep is gated off until the initial sync finishes anyway.
    static let syncPhaseMaxRetryAttempts = 3

    /// Retry with exponential backoff, bounded by `maxAttempts` (~75s of trying at the
    /// defaults). This must NOT retry forever: `fetchNewMessages` holds `isSyncInProgress`
    /// (and, via `maybeRunCatchUpSync`, `catchUpSyncInFlight`) across these calls, and both
    /// flags gate every other delivery backstop - the foreground contact sweep skips while a
    /// sync is "in progress" and future catch-up syncs skip while one is "in flight". An
    /// unbounded retry on a persistently failing endpoint (indexer 5xx on one query, DPI,
    /// decode error) therefore used to wedge those flags permanently, starving all live
    /// message delivery except the open-chat poll - exactly the "messages only appear when I
    /// open the chat" failure. Giving up returns nil; callers treat nil as "skip this phase
    /// for this cycle" (see `fetchNewMessages`) - the phase's cursor doesn't advance and the
    /// remaining phases still run, so the fallback poll / sweep / next catch-up simply retry
    /// the missed window later. Sync-cycle phases pass `syncPhaseMaxRetryAttempts`.
    func retryUntilSuccess<T>(
        label: String,
        initialDelayNs: UInt64 = 1_000_000_000,
        maxDelayNs: UInt64 = 15_000_000_000,
        maxAttempts: Int = 8,
        operation: @escaping () async throws -> T
    ) async -> T? {
        var attempt = 0
        var delay = initialDelayNs

        while !Task.isCancelled {
            do {
                return try await operation()
            } catch {
                attempt += 1
                if attempt >= maxAttempts {
                    AppLog.log("[ChatService] %@ failed (attempt %d): %@. Giving up until the next sync",
                          label, attempt, error.localizedDescription)
                    return nil
                }
                let delaySeconds = Double(delay) / 1_000_000_000.0
                AppLog.log("[ChatService] %@ failed (attempt %d): %@. Retrying in %.1fs",
                      label, attempt, error.localizedDescription, delaySeconds)
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, maxDelayNs)
            }
        }

        AppLog.log("[ChatService] %@ cancelled", label)
        return nil
    }

    static func handleDpiPaginationFailure(_ error: Error, context: String) -> Bool {
        if case KasiaAPIClientError.dpiPaginationExhausted(let endpoint) = error {
            AppLog.log("[ChatService] DPI pagination exhausted for %@ (%@)", endpoint, context)
            MessageStore.shared.markDpiCorruptionWarning(endpoint: endpoint)
            return true
        }
        return false
    }

    func beginChatFetch(_ address: String) {
        let count = (chatFetchCounts[address] ?? 0) + 1
        chatFetchCounts[address] = count
        if count == 1 {
            chatFetchFailed.remove(address)
        }
    }

    func markChatFetchLoading(_ address: String) {
        // Show spinner only when there is actual payload work to parse/add.
        if chatFetchCounts[address] != nil {
            chatFetchStates[address] = .loading
        }
    }

    func endChatFetch(_ address: String, success: Bool) {
        if !success {
            chatFetchFailed.insert(address)
        }
        let nextCount = (chatFetchCounts[address] ?? 1) - 1
        if nextCount <= 0 {
            chatFetchCounts.removeValue(forKey: address)
            if chatFetchFailed.contains(address) {
                chatFetchStates[address] = .failed
            } else {
                chatFetchStates.removeValue(forKey: address)
            }
        } else {
            chatFetchCounts[address] = nextCount
        }
    }

    /// Caps how many contacts' incoming/outgoing contextual fetches run at once. Bounded rather
    /// than unlimited so a large contact list doesn't fire dozens of simultaneous indexer
    /// requests at once - just enough overlap to hide per-request network latency.
    private static let contextualFetchConcurrencyLimit = 6

    func fetchContextualMessages(
        myAddress: String,
        privateKey: Data?,
        fallbackSince: UInt64,
        nowMs: UInt64
    ) async -> Bool {
        // Don't fetch/store this wallet's conversation history if it's no longer the active wallet.
        guard isActiveWallet(myAddress) else { return false }
        // Self-chat ("Note to Self"): seed routing state + a contact for your own address (unless
        // you deleted it) so your self→self notes get swept and there's an entry point in the list.
        if !contactsManager.isAddressDeleted(myAddress) {
            ensureRoutingState(for: myAddress, privateKey: privateKey)
            _ = contactsManager.getOrCreateContact(address: myAddress)
        }
        // Build contact set from routing states (preferred) + legacy aliases (fallback)
        let allContactAddresses = Array(Set(routingStates.keys).union(conversationAliases.keys))
        AppLog.log("%@", "[ChatService] Fetching contextual messages for \(allContactAddresses.count) contacts")

        // Fetch INCOMING messages (from contacts to us). Previously this was one contact at a
        // time - with N contacts that's N sequential network round-trips, which is why
        // pull-to-refresh could sit spinning for a long time on accounts with many chats.
        // Fetching several contacts concurrently overlaps that network latency instead.
        let incomingSucceeded = await fetchContactsConcurrently(
            allContactAddresses,
            limit: Self.contextualFetchConcurrencyLimit
        ) { [self] contactAddress in
            await fetchIncomingContextualMessages(
                contactAddress: contactAddress,
                myAddress: myAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
        }
        // Phase isolation: a failed incoming pass (some contact exhausted its retry budget)
        // must not starve the outgoing pass - each alias advances only its own cursor, so
        // running the rest is always safe. Only bail if the wallet changed mid-fetch.
        guard isActiveWallet(myAddress) else { return false }

        // Fetch OUTGOING messages (from us to contacts)
        let allOutgoingAddresses = Array(Set(routingStates.keys).union(ourAliases.keys))
        let outgoingSucceeded = await fetchContactsConcurrently(
            allOutgoingAddresses,
            limit: Self.contextualFetchConcurrencyLimit
        ) { [self] contactAddress in
            await fetchOutgoingContextualMessages(
                contactAddress: contactAddress,
                myAddress: myAddress,
                privateKey: privateKey,
                fallbackSince: fallbackSince,
                nowMs: nowMs
            )
        }
        return incomingSucceeded && outgoingSucceeded
    }

    /// Runs `operation` over `addresses` with at most `limit` running concurrently, starting the
    /// next one as soon as a slot frees up. Every address is still attempted even after one
    /// fails; the return value is `false` if ANY operation returned `false` (retry budget
    /// exhausted, cancellation, or wallet switch), so the caller can withhold cycle-level
    /// success without any contact starving another.
    private func fetchContactsConcurrently(
        _ addresses: [String],
        limit: Int,
        operation: @escaping (String) async -> Bool
    ) async -> Bool {
        guard !addresses.isEmpty else { return true }
        var allSucceeded = true
        await withTaskGroup(of: Bool.self) { group in
            var iterator = addresses.makeIterator()

            func startNext() {
                guard let address = iterator.next() else { return }
                group.addTask { await operation(address) }
            }

            for _ in 0..<min(limit, addresses.count) {
                startNext()
            }

            while let result = await group.next() {
                if !result { allSucceeded = false }
                startNext()
            }
        }
        return allSucceeded
    }

    /// Fetches incoming contextual messages for a single contact across all its known incoming
    /// aliases. Returns `false` when any alias's fetch exhausted its retry budget or was
    /// cancelled, or the wallet changed mid-fetch; a failed alias is skipped (its cursor stays
    /// put) and the remaining aliases are still fetched.
    private func fetchIncomingContextualMessages(
        contactAddress: String,
        myAddress: String,
        privateKey: Data?,
        fallbackSince: UInt64,
        nowMs: UInt64
    ) async -> Bool {
        guard !contactsManager.isAddressDeleted(contactAddress) else { return true }
        let aliases = incomingAliases(for: contactAddress)
        guard !aliases.isEmpty else { return true }
        beginChatFetch(contactAddress)
        var contactSuccess = true
        defer { endChatFetch(contactAddress, success: contactSuccess) }
        for alias in aliases {
            let syncObjectKey = contextualSyncObjectKey(
                direction: "in",
                queryAddress: contactAddress,
                alias: alias,
                contactAddress: contactAddress
            )
            let startBlockTime = syncStartBlockTime(
                for: syncObjectKey,
                fallbackBlockTime: fallbackSince,
                nowMs: nowMs
            )
            let effectiveSince = applyMessageRetention(to: startBlockTime)
            let fetchKey = contextualFetchKey(address: contactAddress, alias: alias, limit: 50, since: effectiveSince)
            guard beginContextualFetch(fetchKey) else {
                AppLog.log("[ChatService] Contextual fetch in-flight, skipping incoming %@",
                      String(contactAddress.suffix(10)))
                continue
            }
            defer { endContextualFetch(fetchKey) }
            guard let messages = await retryUntilSuccess(
                label: "fetch incoming contextual messages from \(contactAddress.suffix(10))",
                maxAttempts: Self.syncPhaseMaxRetryAttempts,
                operation: { [apiClient] in
                    do {
                        return try await apiClient.getContextualMessagesBySender(
                            address: contactAddress,
                            alias: alias,
                            limit: 50,
                            blockTime: effectiveSince
                        )
                    } catch {
                        if ChatService.handleDpiPaginationFailure(error, context: "incoming contextual messages") {
                            return []
                        }
                        throw error
                    }
                }
            ) else {
                contactSuccess = false
                continue  // Skip this alias for this cycle; still try the contact's other aliases.
            }
            advanceSyncCursor(for: syncObjectKey, maxBlockTime: messages.compactMap { $0.blockTime }.max())

            if !messages.isEmpty {
                markChatFetchLoading(contactAddress)
            }
            AppLog.log("%@", "[ChatService] Got \(messages.count) incoming contextual messages from \(contactAddress)")

            for contextMsg in messages {
                var content = "[Encrypted message]"
                if let privKey = privateKey {
                    // Decrypt on background thread to avoid blocking UI
                    if let decrypted = await decryptContextualMessage(contextMsg.messagePayload, privateKey: privKey) {
                        content = decrypted
                    }
                }
                let msgType = messageType(for: content)

                let message = ChatMessage(
                    txId: contextMsg.txId,
                    senderAddress: contextMsg.sender,
                    receiverAddress: myAddress,
                    content: content,
                    timestamp: Date(timeIntervalSince1970: TimeInterval((contextMsg.blockTime ?? 0) / 1000)),
                    blockTime: contextMsg.blockTime ?? 0,
                    acceptingBlock: contextMsg.acceptingBlock,
                    // Self-chat: a note you sent to yourself is outgoing on every device.
                    isOutgoing: contactAddress == myAddress,
                    messageType: msgType
                )

                // A wallet switch may have happened during the fetch await above; don't append
                // this wallet's history to the now-active wallet's conversation list.
                guard isActiveWallet(myAddress) else { return false }
                addMessageToConversation(message, contactAddress: contactAddress)

                // Capability detection: if message arrived on deterministic alias, mark peer
                if let state = routingStates[contactAddress], alias == state.deterministicMyAlias {
                    if !state.peerSupportsDeterministic {
                        routingStates[contactAddress]?.peerSupportsDeterministic = true
                    }
                    routingStates[contactAddress]?.lastDeterministicIncomingAtMs = contextMsg.blockTime
                }

                if let blockTime = contextMsg.blockTime, blockTime > lastPollTime {
                    updateLastPollTime(blockTime)
                }
            }
        }
        return contactSuccess
    }

    /// Fetches outgoing contextual messages for a single contact across all its known outgoing
    /// aliases. Returns `false` when any alias's fetch exhausted its retry budget or was
    /// cancelled; a failed alias is skipped (its cursor stays put) and the remaining aliases
    /// are still fetched.
    private func fetchOutgoingContextualMessages(
        contactAddress: String,
        myAddress: String,
        privateKey: Data?,
        fallbackSince: UInt64,
        nowMs: UInt64
    ) async -> Bool {
        guard !contactsManager.isAddressDeleted(contactAddress) else { return true }
        // Self-chat: skip the outgoing scan. Self→self messages are already returned with real
        // decrypted content by the INCOMING scan (marked outgoing there); the outgoing scan would
        // only race in a "📤 Sent via another device" placeholder that hides the real note.
        guard contactAddress != myAddress else { return true }
        let aliasSet = outgoingFetchAliases(for: contactAddress)
        guard !aliasSet.isEmpty else { return true }
        beginChatFetch(contactAddress)
        var contactSuccess = true
        defer { endChatFetch(contactAddress, success: contactSuccess) }
        for ourAlias in aliasSet {
            let syncObjectKey = contextualSyncObjectKey(
                direction: "out",
                queryAddress: myAddress,
                alias: ourAlias,
                contactAddress: contactAddress
            )
            let startBlockTime = syncStartBlockTime(
                for: syncObjectKey,
                fallbackBlockTime: fallbackSince,
                nowMs: nowMs
            )
            let effectiveSince = applyMessageRetention(to: startBlockTime)
            let fetchKey = contextualFetchKey(address: myAddress, alias: ourAlias, limit: 50, since: effectiveSince)
            guard beginContextualFetch(fetchKey) else {
                AppLog.log("[ChatService] Contextual fetch in-flight, skipping outgoing %@",
                      String(contactAddress.suffix(10)))
                continue
            }
            defer { endContextualFetch(fetchKey) }
            guard let messages = await retryUntilSuccess(
                label: "fetch outgoing contextual messages to \(contactAddress.suffix(10))",
                maxAttempts: Self.syncPhaseMaxRetryAttempts,
                operation: { [apiClient] in
                    do {
                        return try await apiClient.getContextualMessagesBySender(
                            address: myAddress,
                            alias: ourAlias,
                            limit: 50,
                            blockTime: effectiveSince
                        )
                    } catch {
                        if ChatService.handleDpiPaginationFailure(error, context: "outgoing contextual messages") {
                            return []
                        }
                        throw error
                    }
                }
            ) else {
                contactSuccess = false
                continue  // Skip this alias for this cycle; still try the contact's other aliases.
            }
            advanceSyncCursor(for: syncObjectKey, maxBlockTime: messages.compactMap { $0.blockTime }.max())

            if !messages.isEmpty {
                markChatFetchLoading(contactAddress)
            }
            let sortedMessages = messages.sorted {
                let lhsTime = $0.blockTime ?? 0
                let rhsTime = $1.blockTime ?? 0
                if lhsTime == rhsTime {
                    return $0.txId < $1.txId
                }
                return lhsTime < rhsTime
            }

            AppLog.log("%@", "[ChatService] Got \(sortedMessages.count) outgoing contextual messages to \(contactAddress)")

            for contextMsg in sortedMessages {
                // A reaction's own transaction never gets a CDMessage row - the device that
                // actually decrypted it converted it straight into a CDReaction and returned
                // before ever creating a message (see addMessageToConversation). Re-discovering
                // that same outgoing tx here (this wallet's own catch-up sync) would otherwise
                // create a "📤 Sent via another device" placeholder that can never resolve, since
                // no real message content will ever arrive for it - skip it outright instead.
                if await isKnownReaction(txId: contextMsg.txId) {
                    continue
                }
                // Outgoing messages are encrypted for the recipient, we can't decrypt them
                // Check if we have this message stored locally with content
                let existingMessage = await findLocalMessage(txId: contextMsg.txId)
                // This whole loop attributes BY ALIAS: everything the indexer returns for
                // (sender = us, alias = X) is filed under whichever contact has X in its outgoing
                // set. That is only sound while an alias names exactly one conversation, and
                // nothing enforces that - which is why the UTXO fast path already refuses an
                // alias that belongs to someone else (`shouldAttemptSelfStashDecryption`).
                //
                // When we hold the message locally we know its real conversation and no guess is
                // involved. When we do not, all this can produce is a "Sent via another device"
                // placeholder - so if the alias is ambiguous, skip it rather than write a message
                // we sent to one person into the thread of another.
                if existingMessage == nil,
                   outgoingAliasBelongsToAnotherContact(ourAlias, excluding: contactAddress) {
                    AppLog.log("[ChatService] Outgoing %@: alias %@ is registered to more than one contact - not attributing to %@",
                          String(contextMsg.txId.prefix(12)), ourAlias, String(contactAddress.suffix(10)))
                    continue
                }
                let content = existingMessage?.content ?? ChatMessage.sentViaOtherDevicePlaceholder
                let msgType = existingMessage?.messageType ?? messageType(for: content)

                let message = ChatMessage(
                    txId: contextMsg.txId,
                    senderAddress: myAddress,
                    receiverAddress: contactAddress,
                    content: content,
                    timestamp: Date(timeIntervalSince1970: TimeInterval((contextMsg.blockTime ?? 0) / 1000)),
                    blockTime: contextMsg.blockTime ?? 0,
                    acceptingBlock: contextMsg.acceptingBlock,
                    isOutgoing: true,
                    messageType: msgType
                )

                // A wallet switch may have happened during the fetch await above; don't append
                // this wallet's history to the now-active wallet's conversation list.
                guard isActiveWallet(myAddress) else { return false }
                addMessageToConversation(message, contactAddress: contactAddress)
                if let blockTime = contextMsg.blockTime, blockTime > lastPollTime {
                    updateLastPollTime(blockTime)
                }
            }
        }
        return contactSuccess
    }

    func fetchContextualMessagesForActive(
        contactAddress: String,
        myAddress: String,
        privateKey: Data?,
        fallbackSince: UInt64,
        nowMs: UInt64,
        forceExactBlockTime: Bool = false
    ) async -> Bool {
        // Don't fetch/store this wallet's conversation history if it's no longer the active wallet.
        guard isActiveWallet(myAddress) else { return false }
        if contactsManager.isAddressDeleted(contactAddress) {
            return true
        }
        beginChatFetch(contactAddress)
        var contactSuccess = true
        defer { endChatFetch(contactAddress, success: contactSuccess) }
        // Incoming from contact (use routing state aliases + legacy fallback)
        let inAliases = incomingAliases(for: contactAddress)
        if !inAliases.isEmpty {
            for alias in inAliases {
                let syncObjectKey = contextualSyncObjectKey(
                    direction: "in",
                    queryAddress: contactAddress,
                    alias: alias,
                    contactAddress: contactAddress
                )
                let startBlockTime: UInt64
                if forceExactBlockTime {
                    startBlockTime = fallbackSince
                } else {
                    startBlockTime = syncStartBlockTime(
                        for: syncObjectKey,
                        fallbackBlockTime: fallbackSince,
                        nowMs: nowMs
                    )
                }
                let effectiveSince = forceExactBlockTime ? startBlockTime : applyMessageRetention(to: startBlockTime)
                let fetchKey = contextualFetchKey(address: contactAddress, alias: alias, limit: 50, since: effectiveSince)
                guard beginContextualFetch(fetchKey) else {
                    AppLog.log("[ChatService] Contextual fetch in-flight, skipping active incoming %@",
                          String(contactAddress.suffix(10)))
                    continue
                }
                defer { endContextualFetch(fetchKey) }
                guard let messages = await retryUntilSuccess(
                    label: "fetch incoming contextual messages (active) from \(contactAddress.suffix(10))",
                    maxAttempts: Self.syncPhaseMaxRetryAttempts,
                    operation: { [apiClient] in
                        do {
                            return try await apiClient.getContextualMessagesBySender(
                                address: contactAddress,
                                alias: alias,
                                limit: 50,
                                blockTime: effectiveSince
                            )
                        } catch {
                            if ChatService.handleDpiPaginationFailure(error, context: "active incoming contextual messages") {
                                return []
                            }
                            throw error
                        }
                    }
            ) else {
                contactSuccess = false
                continue  // Skip this alias for this cycle; still try the remaining aliases.
                }
                if !forceExactBlockTime {
                    advanceSyncCursor(for: syncObjectKey, maxBlockTime: messages.compactMap { $0.blockTime }.max())
                }

                if !messages.isEmpty {
                    markChatFetchLoading(contactAddress)
                }
                for contextMsg in messages {
                    var content = "[Encrypted message]"
                    if let privKey = privateKey {
                        // Decrypt on background thread to avoid blocking UI
                        if let decrypted = await decryptContextualMessage(contextMsg.messagePayload, privateKey: privKey) {
                            content = decrypted
                        }
                    }

                    let message = ChatMessage(
                        txId: contextMsg.txId,
                        senderAddress: contextMsg.sender,
                        receiverAddress: myAddress,
                        content: content,
                        timestamp: Date(timeIntervalSince1970: TimeInterval((contextMsg.blockTime ?? 0) / 1000)),
                        blockTime: contextMsg.blockTime ?? 0,
                        acceptingBlock: contextMsg.acceptingBlock,
                        // Self-chat: a note you sent to yourself is outgoing on every device.
                        isOutgoing: contactAddress == myAddress,
                        messageType: .contextual
                    )

                    addMessageToConversation(message, contactAddress: contactAddress)

                    // Capability detection: if message arrived on deterministic alias, mark peer
                    if let state = routingStates[contactAddress], alias == state.deterministicMyAlias {
                        if !state.peerSupportsDeterministic {
                            routingStates[contactAddress]?.peerSupportsDeterministic = true
                        }
                        routingStates[contactAddress]?.lastDeterministicIncomingAtMs = contextMsg.blockTime
                    }

                    if let blockTime = contextMsg.blockTime, blockTime > lastPollTime {
                        updateLastPollTime(blockTime)
                    }
                }
            }
        }

        // Outgoing from us (use routing state aliases + legacy fallback). Skipped for self-chat —
        // the incoming scan above already returns self→self notes with real content marked
        // outgoing, so the outgoing scan would only race in a hiding placeholder.
        let outAliases = contactAddress == myAddress ? [] : outgoingFetchAliases(for: contactAddress)
        if !outAliases.isEmpty {
            for ourAlias in outAliases {
                let syncObjectKey = contextualSyncObjectKey(
                    direction: "out",
                    queryAddress: myAddress,
                    alias: ourAlias,
                    contactAddress: contactAddress
                )
                let startBlockTime: UInt64
                if forceExactBlockTime {
                    startBlockTime = fallbackSince
                } else {
                    startBlockTime = syncStartBlockTime(
                        for: syncObjectKey,
                        fallbackBlockTime: fallbackSince,
                        nowMs: nowMs
                    )
                }
                let effectiveSince = forceExactBlockTime ? startBlockTime : applyMessageRetention(to: startBlockTime)
                let fetchKey = contextualFetchKey(address: myAddress, alias: ourAlias, limit: 50, since: effectiveSince)
                guard beginContextualFetch(fetchKey) else {
                    AppLog.log("[ChatService] Contextual fetch in-flight, skipping active outgoing %@",
                          String(contactAddress.suffix(10)))
                    continue
                }
                defer { endContextualFetch(fetchKey) }
                guard let messages = await retryUntilSuccess(
                    label: "fetch outgoing contextual messages (active) to \(contactAddress.suffix(10))",
                    maxAttempts: Self.syncPhaseMaxRetryAttempts,
                    operation: { [apiClient] in
                        do {
                            return try await apiClient.getContextualMessagesBySender(
                                address: myAddress,
                                alias: ourAlias,
                                limit: 50,
                                blockTime: effectiveSince
                            )
                        } catch {
                            if ChatService.handleDpiPaginationFailure(error, context: "active outgoing contextual messages") {
                                return []
                            }
                            throw error
                        }
                    }
            ) else {
                contactSuccess = false
                continue  // Skip this alias for this cycle; still try the remaining aliases.
                }
                if !forceExactBlockTime {
                    advanceSyncCursor(for: syncObjectKey, maxBlockTime: messages.compactMap { $0.blockTime }.max())
                }

                if !messages.isEmpty {
                    markChatFetchLoading(contactAddress)
                }
                let sortedMessages = messages.sorted {
                    let lhsTime = $0.blockTime ?? 0
                    let rhsTime = $1.blockTime ?? 0
                    if lhsTime == rhsTime {
                        return $0.txId < $1.txId
                    }
                    return lhsTime < rhsTime
                }

                for contextMsg in sortedMessages {
                    let existingMessage = await findLocalMessage(txId: contextMsg.txId)
                    // Same by-alias attribution, same guard - see the sibling loop in
                    // `fetchOutgoingContextualMessages` for why an ambiguous alias must not
                    // produce a placeholder in a conversation it may not belong to.
                    if existingMessage == nil,
                       outgoingAliasBelongsToAnotherContact(ourAlias, excluding: contactAddress) {
                        AppLog.log("[ChatService] Outgoing %@: alias %@ is registered to more than one contact - not attributing to %@",
                              String(contextMsg.txId.prefix(12)), ourAlias, String(contactAddress.suffix(10)))
                        continue
                    }
                    let content = existingMessage?.content ?? ChatMessage.sentViaOtherDevicePlaceholder

                    let message = ChatMessage(
                        txId: contextMsg.txId,
                        senderAddress: myAddress,
                        receiverAddress: contactAddress,
                        content: content,
                        timestamp: Date(timeIntervalSince1970: TimeInterval((contextMsg.blockTime ?? 0) / 1000)),
                        blockTime: contextMsg.blockTime ?? 0,
                        acceptingBlock: contextMsg.acceptingBlock,
                        isOutgoing: true,
                        messageType: .contextual
                    )

                    addMessageToConversation(message, contactAddress: contactAddress)
                    if let blockTime = contextMsg.blockTime, blockTime > lastPollTime {
                        updateLastPollTime(blockTime)
                    }
                }
            }
        }

        return contactSuccess
    }

    /// Fetch contextual messages with polling (triggered by UTXO notification)
    /// Algorithm: wait 1500ms initial delay, then poll every 500ms until we get new messages (max 10 attempts)
    func fetchContextualMessagesFromContactWithRetry(contactAddress: String, myAddress: String, privateKey: Data) async {
        // Initial delay to give indexer time to process
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1500ms

        let maxAttempts = 20
        let pollIntervalNs: UInt64 = 500_000_000  // 500ms

        beginChatFetch(contactAddress)
        var completedSuccessfully = false
        defer {
            endChatFetch(contactAddress, success: completedSuccessfully)
        }
        for attempt in 1...maxAttempts {
            let result = await fetchContextualMessagesFromContact(
                contactAddress: contactAddress,
                myAddress: myAddress,
                privateKey: privateKey
            )

            switch result {
            case .success(let added):
                if added, attempt > 1 {
                    AppLog.log("[ChatService] Found messages from %@ on attempt %d", String(contactAddress.suffix(10)), attempt)
                }
                completedSuccessfully = true
                return
            case .failure:
                break
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: pollIntervalNs)
            }
        }

        AppLog.log("[ChatService] No new messages from %@ after %d attempts", String(contactAddress.suffix(10)), maxAttempts)
    }

    /// Fetch contextual messages from a specific contact (triggered by UTXO notification)
    /// Returns true if any new messages were added.
    /// `reorgRewindMs`: high-frequency live-tail callers (open-chat poll, foreground sweep)
    /// pass `liveTailReorgBufferMs` to avoid re-downloading a 10-minute window every few
    /// seconds; catch-up/notification callers omit it for the full reorg buffer.
    @discardableResult
    func fetchContextualMessagesFromContact(contactAddress: String, myAddress: String, privateKey: Data, reorgRewindMs: UInt64? = nil) async -> ContactFetchResult {
        // Get incoming aliases for this contact (deterministic + legacy)
        let aliases = incomingAliases(for: contactAddress)
        guard !aliases.isEmpty else {
            AppLog.log("[ChatService] No alias for contact %@, cannot fetch contextual messages", String(contactAddress.suffix(10)))
            return .success(added: false)
        }
        let nowMs = currentTimeMs()
        let fallbackSince = lastPollTime > syncReorgBufferMs ? lastPollTime - syncReorgBufferMs : lastPollTime

        var newMessagesAdded = false

        do {
            for alias in aliases {
                let syncObjectKey = contextualSyncObjectKey(
                    direction: "in",
                    queryAddress: contactAddress,
                    alias: alias,
                    contactAddress: contactAddress
                )
                let startBlockTime = syncStartBlockTime(
                    for: syncObjectKey,
                    fallbackBlockTime: fallbackSince,
                    nowMs: nowMs,
                    rewindMs: reorgRewindMs
                )
                let effectiveSince = applyMessageRetention(to: startBlockTime)
                let fetchKey = contextualFetchKey(address: contactAddress, alias: alias, limit: 10, since: effectiveSince)
                guard beginContextualFetch(fetchKey) else {
                    AppLog.log("[ChatService] Contextual fetch in-flight, skipping contact %@",
                          String(contactAddress.suffix(10)))
                    continue
                }
                defer { endContextualFetch(fetchKey) }

                // Fetch recent messages from this contact
                let messages = try await apiClient.getContextualMessagesBySender(
                    address: contactAddress,
                    alias: alias,
                    limit: 10,  // Only fetch recent messages
                    blockTime: effectiveSince
                )
                advanceSyncCursor(for: syncObjectKey, maxBlockTime: messages.compactMap { $0.blockTime }.max())

                if !messages.isEmpty {
                    markChatFetchLoading(contactAddress)
                }
                for contextMsg in messages {
                    // Skip if already have this message
                    if await findLocalMessage(txId: contextMsg.txId) != nil {
                        continue
                    }

                    var content = "[Encrypted message]"
                    if let decrypted = await decryptContextualMessage(contextMsg.messagePayload, privateKey: privateKey) {
                        content = decrypted
                    }

                    let message = ChatMessage(
                        txId: contextMsg.txId,
                        senderAddress: contextMsg.sender,
                        receiverAddress: myAddress,
                        content: content,
                        timestamp: Date(timeIntervalSince1970: TimeInterval((contextMsg.blockTime ?? 0) / 1000)),
                        blockTime: contextMsg.blockTime ?? 0,
                        acceptingBlock: contextMsg.acceptingBlock,
                        // Self-chat: a message you sent to yourself is outgoing on every device.
                        isOutgoing: contactAddress == myAddress,
                        messageType: .contextual
                    )

                    addMessageToConversation(message, contactAddress: contactAddress)
                    newMessagesAdded = true

                    // Capability detection
                    if let state = routingStates[contactAddress], alias == state.deterministicMyAlias {
                        if !state.peerSupportsDeterministic {
                            routingStates[contactAddress]?.peerSupportsDeterministic = true
                        }
                        routingStates[contactAddress]?.lastDeterministicIncomingAtMs = contextMsg.blockTime
                    }

                    if let blockTime = contextMsg.blockTime, blockTime > lastPollTime {
                        updateLastPollTime(blockTime)
                    }
                }
            }

            if newMessagesAdded {
                saveMessages()
                AppLog.log("[ChatService] New contextual messages added from contact %@", String(contactAddress.suffix(10)))
            }

            return .success(added: newMessagesAdded)

        } catch {
            if ChatService.handleDpiPaginationFailure(error, context: "contact contextual messages") {
                return .failure
            }
            AppLog.log("[ChatService] Failed to fetch contextual messages from contact %@: %@",
                  String(contactAddress.suffix(10)), error.localizedDescription)
            return .failure
        }
    }

    func contextualFetchKey(address: String, alias: String, limit: Int, since: UInt64) -> String {
        "\(address)|\(alias)|\(limit)|\(since)"
    }

    func beginContextualFetch(_ key: String) -> Bool {
        if contextualFetchInFlight.contains(key) {
            return false
        }
        contextualFetchInFlight.insert(key)
        return true
    }

    func endContextualFetch(_ key: String) {
        contextualFetchInFlight.remove(key)
    }

    func processPayments(
        _ payments: [PaymentResponse],
        isOutgoing: Bool,
        myAddress: String,
        privateKey: Data? = nil,
        deliveryStatus: ChatMessage.DeliveryStatus = .sent
    ) async {
        let direction = isOutgoing ? "outgoing" : "incoming"
        AppLog.log("[ChatService] === PROCESSING %d %@ PAYMENTS ===", payments.count, direction)

        var needsFullSync = false

        for payment in payments {
            // Stop if the user switched/imported a different wallet mid-loop - the remaining
            // payments belong to `myAddress`, not the now-active wallet. See isActiveWallet.
            guard isActiveWallet(myAddress) else { return }
            if isSuppressedPaymentTxId(payment.txId) {
                _ = await addKNSTransferMessageFromHintIfNeeded(
                    txId: payment.txId,
                    myAddress: myAddress,
                    blockTimeMs: payment.blockTime,
                    acceptingBlock: payment.acceptingBlock
                )
                let normalizedTxId = payment.txId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                _ = removeSuppressedPaymentMessages(txIds: [normalizedTxId])
                continue
            }

            if !isOutgoing, let amount = payment.amount, amount > 0 {
                incomingResolutionAmountHints[payment.txId] = amount
            }

            // Determine contact address
            var contactAddress: String
            if isOutgoing {
                contactAddress = payment.receiver
            } else {
                // For incoming payments, sender might need resolution
                if payment.sender == "pending_resolution" || payment.sender.isEmpty || !isValidKaspaAddress(payment.sender) {
                    // Try one more resolution attempt (in case API is now available)
                    if let resolved = await resolveSenderAddress(
                        sender: "",
                        txId: payment.txId,
                        receiver: myAddress
                    ) {
                        contactAddress = resolved
                        AppLog.log("%@", "[ChatService] Resolved sender for \(payment.txId.prefix(16))...: \(contactAddress.suffix(10))")
                    } else {
                        // Still couldn't resolve - try to get any input address from the transaction
                        // as a temporary solution, then schedule full sync for proper resolution
                        if let tempSender = await fetchAnyInputAddress(txId: payment.txId, excludeAddress: myAddress) {
                            contactAddress = tempSender
                            AppLog.log("[ChatService] Using temporary sender for %@: %@", String(payment.txId.prefix(16)), String(tempSender.suffix(20)))
                            needsFullSync = true
                        } else {
                            AppLog.log("[ChatService] Sender completely unresolved for %@, scheduling full sync", String(payment.txId.prefix(16)))
                            needsFullSync = true
                            continue
                        }
                    }
                } else {
                    contactAddress = payment.sender
                }
            }

            // Skip if we couldn't determine the contact address
            AppLog.log("[ChatService] Payment %@ - contactAddress: %@, myAddress: %@, match: %d",
                  String(payment.txId.prefix(16)),
                  String(contactAddress.suffix(20)),
                  String(myAddress.suffix(20)),
                  contactAddress == myAddress ? 1 : 0)

            if !isOutgoing, let existing = await findLocalMessage(txId: payment.txId) {
                if existing.isOutgoing {
                    // Don't replace a promoted outgoing payment with an incoming classification
                    // from an async resolve - the outgoing classification is authoritative
                    if existing.messageType == .payment && existing.deliveryStatus != .pending {
                        AppLog.log("[ChatService] Skipping incoming reclassification for %@ - already promoted as outgoing payment",
                              String(payment.txId.prefix(16)))
                        continue
                    }
                    AppLog.log("[ChatService] Replacing outgoing message for %@ with incoming payment",
                          String(payment.txId.prefix(16)))
                    removeMessage(txId: payment.txId)
                } else {
                    let shouldPromoteStatus = deliveryStatus.priority > existing.deliveryStatus.priority
                    let shouldKeepPending = incomingResolutionPendingTxIds.contains(payment.txId) && deliveryStatus == .sent
                    if shouldPromoteStatus && !shouldKeepPending {
                        if updateIncomingPaymentStatus(txId: payment.txId, deliveryStatus: deliveryStatus, content: paymentContent(payment, isOutgoing: isOutgoing)) {
                            saveMessages()
                        }
                        if deliveryStatus == .sent {
                            clearIncomingResolutionTracking(txId: payment.txId)
                        } else if deliveryStatus == .warning {
                            incomingResolutionWarningTxIds.insert(payment.txId)
                        }
                        continue
                    }
                    // Incoming already present.
                    continue
                }
            }

            if contactAddress.isEmpty || contactAddress == myAddress {
                AppLog.log("[ChatService] Skipping payment %@ - self-address detected", String(payment.txId.prefix(16)))
                continue
            }

            // Skip if this transaction already exists as a handshake message
            if let existingMsg = await findLocalMessage(txId: payment.txId), existingMsg.messageType == .handshake {
                AppLog.log("[ChatService] Skipping payment %@ - already exists as handshake", String(payment.txId.prefix(16)))
                continue
            }

            // Check if this payment is actually a handshake (REST API payload detection)
            if let payload = payment.messagePayload, !payload.isEmpty, isHandshakePayload(payload) {
                AppLog.log("[ChatService] Payment %@ has handshake payload - processing as handshake", String(payment.txId.prefix(16)))
                var handshakeContent = "[Handshake]"
                if !isOutgoing, let privKey = privateKey {
                    // For incoming handshakes, decrypt to extract alias
                    if let decrypted = await decryptHandshakePayload(payload, privateKey: privKey) {
                        handshakeContent = decrypted.isResponse == true
                            ? "[Request accepted]"
                            : "[Request to communicate]"
                        if let alias = decrypted.alias {
                            addConversationAlias(alias, for: contactAddress, blockTime: payment.blockTime)
                            AppLog.log("[ChatService] Extracted alias '%@' from payment-handshake by %@", alias, String(contactAddress.suffix(10)))
                        } else {
                            AppLog.log("[ChatService] Received deterministic (alias-less) payment-handshake from %@", String(contactAddress.suffix(10)))
                        }
                        if let convId = decrypted.conversationId {
                            conversationIds[contactAddress] = convId
                        }
                    }
                } else {
                    handshakeContent = "[Handshake sent]"
                }
                let handshakeMsg = ChatMessage(
                    txId: payment.txId,
                    senderAddress: isOutgoing ? payment.sender : contactAddress,
                    receiverAddress: payment.receiver,
                    content: handshakeContent,
                    timestamp: Date(timeIntervalSince1970: TimeInterval((payment.blockTime ?? 0) / 1000)),
                    blockTime: payment.blockTime ?? 0,
                    acceptingBlock: payment.acceptingBlock,
                    isOutgoing: isOutgoing,
                    messageType: .handshake
                )
                addMessageToConversation(handshakeMsg, contactAddress: contactAddress)
                if let blockTime = payment.blockTime, blockTime > lastPollTime {
                    updateLastPollTime(blockTime)
                }
                continue
            }

            if let payload = payment.messagePayload, !payload.isEmpty {
                if isContextualPayload(payload) {
                    AppLog.log("[ChatService] Payment %@ has contextual payload - skipping as payment", String(payment.txId.prefix(16)))
                    if let privateKey,
                       shouldAttemptSelfStashDecryption(payloadHex: payload, contactAddress: contactAddress),
                       let decrypted = await decryptContextualMessageFromRawPayload(payload, privateKey: privateKey) {
                        let message = ChatMessage(
                            txId: payment.txId,
                            senderAddress: isOutgoing ? payment.sender : contactAddress,
                            receiverAddress: payment.receiver,
                            content: decrypted,
                            timestamp: Date(timeIntervalSince1970: TimeInterval((payment.blockTime ?? 0) / 1000)),
                            blockTime: payment.blockTime ?? 0,
                            acceptingBlock: payment.acceptingBlock,
                            isOutgoing: isOutgoing,
                            messageType: messageType(for: decrypted)
                        )
                        addMessageToConversation(message, contactAddress: contactAddress)
                        if let blockTime = payment.blockTime, blockTime > lastPollTime {
                            updateLastPollTime(blockTime)
                        }
                    }
                    continue
                }

                if isSelfStashPayload(payload) {
                    AppLog.log("[ChatService] Payment %@ has self-stash payload - skipping", String(payment.txId.prefix(16)))
                    continue
                }
            }

            // Decode payment message
            var content = paymentContent(payment, isOutgoing: isOutgoing)

            // A plain KAS payment from an address we have NO contact for must not open a
            // chat with the stranger. Internal moves from our own spending chain surface
            // nowhere in chats; genuinely unknown senders collect in the SELF-chat (the
            // conversation with our own chatting address) with the sender noted in the
            // bubble. Wallet history and notifications are unaffected. Outgoing payments
            // (withdrawals from the chatting address) keep creating destination chats.
            var conversationAddress = contactAddress
            if !isOutgoing, contactsManager.getContact(byAddress: contactAddress) == nil {
                if WalletManager.shared.allSpendingAddresses().contains(contactAddress) {
                    AppLog.log("[ChatService] Skipping payment %@ - internal move from own spending chain", String(payment.txId.prefix(16)))
                    continue
                }
                conversationAddress = myAddress
                content = "\(content)\n\(AppLocalization.string("From:")) \(contactAddress)"
            }

            // Use resolved sender for incoming payments
            let resolvedSender = isOutgoing ? payment.sender : contactAddress

            if isOutgoing,
               updateOutgoingPendingMessageIfMatch(
                contactAddress: contactAddress,
                newTxId: payment.txId,
                content: content,
                messageType: .payment
               ) {
                saveMessages()
                if let blockTime = payment.blockTime, blockTime > lastPollTime {
                    updateLastPollTime(blockTime)
                }
                continue
            }

            let message = ChatMessage(
                txId: payment.txId,
                senderAddress: resolvedSender,
                receiverAddress: payment.receiver,
                content: content,
                timestamp: Date(timeIntervalSince1970: TimeInterval((payment.blockTime ?? 0) / 1000)),
                blockTime: payment.blockTime ?? 0,
                acceptingBlock: payment.acceptingBlock,
                isOutgoing: isOutgoing,
                messageType: .payment,
                deliveryStatus: deliveryStatus
            )

            addMessageToConversation(message, contactAddress: conversationAddress)

            if !isOutgoing {
                if deliveryStatus == .sent {
                    clearIncomingResolutionTracking(txId: payment.txId)
                } else if deliveryStatus == .warning {
                    incomingResolutionWarningTxIds.insert(payment.txId)
                } else if deliveryStatus == .pending {
                    incomingResolutionPendingTxIds.insert(payment.txId)
                }
            }

            // Update last poll time
            if let blockTime = payment.blockTime, blockTime > lastPollTime {
                updateLastPollTime(blockTime)
            }
        }

        // Trigger full sync if we have unresolved senders
        if needsFullSync {
            AppLog.log("[ChatService] Triggering full sync to resolve pending senders...")
            Task { @MainActor in
                // Small delay before full sync to let API propagate
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self.fetchNewMessages(forActiveOnly: nil)  // nil triggers full fetch
            }
        }
    }

    /// Find a locally stored message by transaction ID. `async` because the store fallback must
    /// NOT block the main thread - `ChatService` is `@MainActor` and this fires once per UTXO in a
    /// notification burst; a synchronous Core Data fetch here froze the app during initial sync
    /// (see `MessageStore.fetchMessage`). The in-memory scan below is the fast path and stays
    /// synchronous; only a miss awaits the background-context fetch.
    func findLocalMessage(txId: String) async -> ChatMessage? {
        for conversation in conversations {
            if let message = conversation.messages.first(where: { $0.txId == txId }) {
                return message
            }
        }
        guard let key = messageEncryptionKey() else { return nil }
        return await messageStore.fetchMessage(txId: txId, decryptionKey: key)
    }

    func hasLocalMessage(txId: String) async -> Bool {
        return await findLocalMessage(txId: txId) != nil
    }

    /// True if `txId` is a reaction's own transaction, not a real message - see
    /// `MessageStore.isReactionTransaction`'s doc comment for why this must be checked before
    /// ever falling back to the "📤 Sent via another device" placeholder for an outgoing tx this
    /// device has no local content for for: a reaction will never get real message content to
    /// replace that placeholder with, since it was never meant to be a message at all.
    func isKnownReaction(txId: String) async -> Bool {
        await messageStore.isReactionTransaction(txId: txId)
    }

    func addOutgoingMessageFromPush(
        txId: String,
        sender: String,
        payload: String?,
        timestamp: Int64
    ) async -> Bool {
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            AppLog.log("[ChatService] Outgoing push: missing private key")
            return false
        }

        // A reaction's own transaction never gets a CDMessage row (see isKnownReaction's doc
        // comment) - nothing below this point could ever resolve real "message" content for it,
        // so treat it as already handled rather than falling through to the placeholder.
        if await isKnownReaction(txId: txId) {
            AppLog.log("[ChatService] Outgoing push is a reaction, not a message: %@", txId)
            return true
        }

        // Check if message already exists with content (not placeholder)
        if let existingMsg = await findLocalMessage(txId: txId),
           !existingMsg.isSentPlaceholder {
            AppLog.log("[ChatService] Outgoing push already exists with content: %@", txId)
            return true
        }

        // PRIORITY 1: Try CloudKit sync first
        // Outgoing messages from other devices have their content stored in CloudKit
        // The on-chain payload is encrypted for the recipient, so we can't decrypt it here
        AppLog.log("[ChatService] Outgoing push from other device: %@ - trying CloudKit sync", txId)

        let settings = currentSettings
        if settings.storeMessagesInICloud {
            // Trigger CloudKit to fetch any pending changes
            await messageStore.waitForCloudKitSync(timeout: 5)

            // Reload messages from store (includes CloudKit-synced data)
            await loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

            // Brief pause for Core Data to merge
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Check if CloudKit delivered the content
            if let cloudKitMsg = await findLocalMessage(txId: txId),
               !cloudKitMsg.isSentPlaceholder {
                AppLog.log("[ChatService] Outgoing push resolved via CloudKit: %@", txId)
                return true
            }

            AppLog.log("[ChatService] CloudKit sync did not deliver content for %@ - trying payload decrypt", txId)
        }

        // PRIORITY 2: Try to decrypt on-chain payload (may work for some message types)
        let rawPayload = await resolveRawPayloadForTx(txId: txId, payloadHint: payload)
        guard let rawPayload else {
            AppLog.log("[ChatService] Outgoing push: failed to resolve raw payload for %@", txId)
            // Schedule a retry - CloudKit may deliver later
            scheduleCloudKitRetryForOutgoing(txId: txId, sender: sender, timestamp: timestamp)
            return false
        }

        guard let payloadString = Self.hexStringToData(rawPayload)
            .flatMap({ String(data: $0, encoding: .utf8) }) else {
            AppLog.log("[ChatService] Outgoing push: invalid raw payload for %@", txId)
            return false
        }

        guard let alias = Self.extractContextualAlias(fromRawPayloadString: payloadString) else {
            AppLog.log("[ChatService] Outgoing push: alias not found for %@", txId)
            return false
        }

        guard let contactAddress = contactAddressForOutgoingAlias(alias) else {
            AppLog.log("[ChatService] Outgoing push: no contact for alias %@ (tx=%@)", alias, txId)
            return false
        }

        guard let decrypted = await decryptContextualMessageFromRawPayload(rawPayload, privateKey: privateKey) else {
            AppLog.log("[ChatService] Outgoing push: decrypt failed for %@ - content will sync via CloudKit", txId)
            // Create placeholder message - CloudKit will deliver actual content
            let placeholderMessage = ChatMessage(
                txId: txId,
                senderAddress: sender,
                receiverAddress: contactAddress,
                content: ChatMessage.sentViaOtherDevicePlaceholder,
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
                blockTime: UInt64(timestamp),
                acceptingBlock: nil,
                isOutgoing: true,
                messageType: .contextual
            )
            addMessageToConversation(placeholderMessage, contactAddress: contactAddress)
            saveMessages()

            // Schedule CloudKit retry
            scheduleCloudKitRetryForOutgoing(txId: txId, sender: sender, timestamp: timestamp)
            return true  // Return true since we created a placeholder
        }

        let msgType = messageType(for: decrypted)
        if updateOutgoingPendingMessageIfMatch(
            contactAddress: contactAddress,
            newTxId: txId,
            content: decrypted,
            messageType: msgType
        ) {
            saveMessages(triggerExport: true)
            AppLog.log("[ChatService] Outgoing push updated pending message: %@ to %@", txId, String(contactAddress.suffix(10)))
            return true
        }

        let message = ChatMessage(
            txId: txId,
            senderAddress: sender,
            receiverAddress: contactAddress,
            content: decrypted,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
            blockTime: UInt64(timestamp),
            acceptingBlock: nil,
            isOutgoing: true,
            messageType: msgType
        )

        addMessageToConversation(message, contactAddress: contactAddress)
        saveMessages(triggerExport: true)
        AppLog.log("[ChatService] Outgoing push imported: %@ to %@", txId, String(contactAddress.suffix(10)))
        return true
    }

    /// Schedule a CloudKit retry for outgoing messages that couldn't be resolved immediately
    func scheduleCloudKitRetryForOutgoing(txId: String, sender: String, timestamp: Int64) {
        Task {
            // Wait 5 seconds for CloudKit to potentially deliver
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            // Reload from store
            await loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

            // Check if content arrived
            if let msg = await findLocalMessage(txId: txId),
               !msg.isSentPlaceholder {
                AppLog.log("[ChatService] CloudKit retry successful for outgoing: %@", txId)
                return
            }

            // Try again after 15 seconds
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

            if let msg = await findLocalMessage(txId: txId),
               msg.isSentPlaceholder {
                AppLog.log("[ChatService] Outgoing message %@ still awaiting CloudKit sync", txId)
            }
        }
    }

    func contactAddressForOutgoingAlias(_ alias: String) -> String? {
        for (address, aliases) in ourAliases where aliases.contains(alias) {
            return address
        }
        return nil
    }

    func resolveRawPayloadForTx(txId: String, payloadHint: String?) async -> String? {
        if let payloadHint,
           let data = Data(base64Encoded: payloadHint),
           let raw = String(data: data, encoding: .utf8),
           (raw.hasPrefix("kchat:") || raw.hasPrefix("ciph_msg:")) {
            return raw.data(using: .utf8)?.hexString
        }

        if let payloadHint,
           let data = Data(hexString: payloadHint),
           let raw = String(data: data, encoding: .utf8),
           (raw.hasPrefix("kchat:") || raw.hasPrefix("ciph_msg:")) {
            return payloadHint
        }

        if let entry = await NodePoolService.shared.getMempoolEntry(txId: txId, attempt: 1),
           !entry.payload.isEmpty {
            return entry.payload
        }

        if let url = kaspaRestURL(
            path: "/transactions/\(txId)",
            queryItems: [URLQueryItem(name: "resolve_previous_outpoints", value: "light")]
        ),
           let (data, response) = try? await URLSession.shared.data(from: url),
           let httpResponse = response as? HTTPURLResponse,
           (200...299).contains(httpResponse.statusCode),
           let fullTx = try? JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data),
           let payload = fullTx.payload,
           !payload.isEmpty {
            return payload
        }

        return nil
    }

    func addMessageToConversation(_ message: ChatMessage, contactAddress: String) {
        // A deleted contact's address is tombstoned - this check must run before
        // `getOrCreateContact`, which would otherwise silently resurrect it.
        if contactsManager.isAddressDeleted(contactAddress) {
            return
        }

        // Reactions are never shown as their own chat bubble - just attached to the message they
        // target - so intercept and route to the reactions store before this ever becomes a
        // conversation update. Covers both incoming reactions (contactAddress is the sender) and
        // our own outgoing reaction messages if they're ever independently re-fetched -
        // `sendReaction` already applies the optimistic local update at send time, so this is a
        // safety net for that direction, not its primary path.
        if let reaction = MessageReactionCodec.parse(message.content) {
            let reactorAddress = message.isOutgoing
                ? (WalletManager.shared.currentWallet?.publicAddress ?? message.senderAddress)
                : message.senderAddress
            if reaction.action == "add" {
                applyLocalReaction(targetTxId: reaction.targetTxId, reactorAddress: reactorAddress, emoji: reaction.emoji)
                if let key = messageEncryptionKey() {
                    messageStore.upsertReaction(
                        targetTxId: reaction.targetTxId, reactorAddress: reactorAddress, contactAddress: contactAddress,
                        emoji: reaction.emoji, reactionTxId: message.txId, blockTime: Int64(message.blockTime), encryptionKey: key
                    )
                }
            } else {
                removeLocalReaction(targetTxId: reaction.targetTxId, reactorAddress: reactorAddress)
                messageStore.removeReaction(targetTxId: reaction.targetTxId, reactorAddress: reactorAddress)
            }
            // Same self-triggered-notification suppression as every other local Core Data write -
            // see `ChatService+Reactions.swift`'s identical call for why this matters.
            recordLocalSave()
            return
        }

        // Fresh-address payment pool envelopes (addr_pool / addr_pool_request / payment_notice)
        // are likewise never chat bubbles - same interception pattern as reactions above. A
        // payment_notice DOES produce a payment bubble, but the handler constructs that bubble
        // itself and re-enters this function with plain payment content. See
        // `ChatService+PaymentPools.swift` and MESSAGING.md ("Fresh-Address Payment Pools").
        if let poolEnvelope = PaymentPoolCodec.parse(message.content) {
            handlePaymentPoolEnvelope(poolEnvelope, message: message, contactAddress: contactAddress)
            return
        }

        let contact = contactsManager.getOrCreateContact(address: contactAddress)
        if message.isOutgoing {
            contactsManager.markHasSentOutgoingMessage(address: contactAddress)
        }
        var isNewMessage = false
        var isNewConversation = false

        if message.isOutgoing && message.deliveryStatus == .sent {
            if updateOutgoingPendingMessageIfMatch(
                contactAddress: contactAddress,
                newTxId: message.txId,
                content: message.content,
                messageType: message.messageType
            ) {
                return
            }
            if updatePendingFromQueue(
                contactAddress: contactAddress,
                newTxId: message.txId,
                messageType: message.messageType
            ) {
                return
            }
            if updateOldestPendingOutgoingMessage(
                contactAddress: contactAddress,
                newTxId: message.txId,
                messageType: message.messageType
            ) {
                return
            }
        }

        let isUserViewing = activeConversationAddress == contactAddress &&
            UIApplication.shared.applicationState == .active

        // Floor the per-contact read cursor at the wallet-import moment: anything mined before
        // the wallet first landed on this device is backfilled history (seed re-import initial
        // sync, forced from-genesis contact sync, catch-up after an archive restore), not new
        // mail - it must land read and must not notify. 0 for pre-existing wallets (no gating).
        let importBaselineMs = walletImportBaselineMs(for: WalletManager.shared.currentWallet?.publicAddress)

        if let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            updateConversation(at: index) { conversation in
                if !conversation.messages.contains(where: { $0.txId == message.txId }) {
                    conversation.messages.append(message)
                    isNewMessage = true
                    if !message.isOutgoing {
                        if isUserViewing {
                            conversation.unreadCount = 0
                        } else if Int64(message.blockTime) > max(readCursorByAddress[contactAddress] ?? 0, importBaselineMs) {
                            // Only bump for messages newer than the persisted read cursor (floored
                            // at the wallet-import baseline) - a re-fetched already-read message
                            // (initial full re-sync) or pre-import history must not resurrect
                            // unread. See `readCursorByAddress` / `walletImportBaselineMs`.
                            conversation.unreadCount += 1
                        }
                    }
                }
            }
            // Mark for batched save if sync in progress
            if isSyncInProgress && isNewMessage {
                needsMessageStoreSyncAfterBatch = true
            }
        } else {
            var conversation = Conversation(contact: contact, messages: [message])
            isNewMessage = true
            isNewConversation = true
            if !message.isOutgoing {
                let isAlreadyRead = Int64(message.blockTime) <= max(readCursorByAddress[contactAddress] ?? 0, importBaselineMs)
                conversation.unreadCount = (isUserViewing || isAlreadyRead) ? 0 : 1
            }
            conversations.append(conversation)
            markConversationDirty(contactAddress)
            AppLog.log("%@", "[ChatService] Created NEW conversation for contact \(contactAddress.suffix(10)), total conversations: \(conversations.count)")
            if isSyncInProgress {
                needsMessageStoreSyncAfterBatch = true
            } else {
                saveMessages()
            }
        }

        // Update contact's last message time (debounced to avoid per-message saves)
        queueLastMessageUpdate(contactId: contact.id, date: message.timestamp)

        if isNewMessage {
            AppLog.log("%@", "[ChatService] Added message \(message.txId.prefix(16))... to \(contactAddress.suffix(10)), type: \(message.messageType), isNew: \(isNewConversation)")
            // Continuous Nextcloud sync: every message that lands - incoming or outgoing,
            // whatever the delivery path - marks the archive dirty and (re)arms the debounced
            // merge upload. No-op unless Automatic Sync is on and a server is connected.
            NextcloudService.shared.noteMessageActivity()
        }

        // If user is currently viewing this chat, advance read marker immediately
        // to prevent unread counter resurrection after store reload/merge.
        if isNewMessage && !message.isOutgoing && isUserViewing && message.blockTime > 0 {
            ReadStatusSyncManager.shared.markAsRead(
                contactAddress: contactAddress,
                lastReadTxId: message.txId,
                lastReadBlockTime: message.blockTime
            )
        }

        // Send local notification for new incoming messages.
        // Only suppress when the app is actively in the foreground AND the user is viewing that conversation.
        let isViewingConversation = activeConversationAddress == contactAddress &&
            UIApplication.shared.applicationState == .active
        // Backfilled pre-import history never notifies either - restoring is not receiving.
        let isBackfilledHistory = message.blockTime > 0 && Int64(message.blockTime) <= importBaselineMs
        if isNewMessage && !message.isOutgoing && !isViewingConversation && !isBackfilledHistory {
            sendLocalNotification(for: message, from: contact)
        }
    }

    func updateIncomingPaymentStatus(
        txId: String,
        deliveryStatus: ChatMessage.DeliveryStatus,
        content: String
    ) -> Bool {
        for index in conversations.indices {
            if let msgIndex = conversations[index].messages.firstIndex(where: { $0.txId == txId && !$0.isOutgoing }) {
                let existing = conversations[index].messages[msgIndex]
                if existing.deliveryStatus == deliveryStatus && existing.content == content {
                    return false
                }
                let updated = ChatMessage(
                    id: existing.id,
                    txId: existing.txId,
                    senderAddress: existing.senderAddress,
                    receiverAddress: existing.receiverAddress,
                    content: content,
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

    /// Removes DELIVERED notifications for one thread from the lock screen / Notification
    /// Center - reading a chat must take its banners with it, or they linger (and can appear
    /// to "come back" when the lock screen re-sorts). Matches every notification the app or
    /// its extension posts, local and push alike, by threadIdentifier.
    /// Throttle bookkeeping for `clearDeliveredNotifications` - the sweep is an XPC
    /// round-trip to the notification daemon, and mark-read paths can fire in bursts
    /// during catch-up sync. One sweep per thread per 2s is plenty.
    /// NSLock, not DispatchQueue.sync: callers run inside Swift Concurrency tasks, and a
    /// forced dispatch sync from the cooperative pool trips the runtime's
    /// "unsafeForcedSync called from Swift Concurrent context" diagnostic. A lock around
    /// a dictionary lookup is the sanctioned pattern for a critical section this small.
    private nonisolated static let clearThrottleLock = NSLock()
    nonisolated(unsafe) private static var lastClearByThread: [String: Date] = [:]

    nonisolated static func clearDeliveredNotifications(threadIdentifier: String) {
        clearThrottleLock.lock()
        let now = Date()
        let allowed: Bool
        if let last = lastClearByThread[threadIdentifier], now.timeIntervalSince(last) < 2.0 {
            allowed = false
        } else {
            lastClearByThread[threadIdentifier] = now
            allowed = true
        }
        clearThrottleLock.unlock()
        guard allowed else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.threadIdentifier == threadIdentifier }
                .map { $0.request.identifier }
            if !ids.isEmpty {
                // Re-fetched rather than captured - UNUserNotificationCenter isn't Sendable.
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    /// App Group ledger of 1:1 txIds the MAIN APP posted a local banner for - the 1:1
    /// counterpart of `GroupChatService.localPostedTxIdsKey`. `AppDelegate.willPresent` drops
    /// a foreground push whose tx_id appears here.
    static let localPostedTxIdsKey = "chat_local_posted_txids"

    /// Returns false when this txId already produced a banner - the notification extension
    /// handled its push (`chat_push_handled_txids`, written in NotificationService.didReceive),
    /// or the main app already posted a local banner for it. Records the claim and returns
    /// true otherwise. Bounded FIFO, mirroring `GroupChatService.claimGroupBannerSlot`.
    private static func claimChatBannerSlot(txId: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.com.kachat.app") else { return true }
        let pushHandled = defaults.stringArray(forKey: "chat_push_handled_txids") ?? []
        guard !pushHandled.contains(txId) else { return false }
        var posted = defaults.stringArray(forKey: localPostedTxIdsKey) ?? []
        guard !posted.contains(txId) else { return false }
        posted.append(txId)
        if posted.count > 300 { posted.removeFirst(posted.count - 300) }
        defaults.set(posted, forKey: localPostedTxIdsKey)
        return true
    }

    func sendLocalNotification(for message: ChatMessage, from contact: Contact) {
        let settings = currentSettings
        // Check if notifications are enabled
        guard settings.notificationsEnabled else { return }
        // Foreground: the app's own live sync paths (subscription, sweep, open-chat poll,
        // catch-up) are the notification source no matter the push mode - remote push only
        // matters for background/closed. Background keeps the remote-push suppression so
        // users whose push works don't get double banners there.
        if UIApplication.shared.applicationState != .active {
            guard settings.notificationMode != .remotePush else { return }
        }

        // Don't notify during initial sync after wallet import/create
        guard !suppressNotificationsUntilSynced else { return }

        // Respect global defaults + optional per-contact override.
        guard settings.shouldDeliverIncomingNotification(for: contact) else { return }

        // Don't notify for pending messages
        guard message.deliveryStatus != .pending else { return }

        // One banner per txId across the local-vs-APNs race: skip if the notification
        // extension already handled this message's push, and record this local post so a
        // foreground push duplicate is dropped in AppDelegate.willPresent.
        guard Self.claimChatBannerSlot(txId: message.txId) else { return }

        let content = UNMutableNotificationContent()
        content.title = contact.alias
        content.body = notificationBody(for: message)
        let shouldPlaySound = settings.shouldPlayIncomingNotificationSound(for: contact)
        content.sound = shouldPlaySound ? .default : nil
        content.threadIdentifier = contact.address
        content.categoryIdentifier = AppDelegate.messageCategoryId

        if !shouldPlaySound &&
            settings.incomingNotificationVibrationEnabled &&
            UIApplication.shared.applicationState == .active {
            Haptics.impact(.light)
        }

        let request = UNNotificationRequest(
            identifier: message.txId,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                AppLog.log("%@", "[ChatService] Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    /// Banner text for one incoming message.
    ///
    /// Some message contents are internal PLACEHOLDERS, not text the sender wrote: a handshake
    /// carries "[Request to communicate]", an undecryptable message carries "[Encrypted
    /// message]". The chat bubble renders those as proper UI and the push extension has its own
    /// wording for them, but this path put the bracketed placeholder straight into the banner, so
    /// a connect request arrived on screen as literally "[Request to communicate]".
    ///
    /// Handshake wording is kept in step with `KaChatNotificationService`, which sees only the
    /// push type and so cannot tell a request from an acceptance; this path can, and says so.
    private func notificationBody(for message: ChatMessage) -> String {
        let raw = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.messageType == .handshake {
            return raw == "[Request accepted]"
                ? NSLocalizedString("Accepted your request to communicate", comment: "Banner body when a contact accepts a handshake")
                : NSLocalizedString("Started a conversation", comment: "Push body for handshake notification")
        }
        if raw == "[Encrypted message]" {
            return NSLocalizedString("Sent you a message", comment: "Banner body for a message that could not be decrypted")
        }
        return formatNotificationBody(message.content)
    }

    func formatNotificationBody(_ content: String) -> String {
        // Unwrap a reply envelope first, so a reply's own text (or its attachment, below) is
        // what's notified rather than the raw `{"type":"reply",...}` JSON.
        let unwrapped = MessageReplyCodec.unwrappedText(content)

        // Chess envelopes are JSON in the message content; without this they banner as raw
        // JSON on the local (foreground) path while the push extension shows friendly text.
        // Wording matches the NSE's chessPreviewText exactly.
        if let chessEnvelope = ChessCodec.parseAny(unwrapped) {
            switch chessEnvelope {
            case .invite:
                return "♟️ Invited you to a game of chess"
            case .response(let response):
                return response.accepted ? "♟️ Accepted your chess game" : "♟️ Declined your chess game"
            case .move(let move):
                return "♟️ Played \(move.from) → \(move.to)"
            case .resign(let resign):
                return resign.reason == "timeout" ? "♟️ Lost on time" : "♟️ Resigned the chess game"
            }
        }
        // Same guard for reaction envelopes, mirroring the NSE's reactionPreviewText.
        if let reaction = MessageReactionCodec.parse(unwrapped) {
            return "Reacted \(reaction.emoji)"
        }

        // Check if content is a file JSON payload
        let trimmed = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            return unwrapped
        }

        guard let data = unwrapped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let mimeType = json["mimeType"] as? String else {
            return unwrapped
        }

        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") {
            return "Sent a photo"
        } else if mime.hasPrefix("audio/") {
            return "Sent a voice message"
        } else if mime.hasPrefix("video/") {
            return "Sent a video"
        } else {
            return "Sent a file"
        }
    }

    func updateConversation(
        at index: Int,
        persist: Bool = true,
        normalizeMessages: Bool = false,
        update: (inout Conversation) -> Void
    ) {
        guard conversations.indices.contains(index) else { return }
        // Mutate a single element and write it back once. The previous shape copied the WHOLE
        // conversations array twice per call (plus an extra copy of the element's message array via
        // COW) - and this runs once per ingested message on the main actor, so during a catch-up
        // sync it was a dominant source of intermittent main-thread stalls.
        var conversation = conversations[index]
        update(&conversation)
        if normalizeMessages {
            conversation.messages = Self.dedupeMessages(conversation.messages)
        }
        guard conversation != conversations[index] else { return }
        conversations[index] = conversation
        guard persist else { return }
        markConversationDirty(conversation.contact.address)
        if isSyncInProgress {
            needsMessageStoreSyncAfterBatch = true
        } else {
            saveMessages()
        }
    }

    func decodeMessagePayload(_ hexPayload: String?) -> String? {
        guard let hexPayload = hexPayload else { return nil }
        // Remove "ciph_msg:" prefix if present
        var payload = hexPayload
        if payload.hasPrefix("kchat:") {
            payload = String(payload.dropFirst(6))
        } else if payload.hasPrefix("ciph_msg:") {
            payload = String(payload.dropFirst(9))
        }

        // Try to decode as hex
        guard let data = Self.hexStringToData(payload) else { return nil }

        // Try to parse as JSON
        if let json = try? JSONDecoder().decode(HandshakePayload.self, from: data) {
            if let convId = json.conversationId, let recipient = json.recipientAddress {
                conversationIds[recipient] = convId
            }
            return "[Request to communicate]"
        }

        if let json = try? JSONDecoder().decode(MessagePayload.self, from: data) {
            return json.content
        }

        // Return as string if possible
        return String(data: data, encoding: .utf8)
    }

    func decodePaymentPayload(_ hexPayload: String?) -> PaymentPayload? {
        guard let hexPayload = hexPayload else { return nil }
        var payload = hexPayload
        if payload.hasPrefix("kchat:") {
            payload = String(payload.dropFirst(6))
        } else if payload.hasPrefix("ciph_msg:") {
            payload = String(payload.dropFirst(9))
        }

        guard let data = Self.hexStringToData(payload) else { return nil }

        if let json = try? JSONDecoder().decode(PaymentPayload.self, from: data) {
            return json
        }

        return nil
    }

    func messageType(for content: String) -> ChatMessage.MessageType {
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let type = json["type"] as? String,
              type == "file",
              let mime = json["mimeType"] as? String else {
            return .contextual
        }

        if mime.lowercased().hasPrefix("audio/") {
            return .audio
        }

        return .contextual
    }

    func paymentContent(_ payment: PaymentResponse, isOutgoing: Bool) -> String {
        if let amount = payment.amount {
            let formatted = formatKasAmount(amount)
            if let payload = decodePaymentPayload(payment.messagePayload),
               !payload.message.isEmpty {
                let template = isOutgoing
                    ? AppLocalization.string("Sent %@ KAS — %@")
                    : AppLocalization.string("Received %@ KAS — %@")
                return String(format: template, formatted, payload.message)
            }
            let template = isOutgoing
                ? AppLocalization.string("Sent %@ KAS")
                : AppLocalization.string("Received %@ KAS")
            return String(format: template, formatted)
        }

        if let payload = decodePaymentPayload(payment.messagePayload) {
            let formatted = formatKasAmount(payload.amount)
            let template = AppLocalization.string("Payment: %@ KAS — %@")
            return String(format: template, formatted, payload.message)
        }

        return AppLocalization.string("[Payment]")
    }

    func localizedKNSTransferMessage(domainName: String?, isOutgoing: Bool) -> String {
        let trimmedDomain = domainName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDomain.isEmpty {
            let template = isOutgoing
                ? AppLocalization.string("Sent %@ domain")
                : AppLocalization.string("Received %@ domain")
            return String(format: template, trimmedDomain)
        }
        return isOutgoing
            ? AppLocalization.string("Sent domain transfer")
            : AppLocalization.string("Received domain transfer")
    }

    func formatKasAmount(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        return formatter.string(from: NSNumber(value: kas)) ?? String(format: "%.8f", kas)
    }

}

// MARK: - Danger Zone: wipe & re-sync incoming messages

extension ChatService {
    /// Progress events reported by `wipeAndResyncIncomingMessages`, in order. The coordinator
    /// driving the blocking modal maps these onto the same stage-weight pattern the Nextcloud
    /// restore modal uses.
    enum IncomingResyncEvent {
        case wiping
        case fetchingHandshakes
        case fetchingPayments
        /// Per-contact contextual re-fetch: `done` of `total` chats finished.
        case syncingChats(done: Int, total: Int)
        case finalizing
    }

    struct IncomingResyncSummary {
        let chats: Int
        let messages: Int
    }

    enum IncomingResyncError: LocalizedError {
        case noWallet
        case notConfigured
        case walletChanged
        case handshakeFetchFailed
        case paymentFetchFailed
        case chatsFailed(failed: Int, total: Int)

        var errorDescription: String? {
            switch self {
            case .noWallet:
                return "No active account. Log in and try again."
            case .notConfigured:
                return "The indexer connection is not available. Check Connection Settings and try again."
            case .walletChanged:
                return "The active account changed while re-syncing. Messages already recovered were kept."
            case .handshakeFetchFailed:
                return "Could not re-fetch handshakes from the indexer. Messages already recovered were kept; try again on a better connection."
            case .paymentFetchFailed:
                return "Could not re-fetch payments from the indexer. Messages already recovered were kept; try again on a better connection."
            case .chatsFailed(let failed, let total):
                return "\(failed) of \(total) chats could not be re-synced. Messages already recovered were kept; try again on a better connection."
            }
        }
    }

    /// Wipes incoming messages and re-fetches them from the indexer, scoped to `contacts`
    /// (nil = every known 1:1 chat). Owned by `IncomingResyncCoordinator`, never by a view.
    ///
    /// Scope mechanics: the wipe deletes only the selected conversations' incoming rows (in
    /// memory and in the Core Data store, matched by `contactAddress`) and drops only those
    /// contacts' incoming contextual cursors, so the per-contact re-fetch below starts from
    /// block time 0 (retention-clamped) for exactly those chats and nothing else. Handshake and
    /// payment rows are incoming messages too, so both phases re-run from 0 - they are
    /// wallet-global endpoints and idempotent (`addMessageToConversation` dedupes by txId), so
    /// untouched chats simply no-op. The global `lastPollTime` fallback cursor is never
    /// advanced by this flow (`endSyncBlockTime(success: false)`): only the re-fetched objects'
    /// own cursors move, so unrelated sync windows cannot be skipped.
    func wipeAndResyncIncomingMessages(
        contacts selectedAddresses: [String]?,
        progress: @escaping (IncomingResyncEvent) -> Void
    ) async throws -> IncomingResyncSummary {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw IncomingResyncError.noWallet
        }
        await configureAPIIfNeeded()
        guard isConfigured else {
            throw IncomingResyncError.notConfigured
        }
        let myAddress = wallet.publicAddress
        let privateKey = WalletManager.shared.getPrivateKey()
        let scopeIsAll = selectedAddresses == nil

        // Target set: the picked chats, or (for All Chats) the same contact universe the full
        // sync sweeps - routing states + legacy aliases + every live conversation. Ordered by
        // conversation recency so the progress bar works through visible chats first.
        var targetPool: Set<String>
        if let selectedAddresses {
            targetPool = Set(selectedAddresses)
        } else {
            targetPool = Set(routingStates.keys)
                .union(conversationAliases.keys)
                .union(conversations.map { $0.contact.address })
        }
        let recency: [String: Date] = Dictionary(
            conversations.compactMap { convo -> (String, Date)? in
                guard let last = convo.lastMessage else { return nil }
                return (convo.contact.address.lowercased(), last.timestamp)
            },
            uniquingKeysWith: { max($0, $1) }
        )
        let targets = targetPool.sorted { a, b in
            let la = recency[a.lowercased()]
            let lb = recency[b.lowercased()]
            switch (la, lb) {
            case let (da?, db?) where da != db: return da > db
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a < b
            }
        }
        let targetSet = Set(targets.map { $0.lowercased() })

        // PHASE 1 - wipe. In-memory first (synchronous, so the UI empties immediately), then
        // the store (awaited, so the re-fetch cannot race the batch delete), then the cursors.
        progress(.wiping)
        var updated = conversations
        for index in updated.indices where targetSet.contains(updated[index].contact.address.lowercased()) {
            updated[index].messages.removeAll(where: { !$0.isOutgoing })
            updated[index].unreadCount = 0
        }
        conversations = updated
        await MessageStore.shared.clearIncomingMessagesAndWait(forContacts: scopeIsAll ? nil : targets)
        MessageStore.shared.clearDpiCorruptionWarning()
        removeIncomingSyncCursors(for: targets, includeIncomingHandshakes: true)
        saveMessages()

        // Re-fetch under sync batching, with notifications suppressed: everything below is
        // historical data the user has already seen.
        let previousSuppress = suppressNotificationsUntilSynced
        suppressNotificationsUntilSynced = true
        beginSyncBlockTime()
        defer {
            // Never advance the global lastPollTime fallback off this scoped run - per-object
            // cursors advanced above are the only state this flow is allowed to move forward.
            endSyncBlockTime(success: false)
            suppressNotificationsUntilSynced = previousSuppress
        }

        let nowMs = currentTimeMs()
        let historyStart = applyMessageRetention(to: 0)

        // PHASE 2 - incoming handshakes (restores wiped handshake rows and re-derives aliases).
        progress(.fetchingHandshakes)
        var handshakeTxIds = Set<String>()
        if let fetched = await retryUntilSuccess(
            label: "re-sync incoming handshakes",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchIncomingHandshakes(for: myAddress, blockTime: historyStart) }
        ) {
            handshakeTxIds = Set(fetched.map { $0.txId })
            await processHandshakes(fetched, isOutgoing: false, myAddress: myAddress, privateKey: privateKey)
            advanceSyncCursor(
                for: handshakeSyncObjectKey(direction: "in", address: myAddress),
                maxBlockTime: fetched.compactMap { $0.blockTime }.max()
            )
        } else {
            throw IncomingResyncError.handshakeFetchFailed
        }
        guard isActiveWallet(myAddress) else { throw IncomingResyncError.walletChanged }

        // PHASE 3 - incoming payments (payment rows are incoming messages and were wiped too).
        // Handshake txIds are filtered out so a handshake is never re-added as a payment (the
        // same Bug 4 guard the full sync applies).
        progress(.fetchingPayments)
        if let fetched = await retryUntilSuccess(
            label: "re-sync incoming payments",
            maxAttempts: Self.syncPhaseMaxRetryAttempts,
            operation: { [self] in try await fetchIncomingPayments(for: myAddress, blockTime: historyStart) }
        ) {
            let payments = fetched.filter { !handshakeTxIds.contains($0.txId) }
            await processPayments(payments, isOutgoing: false, myAddress: myAddress, privateKey: privateKey)
        } else {
            throw IncomingResyncError.paymentFetchFailed
        }
        guard isActiveWallet(myAddress) else { throw IncomingResyncError.walletChanged }

        // PHASE 4 - per-contact contextual history. Serial on purpose: the modal's bar advances
        // one chat at a time, and a re-sync is a repair operation, not a latency-critical sync.
        // Each contact's incoming cursor was dropped above, so `fallbackSince: 0` makes
        // `fetchIncomingContextualMessages` page through that chat's full (retention-clamped)
        // history; contacts with no incoming alias yet return immediately.
        var failedChats = 0
        var done = 0
        progress(.syncingChats(done: 0, total: targets.count))
        for address in targets {
            guard isActiveWallet(myAddress) else { throw IncomingResyncError.walletChanged }
            let ok = await fetchIncomingContextualMessages(
                contactAddress: address,
                myAddress: myAddress,
                privateKey: privateKey,
                fallbackSince: 0,
                nowMs: nowMs
            )
            if !ok { failedChats += 1 }
            done += 1
            progress(.syncingChats(done: done, total: targets.count))
        }

        // PHASE 5 - persist everything the phases touched.
        progress(.finalizing)
        saveConversationAliases()
        saveOurAliases()
        saveConversationIds()
        saveRoutingStates()
        saveMessages()

        if failedChats > 0 {
            throw IncomingResyncError.chatsFailed(failed: failedChats, total: targets.count)
        }

        let restoredMessages = conversations.reduce(0) { count, convo in
            guard targetSet.contains(convo.contact.address.lowercased()) else { return count }
            return count + convo.messages.filter { !$0.isOutgoing }.count
        }
        return IncomingResyncSummary(chats: targets.count, messages: restoredMessages)
    }
}
