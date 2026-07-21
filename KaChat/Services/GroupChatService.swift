import Foundation
import Combine
import CryptoKit
import P256K

/// Orchestrates KaChat's group chat feature: group lifecycle (create/add/remove member,
/// epoch rotation), sending/receiving `gcomm` group messages, and the invite-beacon join flow.
///
/// Architecturally self-contained, like `BroadcastService`: owns its own block-scan discovery
/// (`NodePoolService.shared.subscribeBlockAdded()`) rather than threading group state through
/// `ChatService`'s 1:1 contact/conversation machinery, so this feature can't regress existing
/// 1:1 messaging. Reuses `ChatService`'s UTXO reservation coordination
/// (`prepareMessageUtxos`/`enqueueOutgoingTxOperation`/etc.) since that's shared, correctness-
/// critical state across every service that spends the wallet's UTXOs.
///
/// Three on-chain payload types, all self-stash (sender spends their own UTXOs, output returns
/// to their own address), all discovered via the same block-scan:
///  - `ciph_msg:1:gcomm:...` - a group message (see GroupCipher, protocol spec).
///  - `ciph_msg:1:ginv:...` - an invite beacon (KaChat extension, see GroupCipher).
///  - `ciph_msg:1:gctl:...` - a control message (`gctl_root`/`gctl_epoch`), ECIES-encrypted
///    (via KasiaCipher, the same crypto 1:1 contextual messages use) to one specific recipient.
///    The spec describes this as riding "the existing 1:1 encrypted COMM channel" - here that
///    means reusing the same ECIES scheme and self-stash shape, not literally routing through
///    ChatService's contact/conversation UI, so control payloads never leak into a 1:1 chat.
@MainActor
final class GroupChatService: ObservableObject {
    static let shared = GroupChatService()

    @Published private(set) var groups: [GroupChat] = []
    @Published var groupMessages: [String: [GroupMessage]] = [:]

    private let store = GroupStore.shared
    private let keychain = KeychainService.shared

    /// Pending invite seeds this device is scanning for, keyed by invite_tag.
    private var pendingInvites: [Data: Data] = [:]

    private var blockNotificationHandlerId: UUID?
    private var isScanningActive = false

    private static let gcommPrefix = "ciph_msg:1:gcomm:"
    private static let ginvPrefix = "ciph_msg:1:ginv:"
    private static let gctlPrefix = "ciph_msg:1:gctl:"
    private static let gcommPrefixHex = hexPrefix(gcommPrefix)
    private static let ginvPrefixHex = hexPrefix(ginvPrefix)
    private static let gctlPrefixHex = hexPrefix(gctlPrefix)

    private static func hexPrefix(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private init() {}

    // MARK: - Wallet lifecycle

    func setCurrentWallet(_ walletAddress: String?) {
        store.setCurrentWallet(walletAddress)
        pendingInvites.removeAll()
        groups = walletAddress == nil ? [] : store.allGroups()
        groupMessages.removeAll()
        for group in groups {
            loadMessages(for: group.id)
        }
        updateScanningStateIfNeeded()
    }

    /// Clears all local group data for the current wallet (Core Data + Keychain bags).
    /// Call from the same wallet-reset paths that call `MessageStore`/`BroadcastStore` clearAll.
    func clearAllLocalData() {
        for group in groups {
            try? keychain.deleteGroupBag(groupId: group.id)
        }
        store.clearAll()
        groups = []
        groupMessages.removeAll()
        pendingInvites.removeAll()
        updateScanningStateIfNeeded()
    }

    // MARK: - GroupChat creation & membership

    func createGroup(name: String, members: [Contact]) async throws -> GroupChat {
        guard let wallet = WalletManager.shared.currentWallet,
              let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.walletNotFound
        }
        let adminXOnlyPub = try schnorrXOnlyPublicKey(from: privateKey)

        let groupSeed = GroupCipher.generateGroupSeed()
        let groupId = GroupCipher.deriveGroupId(groupSeed: groupSeed)
        let groupRootEpoch0 = GroupCipher.deriveGroupRootEpoch(groupSeed: groupSeed, groupId: groupId, epoch: 0)
        let blindingKey = GroupCipher.deriveBlindingKey(groupSeed: groupSeed, groupId: groupId)
        let deviceId = GroupCipher.generateDeviceId()

        var roster: [GroupMember] = [
            GroupMember(address: wallet.publicAddress, xOnlyPubKeyHex: adminXOnlyPub.hexString, isAdmin: true, displayName: nil)
        ]
        for contact in members {
            guard let memberXOnlyPub = KaspaAddress.publicKey(from: contact.address) else { continue }
            roster.append(GroupMember(address: contact.address, xOnlyPubKeyHex: memberXOnlyPub.hexString, isAdmin: false, displayName: contact.alias))
        }

        let bag = GroupBag(
            groupId: groupId.hexString,
            groupSeed: groupSeed.hexString,
            groupRootEpoch: groupRootEpoch0.hexString,
            blindingKey: blindingKey.hexString,
            currentEpoch: 0,
            deviceId: deviceId.hexString,
            msgCounter: 0
        )
        try keychain.saveGroupBag(bag)

        let group = GroupChat(
            id: groupId.hexString,
            name: name,
            adminAddress: wallet.publicAddress,
            adminXOnlyPubKeyHex: adminXOnlyPub.hexString,
            members: roster,
            currentEpoch: 0,
            createdAt: Date(),
            isAdmin: true
        )
        store.upsertGroup(group)
        groups = store.allGroups()
        groupMessages[group.id] = []
        updateScanningStateIfNeeded()

        // Distribute gctl_root to each initial member directly (they must already be 1:1
        // contacts, i.e. their pubkey is resolvable from their address). Members added later
        // via invite link don't need this - they bootstrap from the invite beacon instead.
        var sendErrors: [Error] = []
        for member in roster where !member.isAdmin {
            do {
                try await sendRootControlMessage(group: group, bag: bag, to: member.address, privateKey: privateKey)
            } catch {
                sendErrors.append(error)
            }
        }
        if !sendErrors.isEmpty {
            AppLog.log("[GroupChatService] %d/%d member(s) failed to receive gctl_root for new group %@",
                       sendErrors.count, roster.count - 1, String(group.id.prefix(12)))
        }

        return group
    }

    /// Adds a member directly (requires an existing 1:1-resolvable address) - bumps the epoch
    /// and redistributes the new root to every member (old + new), matching the reference
    /// spec's "membership change -> epoch rotation" model.
    func addMember(_ contact: Contact, to groupId: String) async throws {
        try await rotateEpoch(groupId: groupId, reason: .add) { roster in
            guard let xOnlyPub = KaspaAddress.publicKey(from: contact.address) else {
                throw KasiaError.invalidAddress
            }
            if !roster.contains(where: { $0.address == contact.address }) {
                roster.append(GroupMember(address: contact.address, xOnlyPubKeyHex: xOnlyPub.hexString, isAdmin: false, displayName: contact.alias))
            }
        }
    }

    /// Removes a member and rotates the epoch so the removed member can no longer decrypt
    /// future messages (the new root is only distributed to remaining members).
    func removeMember(_ member: GroupMember, from groupId: String) async throws {
        try await rotateEpoch(groupId: groupId, reason: .remove) { roster in
            roster.removeAll { $0.address == member.address }
        }
    }

    private func rotateEpoch(groupId: String, reason: GroupCipher.EpochChangeReason, mutateRoster: (inout [GroupMember]) throws -> Void) async throws {
        guard var group = store.group(id: groupId), group.isAdmin else {
            throw KasiaError.networkError("Only the group admin can change membership.")
        }
        guard var bag = try keychain.loadGroupBag(groupId: groupId), let groupSeedHex = bag.groupSeed,
              let groupSeed = Data(hexString: groupSeedHex), let gid = Data(hexString: groupId) else {
            throw KasiaError.networkError("Missing admin group secrets.")
        }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.walletNotFound
        }

        var roster = group.members
        try mutateRoster(&roster)

        let newEpoch = bag.currentEpoch + 1
        let newRoot = GroupCipher.deriveGroupRootEpoch(groupSeed: groupSeed, groupId: gid, epoch: newEpoch)
        bag.currentEpoch = newEpoch
        bag.groupRootEpoch = newRoot.hexString
        try keychain.saveGroupBag(bag)

        group.members = roster
        group.currentEpoch = newEpoch
        store.upsertGroup(group)
        groups = store.allGroups()

        var sendErrors: [Error] = []
        for member in roster where member.address != wallet.publicAddress {
            do {
                try await sendEpochControlMessage(groupId: gid, epoch: newEpoch, reason: reason, to: member.address, adminPrivateKey: privateKey)
                try await sendRootControlMessage(group: group, bag: bag, to: member.address, privateKey: privateKey)
            } catch {
                sendErrors.append(error)
            }
        }
        if !sendErrors.isEmpty {
            AppLog.log("[GroupChatService] %d member(s) failed to receive epoch rotation for group %@",
                       sendErrors.count, String(groupId.prefix(12)))
            throw KasiaError.networkError("Epoch rotated, but \(sendErrors.count) member(s) may not have received the update yet.")
        }
    }

    // MARK: - Invite beacon (KaChat extension)

    /// Builds a shareable invite link for a group. The admin still needs to call
    /// `publishInvite` (at least once) for scanning devices to actually discover it on-chain.
    func createInvite(for groupId: String) throws -> GroupInvite {
        let inviteSeed = GroupCipher.generateInviteSeed()
        return GroupInvite(groupId: groupId, inviteSeedHex: inviteSeed.hexString, createdAt: Date())
    }

    static func inviteLink(_ invite: GroupInvite) -> String {
        "kachat-group-invite:v1:\(invite.inviteSeedHex)"
    }

    static func parseInviteLink(_ link: String) -> Data? {
        let prefix = "kachat-group-invite:v1:"
        guard link.hasPrefix(prefix) else { return nil }
        return Data(hexString: String(link.dropFirst(prefix.count)))
    }

    /// Publishes (or republishes) the invite beacon on-chain so scanning devices can find it.
    func publishInvite(_ invite: GroupInvite) async throws {
        guard let group = store.group(id: invite.groupId), group.isAdmin else {
            throw KasiaError.networkError("Only the group admin can publish an invite.")
        }
        guard let bag = try keychain.loadGroupBag(groupId: invite.groupId),
              let gid = Data(hexString: invite.groupId),
              let groupRootEpoch = Data(hexString: bag.groupRootEpoch),
              let blindingKey = Data(hexString: bag.blindingKey),
              let adminXOnlyPub = Data(hexString: group.adminXOnlyPubKeyHex),
              let inviteSeed = Data(hexString: invite.inviteSeedHex) else {
            throw KasiaError.networkError("Missing group secrets.")
        }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.walletNotFound
        }

        let rootPayload = try GroupCipher.buildSignedRootPayload(
            groupId: gid, epoch: bag.currentEpoch, groupRootEpoch: groupRootEpoch, blindingKey: blindingKey,
            adminSigningPub: adminXOnlyPub, members: group.members.map { $0.address }, name: group.name,
            adminPrivateKey: privateKey
        )
        let innerJSON = try JSONEncoder().encode(rootPayload)
        let encrypted = try GroupCipher.encryptInvitePayload(innerJSON, inviteSeed: inviteSeed)
        let inviteTag = GroupCipher.deriveInviteTag(inviteSeed: inviteSeed)
        let payloadString = GroupCipher.buildGroupInvitePayload(inviteTag: inviteTag, encryptedPayload: encrypted)

        _ = try await ChatService.shared.enqueueOutgoingTxOperation { [weak self] in
            try await self?.sendSelfStashPayload(payloadString, from: wallet.publicAddress, privateKey: privateKey)
        }
    }

    /// Registers an invite link for background scanning. The actual join completes
    /// asynchronously once (if) a matching beacon is seen on-chain - call `publishInvite`
    /// on the sharer's side to make sure one is actually being broadcast.
    @discardableResult
    func joinFromInvite(_ inviteLink: String) -> Bool {
        guard let inviteSeed = Self.parseInviteLink(inviteLink) else { return false }
        let inviteTag = GroupCipher.deriveInviteTag(inviteSeed: inviteSeed)
        pendingInvites[inviteTag] = inviteSeed
        updateScanningStateIfNeeded()
        return true
    }

    // MARK: - Sending group messages

    func sendGroupMessage(_ text: String, to groupId: String) async throws {
        guard store.group(id: groupId) != nil else {
            throw KasiaError.networkError("Unknown group.")
        }
        guard var bag = try keychain.loadGroupBag(groupId: groupId),
              let gid = Data(hexString: groupId),
              let groupRootEpoch = Data(hexString: bag.groupRootEpoch),
              let blindingKey = Data(hexString: bag.blindingKey),
              let deviceId = Data(hexString: bag.deviceId) else {
            throw KasiaError.networkError("Missing group secrets - try rejoining this group.")
        }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.walletNotFound
        }
        let senderXOnlyPub = try schnorrXOnlyPublicKey(from: privateKey)
        let senderId = GroupCipher.deriveSenderId(senderAddress: wallet.publicAddress)

        // Persist the incremented counter BEFORE building/sending - a msg_id must never be
        // reused even if the send itself later fails (spec: "Message ID reuse breaks
        // confidentiality/integrity").
        bag.msgCounter += 1
        let counter = bag.msgCounter
        try keychain.saveGroupBag(bag)

        let msgId = GroupCipher.buildMsgId(deviceId: deviceId, counter: counter)
        let ciphertext = try GroupCipher.encryptMessage(
            plaintext: text, groupRootEpoch: groupRootEpoch, groupId: gid, epoch: bag.currentEpoch, senderId: senderId, msgId: msgId
        )
        let aad = GroupCipher.buildMessageAAD(groupId: gid, epoch: bag.currentEpoch, senderId: senderId, msgId: msgId)
        let signature = try GroupCipher.sign(
            GroupCipher.buildMessageSigningPayload(aad: aad, ciphertextWithTag: ciphertext), privateKey: privateKey
        )
        let blindedGroupId = GroupCipher.deriveBlindedGroupId(blindingKey: blindingKey, memberXOnlyPubKey: senderXOnlyPub)
        let payloadString = GroupCipher.buildGroupMessagePayload(
            blindedGroupId: blindedGroupId, epoch: bag.currentEpoch, senderId: senderId, senderPubKey: senderXOnlyPub,
            msgId: msgId, ciphertext: ciphertext, signature: signature
        )

        let pendingId = "pending_\(UUID().uuidString)"
        let pendingTimestamp = Date()
        let pendingMessage = GroupMessage(
            id: UUID(), groupId: groupId, txId: pendingId, senderAddress: wallet.publicAddress,
            senderIdHex: senderId.hexString, content: text, timestamp: pendingTimestamp,
            blockTime: Int64(pendingTimestamp.timeIntervalSince1970 * 1000), isOutgoing: true, deliveryStatus: .pending
        )
        groupMessages[groupId, default: []].append(pendingMessage)
        store.insertMessage(
            txId: pendingId, groupId: groupId, senderAddress: wallet.publicAddress, senderIdHex: senderId.hexString,
            epoch: bag.currentEpoch, msgIdHex: msgId.hexString, contentEncrypted: ciphertext,
            blockTime: pendingMessage.blockTime, isOutgoing: true, deliveryStatus: .pending
        )

        do {
            let realTxId = try await ChatService.shared.enqueueOutgoingTxOperation { [weak self] in
                try await self?.sendSelfStashPayload(payloadString, from: wallet.publicAddress, privateKey: privateKey) ?? ""
            }
            store.resolvePendingMessage(pendingId: pendingId, realId: realTxId, blockTime: pendingMessage.blockTime)
            if let index = groupMessages[groupId]?.firstIndex(where: { $0.txId == pendingId }) {
                groupMessages[groupId]?[index] = GroupMessage(
                    id: pendingMessage.id, groupId: groupId, txId: realTxId, senderAddress: wallet.publicAddress,
                    senderIdHex: senderId.hexString, content: text, timestamp: pendingTimestamp,
                    blockTime: pendingMessage.blockTime, isOutgoing: true, deliveryStatus: .sent
                )
            }
        } catch {
            store.markMessageFailed(pendingId: pendingId)
            if let index = groupMessages[groupId]?.firstIndex(where: { $0.txId == pendingId }) {
                groupMessages[groupId]?[index].deliveryStatus = .failed
            }
            throw error
        }
    }

    /// Shared self-stash send primitive for gcomm/ginv/gctl payloads - mirrors
    /// `BroadcastService.sendBroadcastInternal`'s UTXO fetch/reserve/submit sequence exactly,
    /// reusing `ChatService`'s shared UTXO reservation state so group sends can't race with
    /// 1:1/broadcast sends for the same UTXOs.
    private func sendSelfStashPayload(_ payloadString: String, from address: String, privateKey: Data) async throws -> String {
        let chatService = ChatService.shared
        let freshUtxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        let candidateUtxos = chatService.prepareMessageUtxos(confirmed: freshUtxos)
        guard !candidateUtxos.isEmpty else {
            throw KasiaError.networkError(chatService.noSpendableFundsYetMessage())
        }

        let tx = try KasiaTransactionBuilder.buildGroupPayloadTx(
            from: address, payloadString: payloadString, senderPrivateKey: privateKey, utxos: candidateUtxos
        )
        let spentUtxos = chatService.spentMessageUtxos(from: tx, candidates: candidateUtxos)
        let usesUnconfirmedInputs = spentUtxos.contains { $0.blockDaaScore == 0 }

        do {
            let (txId, _) = try await NodePoolService.shared.submitTransaction(tx, allowOrphan: usesUnconfirmedInputs)
            chatService.reserveMessageOutpoints(spentUtxos)
            chatService.consumePendingUtxos(spentUtxos)
            if let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: address) {
                chatService.addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: senderScriptPubKey)
            }
            return txId
        } catch {
            chatService.releaseMessageOutpoints()
            throw error
        }
    }

    // MARK: - Control message send (gctl_root / gctl_epoch)

    private func sendRootControlMessage(group: GroupChat, bag: GroupBag, to recipientAddress: String, privateKey: Data) async throws {
        guard let gid = Data(hexString: group.id),
              let groupRootEpoch = Data(hexString: bag.groupRootEpoch),
              let blindingKey = Data(hexString: bag.blindingKey),
              let adminXOnlyPub = Data(hexString: group.adminXOnlyPubKeyHex),
              let recipientPublicKey = KaspaAddress.publicKey(from: recipientAddress),
              let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.invalidAddress
        }
        let rootPayload = try GroupCipher.buildSignedRootPayload(
            groupId: gid, epoch: bag.currentEpoch, groupRootEpoch: groupRootEpoch, blindingKey: blindingKey,
            adminSigningPub: adminXOnlyPub, members: group.members.map { $0.address }, name: group.name,
            adminPrivateKey: privateKey
        )
        let json = try JSONEncoder().encode(rootPayload)
        try await sendControlPayload(json, to: recipientPublicKey, from: wallet.publicAddress, privateKey: privateKey)
    }

    private func sendEpochControlMessage(groupId: Data, epoch: UInt64, reason: GroupCipher.EpochChangeReason, to recipientAddress: String, adminPrivateKey: Data) async throws {
        guard let recipientPublicKey = KaspaAddress.publicKey(from: recipientAddress),
              let wallet = WalletManager.shared.currentWallet else {
            throw KasiaError.invalidAddress
        }
        let epochPayload = try GroupCipher.buildSignedEpochPayload(groupId: groupId, epoch: epoch, reason: reason, adminPrivateKey: adminPrivateKey)
        let json = try JSONEncoder().encode(epochPayload)
        try await sendControlPayload(json, to: recipientPublicKey, from: wallet.publicAddress, privateKey: adminPrivateKey)
    }

    private func sendControlPayload(_ json: Data, to recipientPublicKey: Data, from senderAddress: String, privateKey: Data) async throws {
        let jsonString = String(data: json, encoding: .utf8) ?? "{}"
        let encrypted = try KasiaCipher.encrypt(jsonString, recipientPublicKey: recipientPublicKey)
        let payloadString = Self.gctlPrefix + encrypted.toHex()
        try await ChatService.shared.enqueueOutgoingTxOperation { [weak self] in
            _ = try await self?.sendSelfStashPayload(payloadString, from: senderAddress, privateKey: privateKey)
        }
    }

    // MARK: - Message loading (decrypt-on-read from stored ciphertext)

    func loadMessages(for groupId: String) {
        guard let bag = try? keychain.loadGroupBag(groupId: groupId),
              let gid = Data(hexString: groupId) else {
            groupMessages[groupId] = []
            return
        }
        let rows = store.messageRows(forGroup: groupId)
        var decoded: [GroupMessage] = []
        for row in rows {
            guard let msgId = Data(hexString: row.msgIdHex),
                  let root = groupRootEpoch(for: row.epoch, bag: bag, groupId: gid) else { continue }
            let senderId = Data(hexString: row.senderIdHex) ?? Data()
            guard let plaintext = try? GroupCipher.decryptMessage(
                ciphertextWithTag: row.contentEncrypted, groupRootEpoch: root, groupId: gid, epoch: row.epoch, senderId: senderId, msgId: msgId
            ) else { continue }
            decoded.append(GroupMessage(
                id: UUID(), groupId: groupId, txId: row.txId, senderAddress: row.senderAddress,
                senderIdHex: row.senderIdHex, content: plaintext, timestamp: Date(timeIntervalSince1970: Double(row.blockTime) / 1000),
                blockTime: row.blockTime, isOutgoing: row.isOutgoing, deliveryStatus: row.deliveryStatus
            ))
        }
        groupMessages[groupId] = decoded
    }

    /// Admins can derive any past epoch's root on demand (they hold groupSeed); non-admins only
    /// retain the current epoch's root - by design, this is the protocol's forward-secrecy
    /// boundary, not a bug.
    private func groupRootEpoch(for epoch: UInt64, bag: GroupBag, groupId: Data) -> Data? {
        if epoch == bag.currentEpoch, let root = Data(hexString: bag.groupRootEpoch) {
            return root
        }
        if let seedHex = bag.groupSeed, let seed = Data(hexString: seedHex) {
            return GroupCipher.deriveGroupRootEpoch(groupSeed: seed, groupId: groupId, epoch: epoch)
        }
        return nil
    }

    // MARK: - Block-scan discovery lifecycle

    private func updateScanningStateIfNeeded() {
        let shouldScan = !groups.isEmpty || !pendingInvites.isEmpty
        guard shouldScan != isScanningActive else { return }
        isScanningActive = shouldScan
        if shouldScan {
            if blockNotificationHandlerId == nil {
                blockNotificationHandlerId = NodePoolService.shared.addNotificationHandler { [weak self] type, data in
                    guard type == .blockAdded else { return }
                    Task { @MainActor in
                        self?.handleBlockAddedData(data)
                    }
                }
            }
            Task { await NodePoolService.shared.subscribeBlockAdded() }
        } else {
            Task { await NodePoolService.shared.unsubscribeBlockAdded() }
        }
    }

    private func handleBlockAddedData(_ data: Data) {
        guard isScanningActive else { return }
        guard let notification = try? Protowire_BlockAddedNotificationMessage(serializedBytes: data) else { return }
        let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"

        for tx in notification.block.transactions {
            let payloadHex = tx.payload
            let matchesGcomm = payloadHex.hasPrefix(Self.gcommPrefixHex)
            let matchesGinv = payloadHex.hasPrefix(Self.ginvPrefixHex)
            let matchesGctl = payloadHex.hasPrefix(Self.gctlPrefixHex)
            guard matchesGcomm || matchesGinv || matchesGctl else { continue }
            guard let payloadData = CryptoUtils.hexToData(payloadHex),
                  let payloadString = String(data: payloadData, encoding: .utf8) else { continue }

            let txId = tx.verboseData.transactionID
            guard !txId.isEmpty else { continue }
            let blockTime = Int64(tx.verboseData.blockTime)

            if matchesGcomm, let parsed = GroupCipher.parseGroupMessagePayload(payloadString) {
                handleIncomingGroupMessage(parsed, txId: txId, blockTime: blockTime)
            } else if matchesGinv, let parsed = GroupCipher.parseGroupInvitePayload(payloadString) {
                handleIncomingInvite(parsed)
            } else if matchesGctl {
                guard let firstOutput = tx.outputs.first,
                      let scriptData = CryptoUtils.hexToData(firstOutput.scriptPublicKey.scriptPublicKey),
                      let senderAddress = KaspaAddress.address(fromScriptPublicKey: scriptData, hrp: hrp) else { continue }
                handleIncomingControlMessage(payloadString, senderAddress: senderAddress)
            }
        }
    }

    private func handleIncomingGroupMessage(_ parsed: GroupCipher.ParsedGroupMessage, txId: String, blockTime: Int64) {
        for group in groups {
            guard let bag = try? keychain.loadGroupBag(groupId: group.id),
                  let blindingKey = Data(hexString: bag.blindingKey),
                  let gid = Data(hexString: group.id) else { continue }

            let candidateBlindedId = GroupCipher.deriveBlindedGroupId(blindingKey: blindingKey, memberXOnlyPubKey: parsed.senderPubKey)
            guard candidateBlindedId == parsed.blindedGroupId else { continue }

            // Found the group. Verify sender identity: pubkey -> address -> in roster -> hashes to senderId.
            let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
            let senderAddress = KaspaAddress(hrp: hrp, type: .pubKey, payload: parsed.senderPubKey).address
            guard !senderAddress.isEmpty,
                  group.members.contains(where: { $0.address == senderAddress }),
                  GroupCipher.deriveSenderId(senderAddress: senderAddress) == parsed.senderId else {
                AppLog.log("[GroupChatService] Rejected gcomm: sender not a known member of group %@", String(group.id.prefix(12)))
                return
            }

            let aad = GroupCipher.buildMessageAAD(groupId: gid, epoch: parsed.epoch, senderId: parsed.senderId, msgId: parsed.msgId)
            guard GroupCipher.verify(parsed.signature, message: GroupCipher.buildMessageSigningPayload(aad: aad, ciphertextWithTag: parsed.ciphertext), xOnlyPublicKey: parsed.senderPubKey) else {
                AppLog.log("[GroupChatService] Rejected gcomm: bad signature for group %@", String(group.id.prefix(12)))
                return
            }

            guard let root = groupRootEpoch(for: parsed.epoch, bag: bag, groupId: gid),
                  let plaintext = try? GroupCipher.decryptMessage(
                      ciphertextWithTag: parsed.ciphertext, groupRootEpoch: root, groupId: gid, epoch: parsed.epoch, senderId: parsed.senderId, msgId: parsed.msgId
                  ) else {
                return
            }

            let inserted = store.insertMessage(
                txId: txId, groupId: group.id, senderAddress: senderAddress, senderIdHex: parsed.senderId.hexString,
                epoch: parsed.epoch, msgIdHex: parsed.msgId.hexString, contentEncrypted: parsed.ciphertext,
                blockTime: blockTime, isOutgoing: senderAddress == WalletManager.shared.currentWallet?.publicAddress,
                deliveryStatus: .sent
            )
            guard inserted else { return }

            let message = GroupMessage(
                id: UUID(), groupId: group.id, txId: txId, senderAddress: senderAddress, senderIdHex: parsed.senderId.hexString,
                content: plaintext, timestamp: Date(timeIntervalSince1970: Double(blockTime) / 1000), blockTime: blockTime,
                isOutgoing: senderAddress == WalletManager.shared.currentWallet?.publicAddress, deliveryStatus: .sent
            )
            groupMessages[group.id, default: []].append(message)
            return
        }
    }

    private func handleIncomingInvite(_ parsed: GroupCipher.ParsedGroupInvite) {
        guard let inviteSeed = pendingInvites[parsed.inviteTag] else { return }
        guard let decrypted = try? GroupCipher.decryptInvitePayload(parsed.encryptedPayload, inviteSeed: inviteSeed),
              let rootPayload = try? JSONDecoder().decode(GroupCipher.GroupRootPayload.self, from: decrypted),
              GroupCipher.verifyRootPayload(rootPayload) else {
            return
        }
        completeJoin(from: rootPayload)
        pendingInvites.removeValue(forKey: parsed.inviteTag)
        updateScanningStateIfNeeded()
    }

    private func handleIncomingControlMessage(_ payloadString: String, senderAddress: String) {
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey(),
              wallet.publicAddress != senderAddress else { return }
        let hexPayload = String(payloadString.dropFirst(Self.gctlPrefix.count))
        guard let plaintext = try? KasiaCipher.decryptHex(hexPayload, privateKey: privateKey),
              let jsonData = plaintext.data(using: .utf8) else { return }

        if let rootPayload = try? JSONDecoder().decode(GroupCipher.GroupRootPayload.self, from: jsonData), rootPayload.type == "gctl_root" {
            guard GroupCipher.verifyRootPayload(rootPayload) else { return }
            completeJoin(from: rootPayload)
        }
        // gctl_epoch is an advance-notice heads-up only (spec: state updates on gctl_root
        // arrival, not on gctl_epoch) - no local state change needed here in the data layer;
        // Phase 3 UI may surface it as a transient "membership changing..." hint.
    }

    /// Applies a verified `gctl_root` payload: creates or updates the local GroupBag + roster.
    /// Refuses to downgrade to an older epoch than what's already stored (replay protection).
    private func completeJoin(from payload: GroupCipher.GroupRootPayload) {
        // Refuse to downgrade to an older epoch than what's already stored locally (replay
        // protection); otherwise apply (covers both "brand new group" and "legitimate advance").
        if let existingBag = try? keychain.loadGroupBag(groupId: payload.groupId),
           existingBag.currentEpoch > payload.epoch {
            return
        }
        applyRootPayload(payload)
    }

    private func applyRootPayload(_ payload: GroupCipher.GroupRootPayload) {
        // device_id is persistent per device (spec) - preserve it across epoch-rotation
        // updates to an already-joined group; only a genuinely first-time join mints a new
        // one. msgCounter always resets to 0 on a new epoch root, per the spec's own
        // "update currentEpoch, reset counter" step. groupSeed is preserved defensively in
        // case this device somehow already held admin secrets for this group (normally it
        // won't - the admin never sends gctl_root/an invite to itself).
        let existingBag = try? keychain.loadGroupBag(groupId: payload.groupId)
        let deviceId = existingBag?.deviceId ?? GroupCipher.generateDeviceId().hexString
        let bag = GroupBag(
            groupId: payload.groupId,
            groupSeed: existingBag?.groupSeed,
            groupRootEpoch: payload.groupRootEpoch,
            blindingKey: payload.blindingKey,
            currentEpoch: payload.epoch,
            deviceId: deviceId,
            msgCounter: 0
        )
        try? keychain.saveGroupBag(bag)

        var members: [GroupMember] = []
        for address in payload.members {
            guard let xOnlyPub = KaspaAddress.publicKey(from: address) else { continue }
            let isAdminMember = xOnlyPub.hexString == payload.adminSigningPub
            members.append(GroupMember(address: address, xOnlyPubKeyHex: xOnlyPub.hexString, isAdmin: isAdminMember, displayName: nil))
        }

        let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
        let derivedAdminAddress = KaspaAddress(hrp: hrp, type: .pubKey, payload: Data(hexString: payload.adminSigningPub) ?? Data()).address
        let adminAddress = derivedAdminAddress.isEmpty
            ? (members.first(where: { $0.isAdmin })?.address ?? "")
            : derivedAdminAddress

        let group = GroupChat(
            id: payload.groupId, name: payload.name, adminAddress: adminAddress, adminXOnlyPubKeyHex: payload.adminSigningPub,
            members: members, currentEpoch: payload.epoch, createdAt: Date(),
            isAdmin: WalletManager.shared.currentWallet?.publicAddress == adminAddress
        )
        store.upsertGroup(group)
        groups = store.allGroups()
        if groupMessages[group.id] == nil {
            groupMessages[group.id] = []
        }
        loadMessages(for: group.id)
        updateScanningStateIfNeeded()
    }

    // MARK: - Helpers

    private func schnorrXOnlyPublicKey(from privateKey: Data) throws -> Data {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        return Data(key.xonly.bytes)
    }
}
