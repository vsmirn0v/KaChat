import Foundation

// MARK: - Notifications

extension Notification.Name {
    static let rpcSubscriptionsRestored = Notification.Name("rpcSubscriptionsRestored")
    static let rpcReconnected = Notification.Name("rpcReconnected")
}

/// RPC notification types emitted by gRPC subscriptions
enum KaspaRPCNotification: Equatable {
    case utxosChanged
}

// MARK: - Node Info

struct NodeInfo {
    let p2pId: String
    let mempoolSize: UInt64
    let serverVersion: String
    let isUtxoIndexed: Bool
    let isSynced: Bool
    let hasNotifyCommand: Bool
    let hasMessageId: Bool

    var networkId: String { "mainnet" }
}

// MARK: - UTXO

struct UTXO {
    let address: String
    let outpoint: Outpoint
    let amount: UInt64
    let scriptPublicKey: Data
    let blockDaaScore: UInt64
    let isCoinbase: Bool

    struct Outpoint {
        let transactionId: String
        let index: UInt32
    }
}

// MARK: - Mempool Entry Result

struct MempoolEntryResult {
    let txId: String
    let sender: String?
    let inputs: [(txId: String, index: UInt32)]
    let outputs: [(address: String, amount: UInt64)]
    let payload: String
    let fee: UInt64
    let isOrphan: Bool
}

// MARK: - RPC Transaction Types

struct KaspaRpcTransaction {
    let version: UInt16
    let inputs: [KaspaRpcTransactionInput]
    let outputs: [KaspaRpcTransactionOutput]
    let lockTime: UInt64
    let subnetworkId: Data
    let gas: UInt64
    let payload: Data
    var mass: UInt64 = 0

    /// Encode for mass calculation
    func encodeTo(_ data: inout Data) {
        var structVersion: UInt16 = 1
        data.append(Data(bytes: &structVersion, count: 2))

        var txVersion = version.littleEndian
        data.append(Data(bytes: &txVersion, count: 2))

        var inputsPayload = Data()
        var inputCount = UInt32(inputs.count).littleEndian
        inputsPayload.append(Data(bytes: &inputCount, count: 4))
        for input in inputs {
            var item = Data()
            input.encodeTo(&item)
            appendPayload(&inputsPayload, item)
        }
        appendPayload(&data, inputsPayload)

        var outputsPayload = Data()
        var outputCount = UInt32(outputs.count).littleEndian
        outputsPayload.append(Data(bytes: &outputCount, count: 4))
        for output in outputs {
            var item = Data()
            output.encodeTo(&item)
            appendPayload(&outputsPayload, item)
        }
        appendPayload(&data, outputsPayload)

        var lt = lockTime.littleEndian
        data.append(Data(bytes: &lt, count: 8))

        var subnetBytes = subnetworkId
        if subnetBytes.count < 20 {
            subnetBytes.append(contentsOf: Data(repeating: 0, count: 20 - subnetBytes.count))
        } else if subnetBytes.count > 20 {
            subnetBytes = subnetBytes.prefix(20)
        }
        data.append(subnetBytes)

        var g = gas.littleEndian
        data.append(Data(bytes: &g, count: 8))

        var payloadLen = UInt32(payload.count).littleEndian
        data.append(Data(bytes: &payloadLen, count: 4))
        data.append(payload)

        var m = mass.littleEndian
        data.append(Data(bytes: &m, count: 8))

        data.append(0x01)
        var emptyLen: UInt32 = 0
        data.append(Data(bytes: &emptyLen, count: 4))
    }
}

struct KaspaRpcTransactionInput {
    let previousOutpoint: UTXO.Outpoint
    let signatureScript: Data
    let sequence: UInt64
    let sigOpCount: UInt8

    func encodeTo(_ data: inout Data) {
        data.append(0x01)

        var outpointData = Data()
        encodeOutpoint(&outpointData)
        appendPayload(&data, outpointData)

        var sigLen = UInt32(signatureScript.count).littleEndian
        data.append(Data(bytes: &sigLen, count: 4))
        data.append(signatureScript)

        var seq = sequence.littleEndian
        data.append(Data(bytes: &seq, count: 8))

        data.append(sigOpCount)

        data.append(0x01)
        var emptyLen: UInt32 = 0
        data.append(Data(bytes: &emptyLen, count: 4))
    }

    private func encodeOutpoint(_ data: inout Data) {
        data.append(0x01)

        var txIdBytes = Data(hexString: previousOutpoint.transactionId) ?? Data(repeating: 0, count: 32)
        if txIdBytes.count < 32 {
            txIdBytes = Data(repeating: 0, count: 32 - txIdBytes.count) + txIdBytes
        } else if txIdBytes.count > 32 {
            txIdBytes = Data(txIdBytes.prefix(32))
        }
        data.append(txIdBytes)

        var idx = previousOutpoint.index.littleEndian
        data.append(Data(bytes: &idx, count: 4))
    }
}

struct KaspaRpcTransactionOutput {
    let value: UInt64
    let scriptPublicKey: KaspaScriptPublicKey

    func encodeTo(_ data: inout Data) {
        data.append(0x01)

        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))

        scriptPublicKey.encodeTo(&data)

        data.append(0x01)
        var emptyLen: UInt32 = 0
        data.append(Data(bytes: &emptyLen, count: 4))
    }
}

struct KaspaScriptPublicKey {
    let version: UInt16
    let script: Data

    func encodeTo(_ data: inout Data) {
        var v = version.littleEndian
        data.append(Data(bytes: &v, count: 2))

        var scriptLen = UInt32(script.count).littleEndian
        data.append(Data(bytes: &scriptLen, count: 4))
        data.append(script)
    }

    static func p2pk(publicKey: Data) -> KaspaScriptPublicKey {
        var script = Data()
        script.append(UInt8(publicKey.count))
        script.append(publicKey)
        script.append(0xAC) // OP_CHECKSIG
        return KaspaScriptPublicKey(version: 0, script: script)
    }
}

// MARK: - Protobuf Conversions

extension KaspaRpcTransaction {
    /// Convert to gRPC protobuf format
    func toProtobuf() -> Protowire_RpcTransaction {
        var tx = Protowire_RpcTransaction()
        tx.version = UInt32(version)
        tx.inputs = inputs.map { $0.toProtobuf() }
        tx.outputs = outputs.map { $0.toProtobuf() }
        tx.lockTime = lockTime
        tx.subnetworkID = subnetworkId.hexString
        tx.gas = gas
        tx.payload = payload.hexString
        return tx
    }
}

extension KaspaRpcTransactionInput {
    /// Convert to gRPC protobuf format
    func toProtobuf() -> Protowire_RpcTransactionInput {
        var input = Protowire_RpcTransactionInput()
        var outpoint = Protowire_RpcOutpoint()
        outpoint.transactionID = previousOutpoint.transactionId
        outpoint.index = previousOutpoint.index
        input.previousOutpoint = outpoint
        input.signatureScript = signatureScript.hexString
        input.sequence = sequence
        input.sigOpCount = UInt32(sigOpCount)
        return input
    }
}

extension KaspaRpcTransactionOutput {
    /// Convert to gRPC protobuf format
    func toProtobuf() -> Protowire_RpcTransactionOutput {
        var output = Protowire_RpcTransactionOutput()
        output.amount = value
        var spk = Protowire_RpcScriptPublicKey()
        spk.version = UInt32(scriptPublicKey.version)
        spk.scriptPublicKey = scriptPublicKey.script.hexString
        output.scriptPublicKey = spk
        return output
    }
}

private func appendPayload(_ target: inout Data, _ payload: Data) {
    var len = UInt32(payload.count).littleEndian
    target.append(Data(bytes: &len, count: 4))
    target.append(payload)
}

// MARK: - UTXO Change Notification Parsing (Protobuf format)

struct ParsedUtxoEntry {
    let transactionId: String
    let outputIndex: UInt32
    let amount: UInt64
    let address: String?
    let blockDaaScore: UInt64
    let isCoinbase: Bool
}

struct ParsedUtxosChangedNotification {
    let added: [ParsedUtxoEntry]
    let removed: [ParsedUtxoEntry]
}

// MARK: - gRPC Notification Parsing

enum GrpcNotificationParser {
    /// Parse UtxosChangedNotification from gRPC protobuf serialized data
    static func parseUtxosChangedNotification(_ data: Data) -> ParsedUtxosChangedNotification? {
        guard let notification = try? Protowire_UtxosChangedNotificationMessage(serializedBytes: data) else {
            return nil
        }

        let added = notification.added.map { entry -> ParsedUtxoEntry in
            ParsedUtxoEntry(
                transactionId: entry.outpoint.transactionID,
                outputIndex: entry.outpoint.index,
                amount: entry.utxoEntry.amount,
                address: entry.address.isEmpty ? nil : entry.address,
                blockDaaScore: entry.utxoEntry.blockDaaScore,
                isCoinbase: entry.utxoEntry.isCoinbase
            )
        }

        let removed = notification.removed.map { entry -> ParsedUtxoEntry in
            ParsedUtxoEntry(
                transactionId: entry.outpoint.transactionID,
                outputIndex: entry.outpoint.index,
                amount: entry.utxoEntry.amount,
                address: entry.address.isEmpty ? nil : entry.address,
                blockDaaScore: entry.utxoEntry.blockDaaScore,
                isCoinbase: entry.utxoEntry.isCoinbase
            )
        }

        return ParsedUtxosChangedNotification(added: added, removed: removed)
    }
}
