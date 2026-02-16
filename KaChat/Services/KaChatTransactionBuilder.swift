import Foundation
import CryptoKit
import P256K

/// Builds Kaspa transactions for Kasia messaging protocol
struct KasiaTransactionBuilder {

    // Kaspa constants
    static let handshakeAmount: UInt64 = 20_000_000 // 0.2 KAS handshake amount
    static let dustThreshold: UInt64 = 10_000 // Minimum output value for P2PKH (0.0001 KAS)
    static let standardSubnetworkId = Data(repeating: 0, count: 20)
    private static let selfStashScope = "saved_handshake"

    private static func addSompiChecked(_ current: UInt64, _ amount: UInt64, context: String) throws -> UInt64 {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard !overflow else {
            NSLog("[TxBuilder] Rejecting suspicious UTXO sum overflow (%@): current=%llu add=%llu", context, current, amount)
            throw KasiaError.networkError("Invalid UTXO data: amount overflow")
        }
        return next
    }

    /// Build a contextual message transaction
    static func buildContextualMessageTx(
        from senderAddress: String,
        to recipientAddress: String,
        alias: String,
        message: String,
        senderPrivateKey: Data,
        recipientPublicKey: Data,
        utxos: [UTXO]
    ) throws -> KaspaRpcTransaction {
        // 1. Encrypt the message for the recipient
        let kasiaPayload = try buildContextualMessagePayload(
            alias: alias,
            message: message,
            recipientPublicKey: recipientPublicKey
        )

        // 3. Select UTXOs (use all available)
        let (selectedUtxos, totalInput) = try selectUtxos(utxos, requiredAmount: 1)

        // 4. Build sender output script (self-spend)
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        // 5. Estimate fee using mass-based calculation (1 sompi per gram) and add tiny buffer to avoid under-fee rejection
        let baseFee = estimateFee(
            payload: kasiaPayload,
            inputCount: selectedUtxos.count,
            outputs: [
                KaspaRpcTransactionOutput(
                    value: 0,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
                )
            ]
        )
        let fee = baseFee + 3 // small constant to cover observed 3-sompi gap

        // Self-spend: single output back to sender (full amount minus fee)
        guard totalInput > fee else {
            throw KasiaError.networkError("Insufficient funds after fee")
        }
        let outputAmount = totalInput - fee

        let outputs = [KaspaRpcTransactionOutput(
            value: outputAmount,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )]

        // Build unsigned transaction - payload contains Kasia message
        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: selectedUtxos.map { utxo in
                KaspaRpcTransactionInput(
                    previousOutpoint: utxo.outpoint,
                    signatureScript: Data(), // Will be filled after signing
                    sequence: 0,
                    sigOpCount: 1
                )
            },
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: kasiaPayload
        )

        // 8. Sign transaction
        let signedTx = try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selectedUtxos)

        return signedTx
    }

    /// Estimate fee for a contextual message based on payload and input count
    static func estimateContextualMessageFee(payload: Data, inputCount: Int, senderScriptPubKey: Data) -> UInt64 {
        let output = KaspaRpcTransactionOutput(
            value: 0,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )
        // Add a tiny constant to avoid under-fee rejection (observed 3 sompi gap)
        return estimateFee(payload: payload, inputCount: inputCount, outputs: [output]) + 3
    }

    /// Build a payment transaction
    /// Uses same encoding as contextual messages (wrapPayloads=true, verboseData=true, legacyVersionByte=true)
    static func buildPaymentTx(
        from senderAddress: String,
        to recipientAddress: String,
        amount: UInt64,
        note: String,
        senderPrivateKey: Data,
        recipientPublicKey: Data,
        utxos: [UTXO]
    ) throws -> KaspaRpcTransaction {
        guard amount > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }

        #if DEBUG
        NSLog("[TxBuilder] Building payment transaction:")
        NSLog("[TxBuilder]   from: %@", senderAddress)
        NSLog("[TxBuilder]   to: %@", recipientAddress)
        NSLog("[TxBuilder]   amount: %llu sompi", amount)
        #endif

        // Build payment payload (encrypted hex under ciph_msg:1:pay:)
        let paymentPayload = try buildPaymentPayload(message: note, amount: amount, recipientPublicKey: recipientPublicKey)
        #if DEBUG
        NSLog("[TxBuilder]   payload size: %d bytes", paymentPayload.count)
        NSLog("[TxBuilder]   payload hex (first 100): %@", paymentPayload.prefix(100).map { String(format: "%02x", $0) }.joined())
        #endif

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: recipientAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        let selection = try selectUtxosForPayment(
            utxos: utxos,
            amount: amount,
            payload: paymentPayload,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        )

        #if DEBUG
        var selectedTotal: UInt64 = 0
        var selectedTotalOverflow = false
        for utxo in selection.utxos {
            let (next, overflow) = selectedTotal.addingReportingOverflow(utxo.amount)
            if overflow {
                selectedTotalOverflow = true
                break
            }
            selectedTotal = next
        }
        let totalForLog = selectedTotalOverflow ? "overflow" : String(selectedTotal)
        NSLog("[TxBuilder]   selected %d UTXOs, total input: %@, change: %llu", selection.utxos.count, totalForLog, selection.change)
        #endif

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )
        ]
        if selection.change > dustThreshold {
            outputs.append(KaspaRpcTransactionOutput(
                value: selection.change,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
            ))
        }

        #if DEBUG
        NSLog("[TxBuilder]   %d outputs: %@", outputs.count, outputs.map { String($0.value) }.joined(separator: ", "))
        #endif

        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: selection.utxos.map { utxo in
                KaspaRpcTransactionInput(
                    previousOutpoint: utxo.outpoint,
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            },
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: paymentPayload
        )

        let signedTx = try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selection.utxos)
        return signedTx
    }

    /// Estimate payment fee based on payload and utxo set
    static func estimatePaymentFee(utxos: [UTXO], payload: Data, amount: UInt64, recipientScriptPubKey: Data, senderScriptPubKey: Data) throws -> UInt64 {
        let selection = try selectUtxosForPayment(
            utxos: utxos,
            amount: amount,
            payload: payload,
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey
        )

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )
        ]
        if selection.change > dustThreshold {
            outputs.append(KaspaRpcTransactionOutput(
                value: selection.change,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
            ))
        }

        return estimateFee(payload: payload, inputCount: selection.utxos.count, outputs: outputs)
    }

    /// Estimate fee for send-all transaction (all UTXOs, single output, no change)
    /// Uses 2 outputs in calculation to be conservative (matches selectUtxosForPayment behavior)
    static func estimateSendAllFee(utxos: [UTXO], payload: Data, recipientScriptPubKey: Data, senderScriptPubKey: Data) -> UInt64 {
        let spendable = utxos.filter { !$0.isCoinbase }
        // Calculate with 2 outputs to match selectUtxosForPayment which always estimates with change first
        let outputs = [
            KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)),
            KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
        ]
        return estimateFee(payload: payload, inputCount: spendable.count, outputs: outputs) + 3
    }

    /// Build the contextual message payload used by Kasia transactions
    static func buildContextualMessagePayload(
        alias: String,
        message: String,
        recipientPublicKey: Data
    ) throws -> Data {
        let encryptedPayload = try encryptContextualMessage(
            alias: alias,
            content: message,
            recipientPublicKey: recipientPublicKey
        )
        return buildKasiaPayload(
            type: .contextualMessage,
            alias: alias,
            payload: encryptedPayload
        )
    }

    /// Build a handshake transaction
    static func buildHandshakeTx(
        from senderAddress: String,
        to recipientAddress: String,
        alias: String,
        conversationId: String?,
        isResponse: Bool,
        senderPrivateKey: Data,
        recipientPublicKey: Data,
        utxos: [UTXO]
    ) throws -> KaspaRpcTransaction {
        let encryptedHandshake = try encryptHandshakePayload(
            alias: alias,
            recipientAddress: recipientAddress,
            conversationId: conversationId,
            isResponse: isResponse ? true : nil,
            recipientPublicKey: recipientPublicKey
        )

        // Payload format: hex("ciph_msg:1:handshake:") + <encrypted_hex>
        let prefixHex = hexString(from: "ciph_msg:1:handshake:")
        let payloadHex = prefixHex + encryptedHandshake.toBytes().hexString
        let kasiaPayload = Data(hexString: payloadHex) ?? Data()

        let (selectedUtxos, totalInput) = try selectUtxos(utxos, requiredAmount: 1)

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: recipientAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        let recipientOutput = KaspaRpcTransactionOutput(
            value: handshakeAmount,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
        )

        let feeWithChange = estimateFee(
            payload: kasiaPayload,
            inputCount: selectedUtxos.count,
            outputs: [
                recipientOutput,
                KaspaRpcTransactionOutput(
                    value: 0,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
                )
            ]
        ) + 3 // small buffer to avoid under-fee rejection

        var outputs: [KaspaRpcTransactionOutput] = [recipientOutput]

        if totalInput <= handshakeAmount || totalInput - handshakeAmount <= feeWithChange {
            throw KasiaError.networkError("Insufficient funds for handshake")
        }

        var change = totalInput - handshakeAmount - feeWithChange

        if change > dustThreshold {
            outputs.append(KaspaRpcTransactionOutput(
                value: change,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
            ))
        } else {
            let feeNoChange = estimateFee(
                payload: kasiaPayload,
                inputCount: selectedUtxos.count,
                outputs: [recipientOutput]
            ) + 3 // small buffer to avoid under-fee rejection
            if totalInput <= handshakeAmount || totalInput - handshakeAmount <= feeNoChange {
                throw KasiaError.networkError("Insufficient funds for handshake")
            }
            change = totalInput - handshakeAmount - feeNoChange
            if change > 0 {
                // Treat remainder as additional fee when change is dust
            }
        }

        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: selectedUtxos.map { utxo in
                KaspaRpcTransactionInput(
                    previousOutpoint: utxo.outpoint,
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            },
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: kasiaPayload
        )

        return try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selectedUtxos)
    }

    /// Build a self-stash transaction to persist handshake metadata on-chain (saved_handshake)
    static func buildHandshakeSelfStashTx(
        from senderAddress: String,
        partnerAddress: String,
        ourAlias: String,
        theirAlias: String?,
        isResponse: Bool,
        senderPrivateKey: Data,
        utxos: [UTXO]
    ) throws -> KaspaRpcTransaction {
        // Encrypt handshake metadata to ourselves
        guard let senderPubKey = KaspaAddress.publicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        let payloadDict: [String: Any?] = [
            "type": "handshake",
            "alias": ourAlias,
            "timestamp": UInt64(Date().timeIntervalSince1970 * 1000),
            "version": 1,
            "theirAlias": theirAlias,
            "partnerAddress": partnerAddress,
            "recipientAddress": partnerAddress,
            "isResponse": isResponse ? true : nil
        ]

        let sanitized = payloadDict.compactMapValues { $0 }
        let payloadData = try JSONSerialization.data(withJSONObject: sanitized, options: [])
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw KasiaError.encryptionError("Failed to encode self-stash payload")
        }

        let encrypted = try KasiaCipher.encrypt(payloadString, recipientPublicKey: senderPubKey)
        let encryptedHex = encrypted.toBytes().hexString

        // Payload format: hex("ciph_msg:1:self_stash:") + hex("saved_handshake:") + <hex encrypted bytes>
        let prefixHex = hexString(from: "ciph_msg:1:self_stash:")
        let scopeHex = hexString(from: "\(selfStashScope):")
        let payloadHex = prefixHex + scopeHex + encryptedHex
        let payload = Data(hexString: payloadHex) ?? Data()

        // UTXO selection (no amount spend, just fee)
        let (selectedUtxos, totalInput) = try selectUtxos(utxos, requiredAmount: 1)
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        // Single output back to self
        let outputTemplate = KaspaRpcTransactionOutput(
            value: 0,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )

        let baseFee = estimateFee(
            payload: payload,
            inputCount: selectedUtxos.count,
            outputs: [outputTemplate]
        )
        let fee = baseFee + 3 // small buffer to avoid under-fee rejection

        guard totalInput > fee else {
            throw KasiaError.networkError("Insufficient funds for self-stash fee")
        }

        let changeAmount = totalInput - fee
        let output = KaspaRpcTransactionOutput(
            value: changeAmount,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )

        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: selectedUtxos.map { utxo in
                KaspaRpcTransactionInput(
                    previousOutpoint: utxo.outpoint,
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            },
            outputs: [output],
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: payload
        )

        return try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selectedUtxos)
    }

    // MARK: - Private Methods

    private enum KasiaMessageType {
        case handshake
        case contextualMessage
        case payment
        case selfStash
    }

    /// Build Kasia protocol payload for transaction payload field
    /// Format: ciph_msg:1:<type>:<alias>:<base64_encrypted_payload>
    /// This goes in the transaction's native payload field, NOT as an OP_RETURN script
    private static func buildKasiaPayload(
        type: KasiaMessageType,
        alias: String?,
        payload: Data
    ) -> Data {
        switch type {
        case .handshake:
            // Handshake payload is binary: ciph_msg:1:handshake:<encrypted_bytes>
            var data = Data("ciph_msg:1:handshake:".utf8)
            data.append(payload)
            return data
        case .contextualMessage:
            var protocolString = "ciph_msg:1:comm:"
            if let alias = alias {
                protocolString += alias + ":"
            }
            if let payloadString = String(data: payload, encoding: .utf8) {
                protocolString += payloadString
            }
            return Data(protocolString.utf8)
        case .payment:
            var protocolString = "ciph_msg:1:pay:"
            if let payloadString = String(data: payload, encoding: .utf8) {
                protocolString += payloadString
            }
            return Data(protocolString.utf8)
        case .selfStash:
            var protocolString = "ciph_msg:1:self_stash:"
            if let payloadString = String(data: payload, encoding: .utf8) {
                protocolString += payloadString
            }
            return Data(protocolString.utf8)
        }
    }

    /// Encrypt contextual message for recipient
    private static func encryptContextualMessage(
        alias: String,
        content: String,
        recipientPublicKey: Data
    ) throws -> Data {
        // Encrypt raw message content (external client behavior)
        let encrypted = try KasiaCipher.encrypt(content, recipientPublicKey: recipientPublicKey)

        // Return as base64-encoded string (matching external Kasia format)
        let base64 = encrypted.toBytes().base64EncodedString()
        return Data(base64.utf8)
    }

    /// Encrypt handshake payload for recipient
    private static func encryptHandshakePayload(
        alias: String,
        recipientAddress: String,
        conversationId: String?,
        isResponse: Bool?,
        recipientPublicKey: Data
    ) throws -> KasiaCipher.EncryptedMessage {
        let payload = HandshakePayload(
            type: "handshake",
            alias: alias,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            conversationId: conversationId,
            version: 1,
            recipientAddress: recipientAddress,
            sendToRecipient: true,
            isResponse: isResponse
        )
        guard let payloadData = try? JSONEncoder().encode(payload),
              let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw KasiaError.encryptionError("Failed to encode handshake payload")
        }
        return try KasiaCipher.encrypt(payloadString, recipientPublicKey: recipientPublicKey)
    }

    private struct PaymentSelection {
        let utxos: [UTXO]
        let change: UInt64
    }

    /// Select minimal UTXOs to cover payment and fee
    private static func selectUtxosForPayment(
        utxos: [UTXO],
        amount: UInt64,
        payload: Data,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data
    ) throws -> PaymentSelection {
        // Sort largest first to reduce input count (lower mass)
        let sorted = utxos.sorted { $0.amount > $1.amount }
        var selected: [UTXO] = []
        var total: UInt64 = 0

        for utxo in sorted {
            if utxo.isCoinbase { continue }
            selected.append(utxo)
            total = try addSompiChecked(total, utxo.amount, context: "payment selection")

            let recipientOutput = KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )

            // Estimate with change output (+ buffer to avoid under-fee rejection)
            let feeWithChange = estimateFee(
                payload: payload,
                inputCount: selected.count,
                outputs: [
                    recipientOutput,
                    KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
                ]
            ) + 3

            if total <= amount || total - amount < feeWithChange {
                continue
            }

            var change = total - amount - feeWithChange
            if change > dustThreshold {
                return PaymentSelection(utxos: selected, change: change)
            }

            // Try without change (treat dust as fee, + buffer)
            let feeNoChange = estimateFee(payload: payload, inputCount: selected.count, outputs: [recipientOutput]) + 3
            if total > amount && total - amount >= feeNoChange {
                change = total - amount - feeNoChange
                return PaymentSelection(utxos: selected, change: change)
            }
        }

        throw KasiaError.networkError("Insufficient funds for payment")
    }

    /// Build payment payload (encrypted payment JSON, hex inside ciph_msg:1:pay:)
    static func buildPaymentPayload(message: String, amount: UInt64, recipientPublicKey: Data) throws -> Data {
        let payload = PaymentPayload(
            type: "payment",
            message: message,
            amount: amount,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            version: 1
        )
        let json = try JSONEncoder().encode(payload)
        guard let jsonString = String(data: json, encoding: .utf8) else {
            throw KasiaError.encryptionError("Failed to encode payment payload")
        }
        let encrypted = try KasiaCipher.encrypt(jsonString, recipientPublicKey: recipientPublicKey)
        let hex = encrypted.toBytes().hexString
        let prefixHex = hexString(from: "ciph_msg:1:pay:")
        let payloadHex = prefixHex + hex
        return Data(hexString: payloadHex) ?? Data()
    }

    /// Select UTXOs to cover required amount
    private static func selectUtxos(_ utxos: [UTXO], requiredAmount: UInt64) throws -> ([UTXO], UInt64) {
        // Use ALL available UTXOs (match external Kasia app's behavior)
        // External app uses each UTXO as a separate input
        var selected: [UTXO] = []
        var totalAmount: UInt64 = 0

        for utxo in utxos {
            // Skip coinbase UTXOs that might not be mature
            if utxo.isCoinbase {
                continue
            }

            selected.append(utxo)
            totalAmount = try addSompiChecked(totalAmount, utxo.amount, context: "utxo selection")

            #if DEBUG
            print("[TxBuilder] Selected UTXO: \(utxo.amount) sompi, total: \(totalAmount)")
            #endif
        }

        guard totalAmount >= requiredAmount else {
            throw KasiaError.networkError("Insufficient funds. Have \(totalAmount), need \(requiredAmount)")
        }

        #if DEBUG
        print("[TxBuilder] Total selected: \(selected.count) UTXOs, total amount: \(totalAmount)")
        #endif

        return (selected, totalAmount)
    }

    /// Calculate transaction fee based on compute mass (1 sompi per gram)
    /// Note: Storage mass is a separate validity check (must be <= 100000), not part of fee.
    private static func estimateFee(payload: Data, inputCount: Int, outputs: [KaspaRpcTransactionOutput]) -> UInt64 {
        let sigScriptSize = 66 // 0x41 + 64-byte sig + sighash
        let dummyInput = KaspaRpcTransactionInput(
            previousOutpoint: UTXO.Outpoint(transactionId: String(repeating: "0", count: 64), index: 0),
            signatureScript: Data(repeating: 0, count: sigScriptSize),
            sequence: 0,
            sigOpCount: 1
        )
        let inputs = Array(repeating: dummyInput, count: inputCount)
        return computeComputeMass(
            version: 0,
            inputs: inputs,
            outputs: outputs,
            payload: payload,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            lockTime: 0
        )
    }

    /// Sign transaction inputs using Schnorr
    internal static func signTransaction(
        _ transaction: KaspaRpcTransaction,
        privateKey: Data,
        utxos: [UTXO]
    ) throws -> KaspaRpcTransaction {
        let schnorrPrivKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        var signedInputs: [KaspaRpcTransactionInput] = []

        for (index, input) in transaction.inputs.enumerated() {
            let utxo = utxos[index]
            let sighash = try computeSighash(
                transaction: transaction,
                inputIndex: index,
                utxoScriptPubKey: utxo.scriptPublicKey,
                utxoAmount: utxo.amount
            )

            var sighashBytes = [UInt8](sighash)
            let signature = try schnorrPrivKey.signature(message: &sighashBytes, auxiliaryRand: nil)
            // Zero sighash bytes after signing
            for i in sighashBytes.indices { sighashBytes[i] = 0 }
            let sigBytes = Data(signature.bytes)

            // Kaspa signature script: push 65 bytes, 64-byte Schnorr signature, SIGHASH_ALL
            var sigScript = Data()
            sigScript.append(0x41) // push 65 bytes
            sigScript.append(sigBytes)
            sigScript.append(0x01) // SIGHASH_ALL

            signedInputs.append(KaspaRpcTransactionInput(
                previousOutpoint: input.previousOutpoint,
                signatureScript: sigScript,
                sequence: input.sequence,
                sigOpCount: input.sigOpCount
            ))
        }

        return KaspaRpcTransaction(
            version: transaction.version,
            inputs: signedInputs,
            outputs: transaction.outputs,
            lockTime: transaction.lockTime,
            subnetworkId: transaction.subnetworkId,
            gas: transaction.gas,
            payload: transaction.payload
        )
    }

    /// Compute sighash for transaction input (Kaspa-specific)
    /// Uses Blake2b with "TransactionSigningHash" domain separation (as KEY, not personalization)
    internal static func computeSighash(
        transaction: KaspaRpcTransaction,
        inputIndex: Int,
        utxoScriptPubKey: Data,
        utxoAmount: UInt64
    ) throws -> Data {
        // Kaspa uses Blake2b-256 with KEY for domain separation (not personalization)
        var hasher = Blake2b(digestLength: 32, key: "TransactionSigningHash".data(using: .utf8))

        // Hash version (u16)
        var version = transaction.version.littleEndian
        hasher.update(Data(bytes: &version, count: 2))

        // Hash of all previous outputs (Blake2b of all outpoints)
        var prevOutputsData = Data()
        for input in transaction.inputs {
            let txId = hexToData(input.previousOutpoint.transactionId) ?? Data(repeating: 0, count: 32)
            prevOutputsData.append(txId)
            var idx = input.previousOutpoint.index.littleEndian
            prevOutputsData.append(Data(bytes: &idx, count: 4))
        }
        let prevOutputsHash = Blake2b.hash(prevOutputsData, key: "TransactionSigningHash")
        hasher.update(prevOutputsHash)

        // Hash of all sequences
        var seqData = Data()
        for input in transaction.inputs {
            var seq = input.sequence.littleEndian
            seqData.append(Data(bytes: &seq, count: 8))
        }
        let seqHash = Blake2b.hash(seqData, key: "TransactionSigningHash")
        hasher.update(seqHash)

        // Hash of all sig op counts
        var sigOpData = Data()
        for input in transaction.inputs {
            sigOpData.append(input.sigOpCount)
        }
        let sigOpHash = Blake2b.hash(sigOpData, key: "TransactionSigningHash")
        hasher.update(sigOpHash)

        // Current input's outpoint
        let input = transaction.inputs[inputIndex]
        let txId = hexToData(input.previousOutpoint.transactionId) ?? Data(repeating: 0, count: 32)
        hasher.update(txId)
        var idx = input.previousOutpoint.index.littleEndian
        hasher.update(Data(bytes: &idx, count: 4))

        // UTXO script public key (with version prefix)
        // Use version 0 for sighash
        var scriptVer = UInt16(0).littleEndian
        hasher.update(Data(bytes: &scriptVer, count: 2))

        // Use full UTXO scriptPublicKey for sighash (Kaspa requires the complete script)
        let scriptBytes = utxoScriptPubKey
        // Script length (Kaspa sighash uses u64 length prefix)
        var scriptLen = UInt64(scriptBytes.count).littleEndian
        hasher.update(Data(bytes: &scriptLen, count: 8))
        hasher.update(scriptBytes)

        // UTXO amount
        var amount = utxoAmount.littleEndian
        hasher.update(Data(bytes: &amount, count: 8))

        // Input sequence
        var seq = input.sequence.littleEndian
        hasher.update(Data(bytes: &seq, count: 8))

        // Sig op count
        hasher.update(Data([input.sigOpCount]))

        // Hash of all outputs
        var outputsData = Data()
        for output in transaction.outputs {
            var value = output.value.littleEndian
            outputsData.append(Data(bytes: &value, count: 8))
            var scriptVer = output.scriptPublicKey.version.littleEndian
            outputsData.append(Data(bytes: &scriptVer, count: 2))
            var scriptLen = UInt64(output.scriptPublicKey.script.count).littleEndian
            outputsData.append(Data(bytes: &scriptLen, count: 8))
            outputsData.append(output.scriptPublicKey.script)
        }
        let outputsHash = Blake2b.hash(outputsData, key: "TransactionSigningHash")
        hasher.update(outputsHash)

        // Lock time
        var lockTime = transaction.lockTime.littleEndian
        hasher.update(Data(bytes: &lockTime, count: 8))

        // Subnetwork ID
        hasher.update(transaction.subnetworkId)

        // Gas (always included per rusty-kaspa/consensus/core/src/hashing/sighash.rs:261)
        var gas = transaction.gas.littleEndian
        hasher.update(Data(bytes: &gas, count: 8))

        // Payload hash (rusty-kaspa/consensus/core/src/hashing/sighash.rs:184-195)
        // If native subnetwork AND payload is empty, use ZERO_HASH
        // Otherwise, hash the payload with write_var_bytes format (u64 length + bytes)
        let isNativeSubnetwork = transaction.subnetworkId.allSatisfy { $0 == 0 }
        let payloadHash: Data
        if isNativeSubnetwork && transaction.payload.isEmpty {
            payloadHash = Data(repeating: 0, count: 32)  // ZERO_HASH
        } else {
            // Hash payload with length prefix (write_var_bytes format uses u64 length)
            var payloadToHash = Data()
            var payloadLen = UInt64(transaction.payload.count).littleEndian
            payloadToHash.append(Data(bytes: &payloadLen, count: 8))
            payloadToHash.append(transaction.payload)
            payloadHash = Blake2b.hash(payloadToHash, key: "TransactionSigningHash")
        }
        hasher.update(payloadHash)

        // Sighash type (SIGHASH_ALL = 1)
        hasher.update(Data([0x01]))

        return hasher.finalize()
    }

    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var temp = ""
        for char in hex {
            temp += String(char)
            if temp.count == 2 {
                if let byte = UInt8(temp, radix: 16) {
                    data.append(byte)
                } else {
                    return nil
                }
                temp = ""
            }
        }
        return data
    }

    // MARK: - Schnorr Signature Verification (REST API path)

    /// Input data parsed from REST API response for signature verification
    struct VerificationInput {
        let previousOutpointHash: String   // tx ID of the UTXO being spent
        let previousOutpointIndex: UInt32  // output index of the UTXO
        let signatureScript: String        // hex-encoded signature script
        let previousOutpointAddress: String // resolved address of the UTXO
        let previousOutpointAmount: UInt64 // amount of the UTXO
        let sequence: UInt64
        let sigOpCount: UInt8
    }

    /// Output data parsed from REST API response for signature verification
    struct VerificationOutput {
        let amount: UInt64
        let scriptPublicKey: String  // hex-encoded script public key
    }

    /// Verify Schnorr signatures on a transaction fetched via REST API.
    /// Returns true if all signatures are valid or if verification cannot be performed (missing fields).
    /// Returns false only if a signature is definitively invalid.
    static func verifyTransactionSignatures(
        inputs: [VerificationInput],
        outputs: [VerificationOutput],
        version: UInt16,
        lockTime: UInt64,
        subnetworkId: Data,
        gas: UInt64,
        payload: Data
    ) -> Bool {
        guard !inputs.isEmpty else { return true }

        // Reconstruct KaspaRpcTransaction from REST fields
        var rpcInputs: [KaspaRpcTransactionInput] = []
        for input in inputs {
            guard let outpointIndexVal = UInt32(exactly: input.previousOutpointIndex) else {
                return true // Cannot verify, skip gracefully
            }
            // Use empty signatureScript for sighash computation (sighash is computed over unsigned tx)
            rpcInputs.append(KaspaRpcTransactionInput(
                previousOutpoint: UTXO.Outpoint(
                    transactionId: input.previousOutpointHash,
                    index: outpointIndexVal
                ),
                signatureScript: Data(),
                sequence: input.sequence,
                sigOpCount: input.sigOpCount
            ))
        }

        var rpcOutputs: [KaspaRpcTransactionOutput] = []
        for output in outputs {
            guard let scriptData = hexToData(output.scriptPublicKey), !scriptData.isEmpty else {
                return true // Cannot verify without script data
            }
            rpcOutputs.append(KaspaRpcTransactionOutput(
                value: output.amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: scriptData)
            ))
        }

        let rpcTransaction = KaspaRpcTransaction(
            version: version,
            inputs: rpcInputs,
            outputs: rpcOutputs,
            lockTime: lockTime,
            subnetworkId: subnetworkId,
            gas: gas,
            payload: payload
        )

        // Verify each input's signature
        for (index, input) in inputs.enumerated() {
            // 1. Parse signatureScript: 0x41 (push 65 bytes) + 64-byte Schnorr sig + 0x01 (SIGHASH_ALL)
            guard let sigScriptData = hexToData(input.signatureScript),
                  sigScriptData.count == 66,
                  sigScriptData[0] == 0x41,
                  sigScriptData[65] == 0x01 else {
                // Non-standard signature script format; skip verification for this input
                continue
            }
            let schnorrSigData = sigScriptData[1..<65]

            // 2. Derive scriptPublicKey from the input's resolved address
            guard let utxoScriptPubKey = KaspaAddress.scriptPublicKey(from: input.previousOutpointAddress) else {
                return true // Cannot derive script; skip gracefully
            }

            // 3. Extract x-only public key (32 bytes) from P2PK scriptPublicKey
            // P2PK script format: <length_byte> <pubkey_bytes> OP_CHECKSIG(0xAC)
            guard utxoScriptPubKey.count >= 34, // 1 (len) + 32 (key) + 1 (OP_CHECKSIG)
                  utxoScriptPubKey[0] == 32,
                  utxoScriptPubKey[utxoScriptPubKey.count - 1] == 0xAC else {
                // Not a P2PK script or unexpected format; skip
                continue
            }
            let xOnlyPubKeyData = utxoScriptPubKey[1..<33]

            // 4. Compute sighash
            guard let sighash = try? computeSighash(
                transaction: rpcTransaction,
                inputIndex: index,
                utxoScriptPubKey: utxoScriptPubKey,
                utxoAmount: input.previousOutpointAmount
            ) else {
                return true // Sighash computation failed; skip gracefully
            }

            // 5. Verify Schnorr signature using P256K
            do {
                let xonlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: xOnlyPubKeyData)
                let schnorrSig = try P256K.Schnorr.SchnorrSignature(dataRepresentation: schnorrSigData)
                var sighashBytes = [UInt8](sighash)
                let isValid = xonlyKey.isValid(schnorrSig, for: &sighashBytes)
                // Zero sighash bytes after verification
                for i in sighashBytes.indices { sighashBytes[i] = 0 }
                if !isValid {
                    NSLog("[TxBuilder] Schnorr signature INVALID for input %d of tx", index)
                    return false
                }
            } catch {
                NSLog("[TxBuilder] Schnorr verification error for input %d: %@", index, error.localizedDescription)
                return true // Verification setup failed; skip gracefully
            }
        }

        return true
    }

    /// Storage mass parameter: C = SOMPI_PER_KAS * 10_000 = 1 trillion (KIP-0009)
    private static let storageMassParameter: UInt64 = 100_000_000 * 10_000

    /// Compute non-contextual compute mass per consensus MassCalculator::calc_non_contextual_masses
    private static func computeComputeMass(
        version: UInt16,
        inputs: [KaspaRpcTransactionInput],
        outputs: [KaspaRpcTransactionOutput],
        payload: Data,
        subnetworkId: Data,
        gas: UInt64,
        lockTime: UInt64
    ) -> UInt64 {
        // Consensus parameters (shared across nets)
        let massPerTxByte: UInt64 = 1
        let massPerScriptPubKeyByte: UInt64 = 10
        let massPerSigOp: UInt64 = 1000

        // Re-encode the transaction (with mass=0) to get the exact byte length
        let txForSize = KaspaRpcTransaction(
            version: version,
            inputs: inputs,
            outputs: outputs,
            lockTime: lockTime,
            subnetworkId: subnetworkId,
            gas: gas,
            payload: payload
        )
        var encoded = Data()
        txForSize.encodeTo(&encoded)

        let txSizeMass = UInt64(encoded.count) * massPerTxByte
        let spkMass = outputs.reduce(0) { $0 + (2 + UInt64($1.scriptPublicKey.script.count)) * massPerScriptPubKeyByte }
        let sigOpMass = inputs.reduce(0) { $0 + UInt64($1.sigOpCount) * massPerSigOp }

        return txSizeMass + spkMass + sigOpMass
    }

    /// Compute storage mass per KIP-0009
    /// Formula: max(0, C * (Σ 1/output_amount - Σ 1/input_amount))
    /// Note: Storage mass is designed to prevent UTXO bloat for small outputs.
    /// For outputs >= 1 KAS, storage mass is typically negligible compared to compute mass.
    private static func computeStorageMass(outputValues: [UInt64], inputValues: [UInt64]) -> UInt64 {
        // Filter out zero-value placeholders (used during fee estimation iterations)
        let nonZeroOutputs = outputValues.filter { $0 > 0 }
        let nonZeroInputs = inputValues.filter { $0 > 0 }

        guard !nonZeroOutputs.isEmpty, !nonZeroInputs.isEmpty else { return 0 }

        // Harmonic portion for outputs: Σ (C / output_amount)
        var harmonicOuts: UInt64 = 0
        for outVal in nonZeroOutputs {
            harmonicOuts = harmonicOuts.addingReportingOverflow(storageMassParameter / outVal).partialValue
        }

        // For relaxed formula (single output or single input), use harmonic for inputs too
        // Otherwise use arithmetic mean approach
        let useRelaxedFormula = nonZeroOutputs.count == 1 || nonZeroInputs.count == 1 ||
            (nonZeroOutputs.count == 2 && nonZeroInputs.count == 2)

        var harmonicIns: UInt64 = 0
        if useRelaxedFormula {
            for inVal in nonZeroInputs {
                harmonicIns = harmonicIns.addingReportingOverflow(storageMassParameter / inVal).partialValue
            }
        } else {
            // Arithmetic: |I| / A(I) = |I|^2 / sum(I) = C * |I|^2 / sum(I)
            let sumInputs = nonZeroInputs.reduce(0, +)
            let inputCount = UInt64(nonZeroInputs.count)
            if sumInputs > 0 {
                harmonicIns = storageMassParameter * inputCount * inputCount / sumInputs
            }
        }

        if harmonicOuts > harmonicIns {
            return harmonicOuts - harmonicIns
        }
        return 0
    }

    /// Compute transaction id (Blake2b-256 of encoded transaction, little-endian display)
    static func computeTransactionId(_ tx: KaspaRpcTransaction) -> String {
        var data = Data()
        tx.encodeTo(&data)
        let hash = Blake2b.hash(data, digestLength: 32)
        // Kaspa displays tx ids reversed (little-endian)
        return hash.reversed().map { String(format: "%02x", $0) }.joined()
    }

    private static func hexString(from string: String) -> String {
        return Data(string.utf8).hexString
    }
}
