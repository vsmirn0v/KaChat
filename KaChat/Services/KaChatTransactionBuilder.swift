import Foundation
import CryptoKit
import P256K

/// Broadcast channel name rules, matching the Android client's
/// `MessageProtocol.normalizeChannelName`/`isValidChannelName`.
enum BroadcastChannelName {
    static let maxLength = 36

    /// Normalize a channel name for comparison/storage: trimmed, lowercased.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether an (already-normalized) channel name is valid: non-empty, within length,
    /// and free of whitespace/colons (colons are the payload field delimiter).
    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxLength else { return false }
        guard name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        guard !name.contains(":") else { return false }
        return true
    }
}

/// Builds Kaspa transactions for Kasia messaging protocol
struct KasiaTransactionBuilder {

    // Kaspa constants
    static let handshakeAmount: UInt64 = 20_000_000 // 0.2 KAS handshake amount
    /// Below this, an output's own KIP-9 storage mass alone (C / amount, C = 10^12) already
    /// exceeds a safe standard-mass budget, regardless of how small/simple the rest of the
    /// transaction is - a leftover change output anywhere near the old 10,000-sompi threshold
    /// could single-handedly blow a transaction's total mass past the network's real 500,000
    /// cap and get it flat-out rejected ("transaction storage mass ... larger than max allowed
    /// size"), even for a plain 3-input send. Matches the proven, field-tested value from the
    /// KasSigner firmware's own `kspt.rs` (DUST_THRESHOLD), not a value picked from this file
    /// alone.
    static let dustThreshold: UInt64 = 20_000_000 // 0.2 KAS

    /// Kaspa caps transaction mass (~100,000 grams); each input costs ~1,118 grams (dominated by
    /// 1,000 grams of sig-op mass), so a transaction tops out near ~89 inputs before the node
    /// rejects it as over-mass. Cap selection well under that so we never build a doomed transaction
    /// whose node rejection surfaces as a confusing "network error"; a wallet with more UTXOs than
    /// this must consolidate them in batches of this size first (see ChatService.consolidateSpendingAddress).
    static let maxInputsPerTransaction = 80

    static let standardSubnetworkId = Data(repeating: 0, count: 20)
    private static let selfStashScope = "saved_handshake"

    private static func addSompiChecked(_ current: UInt64, _ amount: UInt64, context: String) throws -> UInt64 {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard !overflow else {
            AppLog.log("[TxBuilder] Rejecting suspicious UTXO sum overflow (%@): current=%llu add=%llu", context, current, amount)
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
        utxos: [UTXO],
        feeOverride: UInt64? = nil
    ) throws -> KaspaRpcTransaction {
        // 1. Encrypt the message for the recipient
        let kasiaPayload = try buildContextualMessagePayload(
            alias: alias,
            message: message,
            recipientPublicKey: recipientPublicKey
        )

        // 3. Build sender output script (self-spend)
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        // 4. Select minimal sufficient UTXOs (prefer fewer inputs to reduce contention)
        let selection = try selectUtxosForContextualMessage(
            utxos: utxos,
            payload: kasiaPayload,
            senderScriptPubKey: senderScriptPubKey,
            feeOverride: feeOverride
        )
        let selectedUtxos = selection.utxos
        let outputAmount = selection.totalInput - selection.fee

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

    /// Build a broadcast channel message transaction (KaChat 2.0 Broadcast feature).
    /// Same self-stash shape as a contextual message, but the payload is plaintext -
    /// broadcasts are public one-to-many channels, so pairwise encryption doesn't apply.
    static func buildBroadcastTx(
        from senderAddress: String,
        channel: String,
        content: String,
        senderPrivateKey: Data,
        utxos: [UTXO],
        feeOverride: UInt64? = nil
    ) throws -> KaspaRpcTransaction {
        let payload = buildBroadcastPayload(channel: channel, content: content)

        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        let selection = try selectUtxosForContextualMessage(
            utxos: utxos,
            payload: payload,
            senderScriptPubKey: senderScriptPubKey,
            feeOverride: feeOverride
        )
        let selectedUtxos = selection.utxos
        let outputAmount = selection.totalInput - selection.fee

        let outputs = [KaspaRpcTransactionOutput(
            value: outputAmount,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )]

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
            payload: payload
        )

        return try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selectedUtxos)
    }

    /// Estimate fee for a broadcast message (compose-bar fee preview)
    static func estimateBroadcastFee(payload: Data, inputCount: Int, senderScriptPubKey: Data) -> UInt64 {
        let output = KaspaRpcTransactionOutput(
            value: 0,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )
        return estimateFee(payload: payload, inputCount: inputCount, outputs: [output]) + 3
    }

    /// Build the plaintext broadcast payload: ciph_msg:1:bcast:<channel>:<content>
    static func buildBroadcastPayload(channel: String, content: String) -> Data {
        Data("ciph_msg:1:bcast:\(channel):\(content)".utf8)
    }

    /// Build a group chat message (`gcomm`) or control (`gctl`) transaction. Same self-stash
    /// shape as a broadcast/contextual message - the payload string is fully built ahead of time
    /// by GroupChatService/GroupCipher, this just wraps it in a signed tx.
    static func buildGroupPayloadTx(
        from senderAddress: String,
        payloadString: String,
        senderPrivateKey: Data,
        utxos: [UTXO],
        feeOverride: UInt64? = nil
    ) throws -> KaspaRpcTransaction {
        let payload = Data(payloadString.utf8)

        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        let selection = try selectUtxosForContextualMessage(
            utxos: utxos,
            payload: payload,
            senderScriptPubKey: senderScriptPubKey,
            feeOverride: feeOverride
        )
        let selectedUtxos = selection.utxos
        let outputAmount = selection.totalInput - selection.fee

        let outputs = [KaspaRpcTransactionOutput(
            value: outputAmount,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )]

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
            payload: payload
        )

        return try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selectedUtxos)
    }

    /// Estimate fee for a group message (compose-bar fee preview)
    static func estimateGroupPayloadFee(payload: Data, inputCount: Int, senderScriptPubKey: Data) -> UInt64 {
        let output = KaspaRpcTransactionOutput(
            value: 0,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )
        return estimateFee(payload: payload, inputCount: inputCount, outputs: [output]) + 3
    }

    /// Parse a decoded transaction payload string back into (channel, content).
    /// Returns nil if the payload isn't a broadcast message.
    static func parseBroadcastPayload(_ payloadString: String) -> (channel: String, content: String)? {
        let prefix = "ciph_msg:1:bcast:"
        guard payloadString.hasPrefix(prefix) else { return nil }
        let rest = payloadString.dropFirst(prefix.count)
        guard let colonIndex = rest.firstIndex(of: ":") else { return nil }
        let channel = String(rest[rest.startIndex..<colonIndex])
        let content = String(rest[rest.index(after: colonIndex)...])
        guard !channel.isEmpty else { return nil }
        return (channel, content)
    }

    /// Build a self-spend compaction transaction for message UTXOs.
    /// Produces a single self output with empty payload to reduce future input count.
    static func buildMessageCompactionTx(
        from senderAddress: String,
        senderPrivateKey: Data,
        utxos: [UTXO],
        minOutputAmount: UInt64,
        maxInputs: Int = 8
    ) throws -> (transaction: KaspaRpcTransaction, selectedUtxos: [UTXO], outputAmount: UInt64) {
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }

        let selection = try selectUtxosForMessageCompaction(
            utxos: utxos,
            senderScriptPubKey: senderScriptPubKey,
            minOutputAmount: minOutputAmount,
            maxInputs: maxInputs
        )

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
            outputs: [
                KaspaRpcTransactionOutput(
                    value: selection.outputAmount,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
                )
            ],
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: Data()
        )

        let signedTx = try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selection.utxos)
        return (transaction: signedTx, selectedUtxos: selection.utxos, outputAmount: selection.outputAmount)
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
        utxos: [UTXO],
        changeAddress: String? = nil
    ) throws -> KaspaRpcTransaction {
        guard amount > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }

        #if DEBUG
        AppLog.log("[TxBuilder] Building payment transaction:")
        AppLog.log("[TxBuilder]   from: %@", senderAddress)
        AppLog.log("[TxBuilder]   to: %@", recipientAddress)
        AppLog.log("[TxBuilder]   amount: %llu sompi", amount)
        #endif

        // Build payment payload (encrypted hex under ciph_msg:1:pay:)
        let paymentPayload = try buildPaymentPayload(message: note, amount: amount, recipientPublicKey: recipientPublicKey)
        #if DEBUG
        AppLog.log("[TxBuilder]   payload size: %d bytes", paymentPayload.count)
        AppLog.log("[TxBuilder]   payload hex (first 100): %@", paymentPayload.prefix(100).map { String(format: "%02x", $0) }.joined())
        #endif

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: recipientAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }
        // A standard P2PK output script is the same size for any address, so which specific
        // address change lands on doesn't affect fee estimation (selectUtxosForPayment below
        // still sizes against senderScriptPubKey) - only which script the actual change output
        // ends up using.
        let changeScriptPubKey: Data
        if let changeAddress {
            guard let script = KaspaAddress.scriptPublicKey(from: changeAddress) else {
                throw KasiaError.invalidAddress
            }
            changeScriptPubKey = script
        } else {
            changeScriptPubKey = senderScriptPubKey
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
        AppLog.log("[TxBuilder]   selected %d UTXOs, total input: %@, change: %llu", selection.utxos.count, totalForLog, selection.change)
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
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
            ))
        }

        #if DEBUG
        AppLog.log("[TxBuilder]   %d outputs: %@", outputs.count, outputs.map { String($0.value) }.joined(separator: ", "))
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

    /// Build a plain KAS transfer transaction — no KaChat protocol payload, just a payment
    /// to an arbitrary address (used by the Profile "Withdraw Kaspa" flow). Reuses the same
    /// UTXO-selection/fee/signing machinery as buildPaymentTx, just without requiring a
    /// recipient public key or attaching an encrypted payload.
    static func buildPlainTransferTx(
        from senderAddress: String,
        to recipientAddress: String,
        amount: UInt64,
        senderPrivateKey: Data,
        utxos: [UTXO],
        manualUtxos: [UTXO]? = nil,
        extraFeeSompi: UInt64 = 0,
        changeAddress: String? = nil
    ) throws -> KaspaRpcTransaction {
        guard amount > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: recipientAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }
        // A standard P2PK output script is the same size for any address, so which specific
        // address change lands on doesn't affect fee estimation — only which script the
        // actual change output below uses.
        let changeScriptPubKey: Data
        if let changeAddress {
            guard let script = KaspaAddress.scriptPublicKey(from: changeAddress) else {
                throw KasiaError.invalidAddress
            }
            changeScriptPubKey = script
        } else {
            changeScriptPubKey = senderScriptPubKey
        }

        let selection: PaymentSelection
        if let manualUtxos, !manualUtxos.isEmpty {
            selection = try selectManualUtxosForPayment(
                utxos: manualUtxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: senderScriptPubKey,
                extraFeeSompi: extraFeeSompi
            )
        } else {
            selection = try selectUtxosForPayment(
                utxos: utxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: senderScriptPubKey,
                extraFeeSompi: extraFeeSompi
            )
        }

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )
        ]
        if selection.change > dustThreshold {
            outputs.append(KaspaRpcTransactionOutput(
                value: selection.change,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
            ))
        }

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
            payload: Data()
        )

        return try signTransaction(unsignedTx, privateKey: senderPrivateKey, utxos: selection.utxos)
    }

    /// Result of building (but not signing) a transfer — used for cold storage / watch-only
    /// sends where no private key is available locally; signing happens on an external device
    /// (KasSigner) via the KSPT QR round trip.
    struct UnsignedTransferResult {
        let transaction: KaspaRpcTransaction
        /// Same order as transaction.inputs — needed since a RawInput alone (just an outpoint +
        /// empty signatureScript) doesn't carry the amount/scriptPublicKey a signer needs.
        let inputUtxos: [UTXO]
        let feeSompi: UInt64
        let changeSompi: UInt64
    }

    /// Same UTXO selection/fee logic as buildPlainTransferTx, but stops short of signing and
    /// returns the unsigned transaction plus the UTXOs it spends. KasSigner's KSPT wire format
    /// carries no BIP32 derivation path per input — the device presumably resolves a signing key
    /// per input by matching its scriptPublicKey against its own derived address set, but
    /// nothing in the format lets KaChat *tell* it which path to use. To stay unambiguous, every
    /// input in a single send is sourced from exactly one address (the `from` address), never
    /// aggregated across several.
    static func buildUnsignedPlainTransferTx(
        from senderAddress: String,
        to recipientAddress: String,
        amount: UInt64,
        utxos: [UTXO],
        extraFeeSompi: UInt64 = 0,
        changeAddress: String? = nil
    ) throws -> UnsignedTransferResult {
        guard amount > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }

        guard let recipientScriptPubKey = KaspaAddress.scriptPublicKey(from: recipientAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: senderAddress) else {
            throw KasiaError.invalidAddress
        }
        let changeScriptPubKey: Data
        if let changeAddress {
            guard let script = KaspaAddress.scriptPublicKey(from: changeAddress) else {
                throw KasiaError.invalidAddress
            }
            changeScriptPubKey = script
        } else {
            changeScriptPubKey = senderScriptPubKey
        }

        let selection = try selectUtxosForPayment(
            utxos: utxos,
            amount: amount,
            payload: Data(),
            recipientScriptPubKey: recipientScriptPubKey,
            senderScriptPubKey: senderScriptPubKey,
            extraFeeSompi: extraFeeSompi
        )

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )
        ]
        var changeSompi: UInt64 = 0
        if selection.change > dustThreshold {
            changeSompi = selection.change
            outputs.append(KaspaRpcTransactionOutput(
                value: selection.change,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
            ))
        }

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
            payload: Data()
        )

        let totalIn = try selection.utxos.reduce(UInt64(0)) { try addSompiChecked($0, $1.amount, context: "unsigned transfer total") }
        let fee = totalIn - amount - changeSompi

        return UnsignedTransferResult(
            transaction: unsignedTx,
            inputUtxos: selection.utxos,
            feeSompi: fee,
            changeSompi: changeSompi
        )
    }

    /// Estimate fee for a plain transfer (no payload). `extraFeeSompi` is the same optional
    /// priority tip accepted by buildPlainTransferTx, reflected here so the UI can show the
    /// real total the user will pay before sending.
    static func estimatePlainTransferFee(
        utxos: [UTXO],
        amount: UInt64,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        manualUtxos: [UTXO]? = nil,
        extraFeeSompi: UInt64 = 0
    ) throws -> UInt64 {
        let selection: PaymentSelection
        if let manualUtxos, !manualUtxos.isEmpty {
            selection = try selectManualUtxosForPayment(
                utxos: manualUtxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: senderScriptPubKey,
                extraFeeSompi: extraFeeSompi
            )
        } else {
            selection = try selectUtxosForPayment(
                utxos: utxos,
                amount: amount,
                payload: Data(),
                recipientScriptPubKey: recipientScriptPubKey,
                senderScriptPubKey: senderScriptPubKey,
                extraFeeSompi: extraFeeSompi
            )
        }
        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(value: amount, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey))
        ]
        if selection.change > dustThreshold {
            outputs.append(KaspaRpcTransactionOutput(value: selection.change, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)))
        }
        return estimateFee(payload: Data(), inputCount: selection.utxos.count, outputs: outputs) + extraFeeSompi
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
    static func estimateSendAllFee(
        utxos: [UTXO],
        payload: Data,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        manualUtxos: [UTXO]? = nil,
        extraFeeSompi: UInt64 = 0
    ) -> UInt64 {
        // With coin control active, "max" means "max spendable from the selected UTXOs", not
        // from the whole address - use exactly the manual set instead of every spendable UTXO.
        let spendable = (manualUtxos?.isEmpty == false ? manualUtxos! : utxos).filter { !$0.isCoinbase }
        // Calculate with 2 outputs to match selectUtxosForPayment which always estimates with change first
        let outputs = [
            KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)),
            KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
        ]
        return estimateFee(payload: payload, inputCount: spendable.count, outputs: outputs) + 3 + extraFeeSompi
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

    // MARK: - KNS Commit-Reveal

    struct KNSCommitContext {
        let redeemScript: Data
        let commitAddress: String
        let commitScriptPubKey: Data
        let commitAmountSompi: UInt64
        let revealAmountSompi: UInt64
        let commitOutputIndex: UInt32
    }

    /// Build commit transaction for a KNS `addProfile` inscription. `ownerAddress`'s pubkey
    /// is embedded in the redeem script — that's what the KNS indexer treats as the
    /// domain/profile's owner. `fundingAddress`/`fundingPrivateKey` only pay for the commit
    /// output (UTXO inputs, change) and sign this transaction; they never touch ownership.
    /// Matches Android's buildAndSubmitCommit(fundingAddress:fundingPrivateKey:ownerPrivateKey:)
    /// split, letting a spending address fund domain/profile writes while the identity
    /// address remains the resolved owner.
    static func buildKNSAddProfileCommitTx(
        ownerAddress: String,
        fundingAddress: String,
        fundingPrivateKey: Data,
        payloadJSON: Data,
        utxos: [UTXO],
        title: String = "kns",
        commitAmountSompi: UInt64 = 200_000_000,
        revealAmountSompi: UInt64 = 100_000_000
    ) throws -> (transaction: KaspaRpcTransaction, context: KNSCommitContext) {
        guard commitAmountSompi > 0 else {
            throw KasiaError.networkError("KNS commit amount must be positive")
        }

        guard let fundingScriptPubKey = KaspaAddress.scriptPublicKey(from: fundingAddress) else {
            throw KasiaError.invalidAddress
        }

        let redeemScript = try buildKNSRedeemScript(
            walletAddress: ownerAddress,
            title: title,
            payloadJSON: payloadJSON
        )
        let commitAddress = try makeKNSCommitAddress(
            redeemScript: redeemScript,
            walletAddress: ownerAddress
        )
        guard let commitScriptPubKey = KaspaAddress.scriptPublicKey(from: commitAddress) else {
            throw KasiaError.invalidAddress
        }

        let selection = try selectUtxosForPayment(
            utxos: utxos,
            amount: commitAmountSompi,
            payload: Data(),
            recipientScriptPubKey: commitScriptPubKey,
            senderScriptPubKey: fundingScriptPubKey
        )

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(
                value: commitAmountSompi,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: commitScriptPubKey)
            )
        ]
        if selection.change > dustThreshold {
            outputs.append(
                KaspaRpcTransactionOutput(
                    value: selection.change,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: fundingScriptPubKey)
                )
            )
        }

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
            payload: Data()
        )
        let signedTx = try signTransaction(unsignedTx, privateKey: fundingPrivateKey, utxos: selection.utxos)
        let context = KNSCommitContext(
            redeemScript: redeemScript,
            commitAddress: commitAddress,
            commitScriptPubKey: commitScriptPubKey,
            commitAmountSompi: commitAmountSompi,
            revealAmountSompi: revealAmountSompi,
            commitOutputIndex: 0
        )
        return (signedTx, context)
    }

    /// Build reveal transaction that spends the commit output and reveals KNS data. The
    /// commit output's redeem script requires a signature from `ownerAddress`'s key (the
    /// identity address — see buildKNSAddProfileCommitTx), so `ownerPrivateKey` must always
    /// be that key regardless of which address funded the commit. `changeAddress` is where
    /// any leftover value (commit amount minus reveal amount minus fee) lands — pass the
    /// funding/spending address here so leftover value returns to spending, not identity.
    static func buildKNSAddProfileRevealTx(
        ownerAddress: String,
        ownerPrivateKey: Data,
        changeAddress: String,
        commitTxId: String,
        commitContext: KNSCommitContext,
        revealTargetAddress: String? = nil,
        revealPriorityFeeSompi: UInt64 = 2_000_000
    ) throws -> KaspaRpcTransaction {
        let targetAddress = revealTargetAddress ?? ownerAddress

        guard let targetScriptPubKey = KaspaAddress.scriptPublicKey(from: targetAddress) else {
            throw KasiaError.invalidAddress
        }
        guard let changeScriptPubKey = KaspaAddress.scriptPublicKey(from: changeAddress) else {
            throw KasiaError.invalidAddress
        }

        let recipientOutput: KaspaRpcTransactionOutput? = commitContext.revealAmountSompi > 0
            ? KaspaRpcTransactionOutput(
                value: commitContext.revealAmountSompi,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: targetScriptPubKey)
            )
            : nil

        // Signature script is push(sig+hashtype) + push(redeemScript)
        let signatureScriptSize = 66 + canonicalPushDataSize(commitContext.redeemScript.count)
        let baseOutputs = recipientOutput.map { [$0] } ?? []
        let feeWithChange = estimateFee(
            payload: Data(),
            inputCount: 1,
            outputs: baseOutputs + [
                KaspaRpcTransactionOutput(
                    value: 0,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
                )
            ],
            signatureScriptSize: signatureScriptSize
        ) + revealPriorityFeeSompi

        guard commitContext.commitAmountSompi >= commitContext.revealAmountSompi,
              commitContext.commitAmountSompi - commitContext.revealAmountSompi >= feeWithChange else {
            throw KasiaError.networkError("KNS reveal amount cannot be covered by commit output")
        }

        var outputs: [KaspaRpcTransactionOutput] = baseOutputs
        var change = commitContext.commitAmountSompi - commitContext.revealAmountSompi - feeWithChange

        if change > dustThreshold {
            outputs.append(
                KaspaRpcTransactionOutput(
                    value: change,
                    scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
                )
            )
        } else {
            let feeNoChange = estimateFee(
                payload: Data(),
                inputCount: 1,
                outputs: baseOutputs,
                signatureScriptSize: signatureScriptSize
            ) + revealPriorityFeeSompi
            guard commitContext.commitAmountSompi >= commitContext.revealAmountSompi,
                  commitContext.commitAmountSompi - commitContext.revealAmountSompi >= feeNoChange else {
                throw KasiaError.networkError("Insufficient commit amount for KNS reveal fee")
            }
            change = commitContext.commitAmountSompi - commitContext.revealAmountSompi - feeNoChange
            if change > dustThreshold {
                outputs.append(
                    KaspaRpcTransactionOutput(
                        value: change,
                        scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScriptPubKey)
                    )
                )
            }
        }

        guard !outputs.isEmpty else {
            throw KasiaError.networkError("KNS reveal transaction has no spendable outputs after fees")
        }

        let unsignedTx = KaspaRpcTransaction(
            version: 0,
            inputs: [
                KaspaRpcTransactionInput(
                    previousOutpoint: UTXO.Outpoint(
                        transactionId: commitTxId,
                        index: commitContext.commitOutputIndex
                    ),
                    signatureScript: Data(),
                    sequence: 0,
                    sigOpCount: 1
                )
            ],
            outputs: outputs,
            lockTime: 0,
            subnetworkId: standardSubnetworkId,
            gas: 0,
            payload: Data()
        )

        return try signKNSRevealTransaction(
            unsignedTx,
            privateKey: ownerPrivateKey,
            utxoScriptPubKey: commitContext.commitScriptPubKey,
            redeemScript: commitContext.redeemScript,
            commitAmountSompi: commitContext.commitAmountSompi
        )
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

    private struct ContextualSelection {
        let utxos: [UTXO]
        let totalInput: UInt64
        let fee: UInt64
    }

    private struct MessageCompactionSelection {
        let utxos: [UTXO]
        let outputAmount: UInt64
    }

    /// Select a minimal UTXO set for contextual messages.
    /// Prefers fewer inputs to avoid quickly consuming all confirmed UTXOs.
    private static func selectUtxosForContextualMessage(
        utxos: [UTXO],
        payload: Data,
        senderScriptPubKey: Data,
        feeOverride: UInt64? = nil
    ) throws -> ContextualSelection {
        let spendable = utxos.filter { !$0.isCoinbase }
        let pending = spendable
            .filter { $0.blockDaaScore == 0 }
            .sorted { $0.amount > $1.amount }

        guard !spendable.isEmpty else {
            throw KasiaError.networkError("Insufficient funds after fee")
        }

        let outputTemplate = KaspaRpcTransactionOutput(
            value: 0,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )

        // A user-set fee (see ChatDetailView/BroadcastChannelView/GroupChatDetailView's tappable
        // fee pill) always wins over the computed estimate, regardless of input count.
        let feeFor: (Int) -> UInt64 = { inputCount in
            feeOverride ?? (estimateFee(payload: payload, inputCount: inputCount, outputs: [outputTemplate]) + 3)
        }

        // Prefer chaining on a single pending self-change UTXO when it can cover fee+dust.
        let singleInputFee = feeFor(1)
        if let pendingSingle = pending.first(where: { $0.amount > singleInputFee && ($0.amount - singleInputFee) > dustThreshold }) {
            return ContextualSelection(utxos: [pendingSingle], totalInput: pendingSingle.amount, fee: singleInputFee)
        }

        // Otherwise, use global largest-first order. This avoids combining many tiny pending UTXOs
        // before trying a larger confirmed one.
        let prioritized = spendable.sorted { lhs, rhs in
            if lhs.amount != rhs.amount {
                return lhs.amount > rhs.amount
            }
            let lhsPending = lhs.blockDaaScore == 0
            let rhsPending = rhs.blockDaaScore == 0
            if lhsPending != rhsPending {
                return lhsPending
            }
            return lhs.outpoint.transactionId > rhs.outpoint.transactionId
        }

        var selected: [UTXO] = []
        var total: UInt64 = 0

        for utxo in prioritized {
            selected.append(utxo)
            total = try addSompiChecked(total, utxo.amount, context: "contextual selection")

            let fee = feeFor(selected.count)
            guard total > fee else { continue }

            let outputAmount = total - fee
            if outputAmount > dustThreshold {
                return ContextualSelection(utxos: selected, totalInput: total, fee: fee)
            }
        }

        throw KasiaError.networkError("Insufficient funds after fee")
    }

    /// Select minimal UTXOs to cover payment and fee. `extraFeeSompi` is an optional
    /// priority tip added on top of the computed minimum-standard fee, for callers that let
    /// the user pay more during network congestion (e.g. the Withdraw Kaspa fee selector).
    private static func selectUtxosForPayment(
        utxos: [UTXO],
        amount: UInt64,
        payload: Data,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        extraFeeSompi: UInt64 = 0
    ) throws -> PaymentSelection {
        // Sort largest first to reduce input count (lower mass)
        let sorted = utxos.sorted { $0.amount > $1.amount }
        var selected: [UTXO] = []
        var total: UInt64 = 0

        for utxo in sorted {
            if utxo.isCoinbase { continue }
            // Refuse to build an over-mass transaction: if we've hit the input cap and still
            // haven't covered the amount, more inputs would exceed Kaspa's mass limit and the node
            // would reject the tx. Fail with a clear, actionable message instead.
            if selected.count >= maxInputsPerTransaction {
                throw KasiaError.networkError("This send needs more than \(maxInputsPerTransaction) inputs. Compound (consolidate) this address's UTXOs first, then try again.")
            }
            selected.append(utxo)
            total = try addSompiChecked(total, utxo.amount, context: "payment selection")

            let recipientOutput = KaspaRpcTransactionOutput(
                value: amount,
                scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
            )

            // Estimate with change output (+ buffer to avoid under-fee rejection, + priority tip)
            let feeWithChange = estimateFee(
                payload: payload,
                inputCount: selected.count,
                outputs: [
                    recipientOutput,
                    KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
                ]
            ) + 3 + extraFeeSompi

            if total <= amount || total - amount < feeWithChange {
                continue
            }

            var change = total - amount - feeWithChange
            if change > dustThreshold {
                return PaymentSelection(utxos: selected, change: change)
            }

            // Try without change (treat dust as fee, + buffer, + priority tip)
            let feeNoChange = estimateFee(payload: payload, inputCount: selected.count, outputs: [recipientOutput]) + 3 + extraFeeSompi
            if total > amount && total - amount >= feeNoChange {
                change = total - amount - feeNoChange
                return PaymentSelection(utxos: selected, change: change)
            }
        }

        throw KasiaError.networkError("Insufficient funds for payment")
    }

    /// Coin-control counterpart to `selectUtxosForPayment` - uses exactly the given `utxos` as
    /// the transaction's input set (no incremental growth/sorting) rather than greedily picking
    /// a subset, since the whole point of coin control is letting the caller fix which specific
    /// inputs a send spends. Same "with change, else without change, else fail" fee logic as the
    /// greedy selector, just evaluated once against the fixed set instead of per candidate added.
    private static func selectManualUtxosForPayment(
        utxos: [UTXO],
        amount: UInt64,
        payload: Data,
        recipientScriptPubKey: Data,
        senderScriptPubKey: Data,
        extraFeeSompi: UInt64 = 0
    ) throws -> PaymentSelection {
        let usable = utxos.filter { !$0.isCoinbase }
        guard !usable.isEmpty else {
            throw KasiaError.networkError("Insufficient funds for payment")
        }
        // A fixed input set over the mass cap would be rejected by the node - refuse it up front.
        // Consolidation feeds this in chunks of maxInputsPerTransaction, so those always pass.
        guard usable.count <= maxInputsPerTransaction else {
            throw KasiaError.networkError("Too many inputs selected (\(usable.count)). Kaspa transactions are limited to about \(maxInputsPerTransaction) inputs - select fewer, or compound this address first.")
        }
        let total = try usable.reduce(UInt64(0)) { try addSompiChecked($0, $1.amount, context: "manual payment selection") }

        let recipientOutput = KaspaRpcTransactionOutput(
            value: amount,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScriptPubKey)
        )

        let feeWithChange = estimateFee(
            payload: payload,
            inputCount: usable.count,
            outputs: [
                recipientOutput,
                KaspaRpcTransactionOutput(value: 0, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey))
            ]
        ) + 3 + extraFeeSompi

        if total > amount, total - amount >= feeWithChange {
            let change = total - amount - feeWithChange
            if change > dustThreshold {
                return PaymentSelection(utxos: usable, change: change)
            }
        }

        // Try without change (treat dust/leftover as fee, + buffer, + priority tip)
        let feeNoChange = estimateFee(payload: payload, inputCount: usable.count, outputs: [recipientOutput]) + 3 + extraFeeSompi
        if total > amount, total - amount >= feeNoChange {
            return PaymentSelection(utxos: usable, change: total - amount - feeNoChange)
        }

        throw KasiaError.networkError("Insufficient funds for payment")
    }

    /// Select confirmed UTXOs for a bounded-input self-compaction transaction.
    private static func selectUtxosForMessageCompaction(
        utxos: [UTXO],
        senderScriptPubKey: Data,
        minOutputAmount: UInt64,
        maxInputs: Int
    ) throws -> MessageCompactionSelection {
        let boundedMaxInputs = max(2, maxInputs)
        let spendable = utxos.filter { !$0.isCoinbase }
        let confirmed = spendable
            .filter { $0.blockDaaScore > 0 }
            .sorted { $0.amount > $1.amount }
        let pending = spendable
            .filter { $0.blockDaaScore == 0 }
            .sorted { $0.amount > $1.amount }
        let candidates = confirmed + pending

        guard candidates.count >= 2 else {
            throw KasiaError.networkError("Not enough spendable UTXOs for compaction")
        }

        let outputTemplate = KaspaRpcTransactionOutput(
            value: 0,
            scriptPublicKey: KaspaScriptPublicKey(version: 0, script: senderScriptPubKey)
        )

        var selected: [UTXO] = []
        var total: UInt64 = 0
        var bestSelection: MessageCompactionSelection?

        for utxo in candidates.prefix(boundedMaxInputs) {
            selected.append(utxo)
            total = try addSompiChecked(total, utxo.amount, context: "message compaction selection")

            guard selected.count >= 2 else { continue }

            let fee = estimateFee(payload: Data(), inputCount: selected.count, outputs: [outputTemplate]) + 3
            guard total > fee && total - fee > dustThreshold else { continue }

            let outputAmount = total - fee
            let candidateSelection = MessageCompactionSelection(
                utxos: selected,
                outputAmount: outputAmount
            )
            if let currentBest = bestSelection {
                if candidateSelection.utxos.count > currentBest.utxos.count ||
                    (candidateSelection.utxos.count == currentBest.utxos.count &&
                        candidateSelection.outputAmount > currentBest.outputAmount) {
                    bestSelection = candidateSelection
                }
            } else {
                bestSelection = candidateSelection
            }
        }

        if let bestSelection {
            if bestSelection.outputAmount < minOutputAmount {
                AppLog.log("[TxBuilder] Compaction target not met (target=%llu, got=%llu) - using best input reduction set (%d inputs)",
                      minOutputAmount,
                      bestSelection.outputAmount,
                      bestSelection.utxos.count)
            }
            return bestSelection
        }

        throw KasiaError.networkError("Insufficient spendable funds for compaction")
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

    /// Calculate the Toccata minimum standard fee.
    /// Fee mass is max(compute mass, normalized transient mass), where post-Toccata
    /// transient mass normalizes to 2 grams per estimated transaction byte.
    private static func estimateFee(payload: Data, inputCount: Int, outputs: [KaspaRpcTransactionOutput]) -> UInt64 {
        estimateFee(payload: payload, inputCount: inputCount, outputs: outputs, signatureScriptSize: 66)
    }

    private static func estimateFee(
        payload: Data,
        inputCount: Int,
        outputs: [KaspaRpcTransactionOutput],
        signatureScriptSize: Int
    ) -> UInt64 {
        let dummyInput = KaspaRpcTransactionInput(
            previousOutpoint: UTXO.Outpoint(transactionId: String(repeating: "0", count: 64), index: 0),
            signatureScript: Data(repeating: 0, count: max(0, signatureScriptSize)),
            sequence: 0,
            sigOpCount: 1
        )
        let inputs = Array(repeating: dummyInput, count: inputCount)
        let computeMass = computeComputeMass(
            version: 0,
            inputs: inputs,
            outputs: outputs,
            payload: payload
        )
        let estimatedBytes = estimateTransactionByteCount(
            version: 0,
            inputs: inputs,
            outputs: outputs,
            payload: payload
        )
        return KaspaFeePolicy.minimumStandardFee(computeMass: computeMass, estimatedTransactionBytes: estimatedBytes)
    }

    private static func buildKNSRedeemScript(
        walletAddress: String,
        title: String,
        payloadJSON: Data
    ) throws -> Data {
        guard let pubKey = KaspaAddress.publicKey(from: walletAddress),
              pubKey.count == 32 else {
            throw KasiaError.invalidAddress
        }
        let titleData = Data(title.utf8)
        guard !titleData.isEmpty else {
            throw KasiaError.networkError("KNS inscription title is empty")
        }
        guard payloadJSON.count <= 520 else {
            throw KasiaError.networkError("KNS inscription payload exceeds 520-byte script element limit")
        }

        var script = Data()
        script.append(0x20) // push 32-byte x-only pubkey
        script.append(pubKey)
        script.append(0xAC) // OP_CHECKSIG
        script.append(0x00) // OP_FALSE
        script.append(0x63) // OP_IF
        script.append(try buildCanonicalPushData(titleData))
        script.append(0x00) // add_i64(0) -> OP_0
        script.append(try buildCanonicalPushData(payloadJSON))
        script.append(0x68) // OP_ENDIF

        return script
    }

    private static func makeKNSCommitAddress(redeemScript: Data, walletAddress: String) throws -> String {
        guard let source = KaspaAddress(address: walletAddress) else {
            throw KasiaError.invalidAddress
        }
        let scriptHash = Blake2b.hash(redeemScript, digestLength: 32)
        return KaspaAddress(hrp: source.hrp, type: .scriptHash, payload: scriptHash).address
    }

    private static func signKNSRevealTransaction(
        _ transaction: KaspaRpcTransaction,
        privateKey: Data,
        utxoScriptPubKey: Data,
        redeemScript: Data,
        commitAmountSompi: UInt64
    ) throws -> KaspaRpcTransaction {
        let schnorrPrivKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)

        let sighash = try computeSighash(
            transaction: transaction,
            inputIndex: 0,
            utxoScriptPubKey: utxoScriptPubKey,
            utxoAmount: commitAmountSompi
        )
        var sighashBytes = [UInt8](sighash)
        let signature = try schnorrPrivKey.signature(message: &sighashBytes, auxiliaryRand: nil)
        for index in sighashBytes.indices {
            sighashBytes[index] = 0
        }

        var sigScript = Data()
        sigScript.append(0x41) // push 65 bytes (64-byte sig + sighash type)
        sigScript.append(Data(signature.bytes))
        sigScript.append(0x01) // SIGHASH_ALL
        sigScript.append(try buildCanonicalPushData(redeemScript))

        let signedInput = KaspaRpcTransactionInput(
            previousOutpoint: transaction.inputs[0].previousOutpoint,
            signatureScript: sigScript,
            sequence: transaction.inputs[0].sequence,
            sigOpCount: transaction.inputs[0].sigOpCount
        )

        return KaspaRpcTransaction(
            version: transaction.version,
            inputs: [signedInput],
            outputs: transaction.outputs,
            lockTime: transaction.lockTime,
            subnetworkId: transaction.subnetworkId,
            gas: transaction.gas,
            payload: transaction.payload
        )
    }

    private static func canonicalPushDataSize(_ dataLength: Int) -> Int {
        if dataLength <= 0 {
            return 1
        }
        if dataLength <= 75 {
            return 1 + dataLength
        }
        if dataLength <= 0xff {
            return 2 + dataLength
        }
        if dataLength <= 0xffff {
            return 3 + dataLength
        }
        return 5 + dataLength
    }

    private static func buildCanonicalPushData(_ data: Data) throws -> Data {
        guard data.count <= 520 else {
            throw KasiaError.networkError("Script element exceeds 520-byte limit")
        }

        var encoded = Data()
        let length = data.count

        if length == 0 {
            encoded.append(0x00) // OP_0
            return encoded
        }

        if length <= 75 {
            encoded.append(UInt8(length))
            encoded.append(data)
            return encoded
        }

        if length <= 0xff {
            encoded.append(0x4c) // OP_PUSHDATA1
            encoded.append(UInt8(length))
            encoded.append(data)
            return encoded
        }

        if length <= 0xffff {
            encoded.append(0x4d) // OP_PUSHDATA2
            var le = UInt16(length).littleEndian
            encoded.append(Data(bytes: &le, count: 2))
            encoded.append(data)
            return encoded
        }

        encoded.append(0x4e) // OP_PUSHDATA4
        var le = UInt32(length).littleEndian
        encoded.append(Data(bytes: &le, count: 4))
        encoded.append(data)
        return encoded
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
                    AppLog.log("[TxBuilder] Schnorr signature INVALID for input %d of tx", index)
                    return false
                }
            } catch {
                AppLog.log("[TxBuilder] Schnorr verification error for input %d: %@", index, error.localizedDescription)
                return true // Verification setup failed; skip gracefully
            }
        }

        return true
    }

    /// Storage mass parameter: C = SOMPI_PER_KAS * 10_000 = 1 trillion (KIP-0009)
    private static let storageMassParameter: UInt64 = 100_000_000 * 10_000

    /// Compute non-contextual compute mass per consensus MassCalculator::calc_non_contextual_masses.
    private static func computeComputeMass(
        version: UInt16,
        inputs: [KaspaRpcTransactionInput],
        outputs: [KaspaRpcTransactionOutput],
        payload: Data
    ) -> UInt64 {
        // Consensus parameters (shared across nets)
        let massPerTxByte: UInt64 = 1
        let massPerScriptPubKeyByte: UInt64 = 10
        let massPerSigOp: UInt64 = 1000

        let estimatedBytes = estimateTransactionByteCount(
            version: version,
            inputs: inputs,
            outputs: outputs,
            payload: payload
        )

        let txSizeMass = estimatedBytes * massPerTxByte
        let spkMass = outputs.reduce(0) { $0 + (2 + UInt64($1.scriptPublicKey.script.count)) * massPerScriptPubKeyByte }
        let sigOpMass = inputs.reduce(0) { $0 + UInt64($1.sigOpCount) * massPerSigOp }

        return txSizeMass + spkMass + sigOpMass
    }

    private static func estimateTransactionByteCount(
        version: UInt16,
        inputs: [KaspaRpcTransactionInput],
        outputs: [KaspaRpcTransactionOutput],
        payload: Data
    ) -> UInt64 {
        let inputBytes = inputs.reduce(UInt64(0)) { total, input in
            var size: UInt64 = 32 + 4 // previous outpoint
            size += 8 + UInt64(input.signatureScript.count)
            size += 8 // sequence
            if version >= 1 {
                size += 2 // compute_budget
            }
            return total + size
        }

        let outputBytes = outputs.reduce(UInt64(0)) { total, output in
            total + 8 + 2 + 8 + UInt64(output.scriptPublicKey.script.count)
        }

        return 2 // version
            + 8 + inputBytes
            + 8 + outputBytes
            + 8 // lock time
            + 20 // subnetwork id
            + 8 // gas
            + 32 // payload hash
            + 8 + UInt64(payload.count)
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
