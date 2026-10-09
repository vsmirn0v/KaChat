import Foundation

extension KachatNames {

    // MARK: - Version-1 transaction model (rusty-kaspa a41a333, consensus/core/src/tx.rs)

    struct Outpoint: Equatable, Hashable {
        /// Transaction id, 32 bytes in hashing order (the hex string as written by the node).
        var txid: Data
        var index: UInt32
    }

    struct UtxoEntry: Equatable {
        var amount: UInt64
        var scriptVersion: UInt16 = 0
        var script: Data
        var blockDaaScore: UInt64
        var isCoinbase: Bool = false
        /// KIP-20 covenant id the UTXO carries (gaps and names: the registry id).
        var covenantId: Data?
    }

    struct Utxo: Equatable {
        var outpoint: Outpoint
        var entry: UtxoEntry
    }

    struct CovenantBinding: Equatable {
        var authorizingInput: UInt16
        var covenantId: Data
    }

    struct TxInput: Equatable {
        var outpoint: Outpoint
        var signatureScript: Data
        var sequence: UInt64
        /// Version-1 compute budget (1 unit = 10,000 script units; 9,999 free per input).
        var computeBudget: UInt16
    }

    struct TxOutput: Equatable {
        var value: UInt64
        var scriptVersion: UInt16 = 0
        var script: Data
        var covenant: CovenantBinding?
    }

    /// A version-1 (Toccata) transaction: output covenant bindings, per-input compute budgets,
    /// native subnetwork, no gas, and the KIP-9 storage-mass commitment.
    struct Tx: Equatable {
        var version: UInt16 = 1
        var inputs: [TxInput]
        var outputs: [TxOutput]
        var lockTime: UInt64
        var subnetworkId = Data(repeating: 0, count: 20)
        var gas: UInt64 = 0
        var payload: Data
        var storageMass: UInt64 = 0

        var isNativeSubnetwork: Bool { subnetworkId == Data(repeating: 0, count: 20) }

        // MARK: Serialization (rusty-kaspa consensus/core/src/hashing/tx.rs `write_transaction`)

        private func write(excludeSignatureScripts: Bool, excludeMassCommit: Bool, excludePayload: Bool) -> Data {
            precondition(version >= 1, "the name core builds version-1 transactions only")
            var d = Data()
            d.append(le16(version))
            d.append(le64(UInt64(inputs.count)))
            for i in inputs {
                d.append(i.outpoint.txid)
                d.append(le32(i.outpoint.index))
                if excludeSignatureScripts {
                    d.append(le64(0))
                } else {
                    d.append(le64(UInt64(i.signatureScript.count)))
                    d.append(i.signatureScript)
                }
                d.append(le64(i.sequence))
                if !excludeMassCommit {
                    d.append(le16(i.computeBudget))
                }
            }
            d.append(le64(UInt64(outputs.count)))
            for o in outputs {
                Tx.appendOutput(o, to: &d)
            }
            d.append(le64(lockTime))
            d.append(subnetworkId)
            d.append(le64(gas))
            if excludePayload {
                d.append(le64(0))
            } else {
                d.append(le64(UInt64(payload.count)))
                d.append(payload)
            }
            if !excludeMassCommit {
                d.append(le64(storageMass))
            }
            return d
        }

        fileprivate static func appendOutput(_ o: TxOutput, to d: inout Data) {
            d.append(le64(o.value))
            d.append(le16(o.scriptVersion))
            d.append(le64(UInt64(o.script.count)))
            d.append(o.script)
            d.append(o.covenant == nil ? 0 : 1)
            if let c = o.covenant {
                d.append(le16(c.authorizingInput))
                d.append(c.covenantId)
            }
        }

        /// The TransactionHash preimage (`write_transaction(tx, FULL)`).
        var fullPreimage: Data { write(excludeSignatureScripts: false, excludeMassCommit: false, excludePayload: false) }

        /// `transaction_v1_rest_preimage`: no payload, signature scripts or mass commitments.
        var restPreimage: Data { write(excludeSignatureScripts: true, excludeMassCommit: true, excludePayload: true) }

        /// The v1 transaction id: `TransactionV1Id(PayloadDigest(payload) || TransactionRest(rest))`.
        var id: Data {
            var d = blake3Keyed("PayloadDigest", payload)
            d.append(blake3Keyed("TransactionRest", restPreimage))
            return blake3Keyed("TransactionV1Id", d)
        }

        var idHex: String { hex(id) }

        /// The transaction hash (commits to signature scripts, budgets and the storage mass).
        var hash: Data { blake2bKeyed("TransactionHash", fullPreimage) }

        // MARK: Sighash (consensus/core/src/hashing/sighash.rs, SIGHASH_ALL, version >= 1)

        /// The Schnorr signature hash of input `index` for SIGHASH_ALL. `entries` are the spent
        /// UTXOs in input order. Version-1 sighashes cover no sig-op counts and no budgets.
        func sighash(inputIndex index: Int, entries: [UtxoEntry]) -> Data {
            let domain = "TransactionSigningHash"
            var prev = Data()
            var seqs = Data()
            for i in inputs {
                prev.append(i.outpoint.txid)
                prev.append(le32(i.outpoint.index))
                seqs.append(le64(i.sequence))
            }
            var outs = Data()
            for o in outputs {
                Tx.appendOutput(o, to: &outs)
            }
            let payloadHash: Data
            if isNativeSubnetwork && payload.isEmpty {
                payloadHash = zero32
            } else {
                var p = le64(UInt64(payload.count))
                p.append(payload)
                payloadHash = blake2bKeyed(domain, p)
            }
            let input = inputs[index]
            let entry = entries[index]
            var d = Data()
            d.append(le16(version))
            d.append(blake2bKeyed(domain, prev))
            d.append(blake2bKeyed(domain, seqs))
            d.append(input.outpoint.txid)
            d.append(le32(input.outpoint.index))
            d.append(le16(entry.scriptVersion))
            d.append(le64(UInt64(entry.script.count)))
            d.append(entry.script)
            d.append(le64(entry.amount))
            d.append(le64(input.sequence))
            d.append(blake2bKeyed(domain, outs))
            d.append(le64(lockTime))
            d.append(subnetworkId)
            d.append(le64(gas))
            d.append(payloadHash)
            d.append(sighashAll)
            return blake2bKeyed(domain, d)
        }
    }

    // MARK: - Mass (consensus/core/src/mass/mod.rs) and fee

    enum Mass {
        static let massPerTxByte: UInt64 = 1
        static let massPerScriptPubKeyByte: UInt64 = 10
        static let gramsPerComputeBudgetUnit: UInt64 = 100
        static let transientByteToMassFactor: UInt64 = 4
        /// KIP-9 `C` = SOMPI_PER_KASPA * 10,000.
        static let storageMassParameter: UInt64 = 1_000_000_000_000
        /// Mempool block mass limits after Toccata (compute 500,000, transient 1,000,000):
        /// normalized transient = transient * 500,000 / 1,000,000.
        static let transientCofactor: Double = 500_000.0 / 1_000_000.0

        /// `transaction_estimated_serialized_size`.
        static func size(_ tx: Tx) -> UInt64 {
            var size: UInt64 = 2 + 8
            for i in tx.inputs {
                size += 32 + 4 + 8 + UInt64(i.signatureScript.count) + 8
                if tx.version >= 1 { size += 2 }
            }
            size += 8
            for o in tx.outputs {
                size += 8 + 2 + 8 + UInt64(o.script.count)
                if o.covenant != nil { size += 2 + 32 }
            }
            size += 8 + 20 + 8 + 32 + 8 + UInt64(tx.payload.count)
            return size
        }

        static func computeMass(_ tx: Tx) -> UInt64 {
            let spkBytes = tx.outputs.reduce(UInt64(0)) { $0 + 2 + UInt64($1.script.count) }
            let budgets = tx.inputs.reduce(UInt64(0)) { $0 + UInt64($1.computeBudget) }
            return size(tx) * massPerTxByte + spkBytes * massPerScriptPubKeyByte + gramsPerComputeBudgetUnit * budgets
        }

        static func transientMass(_ tx: Tx) -> UInt64 { size(tx) * transientByteToMassFactor }

        static func normalizedTransient(_ tx: Tx) -> UInt64 {
            UInt64((Double(transientMass(tx)) * transientCofactor).rounded(.up))
        }

        /// `utxo_plurality`: 100-byte storage units of a UTXO.
        static func plurality(scriptLength: Int, hasCovenant: Bool) -> UInt64 {
            let bytes = 63 + scriptLength + (hasCovenant ? 32 : 0)
            return UInt64((bytes + 99) / 100)
        }

        /// KIP-9 storage mass (`calc_storage_mass`), nil when incomputable (too high).
        static func storageMass(_ tx: Tx, entries: [UtxoEntry]) -> UInt64? {
            let c = storageMassParameter
            var outsPlurality: UInt64 = 0
            var harmonicOuts: UInt64 = 0
            for o in tx.outputs {
                let p = plurality(scriptLength: o.script.count, hasCovenant: o.covenant != nil)
                guard o.value > 0 else { return nil }
                outsPlurality += p
                let (cp, o1) = c.multipliedReportingOverflow(by: p)
                let (cpp, o2) = cp.multipliedReportingOverflow(by: p)
                if o1 || o2 { return nil }
                let (sum, o3) = harmonicOuts.addingReportingOverflow(cpp / o.value)
                if o3 { return nil }
                harmonicOuts = sum
            }
            let ins = entries.map { (p: plurality(scriptLength: $0.script.count, hasCovenant: $0.covenantId != nil), amount: $0.amount) }
            let relaxed: Bool
            if outsPlurality == 1 {
                relaxed = true
            } else if ins.count > 2 {
                relaxed = false
            } else {
                let insPlurality = ins.reduce(UInt64(0)) { $0 + $1.p }
                relaxed = insPlurality == 1 || (outsPlurality == 2 && insPlurality == 2)
            }
            if relaxed {
                var harmonicIns: UInt64 = 0
                for i in ins {
                    guard i.amount > 0 else { return nil }
                    let term = c * i.p * i.p / i.amount
                    let (s, o) = harmonicIns.addingReportingOverflow(term)
                    harmonicIns = o ? UInt64.max : s
                }
                return harmonicOuts > harmonicIns ? harmonicOuts - harmonicIns : 0
            }
            let insPlurality = ins.reduce(UInt64(0)) { $0 + $1.p }
            let sumIns = ins.reduce(UInt64(0)) { $0 + $1.amount }
            let meanIns = max(sumIns / insPlurality, 1)
            let (arith, o) = insPlurality.multipliedReportingOverflow(by: c / meanIns)
            let arithmeticIns = o ? UInt64.max : arith
            return harmonicOuts > arithmeticIns ? harmonicOuts - arithmeticIns : 0
        }

        /// The relay fee the CLI pays: ceil(max(compute, normalized transient) * feerate). Total:
        /// the rate is made safe first (`safeFeerate`), so the product is always a small finite
        /// number - `UInt64(Double)` never sees NaN, infinity or 2^64 (IOS-061).
        static func networkFee(_ tx: Tx, feerate: Double) -> UInt64 {
            let feeMass = max(computeMass(tx), normalizedTransient(tx))
            let fee = (Double(feeMass) * safeFeerate(feerate)).rounded(.up)
            guard fee.isFinite, fee >= 0, fee < 9.0e18 else { return UInt64(9.0e18) }
            return UInt64(fee)
        }
    }
}
