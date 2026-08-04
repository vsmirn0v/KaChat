import Foundation

/// Builds unsigned transactions for a Cold Storage (kpub watch-only) address and broadcasts the
/// signed response scanned back from a KasSigner device — the "send" half of Cold Storage
/// (ColdStorageManager only covers the watch-only half). Deliberately has no dependency on
/// WalletManager: this engine never sees a mnemonic or private key, only public addresses and
/// whatever signature KasSigner hands back.
///
/// Selection/mass/fee logic below is a direct, byte-for-byte port of Android's
/// `KaspaUtxoSelector.selectUtxosAndCalculateFee` + `KaspaMass`, not a reuse of this app's shared
/// `KasiaTransactionBuilder` — that shared path can fall back to a cheaper "no change" pricing
/// when leftover change would be dust, which produced a real, lower-than-Android fee (a KasSigner
/// send failed because of it: iPhone priced ~0.0016 KAS where Android priced 0.002036 KAS for the
/// same send). Android's Cold Storage engine deliberately always prices as if there will be a
/// change output specifically to avoid ever underpricing this way (see the comment in
/// `selectUtxos` below) — ported verbatim rather than patched into the shared path, so this stays
/// scoped to Cold Storage.
@MainActor
final class ColdStorageSendEngine {
    static let shared = ColdStorageSendEngine()
    private init() {}

    struct UnsignedColdTx {
        let transaction: KaspaRpcTransaction
        let inputUtxos: [UTXO]
        let feeSompi: UInt64
        let changeSompi: UInt64
    }

    enum ColdSendError: LocalizedError {
        case noSpendableUtxos
        case insufficientFunds
        case tooManyInputs(Int)
        case notSigned
        case inputCountMismatch
        case outputCountMismatch
        case outputMismatch(Int)
        case inputMismatch(Int)
        case inputNotSigned(Int)
        case badSignatureLength(Int)

        var errorDescription: String? {
            switch self {
            case .noSpendableUtxos:
                return "No spendable UTXOs at this address"
            case .insufficientFunds:
                return "Insufficient funds to cover that amount plus the network fee"
            case .tooManyInputs(let n):
                return "This send would need \(n) UTXOs, but KasSigner only supports \(KsptCodec.maxInputs) inputs per transaction. Send a smaller amount or consolidate this address first."
            case .notSigned:
                return "Scanned transaction is not signed"
            case .inputCountMismatch:
                return "Signed transaction has a different number of inputs"
            case .outputCountMismatch:
                return "Signed transaction has a different number of outputs"
            case .outputMismatch(let i):
                return "Signed transaction's output \(i) doesn't match what was sent for signing, so it won't be broadcast"
            case .inputMismatch(let i):
                return "Signed transaction's input \(i) doesn't match what was sent for signing"
            case .inputNotSigned(let i):
                return "Input \(i) wasn't signed"
            case .badSignatureLength(let n):
                return "Unexpected signature length (\(n) bytes, expected 64)"
            }
        }
    }

    /// Standard Schnorr signature script size (0x41 push + 64-byte sig + 0x01 sighash) — used to
    /// price the eventual *signed* transaction even though the unsigned one built here carries no
    /// real signature bytes yet. Matches Android's SCHNORR_SIG_SCRIPT_LEN.
    private nonisolated static let schnorrSigScriptLen: UInt64 = 66

    /// Change-output dust threshold. Android's own Cold Storage engine uses 500 sompi here, but
    /// that value predates any KIP-9 storage-mass accounting on either platform: below this,
    /// an output's own storage mass (C / amount, C = 10^12) already exceeds a safe standard-mass
    /// budget on its own, regardless of how simple the rest of the transaction is - a leftover
    /// change output anywhere near 500 sompi is exactly the shape of transaction that gets
    /// flat-out rejected ("transaction storage mass ... larger than max allowed size") even for
    /// a plain few-input send. Matches KasiaTransactionBuilder.dustThreshold and the proven,
    /// field-tested value from the KasSigner firmware's own `kspt.rs` (DUST_THRESHOLD).
    private static let changeDustThreshold: UInt64 = 20_000_000

    // MARK: - Mass / fee (KaspaMass.kt port)

    /// Verified against Android's own cited real-world result: 1 input, two 34-byte outputs, no
    /// payload -> mass 2036 (a real mainnet rejection Android hit and reproduced exactly).
    nonisolated static func calculateMass(numInputs: Int, outputScriptLens: [Int], payloadSize: Int, sigOpCountPerInput: Int = 1) -> UInt64 {
        let totalSigScriptBytes = UInt64(numInputs) * schnorrSigScriptLen

        var byteSize: UInt64 = 2 // version (u16)
        byteSize += 8 // input count
        byteSize += UInt64(numInputs) * (36 + 8 + 8) + totalSigScriptBytes // outpoint + sigscript-len field + sequence, + actual sigscript bytes
        byteSize += 8 // output count

        var scriptPubKeyMass: UInt64 = 0
        for scriptLen in outputScriptLens {
            byteSize += 8 + 2 + 8 + UInt64(scriptLen) // value + scriptVersion + scriptLen + script
            scriptPubKeyMass += (2 + UInt64(scriptLen)) * 10
        }

        byteSize += 8  // lockTime
        byteSize += 20 // subnetworkId
        byteSize += 8  // gas
        byteSize += 32 // payload hash (fixed 32 bytes regardless of payload length)
        byteSize += 8  // payload length
        byteSize += UInt64(payloadSize)

        let sigOpMass = UInt64(numInputs) * UInt64(sigOpCountPerInput) * 1000
        let computeMass = byteSize * 1 + scriptPubKeyMass + sigOpMass

        // Post-"Toccata" RPC minimum-standard-fee policy: the real fee floor is
        // 100 sompi * max(computeMass, 2 * transactionByteSize), not compute mass alone.
        return max(computeMass, byteSize * 2)
    }

    /// fee = mass * max(networkMinimum, rate)
    nonisolated static func calculateFee(mass: UInt64, rateSompiPerGram: UInt64) -> UInt64 {
        mass * max(rateSompiPerGram, KaspaFeePolicy.minimumRelayFeePerGramSompi)
    }

    /// Reference mass (1 input, two standard 34-byte P2PK outputs) — used only to convert a
    /// user-entered total fee (KAS) into a sompi-per-gram rate in the send screen's fee editor.
    /// The real per-send mass can differ slightly by input count; Android uses this identical
    /// shortcut for the same conversion.
    nonisolated static let referenceMassForFeeEditor: UInt64 = calculateMass(numInputs: 1, outputScriptLens: [34, 34], payloadSize: 0)

    // MARK: - UTXO selection

    private struct Selection {
        let utxos: [UTXO]
        let feeSompi: UInt64
        let finalAmount: UInt64
        let changeSompi: UInt64
    }

    /// Port of Android's `KaspaUtxoSelector.selectUtxosAndCalculateFee`. Always prices as if
    /// there will be a change output — if change ends up being dust and gets dropped from the
    /// final transaction, the real required fee is only lower, so this direction never
    /// underpays the network (the bug this replaced could: it priced as "no change" whenever
    /// change alone would be dust, silently shipping a too-low fee for a device to reject).
    private static func selectUtxos(
        from utxos: [UTXO],
        amountSompi: UInt64,
        feeRateSompiPerGram: UInt64,
        recipientScriptLen: Int,
        changeScriptLen: Int
    ) -> Selection? {
        let sorted = utxos.sorted { $0.amount > $1.amount }
        var selected: [UTXO] = []
        var totalSelected: UInt64 = 0
        var estimatedFee: UInt64 = 0
        let outputScriptLens = [recipientScriptLen, changeScriptLen]

        for utxo in sorted {
            selected.append(utxo)
            totalSelected += utxo.amount

            let mass = calculateMass(numInputs: selected.count, outputScriptLens: outputScriptLens, payloadSize: 0)
            estimatedFee = calculateFee(mass: mass, rateSompiPerGram: feeRateSompiPerGram)

            if totalSelected >= amountSompi + estimatedFee { break }
        }

        var finalAmount = amountSompi
        var requiredAmount = amountSompi + estimatedFee

        if totalSelected < requiredAmount {
            // "Max Send" leeway: if we're within 2000 sompi, trim the amount down to what's
            // actually available rather than failing outright.
            if totalSelected > estimatedFee && (requiredAmount - totalSelected) < 2000 {
                finalAmount = totalSelected - estimatedFee
                requiredAmount = totalSelected
            } else {
                return nil
            }
        }

        let changeAmount = totalSelected - finalAmount - estimatedFee
        return Selection(utxos: selected, feeSompi: estimatedFee, finalAmount: finalAmount, changeSompi: changeAmount)
    }

    /// Coin control: prices and validates a user-picked, fixed set of UTXOs instead of greedily
    /// growing one. Otherwise identical to `selectUtxos` (same "close enough, trim the amount"
    /// leeway, same always-price-a-change-output policy).
    private static func buildManualSelection(
        utxos: [UTXO],
        amountSompi: UInt64,
        feeRateSompiPerGram: UInt64,
        recipientScriptLen: Int,
        changeScriptLen: Int
    ) -> Selection? {
        guard !utxos.isEmpty else { return nil }
        let totalSelected = utxos.reduce(UInt64(0)) { $0 + $1.amount }
        let mass = calculateMass(numInputs: utxos.count, outputScriptLens: [recipientScriptLen, changeScriptLen], payloadSize: 0)
        let estimatedFee = calculateFee(mass: mass, rateSompiPerGram: feeRateSompiPerGram)

        var finalAmount = amountSompi
        let requiredAmount = amountSompi + estimatedFee
        if totalSelected < requiredAmount {
            if totalSelected > estimatedFee && (requiredAmount - totalSelected) < 2000 {
                finalAmount = totalSelected - estimatedFee
            } else {
                return nil
            }
        }

        let changeAmount = totalSelected - finalAmount - estimatedFee
        return Selection(utxos: utxos, feeSompi: estimatedFee, finalAmount: finalAmount, changeSompi: changeAmount)
    }

    // MARK: - Build

    /// Fetches UTXOs at `fromAddress` and builds (but does not sign) a transfer to `toAddress`.
    /// `feeRateOverride`, if given, is a sompi-per-mass-gram rate the user chose explicitly (via
    /// the send screen's "Adjust Network Fee" editor); otherwise this fetches the network's live
    /// quoted rate, same as Android. `manualUtxos`, if given (coin control), fixes the exact
    /// input set instead of letting `selectUtxos` greedily grow one — re-resolved against this
    /// call's own fresh `getUtxosByAddresses` fetch by outpoint, not used as-is, so a UTXO spent
    /// since the coin-control picker was shown can't silently get included.
    func buildUnsignedTransaction(
        fromAddress: String,
        toAddress: String,
        amountSompi: UInt64,
        feeRateOverride: UInt64? = nil,
        manualUtxos: [UTXO]? = nil
    ) async throws -> UnsignedColdTx {
        guard amountSompi > 0 else {
            throw KasiaError.networkError("Amount must be greater than zero")
        }
        guard let recipientScript = KaspaAddress.scriptPublicKey(from: toAddress),
              let changeScript = KaspaAddress.scriptPublicKey(from: fromAddress) else {
            throw KasiaError.invalidAddress
        }

        // Unlike most of this app's other UTXO-consuming paths, this one deliberately does NOT
        // filter out coinbase UTXOs — matching Android's ColdStorageSendEngine.kt exactly, which
        // passes the node's UTXO response straight into selection with no coinbase filtering at
        // all. A node's UTXO-set query only ever returns mature, spendable outputs in the first
        // place, so a matured coinbase output is just as spendable as any other UTXO; excluding
        // it here made iOS select a different (and potentially larger) set of inputs than
        // Android would for the identical on-chain balance.
        let spendable = try await NodePoolService.shared.getUtxosByAddresses([fromAddress])
        guard !spendable.isEmpty else { throw ColdSendError.noSpendableUtxos }

        let feeRate: UInt64
        if let feeRateOverride {
            feeRate = feeRateOverride
        } else {
            feeRate = await Self.fetchQuotedFeeRateSompiPerGram()
        }

        let selectionResult: Selection?
        if let manualUtxos, !manualUtxos.isEmpty {
            let freshByOutpoint = Dictionary(
                spendable.map { ("\($0.outpoint.transactionId):\($0.outpoint.index)", $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolved = manualUtxos.compactMap { freshByOutpoint["\($0.outpoint.transactionId):\($0.outpoint.index)"] }
            selectionResult = Self.buildManualSelection(
                utxos: resolved,
                amountSompi: amountSompi,
                feeRateSompiPerGram: feeRate,
                recipientScriptLen: recipientScript.count,
                changeScriptLen: changeScript.count
            )
        } else {
            selectionResult = Self.selectUtxos(
                from: spendable,
                amountSompi: amountSompi,
                feeRateSompiPerGram: feeRate,
                recipientScriptLen: recipientScript.count,
                changeScriptLen: changeScript.count
            )
        }
        guard let selection = selectionResult else {
            throw ColdSendError.insufficientFunds
        }
        guard selection.utxos.count <= KsptCodec.maxInputs else {
            throw ColdSendError.tooManyInputs(selection.utxos.count)
        }

        var outputs: [KaspaRpcTransactionOutput] = [
            KaspaRpcTransactionOutput(value: selection.finalAmount, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: recipientScript))
        ]
        var changeSompi: UInt64 = 0
        if selection.changeSompi > Self.changeDustThreshold {
            changeSompi = selection.changeSompi
            outputs.append(KaspaRpcTransactionOutput(value: selection.changeSompi, scriptPublicKey: KaspaScriptPublicKey(version: 0, script: changeScript)))
        }

        let transaction = KaspaRpcTransaction(
            version: 0,
            inputs: selection.utxos.map { utxo in
                KaspaRpcTransactionInput(previousOutpoint: utxo.outpoint, signatureScript: Data(), sequence: 0, sigOpCount: 1)
            },
            outputs: outputs,
            lockTime: 0,
            subnetworkId: KasiaTransactionBuilder.standardSubnetworkId,
            gas: 0,
            payload: Data()
        )

        return UnsignedColdTx(transaction: transaction, inputUtxos: selection.utxos, feeSompi: selection.feeSompi, changeSompi: changeSompi)
    }

    struct AutomaticSelectionPreview {
        let utxos: [UTXO]
        let feeSompi: UInt64
    }

    /// Live preview of what automatic selection *would* pick for `amountSompi` at
    /// `feeRateSompiPerGram` — same selector `buildUnsignedTransaction` itself uses, just without
    /// actually building. Lets the send form show a fee that's already exact (not the 1-input
    /// reference-mass guess) whenever a fresh preview is available, and — critically — lets the
    /// form pass this exact same UTXO set into the real build as `manualUtxos`, so the two numbers
    /// can't diverge the way they could when each independently guessed at the input count.
    /// Uses standard 34-byte output script lengths (matching `referenceMassForFeeEditor`) since
    /// this only needs to be right about *how many inputs*, not the recipient's exact address.
    func previewAutomaticSelection(fromAddress: String, amountSompi: UInt64, feeRateSompiPerGram: UInt64) async -> AutomaticSelectionPreview? {
        guard amountSompi > 0, let spendable = try? await NodePoolService.shared.getUtxosByAddresses([fromAddress]), !spendable.isEmpty else {
            return nil
        }
        guard let selection = Self.selectUtxos(
            from: spendable,
            amountSompi: amountSompi,
            feeRateSompiPerGram: feeRateSompiPerGram,
            recipientScriptLen: 34,
            changeScriptLen: 34
        ) else {
            return nil
        }
        return AutomaticSelectionPreview(utxos: selection.utxos, feeSompi: selection.feeSompi)
    }

    /// Max sendable amount (full balance minus estimated fee, no change output) for the Max
    /// button in the send form — same shape as Android's own Max button: prices using every
    /// spendable UTXO as the input count (a full-balance send will need close to all of them
    /// anyway) rather than running the incremental selection loop. If coin control has fixed a
    /// UTXO set, Max reflects only that subset (re-resolved against this call's own fresh fetch,
    /// same as `buildUnsignedTransaction`) rather than the whole address's balance.
    func estimateMaxAmount(fromAddress: String, feeRateOverride: UInt64? = nil, manualUtxos: [UTXO]? = nil) async throws -> UInt64 {
        // No coinbase filtering here either — see the matching comment in
        // buildUnsignedTransaction above.
        let spendable = try await NodePoolService.shared.getUtxosByAddresses([fromAddress])
        guard !spendable.isEmpty else { throw ColdSendError.noSpendableUtxos }

        let utxosToUse: [UTXO]
        if let manualUtxos, !manualUtxos.isEmpty {
            let freshByOutpoint = Dictionary(
                spendable.map { ("\($0.outpoint.transactionId):\($0.outpoint.index)", $0) },
                uniquingKeysWith: { first, _ in first }
            )
            utxosToUse = manualUtxos.compactMap { freshByOutpoint["\($0.outpoint.transactionId):\($0.outpoint.index)"] }
            guard !utxosToUse.isEmpty else { return 0 }
        } else {
            utxosToUse = spendable
        }

        let totalBalance = utxosToUse.reduce(UInt64(0)) { $0 + $1.amount }
        let feeRate: UInt64
        if let feeRateOverride {
            feeRate = feeRateOverride
        } else {
            feeRate = await Self.fetchQuotedFeeRateSompiPerGram()
        }

        let mass = Self.calculateMass(numInputs: max(utxosToUse.count, 1), outputScriptLens: [34, 34], payloadSize: 0)
        let fee = Self.calculateFee(mass: mass, rateSompiPerGram: feeRate)

        guard totalBalance > fee else { return 0 }
        return totalBalance - fee
    }

    /// Cold-storage "Compound UTXOs" is a single self-send that merges as many of this address's
    /// UTXOs as one KasSigner-signable transaction can hold. A KSPT transaction is capped at
    /// `KsptCodec.maxInputs` (8) inputs, so this returns the largest up-to-8 spendable UTXOs at
    /// `fromAddress` (largest-first, so each round sheds the most value and converges fastest),
    /// plus whether more than that many remain. Merging 8 -> 1 per round means an address with N
    /// UTXOs takes ceil((N-1)/7) rounds; the caller repeats Compound until a single UTXO is left.
    /// No coinbase filtering, matching `buildUnsignedTransaction`.
    func compoundInputs(fromAddress: String) async throws -> (utxos: [UTXO], hasMore: Bool) {
        let spendable = try await NodePoolService.shared.getUtxosByAddresses([fromAddress])
        guard !spendable.isEmpty else { throw ColdSendError.noSpendableUtxos }
        let sorted = spendable.sorted { $0.amount > $1.amount }
        let capped = Array(sorted.prefix(KsptCodec.maxInputs))
        return (capped, sorted.count > KsptCodec.maxInputs)
    }

    /// Live quoted fee rate (sompi per mass-gram), matching Android's ColdStorageSendEngine:
    /// whichever is higher, the network's current "normal" bucket quote or the protocol
    /// minimum. Falls back to the minimum on any request failure, same as Android.
    static func fetchQuotedFeeRateSompiPerGram() async -> UInt64 {
        let minimum = KaspaFeePolicy.minimumRelayFeePerGramSompi
        guard let decoded = await fetchFeeEstimateResponse() else { return minimum }
        guard let quoted = decoded.normalBuckets.first?.feerate else { return minimum }
        return max(UInt64(quoted.rounded(.up)), minimum)
    }

    private struct FeeEstimateResponseBucket: Decodable {
        let feerate: Double
        let estimatedSeconds: Double?
    }

    private struct FeeEstimateResponse: Decodable {
        let priorityBucket: FeeEstimateResponseBucket?
        let normalBuckets: [FeeEstimateResponseBucket]
        let lowBuckets: [FeeEstimateResponseBucket]
    }

    private static func fetchFeeEstimateResponse() async -> FeeEstimateResponse? {
        guard var components = URLComponents(string: AppSettings.load().kaspaRestAPIURL) else { return nil }
        components.path += "/info/fee-estimate"
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(FeeEstimateResponse.self, from: data)
        } catch {
            return nil
        }
    }

    /// KSPT-encodes `tx` for display as an (animated) QR sequence — see `QrFrameChunker`.
    func toKspt(_ tx: UnsignedColdTx) throws -> Data {
        let inputs = tx.transaction.inputs.enumerated().map { index, input -> KsptCodec.UnsignedInput in
            let utxo = tx.inputUtxos[index]
            return KsptCodec.UnsignedInput(
                prevTxId: input.previousOutpoint.transactionId,
                prevIndex: input.previousOutpoint.index,
                amountSompi: utxo.amount,
                sequence: input.sequence,
                sigOpCount: input.sigOpCount,
                spkVersion: 0,
                spkScriptHex: utxo.scriptPublicKey.hexString
            )
        }
        let outputs = tx.transaction.outputs.map { output in
            KsptCodec.UnsignedOutput(
                valueSompi: output.value,
                spkVersion: output.scriptPublicKey.version,
                spkScriptHex: output.scriptPublicKey.script.hexString
            )
        }
        return try KsptCodec.encodeUnsigned(
            txVersion: tx.transaction.version,
            lockTime: tx.transaction.lockTime,
            subnetworkIdHex: tx.transaction.subnetworkId.hexString,
            gas: tx.transaction.gas,
            payloadHex: tx.transaction.payload.isEmpty ? nil : tx.transaction.payload.hexString,
            inputs: inputs,
            outputs: outputs
        )
    }

    /// Merges a scanned signed-KSPT response's per-input Schnorr signatures back into
    /// `unsignedTx`'s inputs and broadcasts. Verifies every input's outpoint AND every output's
    /// amount/script against what was actually sent for signing before broadcasting anything — a
    /// compromised/malfunctioning device altering the destination or amount must fail loudly
    /// here, not get silently broadcast.
    func broadcastSigned(unsignedTx: UnsignedColdTx, decoded: KsptCodec.Decoded) async throws -> String {
        guard decoded.signed else { throw ColdSendError.notSigned }
        guard decoded.inputs.count == unsignedTx.transaction.inputs.count else { throw ColdSendError.inputCountMismatch }
        guard decoded.outputs.count == unsignedTx.transaction.outputs.count else { throw ColdSendError.outputCountMismatch }

        for (index, decodedOutput) in decoded.outputs.enumerated() {
            let original = unsignedTx.transaction.outputs[index]
            guard decodedOutput.valueSompi == original.value,
                  decodedOutput.spkScriptHex == original.scriptPublicKey.script.hexString else {
                throw ColdSendError.outputMismatch(index)
            }
        }

        var signedInputs: [KaspaRpcTransactionInput] = []
        for (index, input) in unsignedTx.transaction.inputs.enumerated() {
            let decodedInput = decoded.inputs[index]
            guard decodedInput.prevTxId == input.previousOutpoint.transactionId,
                  decodedInput.prevIndex == input.previousOutpoint.index else {
                throw ColdSendError.inputMismatch(index)
            }
            guard let sigHex = decodedInput.signatureHex, let sigBytes = Data(hexString: sigHex) else {
                throw ColdSendError.inputNotSigned(index)
            }
            guard sigBytes.count == 64 else { throw ColdSendError.badSignatureLength(sigBytes.count) }

            // Standard P2PK signature script: push-64 opcode + 64-byte Schnorr signature +
            // 1-byte sighash type.
            var sigScript = Data()
            sigScript.append(0x41)
            sigScript.append(sigBytes)
            sigScript.append(decodedInput.sighashType ?? 0x01)

            signedInputs.append(KaspaRpcTransactionInput(
                previousOutpoint: input.previousOutpoint,
                signatureScript: sigScript,
                sequence: input.sequence,
                sigOpCount: input.sigOpCount
            ))
        }

        let signedTx = KaspaRpcTransaction(
            version: unsignedTx.transaction.version,
            inputs: signedInputs,
            outputs: unsignedTx.transaction.outputs,
            lockTime: unsignedTx.transaction.lockTime,
            subnetworkId: unsignedTx.transaction.subnetworkId,
            gas: unsignedTx.transaction.gas,
            payload: unsignedTx.transaction.payload
        )

        let (txId, _) = try await NodePoolService.shared.submitTransaction(signedTx, allowOrphan: false)
        return txId
    }
}
