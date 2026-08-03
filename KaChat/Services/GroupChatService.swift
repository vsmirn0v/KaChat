import Foundation
import Combine
import CryptoKit
import P256K
import UIKit

/// Orchestrates KaChat's group chat feature: group lifecycle (create/add/remove member, epoch
/// rotation) and sending/receiving `gcomm` group messages.
///
/// Architecturally self-contained, like `BroadcastService`: owns its own block-scan discovery
/// (`NodePoolService.shared.subscribeBlockAdded()`) rather than threading group state through
/// `ChatService`'s 1:1 contact/conversation machinery, so this feature can't regress existing
/// 1:1 messaging. Reuses `ChatService`'s UTXO reservation coordination
/// (`prepareMessageUtxos`/`enqueueOutgoingTxOperation`/etc.) since that's shared, correctness-
/// critical state across every service that spends the wallet's UTXOs.
///
/// Two on-chain payload types, both self-stash (sender spends their own UTXOs, output returns
/// to their own address), both discovered via the same block-scan:
///  - `ciph_msg:1:gcomm:...` - a group message (see GroupCipher, protocol spec).
///  - `ciph_msg:1:gctl:...` - a control message (`gctl_root`/`gctl_epoch`), ECIES-encrypted
///    (via KasiaCipher, the same crypto 1:1 contextual messages use) to one specific recipient.
///    The spec describes this as riding "the existing 1:1 encrypted COMM channel" - here that
///    means reusing the same ECIES scheme and self-stash shape, not literally routing through
///    ChatService's contact/conversation UI, so control payloads never leak into a 1:1 chat.
///
/// Deliberately no invite-link/beacon join path: every member is added directly by the admin,
/// who already knows who they are (see `addMember`/`createGroup`). A prior revision had a
/// publicly-joinable invite beacon (KaChat extension, not in the reference spec) - removed once
/// group chats route through indexers, since a way for anyone to discover and join a group's
/// *encrypted* chat is exactly the kind of thing that could be used to infer something bad is
/// happening inside it and pressure an indexer operator into censoring it.
@MainActor
final class GroupChatService: ObservableObject {
    static let shared = GroupChatService()

    @Published private(set) var groups: [GroupChat] = []
    @Published var groupMessages: [String: [GroupMessage]] = [:]
    /// Mirrors `ChatService.replyingTo`/`BroadcastService.replyingTo` - set via a message's
    /// "Reply" action, consumed (wrapped into the outgoing payload, then cleared) by
    /// `sendGroupMessage`.
    @Published var replyingTo: GroupMessage?
    /// This wallet's group reactions, keyed by targetTxId then further by groupId at the top
    /// level - mirrors `ChatService.reactionsByTxId`'s shape for 1:1. Loaded once per group open
    /// (see `loadGroupReactions`) and kept live afterward by `sendGroupReaction`/the
    /// incoming-reaction interception in `handleIncomingGroupMessage` updating it directly.
    @Published var reactionsByGroupId: [String: [String: [GroupStore.ReactionSnapshot]]] = [:]

    /// Set when a group-chat push notification is tapped before `ChatListView` exists yet
    /// (cold start) - consumed and cleared by `ChatListView.checkPendingGroupNavigation()`.
    @Published var pendingGroupNavigation: String?

    /// The group currently on-screen, if any - mirrors `ChatService.activeConversationAddress`.
    /// Checked when a new incoming message arrives so it doesn't bump the unread badge for a
    /// group the user is already actively reading (see `handleIncomingGroupMessage`).
    @Published var activeGroupId: String?

    private let store = GroupStore.shared
    private let keychain = KeychainService.shared

    private var blockNotificationHandlerId: UUID?
    private var isScanningActive = false
    private var hasActiveWallet = false
    private var cancellables = Set<AnyCancellable>()

    /// Per-sync-object opaque catch-up cursors (`gcomm|groupId|blindedId`, `gctl|adminAddress`,
    /// `gctl-recipient|walletAddress`) - lossless, unlike a plain `block_time` (which can collide
    /// across items sharing a timestamp), so unlike ChatService's UInt64 cursor store this is kept
    /// separately here rather than reused. See docs/GROUP_CHAT_API.md.
    private var groupCatchUpCursors: [String: String] = [:]
    private let groupCatchUpCursorsKey = "kachat_group_catchup_cursors"

    /// Per-group "last opened" timestamp, for the Group Chats tab unread badge - one timestamp
    /// per group rather than a per-message read flag (would need a Core Data migration; see
    /// plan doc), persisted the same way as `groupCatchUpCursors`.
    @Published private(set) var groupLastReadAt: [String: Date] = [:]
    private let groupLastReadAtKey = "kachat_group_last_read_at"

    /// Per-group set of hidden member addresses (their messages are filtered out of the thread,
    /// same idea as `BroadcastService`'s hidden senders, but scoped per-group rather than
    /// globally - a member hidden in one group shouldn't affect how they show up in another),
    /// persisted the same way as `groupCatchUpCursors`/`groupLastReadAt`.
    @Published private(set) var groupHiddenMembers: [String: Set<String>] = [:]
    private let groupHiddenMembersKey = "kachat_group_hidden_members"

    /// Per-group set of muted member addresses - unlike hiding, their messages still show up in
    /// the thread, they just stop generating notifications (enforced by excluding their blinded
    /// group id from push registration - see `PushNotificationManager.collectWatchedGroupIds`).
    @Published private(set) var groupMutedMembers: [String: Set<String>] = [:]
    private let groupMutedMembersKey = "kachat_group_muted_members"

    /// Groups where "Only notify if I am mentioned" is on - enforced in the Notification Service
    /// Extension (`NotificationService.handleGroupPush`), which decrypts the payload anyway to
    /// show its banner, so it can cheaply check for an `@{myAddress}` mention before deciding
    /// whether to actually present it. Synced to the shared App Group container so that
    /// extension (a separate process) can read it - see `SharedDataManager.syncGroupsForExtension`.
    @Published private(set) var groupMentionsOnlyNotifications: Set<String> = []
    private let groupMentionsOnlyNotificationsKey = "kachat_group_mentions_only"

    private static let gcommPrefix = "ciph_msg:1:gcomm:"
    private static let gctlPrefix = "ciph_msg:1:gctl:"
    private static let gcommPrefixHex = hexPrefix(gcommPrefix)
    private static let gctlPrefixHex = hexPrefix(gctlPrefix)

    private static func hexPrefix(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    /// Wallet the currently in-memory `groupLastReadAt`/`groupHiddenMembers`/`groupMutedMembers`/
    /// `groupMentionsOnlyNotifications`/`groupCatchUpCursors` belong to. Every UserDefaults key
    /// for those five is suffixed with this address (see `scopedDefaultsKey`) so switching between
    /// multiple accounts on the same device can't let one account's read/mute/hide state leak
    /// into, or get overwritten by, another's - previously all five shared one un-scoped global
    /// key, which is how logging out, creating a second account, then logging back into the first
    /// could reset every group back to "unread."
    private var currentWalletAddress: String?

    /// nil (falling back to the base, un-scoped key) when there's no active wallet - matches every
    /// other per-wallet store in this codebase reading nothing until a wallet is set.
    private func scopedDefaultsKey(_ base: String) -> String? {
        guard let currentWalletAddress else { return nil }
        return "\(base)_\(currentWalletAddress)"
    }

    private init() {
        // Re-evaluate scanning as the node pool warms up - see updateScanningStateIfNeeded's
        // gating on activeNodeCount for why this needs to be reactive, not just re-checked at
        // wallet-load time (activeNodeCount is almost always still 0 right then, at cold start).
        NodePoolService.shared.$activeNodeCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateScanningStateIfNeeded()
            }
            .store(in: &cancellables)
        loadGroupCatchUpCursors()
        loadGroupLastReadAt()
        loadGroupHiddenMembers()
        loadGroupMutedMembers()
        loadGroupMentionsOnlyNotifications()
    }

    private func loadGroupCatchUpCursors() {
        groupCatchUpCursors = loadScoped(groupCatchUpCursorsKey) ?? [:]
    }

    private func saveGroupCatchUpCursors() {
        saveScoped(groupCatchUpCursorsKey, groupCatchUpCursors)
    }

    private func loadGroupLastReadAt() {
        groupLastReadAt = loadScoped(groupLastReadAtKey) ?? [:]
    }

    private func saveGroupLastReadAt() {
        saveScoped(groupLastReadAtKey, groupLastReadAt)
    }

    /// Reads the current wallet's scoped key; if that's never been written yet, falls back to the
    /// old un-scoped global key (read-only, one-time migration for whichever account first loads
    /// after the per-wallet scoping fix - never written back to, so it's still there for any other
    /// account on this device to migrate from too, the first time each of them is loaded).
    private func loadScoped<T: Decodable>(_ baseKey: String) -> T? {
        // No active wallet - nothing to scope to, and no reason to fall back to the legacy blob
        // either (there's no group list on screen to misattribute it to).
        guard let key = scopedDefaultsKey(baseKey) else { return nil }
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        guard let legacyData = UserDefaults.standard.data(forKey: baseKey) else { return nil }
        return try? JSONDecoder().decode(T.self, from: legacyData)
    }

    private func saveScoped<T: Encodable>(_ baseKey: String, _ value: T) {
        guard let key = scopedDefaultsKey(baseKey), let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func loadGroupHiddenMembers() {
        groupHiddenMembers = loadScoped(groupHiddenMembersKey) ?? [:]
    }

    private func saveGroupHiddenMembers() {
        saveScoped(groupHiddenMembersKey, groupHiddenMembers)
    }

    /// Hides a member's messages in one group's thread - their messages stay stored (recoverable
    /// via `unhideMember`), just filtered out of what's displayed.
    func hideMember(_ address: String, in groupId: String) {
        groupHiddenMembers[groupId, default: []].insert(address)
        saveGroupHiddenMembers()
    }

    func unhideMember(_ address: String, in groupId: String) {
        groupHiddenMembers[groupId]?.remove(address)
        saveGroupHiddenMembers()
    }

    func hiddenMemberAddresses(for groupId: String) -> Set<String> {
        groupHiddenMembers[groupId] ?? []
    }

    private func loadGroupMutedMembers() {
        groupMutedMembers = loadScoped(groupMutedMembersKey) ?? [:]
    }

    private func saveGroupMutedMembers() {
        saveScoped(groupMutedMembersKey, groupMutedMembers)
    }

    /// Mutes a member's notifications in one group - their messages still show up in the thread
    /// (unlike `hideMember`), they just stop triggering push notifications.
    func muteMember(_ address: String, in groupId: String) {
        groupMutedMembers[groupId, default: []].insert(address)
        saveGroupMutedMembers()
    }

    func unmuteMember(_ address: String, in groupId: String) {
        groupMutedMembers[groupId]?.remove(address)
        saveGroupMutedMembers()
    }

    func mutedMemberAddresses(for groupId: String) -> Set<String> {
        groupMutedMembers[groupId] ?? []
    }

    private func loadGroupMentionsOnlyNotifications() {
        groupMentionsOnlyNotifications = loadScoped(groupMentionsOnlyNotificationsKey) ?? []
    }

    private func saveGroupMentionsOnlyNotifications() {
        saveScoped(groupMentionsOnlyNotificationsKey, groupMentionsOnlyNotifications)
        SharedDataManager.syncGroupsForExtension()
    }

    func mentionsOnlyNotifications(for groupId: String) -> Bool {
        groupMentionsOnlyNotifications.contains(groupId)
    }

    func setMentionsOnlyNotifications(_ enabled: Bool, for groupId: String) {
        if enabled {
            groupMentionsOnlyNotifications.insert(groupId)
        } else {
            groupMentionsOnlyNotifications.remove(groupId)
        }
        saveGroupMentionsOnlyNotifications()
    }

    /// Marks a group as opened, clearing its unread badge contribution.
    func markGroupAsRead(_ groupId: String) {
        groupLastReadAt[groupId] = Date()
        saveGroupLastReadAt()
        ChatService.shared.scheduleBadgeUpdate()
    }

    /// Forces a group back to "unread" - clears the last-read timestamp entirely rather than
    /// setting it to some sentinel in the past, so this is exactly the same state (and reuses
    /// the same counting logic in `unreadCount(for:)`) as "never opened," matching how a freshly
    /// invited member's group looks before they've opened it.
    func markGroupAsUnread(_ groupId: String) {
        groupLastReadAt.removeValue(forKey: groupId)
        saveGroupLastReadAt()
        ChatService.shared.scheduleBadgeUpdate()
    }

    /// Unread count for one group's tab-badge contribution: messages newer than this group's
    /// last-opened timestamp. A group that's never been opened and that we didn't create
    /// ourselves counts as at least 1, covering "new group added, zero messages yet."
    func unreadCount(for group: GroupChat) -> Int {
        let messages = groupMessages[group.id] ?? []
        guard let lastReadAt = groupLastReadAt[group.id] else {
            let count = messages.filter { !$0.isOutgoing }.count
            return group.isAdmin ? count : max(count, 1)
        }
        return messages.filter { !$0.isOutgoing && $0.timestamp > lastReadAt }.count
    }

    /// Total unread across all groups, for the Group Chats tab badge.
    var totalGroupUnreadCount: Int {
        groups.reduce(0) { $0 + unreadCount(for: $1) }
    }

    /// Bulk "Mark as Read" for multi-selected groups in the chat list - mirrors
    /// `ChatService.markConversationsAsRead`'s shape.
    func markGroupsAsRead(_ groups: [GroupChat]) {
        for group in groups where unreadCount(for: group) > 0 {
            markGroupAsRead(group.id)
        }
    }

    /// Bulk "Mark as Unread" for multi-selected groups in the chat list - mirrors
    /// `ChatService.markConversationsAsUnread`'s shape.
    func markGroupsAsUnread(_ groups: [GroupChat]) {
        for group in groups where unreadCount(for: group) == 0 {
            markGroupAsUnread(group.id)
        }
    }

    // MARK: - Reply

    func startReplyTo(_ message: GroupMessage) {
        replyingTo = message
    }

    func cancelReply() {
        replyingTo = nil
    }

    // MARK: - Active group tracking (unread suppression while viewing)

    /// Mirrors `ChatService.enterConversation(for:)` - call from the group thread's `.onAppear`.
    func enterGroup(_ groupId: String) {
        activeGroupId = groupId
        loadGroupReactions(for: groupId)
    }

    /// Loads this group's reactions from disk into the live in-memory index - mirrors
    /// `ChatService.loadReactions(for:)` for 1:1.
    func loadGroupReactions(for groupId: String) {
        reactionsByGroupId[groupId] = store.fetchGroupReactions(groupId: groupId)
    }

    private func applyLocalGroupReaction(targetTxId: String, groupId: String, reactorAddress: String, emoji: String, deliveryStatus: ChatMessage.DeliveryStatus = .sent, failedAction: String? = nil, blockTime: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        var existing = reactionsByGroupId[groupId]?[targetTxId] ?? []
        existing.removeAll { $0.reactorAddress == reactorAddress }
        existing.append(GroupStore.ReactionSnapshot(targetTxId: targetTxId, reactorAddress: reactorAddress, emoji: emoji, deliveryStatus: deliveryStatus, failedAction: failedAction, blockTime: blockTime))
        reactionsByGroupId[groupId, default: [:]][targetTxId] = existing
    }

    private func removeLocalGroupReaction(targetTxId: String, groupId: String, reactorAddress: String) {
        guard var existing = reactionsByGroupId[groupId]?[targetTxId] else { return }
        existing.removeAll { $0.reactorAddress == reactorAddress }
        if existing.isEmpty {
            reactionsByGroupId[groupId]?.removeValue(forKey: targetTxId)
        } else {
            reactionsByGroupId[groupId, default: [:]][targetTxId] = existing
        }
    }

    /// Mirrors `ChatService.leaveConversation()` - call from the group thread's `.onDisappear`.
    func exitGroup() {
        activeGroupId = nil
    }

    // MARK: - Wallet lifecycle

    func setCurrentWallet(_ walletAddress: String?) {
        hasActiveWallet = walletAddress != nil
        currentWalletAddress = walletAddress
        loadGroupCatchUpCursors()
        loadGroupLastReadAt()
        loadGroupHiddenMembers()
        loadGroupMutedMembers()
        loadGroupMentionsOnlyNotifications()
        store.setCurrentWallet(walletAddress)
        groups = walletAddress == nil ? [] : store.allGroups()
        groupMessages.removeAll()
        replyingTo = nil
        // Load every group's history off the main actor (see loadMessages), one group per run-loop
        // tick, so a wallet with group history doesn't freeze the UI on login/launch. This used to
        // be a synchronous decrypt storm (3 HKDF + ChaChaPoly per message, every group, inline).
        let targetWallet = walletAddress
        Task { [weak self] in
            guard let self else { return }
            for group in self.groups {
                guard self.currentWalletAddress == targetWallet else { return }
                self.loadMessages(for: group.id)
                await Task.yield()
            }
        }
        updateScanningStateIfNeeded()
        ChatService.shared.scheduleBadgeUpdate()
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
        groupCatchUpCursors = [:]
        groupLastReadAt = [:]
        groupHiddenMembers = [:]
        groupMutedMembers = [:]
        groupMentionsOnlyNotifications = []
        for baseKey in [groupCatchUpCursorsKey, groupLastReadAtKey, groupHiddenMembersKey, groupMutedMembersKey, groupMentionsOnlyNotificationsKey] {
            if let key = scopedDefaultsKey(baseKey) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            // Also clear the legacy un-scoped key so a pre-migration blob can't keep resurfacing
            // via loadScoped's fallback for whichever account loads next.
            UserDefaults.standard.removeObject(forKey: baseKey)
        }
        updateScanningStateIfNeeded()
        ChatService.shared.scheduleBadgeUpdate()
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
        SharedDataManager.syncGroupsForExtension()
        groupMessages[group.id] = []
        updateScanningStateIfNeeded()

        // Distribute gctl_root to each initial member directly - they must already be 1:1
        // contacts, i.e. their pubkey is resolvable from their address (every member is added
        // this way; there's no invite-link bootstrap path, see file doc).
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

    /// Renames a group and redistributes the updated `gctl_root` to every member so they all see
    /// the new name - unlike `addMember`/`removeMember`, this does NOT rotate the epoch (a name
    /// change isn't a forward-secrecy event), so it re-signs and re-sends the root at the
    /// *current* epoch. `applyRootPayload`'s replay guard only rejects a strictly older epoch
    /// than what's already stored, so a same-epoch re-send like this is accepted and simply
    /// updates the locally-cached name/roster.
    func renameGroup(_ groupId: String, to newName: String) async throws {
        guard var group = store.group(id: groupId), group.isAdmin else {
            throw KasiaError.networkError("Only the group admin can rename the group.")
        }
        guard let bag = try keychain.loadGroupBag(groupId: groupId) else {
            throw KasiaError.networkError("Missing admin group secrets.")
        }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else {
            throw KasiaError.walletNotFound
        }

        group.name = newName
        store.upsertGroup(group)
        groups = store.allGroups()
        SharedDataManager.syncGroupsForExtension()

        var sendErrors: [Error] = []
        for member in group.members where member.address != wallet.publicAddress {
            do {
                try await sendRootControlMessage(group: group, bag: bag, to: member.address, privateKey: privateKey)
            } catch {
                sendErrors.append(error)
            }
        }
        if !sendErrors.isEmpty {
            AppLog.log("[GroupChatService] %d member(s) failed to receive the renamed gctl_root for group %@",
                       sendErrors.count, String(groupId.prefix(12)))
            throw KasiaError.networkError("Renamed, but \(sendErrors.count) member(s) may not have received the update yet.")
        }
    }

    /// Deletes a group locally: its message history, Keychain-held secrets (root/seed/blinding
    /// key), and roster. Local-only, like leaving/deleting a broadcast channel - there's no
    /// server-side group record to delete, and other members aren't notified (the trust model
    /// is single-admin push, not a shared membership ledger, so this device simply stops
    /// tracking the group and can no longer decrypt or send to it).
    func deleteGroup(_ groupId: String) {
        try? keychain.deleteGroupBag(groupId: groupId)
        store.deleteGroup(id: groupId)
        groups.removeAll { $0.id == groupId }
        groupMessages.removeValue(forKey: groupId)
        SharedDataManager.syncGroupsForExtension()
        updateScanningStateIfNeeded()
    }

    /// Deletes the given messages from this device only - purely local (Core Data + in-memory),
    /// never on-chain. Mirrors `ChatService.deleteMessages(_:from:)` - see its doc comment for why
    /// this distinction is surfaced to the user in the confirmation alert.
    func deleteMessages(_ txIds: Set<String>, groupId: String) {
        guard !txIds.isEmpty else { return }
        groupMessages[groupId]?.removeAll { txIds.contains($0.txId) }
        for txId in txIds {
            store.deleteMessage(txId: txId)
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
        SharedDataManager.syncGroupsForExtension()

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

    // MARK: - Sending group messages

    /// Sends a photo to the group - same inline JSON envelope 1:1 chat's `ChatService.sendImage`
    /// uses (`{"type":"file","name","size","mimeType","content":"data:...;base64,..."}`), just
    /// carried as a `gcomm` message's plaintext instead of a 1:1 contextual message. Reusing the
    /// exact envelope shape means `MediaFile`/`LazyImageBubble` (`MessageBubbleView.swift`) render
    /// it with no changes.
    func sendGroupImage(_ imageData: Data, to groupId: String, fileName: String = "photo.jpg", mimeType: String = "image/jpeg") async throws {
        guard !imageData.isEmpty else {
            throw KasiaError.networkError("Image is empty")
        }
        let base64 = imageData.base64EncodedString()
        let payload: [String: Any] = [
            "type": "file",
            "name": fileName,
            "size": imageData.count,
            "mimeType": mimeType,
            "content": "data:\(mimeType);base64,\(base64)"
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw KasiaError.networkError("Failed to prepare image payload")
        }
        try await sendGroupMessage(jsonString, to: groupId)
    }

    /// Sends a voice message to the group - same envelope/reuse rationale as `sendGroupImage`.
    func sendGroupAudio(_ audioData: Data, to groupId: String, fileName: String = "voice.webm", mimeType: String = "audio/webm") async throws {
        guard !audioData.isEmpty else {
            throw KasiaError.networkError("Audio file is empty")
        }
        let base64 = audioData.base64EncodedString()
        let payload: [String: Any] = [
            "type": "file",
            "name": fileName,
            "size": audioData.count,
            "mimeType": mimeType,
            "content": "data:\(mimeType);base64,\(base64)"
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw KasiaError.networkError("Failed to prepare audio payload")
        }
        try await sendGroupMessage(jsonString, to: groupId)
    }

    // MARK: - Fee estimation

    /// Live "fee: N KAS" preview while composing a group text message - builds the exact real
    /// `gcomm` payload (same crypto as an actual send) rather than a size heuristic, matching
    /// `BroadcastService.estimateBroadcastFee(channel:content:)`. Read-only: doesn't touch
    /// `msgCounter` (a throwaway counter value is fine for sizing, since msg_id is a fixed 24
    /// bytes regardless of the counter's value).
    func estimateGroupMessageFee(_ text: String, for groupId: String, feeOverride: UInt64? = nil) async throws -> UInt64 {
        if let feeOverride {
            return feeOverride
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KasiaError.networkError("Message is empty")
        }
        guard let bag = try keychain.loadGroupBag(groupId: groupId),
              let gid = Data(hexString: groupId),
              let groupRootEpoch = Data(hexString: bag.groupRootEpoch),
              let blindingKey = Data(hexString: bag.blindingKey),
              let deviceId = Data(hexString: bag.deviceId) else {
            throw KasiaError.networkError("Missing group secrets - try rejoining this group.")
        }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey(),
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            throw KasiaError.walletNotFound
        }
        let senderXOnlyPub = try schnorrXOnlyPublicKey(from: privateKey)
        let senderId = GroupCipher.deriveSenderId(senderAddress: wallet.publicAddress)
        let msgId = GroupCipher.buildMsgId(deviceId: deviceId, counter: bag.msgCounter + 1)
        // Account for the reply envelope's extra bytes, matching the wrapping `sendGroupMessage` does.
        let estimatedPlaintext: String
        if let reply = replyingTo {
            estimatedPlaintext = MessageReplyCodec.encode(
                replyToId: reply.txId, replyToSender: reply.senderAddress ?? "",
                replyToPreview: MessageReplyCodec.previewText(for: reply.content), text: trimmed
            )
        } else {
            estimatedPlaintext = trimmed
        }
        let ciphertext = try GroupCipher.encryptMessage(
            plaintext: estimatedPlaintext, groupRootEpoch: groupRootEpoch, groupId: gid, epoch: bag.currentEpoch, senderId: senderId, msgId: msgId
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
        return KasiaTransactionBuilder.estimateBroadcastFee(
            payload: Data(payloadString.utf8), inputCount: 1, senderScriptPubKey: senderScriptPubKey
        )
    }

    /// Heuristic fee preview for a not-yet-sent photo/audio message (final bytes aren't known
    /// until compression/encoding finishes) - same shape as `ImagePrep.estimatedWirePayloadSize`,
    /// but sized for `gcomm`'s wire format: raw bytes -> base64 (1.33x) in the JSON envelope ->
    /// ChaCha20-Poly1305 (+16 byte tag) -> hex (2x) for the ciphertext field, plus ~370 bytes of
    /// fixed hex-encoded overhead (blinded_group_id/sender_id/sender_pub/msg_id/signature) that
    /// 1:1's ECIES-only envelope doesn't carry.
    func estimatedGroupWirePayloadSize(rawBytes: Int) -> Int {
        let jsonEnvelopeBytes = Int(Double(rawBytes) * 1.33) + 150
        let ciphertextHexBytes = (jsonEnvelopeBytes + 16) * 2
        return ciphertextHexBytes + 370
    }

    /// Fee preview for a staged/in-progress photo or audio message, from an estimated raw byte
    /// count - mirrors `estimateGroupMessageFee`'s real-payload version but for content that
    /// doesn't exist yet.
    func estimateGroupMediaFee(rawBytes: Int) -> UInt64? {
        guard let wallet = WalletManager.shared.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            return nil
        }
        let dummyPayload = Data(count: estimatedGroupWirePayloadSize(rawBytes: rawBytes))
        return KasiaTransactionBuilder.estimateBroadcastFee(
            payload: dummyPayload, inputCount: 1, senderScriptPubKey: senderScriptPubKey
        )
    }

    func sendGroupMessage(_ text: String, to groupId: String, feeOverride: UInt64? = nil) async throws {
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

        // If replying, wrap the content in the shared reply envelope (matches
        // ChatService.sendMessage/BroadcastService.sendBroadcast) so the quote survives even if
        // the original message is later pruned.
        let payload: String
        if let reply = replyingTo {
            payload = MessageReplyCodec.encode(
                replyToId: reply.txId, replyToSender: reply.senderAddress ?? "",
                replyToPreview: MessageReplyCodec.previewText(for: reply.content), text: text
            )
        } else {
            payload = text
        }

        // Persist the incremented counter BEFORE building/sending - a msg_id must never be
        // reused even if the send itself later fails (spec: "Message ID reuse breaks
        // confidentiality/integrity").
        bag.msgCounter += 1
        let counter = bag.msgCounter
        try keychain.saveGroupBag(bag)

        let msgId = GroupCipher.buildMsgId(deviceId: deviceId, counter: counter)
        let ciphertext = try GroupCipher.encryptMessage(
            plaintext: payload, groupRootEpoch: groupRootEpoch, groupId: gid, epoch: bag.currentEpoch, senderId: senderId, msgId: msgId
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
            senderIdHex: senderId.hexString, content: payload, timestamp: pendingTimestamp,
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
                try await self?.sendSelfStashPayload(payloadString, from: wallet.publicAddress, privateKey: privateKey, feeOverride: feeOverride) ?? ""
            }
            store.resolvePendingMessage(pendingId: pendingId, realId: realTxId, blockTime: pendingMessage.blockTime)
            if let index = groupMessages[groupId]?.firstIndex(where: { $0.txId == pendingId }) {
                groupMessages[groupId]?[index] = GroupMessage(
                    id: pendingMessage.id, groupId: groupId, txId: realTxId, senderAddress: wallet.publicAddress,
                    senderIdHex: senderId.hexString, content: payload, timestamp: pendingTimestamp,
                    blockTime: pendingMessage.blockTime, isOutgoing: true, deliveryStatus: .sent
                )
            }
            replyingTo = nil
        } catch {
            store.markMessageFailed(pendingId: pendingId)
            if let index = groupMessages[groupId]?.firstIndex(where: { $0.txId == pendingId }) {
                groupMessages[groupId]?[index].deliveryStatus = .failed
            }
            throw error
        }
    }

    /// Reacts to `targetTxId` with `emoji` ("add"), or removes this wallet's existing reaction on
    /// it ("remove"). Unlike `sendGroupMessage`, this never creates a visible pending bubble - the
    /// reaction is applied to the local reactions store immediately (optimistic UI) and the
    /// actual send reuses the exact same single self-stash broadcast `sendGroupMessage` uses,
    /// which already reaches every member via the shared group root key - no per-member fan-out
    /// needed.
    func sendGroupReaction(targetTxId: String, groupId: String, emoji: String, action: String) async throws {
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
        let payload = MessageReactionCodec.encode(targetTxId: targetTxId, emoji: emoji, action: action)

        if action == "add" {
            // Optimistically pending (no icon) - flips to sent (green checkmark) on submit, or
            // failed (red error + Retry) if the send doesn't go through.
            applyLocalGroupReaction(targetTxId: targetTxId, groupId: groupId, reactorAddress: wallet.publicAddress, emoji: emoji, deliveryStatus: .pending)
            store.upsertGroupReaction(targetTxId: targetTxId, groupId: groupId, reactorAddress: wallet.publicAddress, emoji: emoji, reactionTxId: nil, blockTime: Int64(Date().timeIntervalSince1970 * 1000), deliveryStatus: "pending")
        } else {
            removeLocalGroupReaction(targetTxId: targetTxId, groupId: groupId, reactorAddress: wallet.publicAddress)
            store.removeGroupReaction(targetTxId: targetTxId, reactorAddress: wallet.publicAddress)
        }

        bag.msgCounter += 1
        let counter = bag.msgCounter
        try keychain.saveGroupBag(bag)

        let msgId = GroupCipher.buildMsgId(deviceId: deviceId, counter: counter)
        let ciphertext = try GroupCipher.encryptMessage(
            plaintext: payload, groupRootEpoch: groupRootEpoch, groupId: gid, epoch: bag.currentEpoch, senderId: senderId, msgId: msgId
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

        do {
            let realTxId = try await ChatService.shared.enqueueOutgoingTxOperation { [weak self] in
                try await self?.sendSelfStashPayload(payloadString, from: wallet.publicAddress, privateKey: privateKey) ?? ""
            }
            if action == "add" {
                // Success flips pending -> sent (green checkmark) and clears any prior failed flag.
                applyLocalGroupReaction(targetTxId: targetTxId, groupId: groupId, reactorAddress: wallet.publicAddress, emoji: emoji, deliveryStatus: .sent)
                store.upsertGroupReaction(targetTxId: targetTxId, groupId: groupId, reactorAddress: wallet.publicAddress, emoji: emoji, reactionTxId: realTxId, blockTime: Int64(Date().timeIntervalSince1970 * 1000), deliveryStatus: nil, failedAction: nil)
            }
        } catch {
            // The reaction tx failed to send. Flag it failed so the pill shows the red error icon and
            // a "Retry" appears under the message. A failed "remove" restores the optimistically-
            // deleted reaction (marked failed) so it isn't silently lost; Retry re-attempts the change.
            applyLocalGroupReaction(targetTxId: targetTxId, groupId: groupId, reactorAddress: wallet.publicAddress, emoji: emoji, deliveryStatus: .failed, failedAction: action)
            store.upsertGroupReaction(targetTxId: targetTxId, groupId: groupId, reactorAddress: wallet.publicAddress, emoji: emoji, reactionTxId: nil, blockTime: Int64(Date().timeIntervalSince1970 * 1000), deliveryStatus: "failed", failedAction: action)
            throw error
        }
    }

    /// Re-attempts a group reaction whose send previously failed. `action` is the failed reaction's
    /// stored `failedAction` ("add"/"remove"). Delegates to `sendGroupReaction`, which clears the
    /// failed flag optimistically and re-flags it only if this attempt fails too.
    func retryGroupReaction(targetTxId: String, groupId: String, emoji: String, action: String) async throws {
        try await sendGroupReaction(targetTxId: targetTxId, groupId: groupId, emoji: emoji, action: action)
    }

    /// Shared self-stash send primitive for gcomm/gctl payloads - mirrors
    /// `BroadcastService.sendBroadcastInternal`'s UTXO fetch/reserve/submit sequence exactly,
    /// reusing `ChatService`'s shared UTXO reservation state so group sends can't race with
    /// 1:1/broadcast sends for the same UTXOs.
    private func sendSelfStashPayload(_ payloadString: String, from address: String, privateKey: Data, feeOverride: UInt64? = nil) async throws -> String {
        let chatService = ChatService.shared
        let freshUtxos = try await NodePoolService.shared.getUtxosByAddresses([address])
        let candidateUtxos = chatService.prepareMessageUtxos(confirmed: freshUtxos)
        guard !candidateUtxos.isEmpty else {
            throw KasiaError.networkError(chatService.noSpendableFundsYetMessage())
        }

        let tx = try KasiaTransactionBuilder.buildGroupPayloadTx(
            from: address, payloadString: payloadString, senderPrivateKey: privateKey, utxos: candidateUtxos, feeOverride: feeOverride
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

    /// `recipientPublicKey` here is the recipient's x-only pubkey (`KaspaAddress.publicKey(from:)`
    /// returns x-only, not the full compressed key ECIES itself needs internally - `KasiaCipher`
    /// derives that). Wire format is recipient-addressed (`ciph_msg:1:gctl:{recipient_xonly}:
    /// {encrypted}`), not the legacy unaddressed shape - see docs/GROUP_CHAT_API.md. This lets a
    /// brand-new member discover a "you were added" control via `GET /group-control/by-recipient`
    /// before it knows the admin's address at all, and lets push route it to their device even
    /// with zero locally-known groups (no more indexer-side fan-out-to-everyone fallback).
    private func sendControlPayload(_ json: Data, to recipientPublicKey: Data, from senderAddress: String, privateKey: Data) async throws {
        let jsonString = String(data: json, encoding: .utf8) ?? "{}"
        let encrypted = try KasiaCipher.encrypt(jsonString, recipientPublicKey: recipientPublicKey)
        let payloadString = Self.gctlPrefix + recipientPublicKey.hexString + ":" + encrypted.toHex()
        try await ChatService.shared.enqueueOutgoingTxOperation { [weak self] in
            _ = try await self?.sendSelfStashPayload(payloadString, from: senderAddress, privateKey: privateKey)
        }
    }

    // MARK: - Message loading (decrypt-on-read from stored ciphertext)

    func loadMessages(for groupId: String) {
        // Non-blocking: fetch the ciphertext rows on the main actor (fast Core Data read), then
        // decrypt OFF the main actor and publish the result back on main. Decrypting inline froze
        // the UI - especially in `setCurrentWallet`, which loads every group on login/launch.
        let targetWallet = currentWalletAddress
        guard let bag = try? keychain.loadGroupBag(groupId: groupId),
              let gid = Data(hexString: groupId) else {
            groupMessages[groupId] = []
            return
        }
        let rows = store.messageRows(forGroup: groupId)
        Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decryptGroupRows(rows, groupId: groupId, gid: gid, bag: bag)
            }.value
            // Discard if the wallet changed while we were decrypting (avoids a stale group's
            // messages landing under a different account).
            guard let self, self.currentWalletAddress == targetWallet else { return }
            self.groupMessages[groupId] = decoded
        }
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

    // MARK: - Off-main decrypt (nonisolated statics so they run on a background executor)

    /// `groupRootEpoch`, but callable off the main actor (pure crypto, value-type inputs only).
    nonisolated private static func rootEpoch(for epoch: UInt64, bag: GroupBag, groupId: Data) -> Data? {
        if epoch == bag.currentEpoch, let root = Data(hexString: bag.groupRootEpoch) {
            return root
        }
        if let seedHex = bag.groupSeed, let seed = Data(hexString: seedHex) {
            return GroupCipher.deriveGroupRootEpoch(groupSeed: seed, groupId: groupId, epoch: epoch)
        }
        return nil
    }

    /// Decrypts a group's stored ciphertext rows into plaintext messages. Pure/value-type only, so
    /// it runs off the main actor - decryption (3 HKDF + ChaChaPoly per message) is the dominant
    /// cost that used to freeze login/launch when done inline for every group.
    nonisolated private static func decryptGroupRows(_ rows: [CDGroupMessageSnapshot], groupId: String, gid: Data, bag: GroupBag) -> [GroupMessage] {
        var decoded: [GroupMessage] = []
        decoded.reserveCapacity(rows.count)
        for row in rows {
            guard let msgId = Data(hexString: row.msgIdHex),
                  let root = rootEpoch(for: row.epoch, bag: bag, groupId: gid) else { continue }
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
        return decoded
    }

    // MARK: - Block-scan discovery lifecycle

    private func updateScanningStateIfNeeded() {
        // Must scan whenever a wallet is loaded, not just when we already know about a group -
        // a `gctl_root` direct-add (createGroup/addMember) is a push from an admin who may be
        // adding us to a group we've never heard of before, so there's no local state to gate
        // discovery on until group-chat support lands in the indexer (deferred, see plan Phase
        // 4). gcomm matches are still cheap no-ops when irrelevant, since they're filtered
        // against `groups` downstream regardless.
        //
        // Also gated on activeNodeCount > 0: starting the instant the wallet loads (right at cold
        // app launch, before the pool has found any healthy node yet) forced subscribeBlockAdded
        // to compete with the pool's own cold-start discovery/probing for connection resources -
        // real contention that visibly delayed the app connecting to any nodes at all (found via
        // the same issue on Android's mirrored GroupScanningService). Waiting for at least one
        // active node means this only starts once there's already a healthy connection to piggyback on.
        let shouldScan = hasActiveWallet && NodePoolService.shared.activeNodeCount > 0
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
            let matchesGctl = payloadHex.hasPrefix(Self.gctlPrefixHex)
            guard matchesGcomm || matchesGctl else { continue }
            guard let payloadData = CryptoUtils.hexToData(payloadHex),
                  let payloadString = String(data: payloadData, encoding: .utf8) else { continue }

            let txId = tx.verboseData.transactionID
            guard !txId.isEmpty else { continue }
            let blockTime = Int64(tx.verboseData.blockTime)

            if matchesGcomm {
                guard let parsed = GroupCipher.parseGroupMessagePayload(payloadString) else {
                    AppLog.log("[GroupChatService] Failed to parse gcomm payload for tx %@", txId)
                    continue
                }
                handleIncomingGroupMessage(parsed, txId: txId, blockTime: blockTime)
            } else if matchesGctl {
                guard let firstOutput = tx.outputs.first,
                      let scriptData = CryptoUtils.hexToData(firstOutput.scriptPublicKey.scriptPublicKey),
                      let senderAddress = KaspaAddress.address(fromScriptPublicKey: scriptData, hrp: hrp) else { continue }
                handleIncomingControlMessage(Self.normalizeControlPayload(payloadString), senderAddress: senderAddress)
            }
        }
    }

    private func handleIncomingGroupMessage(_ parsed: GroupCipher.ParsedGroupMessage, txId: String, blockTime: Int64) {
        var matchedAnyGroup = false
        for group in groups {
            guard let bag = try? keychain.loadGroupBag(groupId: group.id),
                  let blindingKey = Data(hexString: bag.blindingKey),
                  let gid = Data(hexString: group.id) else { continue }

            let candidateBlindedId = GroupCipher.deriveBlindedGroupId(blindingKey: blindingKey, memberXOnlyPubKey: parsed.senderPubKey)
            guard candidateBlindedId == parsed.blindedGroupId else { continue }
            matchedAnyGroup = true

            // Found the group. Verify sender identity: pubkey -> address -> in roster -> hashes to senderId.
            let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
            let senderAddress = KaspaAddress(hrp: hrp, type: .pubKey, payload: parsed.senderPubKey).address
            guard !senderAddress.isEmpty, group.members.contains(where: { $0.address == senderAddress }) else {
                AppLog.log("[GroupChatService] Rejected gcomm for group %@: sender %@ not in roster %@",
                           String(group.id.prefix(12)), senderAddress, group.members.map { $0.address }.joined(separator: ","))
                return
            }
            guard GroupCipher.deriveSenderId(senderAddress: senderAddress) == parsed.senderId else {
                AppLog.log("[GroupChatService] Rejected gcomm for group %@: senderId mismatch for %@", String(group.id.prefix(12)), senderAddress)
                return
            }

            let aad = GroupCipher.buildMessageAAD(groupId: gid, epoch: parsed.epoch, senderId: parsed.senderId, msgId: parsed.msgId)
            guard GroupCipher.verify(parsed.signature, message: GroupCipher.buildMessageSigningPayload(aad: aad, ciphertextWithTag: parsed.ciphertext), xOnlyPublicKey: parsed.senderPubKey) else {
                AppLog.log("[GroupChatService] Rejected gcomm for group %@: bad signature from %@", String(group.id.prefix(12)), senderAddress)
                return
            }

            guard let root = groupRootEpoch(for: parsed.epoch, bag: bag, groupId: gid) else {
                AppLog.log("[GroupChatService] Rejected gcomm for group %@: no root for epoch %llu (local currentEpoch=%llu)",
                           String(group.id.prefix(12)), parsed.epoch, bag.currentEpoch)
                return
            }
            guard let plaintext = try? GroupCipher.decryptMessage(
                ciphertextWithTag: parsed.ciphertext, groupRootEpoch: root, groupId: gid, epoch: parsed.epoch, senderId: parsed.senderId, msgId: parsed.msgId
            ) else {
                AppLog.log("[GroupChatService] Rejected gcomm for group %@: decrypt failed from %@", String(group.id.prefix(12)), senderAddress)
                return
            }

            // Reactions are never shown as their own chat bubble - just attached to the message
            // they target - so intercept and route to the reactions store before this ever
            // becomes a GroupMessage. Our own outgoing reactions already apply their local update
            // at send time (sendGroupReaction), so this mainly covers incoming ones.
            if let reaction = MessageReactionCodec.parse(plaintext) {
                if reaction.action == "add" {
                    applyLocalGroupReaction(targetTxId: reaction.targetTxId, groupId: group.id, reactorAddress: senderAddress, emoji: reaction.emoji)
                    store.upsertGroupReaction(targetTxId: reaction.targetTxId, groupId: group.id, reactorAddress: senderAddress, emoji: reaction.emoji, reactionTxId: txId, blockTime: blockTime)
                } else {
                    removeLocalGroupReaction(targetTxId: reaction.targetTxId, groupId: group.id, reactorAddress: senderAddress)
                    store.removeGroupReaction(targetTxId: reaction.targetTxId, reactorAddress: senderAddress)
                }
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
            // Already looking at this group's thread right now - keep it marked read instead of
            // letting the badge tick up for a message the user is actively seeing arrive live
            // (mirrors ChatService's identical `isUserViewing` check). Covers both this live
            // block-scan path and catch-up sync, which also routes through this function.
            if !message.isOutgoing, activeGroupId == group.id, UIApplication.shared.applicationState == .active {
                markGroupAsRead(group.id)
            }
            ChatService.shared.scheduleBadgeUpdate()
            return
        }
        if !matchedAnyGroup {
            AppLog.log("[GroupChatService] Rejected gcomm: no local group matched blindedGroupId %@", parsed.blindedGroupId.hexString)
        }
    }

    /// Recipient-addressed gctl (`ciph_msg:1:gctl:{recipient_xonly_pubkey}:{encrypted}`) is only
    /// relevant to the live block-scan path here - the indexer already strips this routing prefix
    /// from `message_payload` in REST catch-up responses (see docs/GROUP_CHAT_API.md), so catch-up
    /// never needs this. Detects and strips an addressed-format recipient prefix, if present, so
    /// the rest of the parse/decrypt path (shared with legacy gctl) always sees the uniform
    /// `ciph_msg:1:gctl:{encrypted}` shape. No recipient-address filtering happens here - same as
    /// legacy gctl already relied on, a mismatched recipient's ECIES decrypt just fails silently.
    private static func normalizeControlPayload(_ payloadString: String) -> String {
        guard payloadString.hasPrefix(gctlPrefix) else { return payloadString }
        let rest = payloadString.dropFirst(gctlPrefix.count)
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 64,
              parts[0].allSatisfy({ $0.isHexDigit }) else {
            return payloadString
        }
        return gctlPrefix + parts[1]
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
        // one. msgCounter resets to 0 only when the epoch actually advances (spec: "update
        // currentEpoch, reset counter") - a same-epoch re-send of the root (e.g. `renameGroup`,
        // which doesn't rotate the epoch, or any other duplicate delivery of the same payload)
        // must NOT reset it, since a msg_id must never be reused (see `sendGroupMessage`'s own
        // doc comment) - resetting here would let this device's next send collide with a
        // counter value it already used earlier in the same epoch. groupSeed is preserved
        // defensively in case this device somehow already held admin secrets for this group
        // (normally it won't - the admin never sends gctl_root/an invite to itself).
        let existingBag = try? keychain.loadGroupBag(groupId: payload.groupId)
        let deviceId = existingBag?.deviceId ?? GroupCipher.generateDeviceId().hexString
        let preservedCounter = existingBag?.currentEpoch == payload.epoch ? (existingBag?.msgCounter ?? 0) : 0
        let bag = GroupBag(
            groupId: payload.groupId,
            groupSeed: existingBag?.groupSeed,
            groupRootEpoch: payload.groupRootEpoch,
            blindingKey: payload.blindingKey,
            currentEpoch: payload.epoch,
            deviceId: deviceId,
            msgCounter: preservedCounter
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
        SharedDataManager.syncGroupsForExtension()
        if groupMessages[group.id] == nil {
            groupMessages[group.id] = []
        }
        loadMessages(for: group.id)
        updateScanningStateIfNeeded()
    }

    // MARK: - Catch-up Sync

    /// Fetches missed `gcomm`/`gctl` history from the indexer, so a device that wasn't actively
    /// block-scanning while away (backgrounded, killed, or just closed) still catches up. Runs
    /// three kinds of sync object, each with its own persisted opaque cursor (see
    /// `groupCatchUpCursors`):
    ///  - `gcomm` per known group member (`blinded_group_id` is per-sender, not per-group, so
    ///    this queries once per member, using their blinded id recomputed from the group's shared
    ///    blindingKey).
    ///  - `gctl` by admin address, for groups already joined.
    ///  - `gctl` by our own wallet address (recipient-addressed) - runs unconditionally, even with
    ///    zero local groups, since this is what actually discovers "you were added to a group"
    ///    without needing to already know the admin. This replaced the indexer's old
    ///    fan-out-to-every-device push fallback for that same case.
    func performCatchUpSync() async {
        guard hasActiveWallet else { return }
        guard let wallet = WalletManager.shared.currentWallet else { return }

        await catchUpGroupControlByRecipient(recipientAddress: wallet.publicAddress)

        for group in groups {
            guard let bag = try? keychain.loadGroupBag(groupId: group.id),
                  let blindingKey = Data(hexString: bag.blindingKey) else { continue }

            for member in group.members {
                guard let memberPubKey = Data(hexString: member.xOnlyPubKeyHex) else { continue }
                let blindedGroupId = GroupCipher.deriveBlindedGroupId(blindingKey: blindingKey, memberXOnlyPubKey: memberPubKey)
                await catchUpGroupMessages(groupId: group.id, blindedGroupIdHex: blindedGroupId.hexString)
            }

            if !group.adminAddress.isEmpty {
                await catchUpGroupControl(adminAddress: group.adminAddress)
            }
        }
    }

    private func catchUpGroupMessages(groupId: String, blindedGroupIdHex: String) async {
        let syncKey = "gcomm|\(groupId)|\(blindedGroupIdHex)"
        do {
            let messages = try await KasiaAPIClient.shared.getGroupMessages(
                blindedGroupId: blindedGroupIdHex, limit: 50, cursor: groupCatchUpCursors[syncKey]
            )
            advanceGroupCatchUpCursor(for: syncKey, from: messages.last?.cursor)
            for msg in messages {
                guard let payloadString = Self.reconstructPayloadString(prefix: Self.gcommPrefix, messagePayloadHex: msg.messagePayload),
                      let parsed = GroupCipher.parseGroupMessagePayload(payloadString) else { continue }
                handleIncomingGroupMessage(parsed, txId: msg.txId, blockTime: Int64(msg.blockTime))
            }
        } catch {
            AppLog.log("[GroupChatService] Catch-up gcomm fetch failed for group %@: %@",
                       String(groupId.prefix(12)), error.localizedDescription)
        }
    }

    private func catchUpGroupControl(adminAddress: String) async {
        let syncKey = "gctl|\(adminAddress.lowercased())"
        do {
            let messages = try await KasiaAPIClient.shared.getGroupControl(
                sender: adminAddress, limit: 50, cursor: groupCatchUpCursors[syncKey]
            )
            advanceGroupCatchUpCursor(for: syncKey, from: messages.last?.cursor)
            for msg in messages {
                guard let payloadString = Self.reconstructPayloadString(prefix: Self.gctlPrefix, messagePayloadHex: msg.messagePayload) else { continue }
                handleIncomingControlMessage(payloadString, senderAddress: msg.sender)
            }
        } catch {
            AppLog.log("[GroupChatService] Catch-up gctl-by-sender fetch failed for admin %@: %@",
                       String(adminAddress.suffix(10)), error.localizedDescription)
        }
    }

    /// Discovers "you were added to a group" via recipient-addressed `gctl` - the only catch-up
    /// path that works before this device knows any group exists at all. See `performCatchUpSync`.
    private func catchUpGroupControlByRecipient(recipientAddress: String) async {
        let syncKey = "gctl-recipient|\(recipientAddress.lowercased())"
        do {
            let messages = try await KasiaAPIClient.shared.getGroupControlByRecipient(
                recipient: recipientAddress, limit: 50, cursor: groupCatchUpCursors[syncKey]
            )
            advanceGroupCatchUpCursor(for: syncKey, from: messages.last?.cursor)
            for msg in messages {
                guard let payloadString = Self.reconstructPayloadString(prefix: Self.gctlPrefix, messagePayloadHex: msg.messagePayload) else { continue }
                handleIncomingControlMessage(payloadString, senderAddress: msg.sender)
            }
        } catch {
            AppLog.log("[GroupChatService] Catch-up gctl-by-recipient fetch failed: %@", error.localizedDescription)
        }
    }

    private func advanceGroupCatchUpCursor(for syncKey: String, from cursor: String?) {
        guard let cursor else { return }
        groupCatchUpCursors[syncKey] = cursor
        saveGroupCatchUpCursors()
    }

    /// Reverses the indexer's double-hex-encoding of `message_payload` (it hex-encodes the raw
    /// on-chain sealed hex text as stored) back into the original `ciph_msg:1:<type>:<hex>`
    /// on-chain payload string, so it can feed straight into the same parse/decrypt path the
    /// live block-scan uses.
    private static func reconstructPayloadString(prefix: String, messagePayloadHex: String) -> String? {
        guard let asciiBytes = CryptoUtils.hexToData(messagePayloadHex),
              let hexText = String(data: asciiBytes, encoding: .utf8) else { return nil }
        return prefix + hexText
    }

    // MARK: - Helpers

    private func schnorrXOnlyPublicKey(from privateKey: Data) throws -> Data {
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKey)
        return Data(key.xonly.bytes)
    }
}
