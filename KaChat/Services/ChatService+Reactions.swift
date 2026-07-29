import Foundation
import CryptoKit

// MARK: - Message reactions (1:1) - see MessageReactionContent/MessageReactionCodec

extension ChatService {
    /// Loads this conversation's reactions from disk into the live in-memory index - called once
    /// per conversation open (`enterConversation`); kept live afterward by `sendReaction`/the
    /// incoming-reaction interception in `addMessageToConversation` updating this same dictionary
    /// directly, rather than a Core Data change-notification round trip for every update.
    func loadReactions(for contactAddress: String) {
        guard let key = messageEncryptionKey() else { return }
        Task { @MainActor in
            let loaded = await messageStore.fetchReactions(contactAddress: contactAddress, decryptionKey: key)
            for (targetTxId, snapshots) in loaded {
                reactionsByTxId[targetTxId] = snapshots
            }
        }
    }

    /// Applies a reaction to the in-memory index immediately (optimistic UI on send, live update
    /// on receipt) - replaces `reactorAddress`'s previous entry for `targetTxId` if any, since
    /// there's only ever one reaction per (message, reactor).
    func applyLocalReaction(targetTxId: String, reactorAddress: String, emoji: String) {
        var existing = reactionsByTxId[targetTxId] ?? []
        existing.removeAll { $0.reactorAddress == reactorAddress }
        existing.append(MessageStore.ReactionSnapshot(targetTxId: targetTxId, reactorAddress: reactorAddress, emoji: emoji))
        reactionsByTxId[targetTxId] = existing
    }

    func removeLocalReaction(targetTxId: String, reactorAddress: String) {
        guard var existing = reactionsByTxId[targetTxId] else { return }
        existing.removeAll { $0.reactorAddress == reactorAddress }
        if existing.isEmpty {
            reactionsByTxId.removeValue(forKey: targetTxId)
        } else {
            reactionsByTxId[targetTxId] = existing
        }
    }

    /// Reacts to `targetTxId` with `emoji` ("add"), or removes this wallet's existing reaction on
    /// it ("remove"). Unlike `sendMessage`, this never creates a visible pending bubble - the
    /// reaction is applied to the local reactions store immediately (optimistic UI) and the
    /// actual send happens in the background via the same contextual-message pipeline any other
    /// message uses.
    func sendReaction(to contact: Contact, targetTxId: String, emoji: String, action: String) async throws {
        guard let key = messageEncryptionKey() else { return }
        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        let blockTime = Int64(Date().timeIntervalSince1970 * 1000)

        if action == "add" {
            applyLocalReaction(targetTxId: targetTxId, reactorAddress: myAddress, emoji: emoji)
            messageStore.upsertReaction(
                targetTxId: targetTxId, reactorAddress: myAddress, contactAddress: contact.address,
                emoji: emoji, reactionTxId: nil, blockTime: blockTime, encryptionKey: key
            )
        } else {
            removeLocalReaction(targetTxId: targetTxId, reactorAddress: myAddress)
            messageStore.removeReaction(targetTxId: targetTxId, reactorAddress: myAddress)
        }
        // Every Core Data write - reactions included - fires a local NSPersistentStoreRemoteChange
        // notification indistinguishable from a real CloudKit import; recording it here (same as
        // every other local save already does) suppresses the resulting full-conversation reload
        // this write would otherwise needlessly trigger.
        recordLocalSave()

        let payload = MessageReactionCodec.encode(targetTxId: targetTxId, emoji: emoji, action: action)
        guard !payload.isEmpty else { return }

        try await enqueueOutgoingTxOperation {
            try await self.sendReactionInternal(
                to: contact, payload: payload, targetTxId: targetTxId,
                reactorAddress: myAddress, emoji: emoji, action: action, encryptionKey: key
            )
        }
    }

    private func sendReactionInternal(
        to contact: Contact,
        payload: String,
        targetTxId: String,
        reactorAddress: String,
        emoji: String,
        action: String,
        encryptionKey: SymmetricKey
    ) async throws {
        guard let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.walletNotFound
        }
        guard let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.keychainError("Could not get private key")
        }
        guard let recipientPublicKey = KaspaAddress.publicKey(from: contact.address) else {
            throw KasiaError.invalidAddress
        }
        guard let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }

        ensureRoutingState(for: contact.address, privateKey: privateKey)
        let alias = outgoingAlias(for: contact.address)

        let rpcManager = NodePoolService.shared
        if !rpcManager.isConnected {
            try await rpcManager.connect(network: currentSettings.networkType)
        }

        let utxos = try await rpcManager.getUtxosByAddresses([wallet.publicAddress])
        let candidateUtxos = prepareMessageUtxos(confirmed: utxos)
        guard !candidateUtxos.isEmpty else {
            throw KasiaError.networkError(noSpendableFundsYetMessage())
        }

        let transaction = try KasiaTransactionBuilder.buildContextualMessageTx(
            from: wallet.publicAddress,
            to: contact.address,
            alias: alias,
            message: payload,
            senderPrivateKey: privateKey,
            recipientPublicKey: recipientPublicKey,
            utxos: candidateUtxos,
            feeOverride: nil
        )
        let spentUtxos = spentMessageUtxos(from: transaction, candidates: candidateUtxos)
        let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }
        let submitted = try await rpcManager.submitTransaction(transaction, allowOrphan: usesUnconfirmedInputs)

        reserveMessageOutpoints(spentUtxos)
        consumePendingUtxos(spentUtxos)
        addPendingOutputs(from: transaction, txId: submitted.txId, senderScriptPubKey: senderScriptPubKey)

        if action == "add" {
            messageStore.upsertReaction(
                targetTxId: targetTxId, reactorAddress: reactorAddress, contactAddress: contact.address,
                emoji: emoji, reactionTxId: submitted.txId,
                blockTime: Int64(Date().timeIntervalSince1970 * 1000), encryptionKey: encryptionKey
            )
            recordLocalSave()
        }
    }
}
