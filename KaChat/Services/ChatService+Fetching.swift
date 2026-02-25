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
                NSLog("[ChatService] Indexer handshake check attempt %d failed: %@", attempt, error.localizedDescription)
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
            NSLog("[ChatService] Handshake fetch in-flight, reusing task (%@)", String(address.suffix(10)))
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
            NSLog("[ChatService] Handshake fetch in-flight, reusing task (%@)", String(address.suffix(10)))
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
            NSLog("[ChatService] Payment fetch in-flight, reusing task (%@)", String(address.suffix(10)))
            return try await existing.value
        }
        NSLog("[ChatService] === FETCH INCOMING PAYMENTS START === address=%@, blockTime=%llu", String(address.suffix(10)), blockTime)
        let task = Task { [self] in
            // Fetch from Kaspa API instead of indexer
            let result = try await fetchPaymentsFromKaspaAPI(for: address, blockTime: blockTime, incoming: true)
            NSLog("[ChatService] === FETCH INCOMING PAYMENTS DONE === count=%d", result.count)
            return result
        }
        paymentFetchTasks[key] = task
        defer { paymentFetchTasks[key] = nil }
        do {
            return try await task.value
        } catch {
            NSLog("[ChatService] === FETCH INCOMING PAYMENTS ERROR === %@", error.localizedDescription)
            throw error
        }
    }

    func fetchOutgoingPayments(for address: String, blockTime: UInt64) async throws -> [PaymentResponse] {
        let key = "out|\(address)|\(blockTime)"
        if let existing = paymentFetchTasks[key] {
            NSLog("[ChatService] Payment fetch in-flight, reusing task (%@)", String(address.suffix(10)))
            return try await existing.value
        }
        NSLog("[ChatService] === FETCH OUTGOING PAYMENTS START === address=%@, blockTime=%llu", String(address.suffix(10)), blockTime)
        let task = Task { [self] in
            // Fetch from Kaspa API instead of indexer
            let result = try await fetchPaymentsFromKaspaAPI(for: address, blockTime: blockTime, incoming: false)
            NSLog("[ChatService] === FETCH OUTGOING PAYMENTS DONE === count=%d", result.count)
            return result
        }
        paymentFetchTasks[key] = task
        defer { paymentFetchTasks[key] = nil }
        do {
            return try await task.value
        } catch {
            NSLog("[ChatService] === FETCH OUTGOING PAYMENTS ERROR === %@", error.localizedDescription)
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
        NSLog("[ChatService] fetchPaymentsFromKaspaAPI START - direction=%@, address=%@", direction, String(address.suffix(10)))

        // Fetch all transactions with pagination
        let transactions = await fetchFullTransactionsPaginated(for: address, stopAtBlockTime: blockTime)
        NSLog("[ChatService] Fetched total %d transactions from Kaspa API", transactions.count)

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
            NSLog("[ChatService] Processed %d KNS reveal tx(s) during %@ payment fetch", knsHandledCount, direction)
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
                    NSLog("[ChatService] Skipping self-stash payment %@ - handled as contextual message",
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
                    NSLog("[ChatService] Skipping non-payment tx %@ (isContextual: %d, isSelfStash: %d, payload prefix: %@)",
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
                        NSLog("[ChatService] WARNING: Skipping payment %@ - Schnorr signature verification FAILED",
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
            NSLog("[ChatService] Found payment [%@]: %@... amount=%llu sompi", dirStr, String(tx.transactionId.prefix(16)), amount)
        }

        let dirStr = incoming ? "incoming" : "outgoing"
        NSLog(
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
                NSLog("[ChatService] Invalid URL for fetching transactions")
                break
            }

            if pageCount == 0 {
                NSLog("[ChatService] Kaspa API URL: %@", url.absoluteString)
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    NSLog("[ChatService] Kaspa API returned non-2xx status")
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
                        NSLog("[ChatService] Pagination: reached transactions older than stopAtBlockTime, stopping")
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
                    NSLog("[ChatService] Pagination: fetched page %d, total transactions: %d, offset: %d",
                          pageCount + 1, allTransactions.count, offset)
                }

            } catch {
                NSLog("[ChatService] Pagination error: %@", error.localizedDescription)
                break
            }
        }

        if allTransactions.count >= maxTransactions {
            NSLog("[ChatService] Pagination: reached max transactions limit (%d)", maxTransactions)
        }

        return allTransactions
    }

    func processHandshakes(_ handshakes: [HandshakeResponse], isOutgoing: Bool, myAddress: String, privateKey: Data?) async {
        for handshake in handshakes {
            let resolvedSender = await resolveSenderAddress(
                sender: handshake.sender,
                txId: handshake.txId,
                receiver: handshake.receiver
            )
            let contactAddress = isOutgoing ? handshake.receiver : (resolvedSender ?? handshake.sender)
            if contactAddress.isEmpty {
                print("[ChatService] Skipping handshake \(handshake.txId) - missing sender")
                continue
            }
            if !isOutgoing {
                clearDeclined(contactAddress)
            }

            // Auto-add contact if not exists
            let existingContact = contactsManager.getContact(byAddress: contactAddress)
            _ = contactsManager.getOrCreateContact(address: contactAddress)
            if existingContact == nil {
                print("[ChatService] Discovered NEW contact from handshake: \(contactAddress.suffix(10))")
            }

            // Try to decrypt handshake payload to extract alias
            var content = "[Handshake]"
            var extractedAlias: String?
            var extractedConversationId: String?

            if let privKey = privateKey, !isOutgoing {
                // For incoming handshakes, decrypt to get sender's alias (runs on background thread)
                if let decrypted = await decryptHandshakePayload(handshake.messagePayload, privateKey: privKey) {
                    content = "[Request to communicate]"
                    extractedAlias = decrypted.alias  // may be nil for deterministic handshakes
                    extractedConversationId = decrypted.conversationId
                    if let alias = decrypted.alias {
                        print("[ChatService] Extracted alias '\(alias)' from handshake by \(contactAddress)")
                    } else {
                        print("[ChatService] Received alias-less (deterministic) handshake from \(contactAddress)")
                    }
                }
            } else {
                // For outgoing handshakes, we know our own alias
                content = decodeMessagePayload(handshake.messagePayload) ?? "[Handshake sent]"
            }

            // Store the alias for this contact
            if let alias = extractedAlias {
                addConversationAlias(alias, for: contactAddress, blockTime: handshake.blockTime)
            } else if !isOutgoing {
                // Alias-less handshake = peer uses deterministic aliases
                routingStates[contactAddress]?.peerSupportsDeterministic = true
            }
            if let convId = extractedConversationId {
                conversationIds[contactAddress] = convId
            }

            // If a payment message with this txId already exists, remove it first
            // (handles UTXO notification initially classifying a handshake as payment)
            if let existingMsg = findLocalMessage(txId: handshake.txId), existingMsg.messageType == .payment {
                NSLog("[ChatService] Replacing misclassified payment with handshake for tx %@", String(handshake.txId.prefix(12)))
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
                    NSLog("[ChatService] Reclassifying outgoing payment %@ as handshake for %@",
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
                    NSLog("[ChatService] Reclassifying incoming payment %@ as handshake for %@",
                          String(earliestPayment.txId.prefix(12)), String(contactAddress.suffix(10)))
                    replaceMessageType(txId: earliestPayment.txId, contactAddress: contactAddress, newType: .handshake, newContent: content)
                    reclassified += 1
                }
            }
        }

        if reclassified > 0 {
            NSLog("[ChatService] Reclassified %d payment(s) as handshake(s)", reclassified)
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
                NSLog("[ChatService] Generated fallback alias for %@ (self-stash unavailable)", String(addr.suffix(10)))
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
    func isHandshakePayload(_ payloadHex: String) -> Bool {
        guard let payloadString = Self.payloadPrefixString(from: payloadHex, byteCount: 21) else {
            return false
        }
        return payloadString.hasPrefix("ciph_msg:1:handshake:")
    }

    func isContextualPayload(_ payloadHex: String) -> Bool {
        guard let payloadString = Self.payloadPrefixString(from: payloadHex, byteCount: 16) else {
            return false
        }
        let matches = payloadString.hasPrefix("ciph_msg:1:comm:")
        if !matches && payloadString.hasPrefix("ciph_msg:") {
            // Log near-miss for debugging
            NSLog("[ChatService] Payload prefix '%@' starts with 'ciph_msg:' but not 'ciph_msg:1:comm:'", payloadString)
        }
        return matches
    }

    func isSelfStashPayload(_ payloadHex: String) -> Bool {
        guard let payloadString = Self.payloadPrefixString(from: payloadHex, byteCount: 22) else {
            return false
        }
        let matches = payloadString.hasPrefix("ciph_msg:1:self_stash:")
        if !matches && payloadString.hasPrefix("ciph_msg:") {
            // Log near-miss for debugging
            NSLog("[ChatService] Payload prefix '%@' starts with 'ciph_msg:' but not 'ciph_msg:1:self_stash:'", payloadString)
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
    ) -> Bool {
        guard let hint = knsTransferChatHint(for: txId) else { return false }

        if let existing = findLocalMessage(txId: txId) {
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
        NSLog(
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
        if addKNSTransferMessageFromHintIfNeeded(
            txId: txId,
            myAddress: myAddress,
            blockTimeMs: blockTimeMs,
            acceptingBlock: transaction.acceptingBlockHash
        ) {
            return
        }

        if let existing = findLocalMessage(txId: txId) {
            if existing.messageType == .payment {
                removeMessage(txId: txId)
            } else {
                return
            }
        }

        let myNormalized = myAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let recipient = recipientAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !recipient.isEmpty else {
            NSLog("[ChatService] KNS transfer %@ missing recipient in payload (%@)", String(txId.prefix(12)), source)
            return
        }

        let isOutgoing = recipient.lowercased() != myNormalized
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
            NSLog("[ChatService] KNS transfer %@ has unresolved counterparty (%@)", String(txId.prefix(12)), source)
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
        NSLog(
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

    nonisolated static func payloadPrefixString(from payloadHex: String, byteCount: Int) -> String? {
        // Remove OP_RETURN prefix if present (6a followed by length byte)
        var hex = payloadHex
        if hex.hasPrefix("6a") && hex.count >= 4 {
            hex = String(hex.dropFirst(4))  // Drop 6a + length byte (2 chars each)
        }

        let prefixHex = String(hex.prefix(byteCount * 2))
        guard let data = Data(hexString: prefixHex),
              let payloadString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return payloadString
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
            print("[ChatService] Failed to fetch tx \(txId): \(error.localizedDescription)")
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
                                NSLog("[ChatService] Indexer sender mismatch for %@ - using full tx sender %@",
                                      String(txId.prefix(12)), String(derivedSender.suffix(10)))
                                return TransactionResolveInfo(
                                    sender: derivedSender,
                                    blockTimeMs: fullTx.acceptingBlockTime ?? fullTx.blockTime ?? blockTimeMs,
                                    payload: fullTx.payload ?? payment.messagePayload
                                )
                            }
                        }
                        NSLog("[ChatService] Resolved tx %@ from indexer (attempt %d, start=%llu)",
                              String(txId.prefix(12)), attempt, startBlockTime)
                        return TransactionResolveInfo(
                            sender: payment.sender,
                            blockTimeMs: blockTimeMs,
                            payload: payment.messagePayload
                        )
                    }
                } catch {
                    NSLog("[ChatService] Indexer resolve failed for %@ (attempt %d): %@",
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
            NSLog("[ChatService] Kaspa REST resolve request: %@", url.absoluteString)

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
                        NSLog("[ChatService] Resolved tx %@ from REST API on attempt %d", String(txId.prefix(12)), attempt)
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
                NSLog("[ChatService] Transaction resolution timeout for %@", String(txId.prefix(12)))
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
        NSLog("[ChatService] Kaspa REST full tx request: %@", url.absoluteString)

        for attempt in 1...max(1, retries) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
                let fullTx = try JSONDecoder().decode(KaspaFullTransactionResponse.self, from: data)
                NSLog("[ChatService] Kaspa REST full tx resolved for %@ on attempt %d",
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
            NSLog("[ChatService] Kaspa REST fetchAnyInputAddress: %@", url.absoluteString)
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
            NSLog("[ChatService] fetchAnyInputAddress failed for %@: %@", String(txId.prefix(16)), error.localizedDescription)
            return nil
        }
    }

    func fetchSavedHandshakes(myAddress: String, privateKey: Data?) async throws {
        guard let privKey = privateKey else {
            NSLog("[ChatService] Cannot fetch saved handshakes - no private key")
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
        NSLog("[ChatService] Fetched %d saved handshakes from self-stash", savedHandshakes.count)

        for stash in savedHandshakes {
            guard let stashedData = stash.stashedData else { continue }
            // Decrypt the stashed data on background thread to get our alias and contact info
            if let savedData = await decryptSelfStash(stashedData, privateKey: privKey) {
                let contact = savedData.contactAddress
                let alias = savedData.ourAlias
                if !contact.isEmpty && !alias.isEmpty {
                    NSLog("[ChatService] Saved handshake: contact=%@, ourAlias=%@, theirAlias=%@",
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
                    NSLog("[ChatService] Saved handshake missing contact or alias")
                }
            }
        }
    }

    func retryUntilSuccess<T>(
        label: String,
        initialDelayNs: UInt64 = 1_000_000_000,
        maxDelayNs: UInt64 = 15_000_000_000,
        operation: @escaping () async throws -> T
    ) async -> T? {
        var attempt = 0
        var delay = initialDelayNs

        while !Task.isCancelled {
            do {
                return try await operation()
            } catch {
                attempt += 1
                let delaySeconds = Double(delay) / 1_000_000_000.0
                NSLog("[ChatService] %@ failed (attempt %d): %@. Retrying in %.1fs",
                      label, attempt, error.localizedDescription, delaySeconds)
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, maxDelayNs)
            }
        }

        NSLog("[ChatService] %@ cancelled", label)
        return nil
    }

    static func handleDpiPaginationFailure(_ error: Error, context: String) -> Bool {
        if case KasiaAPIClientError.dpiPaginationExhausted(let endpoint) = error {
            NSLog("[ChatService] DPI pagination exhausted for %@ (%@)", endpoint, context)
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

    func fetchContextualMessages(
        myAddress: String,
        privateKey: Data?,
        fallbackSince: UInt64,
        nowMs: UInt64
    ) async -> Bool {
        let archivedAddresses = Set(contactsManager.archivedContacts.map { $0.address })
        // Build contact set from routing states (preferred) + legacy aliases (fallback)
        let allContactAddresses = Set(routingStates.keys).union(conversationAliases.keys)
        print("[ChatService] Fetching contextual messages for \(allContactAddresses.count) contacts")

        // Fetch INCOMING messages (from contacts to us)
        for contactAddress in allContactAddresses {
            guard !archivedAddresses.contains(contactAddress) else { continue }
            let aliases = incomingAliases(for: contactAddress)
            guard !aliases.isEmpty else { continue }
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
                    NSLog("[ChatService] Contextual fetch in-flight, skipping incoming %@",
                          String(contactAddress.suffix(10)))
                    continue
                }
                defer { endContextualFetch(fetchKey) }
                guard let messages = await retryUntilSuccess(
                    label: "fetch incoming contextual messages from \(contactAddress.suffix(10))",
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
                    return false
                }
                advanceSyncCursor(for: syncObjectKey, maxBlockTime: messages.compactMap { $0.blockTime }.max())

                if !messages.isEmpty {
                    markChatFetchLoading(contactAddress)
                }
                print("[ChatService] Got \(messages.count) incoming contextual messages from \(contactAddress)")

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
                        isOutgoing: false,
                        messageType: msgType
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

        // Fetch OUTGOING messages (from us to contacts)
        let allOutgoingAddresses = Set(routingStates.keys).union(ourAliases.keys)
        for contactAddress in allOutgoingAddresses {
            guard !archivedAddresses.contains(contactAddress) else { continue }
            let aliasSet = outgoingFetchAliases(for: contactAddress)
            guard !aliasSet.isEmpty else { continue }
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
                    NSLog("[ChatService] Contextual fetch in-flight, skipping outgoing %@",
                          String(contactAddress.suffix(10)))
                    continue
                }
                defer { endContextualFetch(fetchKey) }
                guard let messages = await retryUntilSuccess(
                    label: "fetch outgoing contextual messages to \(contactAddress.suffix(10))",
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
                return false
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

                print("[ChatService] Got \(sortedMessages.count) outgoing contextual messages to \(contactAddress)")

                for contextMsg in sortedMessages {
                    // Outgoing messages are encrypted for the recipient, we can't decrypt them
                    // Check if we have this message stored locally with content
                    let existingMessage = findLocalMessage(txId: contextMsg.txId)
                    let content = existingMessage?.content ?? "📤 Sent via another device"
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

                    addMessageToConversation(message, contactAddress: contactAddress)
                    if let blockTime = contextMsg.blockTime, blockTime > lastPollTime {
                        updateLastPollTime(blockTime)
                    }
                }
            }
        }

        return true
    }

    func fetchContextualMessagesForActive(
        contactAddress: String,
        myAddress: String,
        privateKey: Data?,
        fallbackSince: UInt64,
        nowMs: UInt64,
        forceExactBlockTime: Bool = false
    ) async -> Bool {
        if contactsManager.getContact(byAddress: contactAddress)?.isArchived == true {
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
                    NSLog("[ChatService] Contextual fetch in-flight, skipping active incoming %@",
                          String(contactAddress.suffix(10)))
                    continue
                }
                defer { endContextualFetch(fetchKey) }
                guard let messages = await retryUntilSuccess(
                    label: "fetch incoming contextual messages (active) from \(contactAddress.suffix(10))",
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
                return false
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
                        isOutgoing: false,
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

        // Outgoing from us (use routing state aliases + legacy fallback)
        let outAliases = outgoingFetchAliases(for: contactAddress)
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
                    NSLog("[ChatService] Contextual fetch in-flight, skipping active outgoing %@",
                          String(contactAddress.suffix(10)))
                    continue
                }
                defer { endContextualFetch(fetchKey) }
                guard let messages = await retryUntilSuccess(
                    label: "fetch outgoing contextual messages (active) to \(contactAddress.suffix(10))",
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
                return false
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
                    let existingMessage = findLocalMessage(txId: contextMsg.txId)
                    let content = existingMessage?.content ?? "📤 Sent via another device"

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

        return true
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
                    NSLog("[ChatService] Found messages from %@ on attempt %d", String(contactAddress.suffix(10)), attempt)
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

        NSLog("[ChatService] No new messages from %@ after %d attempts", String(contactAddress.suffix(10)), maxAttempts)
    }

    /// Fetch contextual messages from a specific contact (triggered by UTXO notification)
    /// Returns true if any new messages were added
    @discardableResult
    func fetchContextualMessagesFromContact(contactAddress: String, myAddress: String, privateKey: Data) async -> ContactFetchResult {
        // Get incoming aliases for this contact (deterministic + legacy)
        let aliases = incomingAliases(for: contactAddress)
        guard !aliases.isEmpty else {
            NSLog("[ChatService] No alias for contact %@, cannot fetch contextual messages", String(contactAddress.suffix(10)))
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
                    nowMs: nowMs
                )
                let effectiveSince = applyMessageRetention(to: startBlockTime)
                let fetchKey = contextualFetchKey(address: contactAddress, alias: alias, limit: 10, since: effectiveSince)
                guard beginContextualFetch(fetchKey) else {
                    NSLog("[ChatService] Contextual fetch in-flight, skipping contact %@",
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
                    if findLocalMessage(txId: contextMsg.txId) != nil {
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
                        isOutgoing: false,
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
                NSLog("[ChatService] New contextual messages added from contact %@", String(contactAddress.suffix(10)))
            }

            return .success(added: newMessagesAdded)

        } catch {
            if ChatService.handleDpiPaginationFailure(error, context: "contact contextual messages") {
                return .failure
            }
            NSLog("[ChatService] Failed to fetch contextual messages from contact %@: %@",
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
        NSLog("[ChatService] === PROCESSING %d %@ PAYMENTS ===", payments.count, direction)
        let hideAutoCreatedPaymentChats = SettingsViewModel.loadSettings().hideAutoCreatedPaymentChats

        var needsFullSync = false

        for payment in payments {
            if isSuppressedPaymentTxId(payment.txId) {
                _ = addKNSTransferMessageFromHintIfNeeded(
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
                        print("[ChatService] Resolved sender for \(payment.txId.prefix(16))...: \(contactAddress.suffix(10))")
                    } else {
                        // Still couldn't resolve - try to get any input address from the transaction
                        // as a temporary solution, then schedule full sync for proper resolution
                        if let tempSender = await fetchAnyInputAddress(txId: payment.txId, excludeAddress: myAddress) {
                            contactAddress = tempSender
                            NSLog("[ChatService] Using temporary sender for %@: %@", String(payment.txId.prefix(16)), String(tempSender.suffix(20)))
                            needsFullSync = true
                        } else {
                            NSLog("[ChatService] Sender completely unresolved for %@, scheduling full sync", String(payment.txId.prefix(16)))
                            needsFullSync = true
                            continue
                        }
                    }
                } else {
                    contactAddress = payment.sender
                }
            }

            // Skip if we couldn't determine the contact address
            NSLog("[ChatService] Payment %@ - contactAddress: %@, myAddress: %@, match: %d",
                  String(payment.txId.prefix(16)),
                  String(contactAddress.suffix(20)),
                  String(myAddress.suffix(20)),
                  contactAddress == myAddress ? 1 : 0)

            if !isOutgoing, let existing = findLocalMessage(txId: payment.txId) {
                if existing.isOutgoing {
                    // Don't replace a promoted outgoing payment with an incoming classification
                    // from an async resolve - the outgoing classification is authoritative
                    if existing.messageType == .payment && existing.deliveryStatus != .pending {
                        NSLog("[ChatService] Skipping incoming reclassification for %@ - already promoted as outgoing payment",
                              String(payment.txId.prefix(16)))
                        continue
                    }
                    NSLog("[ChatService] Replacing outgoing message for %@ with incoming payment",
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
                NSLog("[ChatService] Skipping payment %@ - self-address detected", String(payment.txId.prefix(16)))
                continue
            }

            // Skip if this transaction already exists as a handshake message
            if let existingMsg = findLocalMessage(txId: payment.txId), existingMsg.messageType == .handshake {
                NSLog("[ChatService] Skipping payment %@ - already exists as handshake", String(payment.txId.prefix(16)))
                continue
            }

            // Check if this payment is actually a handshake (REST API payload detection)
            if let payload = payment.messagePayload, !payload.isEmpty, isHandshakePayload(payload) {
                NSLog("[ChatService] Payment %@ has handshake payload - processing as handshake", String(payment.txId.prefix(16)))
                var handshakeContent = "[Handshake]"
                if !isOutgoing, let privKey = privateKey {
                    // For incoming handshakes, decrypt to extract alias
                    if let decrypted = await decryptHandshakePayload(payload, privateKey: privKey) {
                        handshakeContent = "[Request to communicate]"
                        if let alias = decrypted.alias {
                            addConversationAlias(alias, for: contactAddress, blockTime: payment.blockTime)
                            NSLog("[ChatService] Extracted alias '%@' from payment-handshake by %@", alias, String(contactAddress.suffix(10)))
                        } else {
                            NSLog("[ChatService] Received deterministic (alias-less) payment-handshake from %@", String(contactAddress.suffix(10)))
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
                    NSLog("[ChatService] Payment %@ has contextual payload - skipping as payment", String(payment.txId.prefix(16)))
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
                    NSLog("[ChatService] Payment %@ has self-stash payload - skipping", String(payment.txId.prefix(16)))
                    continue
                }
            }

            let existingContact = contactsManager.getContact(byAddress: contactAddress)
            let hasExistingConversation = conversations.contains { $0.contact.address == contactAddress }
            if hideAutoCreatedPaymentChats && existingContact == nil && !hasExistingConversation {
                NSLog("[ChatService] Skipping payment %@ - auto-created payment chats disabled for %@",
                      String(payment.txId.prefix(16)),
                      String(contactAddress.suffix(20)))
                if let blockTime = payment.blockTime, blockTime > lastPollTime {
                    updateLastPollTime(blockTime)
                }
                continue
            }

            // Decode payment message
            let content = paymentContent(payment, isOutgoing: isOutgoing)

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

            addMessageToConversation(message, contactAddress: contactAddress)

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
            NSLog("[ChatService] Triggering full sync to resolve pending senders...")
            Task { @MainActor in
                // Small delay before full sync to let API propagate
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self.fetchNewMessages(forActiveOnly: nil)  // nil triggers full fetch
            }
        }
    }

    /// Find a locally stored message by transaction ID
    func findLocalMessage(txId: String) -> ChatMessage? {
        for conversation in conversations {
            if let message = conversation.messages.first(where: { $0.txId == txId }) {
                return message
            }
        }
        guard let key = messageEncryptionKey() else { return nil }
        return messageStore.fetchMessage(txId: txId, decryptionKey: key)
    }

    func hasLocalMessage(txId: String) -> Bool {
        return findLocalMessage(txId: txId) != nil
    }

    func addOutgoingMessageFromPush(
        txId: String,
        sender: String,
        payload: String?,
        timestamp: Int64
    ) async -> Bool {
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            NSLog("[ChatService] Outgoing push: missing private key")
            return false
        }

        // Check if message already exists with content (not placeholder)
        if let existingMsg = findLocalMessage(txId: txId),
           existingMsg.content != "📤 Sent via another device" {
            NSLog("[ChatService] Outgoing push already exists with content: %@", txId)
            return true
        }

        // PRIORITY 1: Try CloudKit sync first
        // Outgoing messages from other devices have their content stored in CloudKit
        // The on-chain payload is encrypted for the recipient, so we can't decrypt it here
        NSLog("[ChatService] Outgoing push from other device: %@ - trying CloudKit sync", txId)

        let settings = currentSettings
        if settings.storeMessagesInICloud {
            // Trigger CloudKit to fetch any pending changes
            await messageStore.waitForCloudKitSync(timeout: 5)

            // Reload messages from store (includes CloudKit-synced data)
            loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

            // Brief pause for Core Data to merge
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Check if CloudKit delivered the content
            if let cloudKitMsg = findLocalMessage(txId: txId),
               cloudKitMsg.content != "📤 Sent via another device" {
                NSLog("[ChatService] Outgoing push resolved via CloudKit: %@", txId)
                return true
            }

            NSLog("[ChatService] CloudKit sync did not deliver content for %@ - trying payload decrypt", txId)
        }

        // PRIORITY 2: Try to decrypt on-chain payload (may work for some message types)
        let rawPayload = await resolveRawPayloadForTx(txId: txId, payloadHint: payload)
        guard let rawPayload else {
            NSLog("[ChatService] Outgoing push: failed to resolve raw payload for %@", txId)
            // Schedule a retry - CloudKit may deliver later
            scheduleCloudKitRetryForOutgoing(txId: txId, sender: sender, timestamp: timestamp)
            return false
        }

        guard let payloadString = Self.hexStringToData(rawPayload)
            .flatMap({ String(data: $0, encoding: .utf8) }) else {
            NSLog("[ChatService] Outgoing push: invalid raw payload for %@", txId)
            return false
        }

        guard let alias = Self.extractContextualAlias(fromRawPayloadString: payloadString) else {
            NSLog("[ChatService] Outgoing push: alias not found for %@", txId)
            return false
        }

        guard let contactAddress = contactAddressForOutgoingAlias(alias) else {
            NSLog("[ChatService] Outgoing push: no contact for alias %@ (tx=%@)", alias, txId)
            return false
        }

        guard let decrypted = await decryptContextualMessageFromRawPayload(rawPayload, privateKey: privateKey) else {
            NSLog("[ChatService] Outgoing push: decrypt failed for %@ - content will sync via CloudKit", txId)
            // Create placeholder message - CloudKit will deliver actual content
            let placeholderMessage = ChatMessage(
                txId: txId,
                senderAddress: sender,
                receiverAddress: contactAddress,
                content: "📤 Sent via another device",
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
            NSLog("[ChatService] Outgoing push updated pending message: %@ to %@", txId, String(contactAddress.suffix(10)))
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
        NSLog("[ChatService] Outgoing push imported: %@ to %@", txId, String(contactAddress.suffix(10)))
        return true
    }

    /// Schedule a CloudKit retry for outgoing messages that couldn't be resolved immediately
    func scheduleCloudKitRetryForOutgoing(txId: String, sender: String, timestamp: Int64) {
        Task {
            // Wait 5 seconds for CloudKit to potentially deliver
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            // Reload from store
            loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

            // Check if content arrived
            if let msg = findLocalMessage(txId: txId),
               msg.content != "📤 Sent via another device" {
                NSLog("[ChatService] CloudKit retry successful for outgoing: %@", txId)
                return
            }

            // Try again after 15 seconds
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)

            if let msg = findLocalMessage(txId: txId),
               msg.content == "📤 Sent via another device" {
                NSLog("[ChatService] Outgoing message %@ still awaiting CloudKit sync", txId)
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
           raw.hasPrefix("ciph_msg:") {
            return raw.data(using: .utf8)?.hexString
        }

        if let payloadHint,
           let data = Data(hexString: payloadHint),
           let raw = String(data: data, encoding: .utf8),
           raw.hasPrefix("ciph_msg:") {
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
        if let existing = contactsManager.getContact(byAddress: contactAddress), existing.isArchived {
            return
        }
        let contact = contactsManager.getOrCreateContact(address: contactAddress)
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

        if let index = conversations.firstIndex(where: { $0.contact.address == contactAddress }) {
            updateConversation(at: index) { conversation in
                if !conversation.messages.contains(where: { $0.txId == message.txId }) {
                    conversation.messages.append(message)
                    isNewMessage = true
                    if !message.isOutgoing {
                        if isUserViewing {
                            conversation.unreadCount = 0
                        } else {
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
                conversation.unreadCount = isUserViewing ? 0 : 1
            }
            conversations.append(conversation)
            markConversationDirty(contactAddress)
            print("[ChatService] Created NEW conversation for contact \(contactAddress.suffix(10)), total conversations: \(conversations.count)")
            if isSyncInProgress {
                needsMessageStoreSyncAfterBatch = true
            } else {
                saveMessages()
            }
        }

        // Update contact's last message time (debounced to avoid per-message saves)
        queueLastMessageUpdate(contactId: contact.id, date: message.timestamp)

        if isNewMessage {
            print("[ChatService] Added message \(message.txId.prefix(16))... to \(contactAddress.suffix(10)), type: \(message.messageType), isNew: \(isNewConversation)")
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
        if isNewMessage && !message.isOutgoing && !isViewingConversation {
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

    func sendLocalNotification(for message: ChatMessage, from contact: Contact) {
        let settings = currentSettings
        // Check if notifications are enabled
        guard settings.notificationsEnabled else { return }
        guard settings.notificationMode != .remotePush else { return }

        // Don't notify during initial sync after wallet import/create
        guard !suppressNotificationsUntilSynced else { return }

        // Respect global defaults + optional per-contact override.
        guard settings.shouldDeliverIncomingNotification(for: contact) else { return }

        // Don't notify for pending messages
        guard message.deliveryStatus != .pending else { return }

        let content = UNMutableNotificationContent()
        content.title = contact.alias
        content.body = formatNotificationBody(message.content)
        let shouldPlaySound = settings.shouldPlayIncomingNotificationSound(for: contact)
        content.sound = shouldPlaySound ? .default : nil
        content.threadIdentifier = contact.address

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
                print("[ChatService] Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    func formatNotificationBody(_ content: String) -> String {
        // Check if content is a file JSON payload
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else {
            return content
        }

        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let mimeType = json["mimeType"] as? String else {
            return content
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
        var updatedConversations = conversations
        let originalConversation = updatedConversations[index]
        var conversation = originalConversation
        update(&conversation)
        if normalizeMessages {
            conversation.messages = dedupeMessages(conversation.messages)
        }
        guard conversation != originalConversation else { return }
        updatedConversations[index] = conversation
        conversations = updatedConversations
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
        if payload.hasPrefix("ciph_msg:") {
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
        if payload.hasPrefix("ciph_msg:") {
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
                    ? NSLocalizedString("Sent %@ KAS — %@", comment: "Outgoing payment with note")
                    : NSLocalizedString("Received %@ KAS — %@", comment: "Incoming payment with note")
                return String(format: template, formatted, payload.message)
            }
            let template = isOutgoing
                ? NSLocalizedString("Sent %@ KAS", comment: "Outgoing payment without note")
                : NSLocalizedString("Received %@ KAS", comment: "Incoming payment without note")
            return String(format: template, formatted)
        }

        if let payload = decodePaymentPayload(payment.messagePayload) {
            let formatted = formatKasAmount(payload.amount)
            let template = NSLocalizedString("Payment: %@ KAS — %@", comment: "Fallback payment content with amount and note")
            return String(format: template, formatted, payload.message)
        }

        return NSLocalizedString("[Payment]", comment: "Fallback payment label")
    }

    func localizedKNSTransferMessage(domainName: String?, isOutgoing: Bool) -> String {
        let trimmedDomain = domainName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDomain.isEmpty {
            let template = isOutgoing
                ? NSLocalizedString("Sent %@ domain", comment: "Outgoing KNS domain transfer message")
                : NSLocalizedString("Received %@ domain", comment: "Incoming KNS domain transfer message")
            return String(format: template, trimmedDomain)
        }
        return isOutgoing
            ? NSLocalizedString("Sent domain transfer", comment: "Outgoing KNS domain transfer fallback")
            : NSLocalizedString("Received domain transfer", comment: "Incoming KNS domain transfer fallback")
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
