import Foundation
import SwiftUI
import Combine
import CryptoKit
import P256K
import UIKit
import UserNotifications

/// Orchestrates KaChat's group chat feature: group lifecycle (create/add/remove member, epoch
/// rotation) and sending/receiving `gcomm` group messages.
///
/// Architecturally self-contained, like `BroadcastService`: owns its own block-scan discovery
/// (`NodePoolService.shared.subscribeBlockAdded(client:)`) rather than threading group state through
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

    /// Set when a group notification that names no group is tapped - the undecryptable-push
    /// fallback (thread id "group", see `NotificationService.deliverGroupFallback`). There's no
    /// room to open, so the Groups LIST is the destination; consumed by `ChatListView`.
    @Published var pendingGroupListNavigation = false

    /// The group currently on-screen, if any - mirrors `ChatService.activeConversationAddress`.
    /// Checked when a new incoming message arrives so it doesn't bump the unread badge for a
    /// group the user is already actively reading (see `handleIncomingGroupMessage`).
    @Published var activeGroupId: String?

    private let store = GroupStore.shared
    private let keychain = KeychainService.shared

    private var blockNotificationHandlerId: UUID?
    private var isScanningActive = false
    /// Read from the (nonisolated) block-notification callback as a cheap pre-parse gate; written
    /// only alongside isScanningActive on the main actor. Benign bool race by design.
    private nonisolated(unsafe) var isScanningActiveMirror = false
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

    /// Groups muted outright - no banner, ever, mentioned or not. Sits ABOVE the mentions-only
    /// rule: silent wins, and the extension checks it before anything else, including before the
    /// undecryptable-push fallback that used to notify unconditionally.
    @Published private(set) var groupSilentNotifications: Set<String> = []
    private let groupSilentNotificationsKey = "kachat_group_silent"

    // Admin-set group photos (groupId -> hex of a compressed JPEG), distributed via gctl_photo and
    // persisted per wallet in UserDefaults (avoids a Core Data migration; photos aren't secret).
    @Published private(set) var groupPhotos: [String: String] = [:]
    private var groupPhotosDefaultsKey: String? {
        guard let addr = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return "kachat_group_photos_\(addr)"
    }
    private func loadGroupPhotos() {
        guard let key = groupPhotosDefaultsKey, let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { groupPhotos = [:]; return }
        groupPhotos = decoded
    }
    private func persistGroupPhotos() {
        guard let key = groupPhotosDefaultsKey else { return }
        if let data = try? JSONEncoder().encode(groupPhotos) { UserDefaults.standard.set(data, forKey: key) }
    }
    /// Local-only photo update (also used when a gctl_photo arrives). hex == nil clears it.
    func setLocalGroupPhoto(_ groupId: String, hex: String?) {
        if let hex, !hex.isEmpty { groupPhotos[groupId] = hex } else { groupPhotos.removeValue(forKey: groupId) }
        persistGroupPhotos()
    }
    /// Hex of the current photo for a group, or nil.
    func groupPhotoHex(for groupId: String) -> String? { groupPhotos[groupId] }

    // Block time of the last gctl_photo we applied per group. The by-sender catch-up returns one
    // control per member (M+ copies per action) and a cursor reset (e.g. after reimport) re-scans
    // ALL history — without this guard each historical photo transition re-applied and re-emitted a
    // "changed/removed the group photo" line, flooding the thread. Persisted per wallet.
    private var groupPhotoUpdatedAt: [String: UInt64] = [:]
    private var groupPhotoUpdatedAtKey: String? {
        guard let addr = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return "kachat_group_photo_bt_\(addr)"
    }
    private func loadGroupPhotoUpdatedAt() {
        guard let key = groupPhotoUpdatedAtKey, let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data) else { groupPhotoUpdatedAt = [:]; return }
        groupPhotoUpdatedAt = decoded
    }
    private func persistGroupPhotoUpdatedAt() {
        guard let key = groupPhotoUpdatedAtKey else { return }
        if let data = try? JSONEncoder().encode(groupPhotoUpdatedAt) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Estimated total on-chain fee (KAS string) for a group action that sends `controlTx` small
    /// control messages and `photoTx` (larger) gctl_photo messages. Pure mass computation (no
    /// network), returning the policy fee this device actually pays. nil on failure.
    func estimateGroupActionFeeKas(groupId: String, controlTx: Int, photoTx: Int) -> String? {
        guard let addr = WalletManager.shared.currentWallet?.publicAddress,
              let scriptPubKey = KaspaAddress.scriptPublicKey(from: addr) else { return nil }
        var totalSompi: UInt64 = 0
        if controlTx > 0 {
            let per = KasiaTransactionBuilder.estimateGroupPayloadFee(payload: Data(count: 1600), inputCount: 1, senderScriptPubKey: scriptPubKey)
            totalSompi += per * UInt64(controlTx)
        }
        if photoTx > 0 {
            let photoBytes = 2 * ((groupPhotos[groupId]?.count ?? 0) + 300)   // gctl_photo wire ≈
            let per = KasiaTransactionBuilder.estimateGroupPayloadFee(payload: Data(count: photoBytes), inputCount: 1, senderScriptPubKey: scriptPubKey)
            totalSompi += per * UInt64(photoTx)
        }
        return String(format: "%.6f", Double(totalSompi) / 100_000_000.0)
    }

    /// Estimated total fee (KAS string) for sending a NEW group photo of `hexLength` hex chars to
    /// `txCount` members — used to confirm a photo change before the photo is stored.
    func estimateGroupPhotoFeeKas(hexLength: Int, txCount: Int) -> String? {
        guard txCount > 0, let addr = WalletManager.shared.currentWallet?.publicAddress,
              let scriptPubKey = KaspaAddress.scriptPublicKey(from: addr) else { return nil }
        let per = KasiaTransactionBuilder.estimateGroupPayloadFee(payload: Data(count: 2 * (hexLength + 300)), inputCount: 1, senderScriptPubKey: scriptPubKey)
        return String(format: "%.6f", Double(per * UInt64(txCount)) / 100_000_000.0)
    }

    // nonisolated: pure constants/helpers with no actor state, referenced from the off-main
    // block-scan extractor (extractBlockScanHits).
    // `kchat:` migration: write the new root, still read the legacy `ciph_msg:` root (tail identical).
    private nonisolated static let gcommPrefix = "kchat:1:gcomm:"        // write
    private nonisolated static let gctlPrefix = "kchat:1:gctl:"          // write
    private nonisolated static let legacyGcommPrefix = "ciph_msg:1:gcomm:" // read-only
    private nonisolated static let legacyGctlPrefix = "ciph_msg:1:gctl:"   // read-only
    private nonisolated static let gcommPrefixHex = hexPrefix(gcommPrefix)
    private nonisolated static let gctlPrefixHex = hexPrefix(gctlPrefix)
    private nonisolated static let legacyGcommPrefixHex = hexPrefix(legacyGcommPrefix)
    private nonisolated static let legacyGctlPrefixHex = hexPrefix(legacyGctlPrefix)

    private nonisolated static func hexPrefix(_ string: String) -> String {
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
        // Block streaming is disabled on expensive (cellular/metered) paths - re-evaluate when
        // the path flips either way so WiFi->cellular stops the stream and cellular->WiFi
        // restores it. See updateScanningStateIfNeeded.
        NetworkEpochMonitor.shared.expensivePathPublisher
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
        groupSilentNotifications = loadScoped(groupSilentNotificationsKey) ?? []
    }

    private func saveGroupMentionsOnlyNotifications() {
        saveScoped(groupMentionsOnlyNotificationsKey, groupMentionsOnlyNotifications)
        SharedDataManager.syncGroupsForExtension()
    }

    private func saveGroupSilentNotifications() {
        saveScoped(groupSilentNotificationsKey, groupSilentNotifications)
        SharedDataManager.syncGroupsForExtension()
    }

    func silentNotifications(for groupId: String) -> Bool {
        groupSilentNotifications.contains(groupId)
    }

    func setSilentNotifications(_ enabled: Bool, for groupId: String) {
        if enabled {
            groupSilentNotifications.insert(groupId)
        } else {
            groupSilentNotifications.remove(groupId)
        }
        saveGroupSilentNotifications()
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
        ChatService.clearDeliveredNotifications(threadIdentifier: "group:\(groupId)")
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
        // Nextcloud mirror runs on an adaptive cadence keyed off the open chat; wake its
        // change watcher so this thread picks up other devices' uploads immediately.
        NextcloudService.shared.noteChatOpened()
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

    /// Posts a local notification for an incoming group message. Fires whenever the message was
    /// NOT ingested with its group thread open on screen - including while the user sits on the
    /// chat list or in another chat (the caller enforces that one suppression). Mirrors what 1:1
    /// gets via APNs, but as a local notification so it also fires when the group's remote push
    /// only wakes the app (content-available) without showing a banner of its own. One banner per
    /// txId across all paths via `claimGroupBannerSlot`.
    private func maybePostGroupLocalNotification(group: GroupChat, message: GroupMessage) {
        let settings = AppSettings.load()
        guard settings.notificationMode != .disabled else { return }
        guard !ChatService.shared.suppressNotificationsUntilSynced else { return }
        guard message.deliveryStatus != .pending else { return }

        // Backfilled history never notifies: anything mined before this device learned about the
        // group (its local createdAt, minus a small clock slack) is a first-catch-up backfill of
        // an existing group's history, not new mail - mirrors ChatService's wallet-import
        // baseline for 1:1. Without this, joining an active group would flood banners.
        guard message.timestamp >= group.createdAt.addingTimeInterval(-120) else { return }

        // Honor this group's "only notify if mentioned" setting (the extension enforces the same
        // rule for the push path; this covers the case where no push reached the extension at all).
        // Suppressing must still CLAIM the banner slot: willPresent only drops a foreground push
        // whose txId is in the local-posted ledger, so an unclaimed suppression would let that
        // same message's push banner anyway and bypass the toggle.
        // Silent wins over everything: no banner for this group at all.
        if silentNotifications(for: group.id) {
            _ = claimGroupBannerSlot(txId: message.txId)
            return
        }
        if mentionsOnlyNotifications(for: group.id), !isPersonalGroupMessage(message.content) {
            _ = claimGroupBannerSlot(txId: message.txId)
            return
        }

        // Don't duplicate a push the extension already handled, and record this local banner so
        // the same message's push arriving later is dropped in willPresent.
        guard claimGroupBannerSlot(txId: message.txId) else { return }

        let content = UNMutableNotificationContent()
        content.title = group.name
        content.subtitle = groupMemberDisplayName(message.senderAddress ?? "", in: group)
        content.body = GroupMentionCodec.decodeForDisplay(
            MessageReplyCodec.previewText(for: message.content),
            members: group.members,
            resolveDisplayName: { self.groupMemberDisplayName($0, in: group) }
        )
        content.threadIdentifier = "group:\(group.id)"
        content.categoryIdentifier = AppDelegate.messageCategoryId
        content.sound = settings.incomingNotificationSoundEnabled ? .default : nil

        let request = UNNotificationRequest(identifier: message.txId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Posts "Alice reacted [emoji] to your message" for an incoming group reaction. Reactions are
    /// intercepted before they ever become GroupMessages (they render as a corner pill), so
    /// `maybePostGroupLocalNotification` never sees them - without this they produced no banner at
    /// all (or only the server's generic fallback). Same foreground policy as messages: fires
    /// while the app is open too, suppressed only while this group's thread is on screen.
    private func maybePostGroupReactionNotification(
        group: GroupChat,
        reactorAddress: String,
        emoji: String,
        targetTxId: String,
        txId: String,
        blockTime: Int64
    ) {
        let settings = AppSettings.load()
        guard settings.notificationMode != .disabled else { return }
        guard !ChatService.shared.suppressNotificationsUntilSynced else { return }
        if activeGroupId == group.id, UIApplication.shared.applicationState == .active { return }

        // Same backfill floor as messages: a reaction older than this device's knowledge of the
        // group is first-catch-up history, not live activity.
        let reactionDate = Date(timeIntervalSince1970: Double(blockTime) / 1000)
        guard reactionDate >= group.createdAt.addingTimeInterval(-120) else { return }

        let targetIsMine = groupMessages[group.id]?.first(where: { $0.txId == targetTxId })?.isOutgoing == true
        // Mentions-only groups: a reaction to YOUR message is personal, like a reply to you;
        // reactions to other members' messages stay silent. Same ledger rule as messages: the
        // suppression claims the banner slot so the reaction's own push can't banner in
        // willPresent and bypass the toggle.
        if silentNotifications(for: group.id) {
            _ = claimGroupBannerSlot(txId: txId)
            return
        }
        if mentionsOnlyNotifications(for: group.id), !targetIsMine {
            _ = claimGroupBannerSlot(txId: txId)
            return
        }

        guard claimGroupBannerSlot(txId: txId) else { return }

        let reactorName = groupMemberDisplayName(reactorAddress, in: group)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = group.name
        switch (targetIsMine, trimmedEmoji.isEmpty) {
        case (true, false):
            content.body = String(format: String(localized: "%1$@ reacted %2$@ to your message"), reactorName, trimmedEmoji)
        case (true, true):
            content.body = String(format: String(localized: "%@ reacted to your message"), reactorName)
        case (false, false):
            content.body = String(format: String(localized: "%1$@ reacted %2$@ to a message"), reactorName, trimmedEmoji)
        case (false, true):
            content.body = String(format: String(localized: "%@ reacted to a message"), reactorName)
        }
        content.threadIdentifier = "group:\(group.id)"
        content.sound = settings.incomingNotificationSoundEnabled ? .default : nil

        let request = UNNotificationRequest(identifier: txId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// The exact rule the notification-service extension applies to a group_message push in a
    /// mentions-only group (`isMentionsOnlyEnabled` + `mentionsMe` + `isReplyToMe` in
    /// NotificationService.swift): a message is "personal" when it replies to one of MY
    /// messages, or when its own text @mentions me in EITHER cross-platform wire form -
    /// iOS/desktop compose `@{fullKaspaAddress}` (`GroupMentionCodec`), Android composes
    /// `@{primaryKNSDomain}` - both checked on the reply-unwrapped text so a quoted
    /// `replyToPreview` that happens to contain my mention doesn't count. The domain form
    /// reuses the domain-mention rendering feature's own tokenizer (`KaPostsView.mentionDomains`:
    /// "@" at a word boundary, lowercased, ".kas" suffix optional) against the wallet's
    /// reverse-resolved primary domain, so detection can never disagree with rendering. No
    /// wallet loaded = treat as personal (don't suppress), matching the NSE's same
    /// conservative fallback.
    private func isPersonalGroupMessage(_ content: String) -> Bool {
        guard let myAddress = WalletManager.shared.currentWallet?.publicAddress, !myAddress.isEmpty else {
            return true
        }
        if MessageReplyCodec.parse(content)?.replyToSender == myAddress { return true }
        let ownText = MessageReplyCodec.unwrappedText(content)
        if GroupMentionCodec.mentions(myAddress, in: ownText) { return true }
        if let myDomain = KNSService.shared.barePrimaryDomain(for: myAddress) {
            return KaPostsView.mentionDomains(in: ownText).contains(myDomain)
        }
        return false
    }

    /// The wallet's own outgoing group-message txIds (newest first, bounded). Shared with the
    /// notification extension (see `SharedDataManager.syncOwnGroupTxIdsForExtension`) so it can
    /// tell a reaction to MY message - personal, notifies even in a mentions-only group - from a
    /// reaction to someone else's message, which stays silent there.
    func ownOutgoingGroupTxIds(limit: Int = 500) -> [String] {
        groupMessages.values
            .flatMap { $0 }
            .filter { $0.isOutgoing && !$0.txId.hasPrefix("pending_") }
            .sorted { $0.blockTime > $1.blockTime }
            .prefix(limit)
            .map { $0.txId }
    }

    /// App Group ledger of group txIds the MAIN APP posted a local banner for. Counterpart of the
    /// extension's `group_push_handled_txids`: together they guarantee ONE banner per group txId
    /// no matter which path (local block-scan/catch-up ingest vs remote push) runs first.
    /// `AppDelegate.willPresent` drops a foreground push whose tx_id appears here.
    static let localPostedTxIdsKey = "group_local_posted_txids"

    /// Returns false when this txId already produced (or deliberately suppressed) a banner - the
    /// extension handled its push, or the main app already posted a local banner for it. Returns
    /// true and records the claim otherwise. Bounded FIFO, mirroring `markGroupPushHandled`.
    private func claimGroupBannerSlot(txId: String) -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.com.kachat.app") else { return true }
        let pushHandled = defaults.stringArray(forKey: "group_push_handled_txids") ?? []
        guard !pushHandled.contains(txId) else { return false }
        var posted = defaults.stringArray(forKey: Self.localPostedTxIdsKey) ?? []
        guard !posted.contains(txId) else { return false }
        posted.append(txId)
        if posted.count > 300 { posted.removeFirst(posted.count - 300) }
        defaults.set(posted, forKey: Self.localPostedTxIdsKey)
        return true
    }

    /// Prefers a 1:1 contact alias, then the roster display-name snapshot, then a shortened
    /// address - matches the notification-service extension's sender-name resolution.
    private func groupMemberDisplayName(_ address: String, in group: GroupChat) -> String {
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias, !alias.isEmpty {
            return alias
        }
        if let member = group.members.first(where: { $0.address == address }),
           let displayName = member.displayName, !displayName.isEmpty {
            return displayName
        }
        return String(address.suffix(10))
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
        loadGroupPhotos()
        loadGroupPhotoUpdatedAt()
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
                // Reactions too: the chat list's reaction preview and the incoming-reaction
                // replay check both need every group's index warm, not just opened groups'.
                self.loadGroupReactions(for: group.id)
                await Task.yield()
            }
            // Every group's history is now in memory - refresh the extension's own-txId list so
            // reactions to this wallet's messages are recognized as personal in the push path.
            SharedDataManager.syncOwnGroupTxIdsForExtension()
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
        for baseKey in [groupCatchUpCursorsKey, groupLastReadAtKey, groupHiddenMembersKey, groupMutedMembersKey, groupMentionsOnlyNotificationsKey, groupSilentNotificationsKey] {
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

    // MARK: - Cross-platform backup archive (manual export/import)

    /// Full group key material for the shared backup archive - including the admin's groupSeed,
    /// which lives ONLY on the creating device and has no on-chain invite for other devices of
    /// the same account to recover from. deviceId/msgCounter are per-device and omitted.
    func archiveGroups() -> [ChatHistoryArchiveGroup] {
        groups.compactMap { group in
            guard let bag = try? keychain.loadGroupBag(groupId: group.id) else { return nil }
            // Decrypt each group's stored history so it can be restored even if the indexer prunes.
            let archivedMessages: [ChatHistoryArchiveGroupMessage] = Data(hexString: group.id).map { gid in
                Self.decryptGroupRows(store.messageRows(forGroup: group.id), groupId: group.id, gid: gid, bag: bag).compactMap { m in
                    guard !m.txId.hasPrefix("pending_") else { return nil }
                    // Membership system lines are re-derived from roster changes on each device —
                    // don't ship them in the backup (they'd re-appear out of context on restore).
                    guard m.senderAddress != GroupChatService.systemSender else { return nil }
                    return ChatHistoryArchiveGroupMessage(
                        msgIdHex: nil, txId: m.txId,
                        senderAddress: m.senderAddress, senderIdHex: m.senderIdHex.isEmpty ? nil : m.senderIdHex,
                        content: m.content, blockTime: UInt64(max(0, m.blockTime)), isOutgoing: m.isOutgoing
                    )
                }
            } ?? []
            return ChatHistoryArchiveGroup(
                groupId: group.id,
                name: group.name,
                isAdmin: group.isAdmin,
                adminAddress: group.adminAddress,
                adminSigningPub: group.adminXOnlyPubKeyHex,
                groupSeed: bag.groupSeed,
                groupRootEpoch: bag.groupRootEpoch,
                blindingKey: bag.blindingKey,
                currentEpoch: bag.currentEpoch,
                members: group.members.map {
                    ChatHistoryArchiveGroupMember(address: $0.address, xOnlyPubKeyHex: $0.xOnlyPubKeyHex, isAdmin: $0.isAdmin)
                },
                messages: archivedMessages,
                photo: groupPhotos[group.id]
            )
        }
    }

    /// Restore groups from a shared backup archive. Recovers admin groups (groupSeed present)
    /// as well as member ones. Mints a fresh deviceId per group so this device's sends can't
    /// collide with msg_ids the exporting device already used; never downgrades a newer epoch.
    func importArchiveGroups(_ archiveGroups: [ChatHistoryArchiveGroup]) {
        var seededReadMarkers = false
        for g in archiveGroups {
            // Never resurrect a group you deleted (tombstoned) - same rule as the on-chain path.
            if isGroupTombstoned(g.groupId) { continue }
            guard let groupRootEpoch = g.groupRootEpoch, let blindingKey = g.blindingKey else { continue }
            let existingBag = try? keychain.loadGroupBag(groupId: g.groupId)
            if let existingBag, existingBag.currentEpoch > g.currentEpoch { continue }
            let deviceId = existingBag?.deviceId ?? GroupCipher.generateDeviceId().hexString
            let msgCounter = existingBag?.currentEpoch == g.currentEpoch ? (existingBag?.msgCounter ?? 0) : 0
            let bag = GroupBag(
                groupId: g.groupId, groupSeed: g.groupSeed, groupRootEpoch: groupRootEpoch,
                blindingKey: blindingKey, currentEpoch: g.currentEpoch, deviceId: deviceId, msgCounter: msgCounter
            )
            try? keychain.saveGroupBag(bag)
            let members = g.members.map {
                GroupMember(address: $0.address, xOnlyPubKeyHex: $0.xOnlyPubKeyHex ?? "", isAdmin: $0.isAdmin, displayName: nil)
            }
            let group = GroupChat(
                id: g.groupId, name: g.name, adminAddress: g.adminAddress ?? "",
                adminXOnlyPubKeyHex: g.adminSigningPub ?? "", members: members,
                currentEpoch: g.currentEpoch, createdAt: Date(), isAdmin: g.isAdmin
            )
            store.upsertGroup(group)

            // Restore the admin-set group photo (if the archive carried one).
            if let photo = g.photo, !photo.isEmpty { setLocalGroupPhoto(g.groupId, hex: photo) }

            // Restore decrypted message history under the negative-epoch sentinel, deduped by txId.
            for m in g.messages ?? [] {
                let txId = (m.txId?.isEmpty == false ? m.txId! : "imported_\((m.msgIdHex ?? UUID().uuidString))")
                store.insertImportedPlaintextMessage(
                    txId: txId, groupId: g.groupId, senderAddress: m.senderAddress,
                    senderIdHex: m.senderIdHex ?? "", msgIdHex: m.msgIdHex ?? "",
                    content: m.content, blockTime: Int64(m.blockTime), isOutgoing: m.isOutgoing
                )
            }

            // Restored history is history, not new mail: without a read marker this group would
            // count every restored (and immediately catch-up-fetched) message as unread, plus
            // the "never opened" minimum badge for member groups. Seed the marker at the restore
            // moment - but only when this device has none, so a live device's genuine unread
            // state is left alone.
            if groupLastReadAt[g.groupId] == nil {
                groupLastReadAt[g.groupId] = Date()
                seededReadMarkers = true
            }
        }
        if seededReadMarkers {
            saveGroupLastReadAt()
            ChatService.shared.scheduleBadgeUpdate()
        }
        groups = store.allGroups()
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
        // Self-addressed recovery copy (seed-carrying) so a seedless re-import finds this group.
        // Best-effort: failure just leaves selfInviteEpoch unset and the sync backfill retries.
        try? await sendSelfRootControlMessage(group: group, bag: bag, privateKey: privateKey)

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

        let previousName = group.name
        group.name = newName
        store.upsertGroup(group)
        groups = store.allGroups()
        SharedDataManager.syncGroupsForExtension()
        if previousName != newName {
            insertGroupSystemLine(groupId, "You changed the group name to \"\(newName)\"")
        }
        // Self-addressed root so the SAME account's OTHER devices pick up the new name.
        try? await sendSelfRootControlMessage(group: group, bag: bag, privateKey: privateKey)

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

    /// Re-broadcast the CURRENT root to every member (admin) — retries invites that failed to
    /// send, without rotating the epoch. Throws if any member still can't be reached.
    func resendInvites(_ groupId: String) async throws {
        guard let group = store.group(id: groupId), group.isAdmin else {
            throw KasiaError.networkError("Only the group admin can resend invites.")
        }
        guard let bag = try keychain.loadGroupBag(groupId: groupId) else { throw KasiaError.networkError("Missing admin group secrets.") }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else { throw KasiaError.walletNotFound }
        var sendErrors: [Error] = []
        for member in group.members where member.address != wallet.publicAddress {
            do { try await sendRootControlMessage(group: group, bag: bag, to: member.address, privateKey: privateKey) }
            catch { sendErrors.append(error) }
        }
        // Also re-push the group photo so anyone who missed it catches up.
        if let hex = groupPhotos[groupId], !hex.isEmpty {
            try? await distributeGroupPhoto(group: group, photoHex: hex, privateKey: privateKey, myAddress: wallet.publicAddress)
        }
        if !sendErrors.isEmpty {
            throw KasiaError.networkError("\(sendErrors.count) invite(s) still could not be sent.")
        }
    }

    /// Re-broadcast the current root to ONE member (admin) — a targeted retry of a single invite.
    func resendInvite(to address: String, groupId: String) async throws {
        guard let group = store.group(id: groupId), group.isAdmin else {
            throw KasiaError.networkError("Only the group admin can resend invites.")
        }
        guard let bag = try keychain.loadGroupBag(groupId: groupId) else { throw KasiaError.networkError("Missing admin group secrets.") }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else { throw KasiaError.walletNotFound }
        guard address != wallet.publicAddress else { return }
        try await sendRootControlMessage(group: group, bag: bag, to: address, privateKey: privateKey)
    }

    /// Admin: set (photoHex = hex of a compressed JPEG) or clear (photoHex = "") the group photo,
    /// then push it to every member via a signed gctl_photo control message.
    func setGroupPhoto(_ groupId: String, photoHex: String) async throws {
        guard let group = store.group(id: groupId), group.isAdmin else {
            throw KasiaError.networkError("Only the group admin can change the group photo.")
        }
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else { throw KasiaError.walletNotFound }
        await MainActor.run {
            setLocalGroupPhoto(groupId, hex: photoHex.isEmpty ? nil : photoHex)
            insertGroupSystemLine(groupId, photoHex.isEmpty ? "You removed the group photo" : "You changed the group photo")
        }
        try await distributeGroupPhoto(group: group, photoHex: photoHex, privateKey: privateKey, myAddress: wallet.publicAddress)
    }

    /// Send the current group photo to every member (admin). Best-effort per member.
    private func distributeGroupPhoto(group: GroupChat, photoHex: String, privateKey: Data, myAddress: String) async throws {
        guard let gid = Data(hexString: group.id), let adminXOnlyPub = Data(hexString: group.adminXOnlyPubKeyHex) else { return }
        let payload = try GroupCipher.buildSignedPhotoPayload(groupId: gid, photoHex: photoHex, signingPub: adminXOnlyPub, privateKey: privateKey)
        let json = try JSONEncoder().encode(payload)
        for member in group.members where member.address != myAddress {
            guard let recipientPublicKey = KaspaAddress.publicKey(from: member.address) else { continue }
            try? await sendControlPayload(json, to: recipientPublicKey, from: myAddress, privateKey: privateKey)
        }
        // Also send a self-addressed copy so the SAME account's OTHER devices sync the photo change.
        if let selfPub = KaspaAddress.publicKey(from: myAddress) {
            try? await sendControlPayload(json, to: selfPub, from: myAddress, privateKey: privateKey)
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
        // Tombstone it so discovery/recovery never re-adds it, and publish an on-chain delete
        // marker (best-effort; the catch-up backfill retries) so the delete survives a seedless
        // re-import too. Local intent is recorded now; the chain write is async.
        recordGroupTombstone(groupId, published: false)
        Task { try? await publishGroupTombstone(groupId) }
    }

    // MARK: - Group deletion tombstones (UserDefaults-backed, per wallet)

    private var tombstonesDefaultsKey: String? {
        guard let addr = WalletManager.shared.currentWallet?.publicAddress else { return nil }
        return "kachat_group_tombstones_\(addr)"
    }
    private struct GroupTombstoneState: Codable { var deleted: [String] = []; var published: [String] = [] }
    private func loadTombstoneState() -> GroupTombstoneState {
        guard let key = tombstonesDefaultsKey, let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(GroupTombstoneState.self, from: data) else { return GroupTombstoneState() }
        return decoded
    }
    private func saveTombstoneState(_ state: GroupTombstoneState) {
        guard let key = tombstonesDefaultsKey, let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
    func isGroupTombstoned(_ groupId: String) -> Bool { loadTombstoneState().deleted.contains(groupId) }
    private func recordGroupTombstone(_ groupId: String, published: Bool) {
        var state = loadTombstoneState()
        if !state.deleted.contains(groupId) { state.deleted.append(groupId) }
        if published, !state.published.contains(groupId) { state.published.append(groupId) }
        saveTombstoneState(state)
    }
    private func markTombstonePublished(_ groupId: String) {
        var state = loadTombstoneState()
        if !state.published.contains(groupId) { state.published.append(groupId) }
        saveTombstoneState(state)
    }
    /// Self-addressed, self-signed delete marker — only our key can produce one, only our key
    /// can read it (see the signing_pub == self + verify check in handleIncomingControlMessage).
    private func publishGroupTombstone(_ groupId: String) async throws {
        guard let gid = Data(hexString: groupId),
              let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey(),
              let selfPub = KaspaAddress.publicKey(from: wallet.publicAddress) else { return }
        let signingPub = try schnorrXOnlyPublicKey(from: privateKey)
        let payload = try GroupCipher.buildSignedTombstonePayload(groupId: gid, signingPub: signingPub, privateKey: privateKey)
        let json = try JSONEncoder().encode(payload)
        try await sendControlPayload(json, to: selfPub, from: wallet.publicAddress, privateKey: privateKey)
        markTombstonePublished(groupId)
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

    /// Reserved sender for iMessage-style membership lines ("X was added/removed"). Stored as a
    /// negative-epoch plaintext row; the group thread renders these centered, not as bubbles.
    static let systemSender = "system"

    /// Best display name for a membership line: contact alias → roster snapshot → KNS → fallback.
    private func groupMemberLabel(_ address: String, fallback: String?) -> String {
        if let contact = ContactsManager.shared.getContact(byAddress: address), !contact.alias.isEmpty { return contact.alias }
        if let f = fallback, !f.isEmpty { return f }
        if let kns = KNSService.shared.profileCache[address]?.domainName, !kns.isEmpty { return kns }
        return Contact.generateDefaultAlias(from: address)
    }

    /// Insert one iMessage-style system line (photo/name change) into a group thread.
    /// `stableKey`, when given, makes the row's txId deterministic (derived from the control's
    /// block time) so re-processing the same control can't insert a duplicate line — the DB dedupes
    /// on txId. Without it we fall back to a wall-clock id (fine for one-shot local emits).
    func insertGroupSystemLine(_ groupId: String, _ text: String, stableKey: String? = nil) {
        let t = Int64(Date().timeIntervalSince1970 * 1000)
        let txId = stableKey.map { "sys_\(groupId.prefix(8))_\($0)" } ?? "sys_\(groupId.prefix(8))_\(t)_\(text.prefix(12))"
        store.insertImportedPlaintextMessage(txId: txId, groupId: groupId, senderAddress: Self.systemSender, senderIdHex: "", msgIdHex: "", content: text, blockTime: t, isOutgoing: false)
        loadMessages(for: groupId)
    }

    /// Emit "X was added" / "Y was removed" lines for a roster change, stored as system messages.
    private func insertMembershipSystemMessages(groupId: String, oldMembers: [GroupMember], newMembers: [GroupMember]) {
        let oldAddrs = Set(oldMembers.map { $0.address })
        let newAddrs = Set(newMembers.map { $0.address })
        var t = Int64(Date().timeIntervalSince1970 * 1000)
        for m in newMembers where !oldAddrs.contains(m.address) {
            let label = groupMemberLabel(m.address, fallback: m.displayName)
            store.insertImportedPlaintextMessage(txId: "sys_\(groupId.prefix(8))_\(t)_add", groupId: groupId, senderAddress: Self.systemSender, senderIdHex: "", msgIdHex: "", content: "\(label) was added to the group chat", blockTime: t, isOutgoing: false)
            t += 1
        }
        for m in oldMembers where !newAddrs.contains(m.address) {
            let label = groupMemberLabel(m.address, fallback: m.displayName)
            store.insertImportedPlaintextMessage(txId: "sys_\(groupId.prefix(8))_\(t)_rem", groupId: groupId, senderAddress: Self.systemSender, senderIdHex: "", msgIdHex: "", content: "\(label) was removed from the group chat", blockTime: t, isOutgoing: false)
            t += 1
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

        let previousRoster = group.members
        var roster = group.members
        try mutateRoster(&roster)

        let newEpoch = bag.currentEpoch + 1
        let newRoot = GroupCipher.deriveGroupRootEpoch(groupSeed: groupSeed, groupId: gid, epoch: newEpoch)
        // Keep the outgoing root so this epoch's messages stay readable afterwards. The admin
        // could re-derive it from the seed, but every other device cannot - and this is the same
        // archive their bag relies on, so both sides behave identically.
        bag.previousRoots = (bag.previousRoots ?? [:]).merging([String(bag.currentEpoch): bag.groupRootEpoch]) { _, new in new }
        bag.currentEpoch = newEpoch
        bag.groupRootEpoch = newRoot.hexString
        try keychain.saveGroupBag(bag)

        group.members = roster
        group.currentEpoch = newEpoch
        store.upsertGroup(group)
        groups = store.allGroups()
        SharedDataManager.syncGroupsForExtension()
        // iMessage-style membership lines for the admin (other members get theirs when they
        // receive the rotated root — see applyRootPayload).
        insertMembershipSystemMessages(groupId: groupId, oldMembers: previousRoster, newMembers: roster)
        loadMessages(for: groupId)

        var sendErrors: [Error] = []
        for member in roster where member.address != wallet.publicAddress {
            do {
                try await sendEpochControlMessage(groupId: gid, epoch: newEpoch, reason: reason, to: member.address, adminPrivateKey: privateKey)
                try await sendRootControlMessage(group: group, bag: bag, to: member.address, privateKey: privateKey)
            } catch {
                sendErrors.append(error)
            }
        }
        // A newly-added member should also receive the current group photo (root doesn't carry it).
        if let hex = groupPhotos[groupId], !hex.isEmpty {
            try? await distributeGroupPhoto(group: group, photoHex: hex, privateKey: privateKey, myAddress: wallet.publicAddress)
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
        // Deterministic field order (mimeType before content) - see MediaFileEnvelope.
        let jsonString = MediaFileEnvelope.json(
            name: fileName,
            size: imageData.count,
            mimeType: mimeType,
            dataUrlContent: "data:\(mimeType);base64,\(base64)"
        )
        try await sendGroupMessage(jsonString, to: groupId)
    }

    /// Sends a voice message to the group - same envelope/reuse rationale as `sendGroupImage`.
    func sendGroupAudio(_ audioData: Data, to groupId: String, fileName: String = "voice.webm", mimeType: String = "audio/webm") async throws {
        guard !audioData.isEmpty else {
            throw KasiaError.networkError("Audio file is empty")
        }
        let base64 = audioData.base64EncodedString()
        let jsonString = MediaFileEnvelope.json(
            name: fileName,
            size: audioData.count,
            mimeType: mimeType,
            dataUrlContent: "data:\(mimeType);base64,\(base64)"
        )
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
        // Animated publish - see ChatService.sendMessageInternal's identical treatment.
        withAnimation(.easeOut(duration: 0.25)) {
            groupMessages[groupId, default: []].append(pendingMessage)
        }
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
            // The message just got its real txId - share it with the notification extension so a
            // reaction to it counts as personal under "Only Notify if I'm Mentioned".
            SharedDataManager.syncOwnGroupTxIdsForExtension()
            replyingTo = nil
        } catch {
            store.markMessageFailed(pendingId: pendingId)
            if let index = groupMessages[groupId]?.firstIndex(where: { $0.txId == pendingId }) {
                groupMessages[groupId]?[index].deliveryStatus = .failed
            }
            throw error
        }
    }

    /// Re-sends a previously-failed group message IN PLACE - it reuses the existing failed row (its
    /// stable `id` and `pending_…` txId) rather than inserting a new one, so Retry never duplicates
    /// the message. `message.content` is already the final payload (reply envelope included if it
    /// was a reply), so it's re-encrypted as-is under a fresh msg_id (reusing a msg_id is forbidden;
    /// the message's identity is unchanged).
    func retryGroupMessage(_ message: GroupMessage) async throws {
        let groupId = message.groupId
        guard message.isOutgoing, message.deliveryStatus == .failed else { return }
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
        let payload = message.content

        // Fresh msg_id/counter for the resend (msg_id reuse is forbidden), even though the message
        // identity/row is unchanged.
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

        // The failed row's own id is its `pending_…` txId (it never got a real one). Reuse it: flip
        // the existing row back to pending in memory, then resolve/fail the SAME row - no insert.
        let pendingId = message.txId
        if let index = groupMessages[groupId]?.firstIndex(where: { $0.id == message.id }) {
            groupMessages[groupId]?[index].deliveryStatus = .pending
        }

        do {
            let realTxId = try await ChatService.shared.enqueueOutgoingTxOperation { [weak self] in
                try await self?.sendSelfStashPayload(payloadString, from: wallet.publicAddress, privateKey: privateKey) ?? ""
            }
            store.resolvePendingMessage(pendingId: pendingId, realId: realTxId, blockTime: message.blockTime)
            if let index = groupMessages[groupId]?.firstIndex(where: { $0.id == message.id }) {
                groupMessages[groupId]?[index] = GroupMessage(
                    id: message.id, groupId: groupId, txId: realTxId, senderAddress: wallet.publicAddress,
                    senderIdHex: senderId.hexString, content: payload, timestamp: message.timestamp,
                    blockTime: message.blockTime, isOutgoing: true, deliveryStatus: .sent
                )
            }
            // Same as sendGroupMessage: the retried message now has a real txId to share.
            SharedDataManager.syncOwnGroupTxIdsForExtension()
        } catch {
            store.markMessageFailed(pendingId: pendingId)
            if let index = groupMessages[groupId]?.firstIndex(where: { $0.id == message.id }) {
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
            let txId: String
            do {
                let (t, _) = try await NodePoolService.shared.submitTransaction(tx, allowOrphan: usesUnconfirmedInputs)
                txId = t
            } catch {
                // A hedged submit can land on a node that briefly lags the DAG tip and rejects a tx
                // spending an input we believe is confirmed as an orphan ("...orphan is disallowed").
                // Retry once tolerating orphan — the node parks it until the parent propagates
                // (sub-second) — rather than surfacing kaspad's raw rejection with no recovery. This
                // is the same recovery the 1:1/Android send paths use; the group path lacked it.
                if !usesUnconfirmedInputs, Self.isOrphanRejection(error) {
                    let (t, _) = try await NodePoolService.shared.submitTransaction(tx, allowOrphan: true)
                    txId = t
                } else {
                    throw error
                }
            }
            chatService.reserveMessageOutpoints(spentUtxos)
            chatService.consumePendingUtxos(spentUtxos)
            if let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: address) {
                chatService.addPendingOutputs(from: tx, txId: txId, senderScriptPubKey: senderScriptPubKey)
            }
            return txId
        } catch {
            chatService.releaseMessageOutpoints()
            // Never surface kaspad's raw "...orphan is disallowed" text — map it to a friendly,
            // actionable message (the send can simply be retried once the parent settles).
            if Self.isOrphanRejection(error) {
                throw KasiaError.networkError("The network is still confirming your last message. Please try again in a moment.")
            }
            throw error
        }
    }

    /// True when a submit was rejected as an orphan (parent not yet seen by the submitting node).
    nonisolated static func isOrphanRejection(_ error: Error) -> Bool {
        return error.localizedDescription.lowercased().contains("orphan")
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

    /// Self-addressed recovery copy carrying the group seed (ECIES-encrypted to our own key, so
    /// members never see it). A seedless re-import of this wallet rediscovers the group via the
    /// by-recipient control scan and rebuilds it as admin. Marks selfInviteEpoch on the bag.
    private func sendSelfRootControlMessage(group: GroupChat, bag: GroupBag, privateKey: Data) async throws {
        guard let gid = Data(hexString: group.id),
              let groupRootEpoch = Data(hexString: bag.groupRootEpoch),
              let blindingKey = Data(hexString: bag.blindingKey),
              let seedHex = bag.groupSeed, let groupSeed = Data(hexString: seedHex),
              let adminXOnlyPub = Data(hexString: group.adminXOnlyPubKeyHex),
              let wallet = WalletManager.shared.currentWallet,
              let selfPublicKey = KaspaAddress.publicKey(from: wallet.publicAddress) else {
            throw KasiaError.invalidAddress
        }
        let rootPayload = try GroupCipher.buildSignedRootPayload(
            groupId: gid, epoch: bag.currentEpoch, groupRootEpoch: groupRootEpoch, blindingKey: blindingKey,
            adminSigningPub: adminXOnlyPub, members: group.members.map { $0.address }, name: group.name,
            adminPrivateKey: privateKey, groupSeed: groupSeed
        )
        let json = try JSONEncoder().encode(rootPayload)
        try await sendControlPayload(json, to: selfPublicKey, from: wallet.publicAddress, privateKey: privateKey)
        var updated = bag
        updated.selfInviteEpoch = bag.currentEpoch
        try? keychain.saveGroupBag(updated)
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
        // Retry to ride out UTXO contention: each member's invite is its own tx, and a
        // back-to-back send fails until the prior tx's change output settles. Without this a
        // multi-member invite silently drops the 2nd+ members even though the loop doesn't abort.
        var lastError: Error?
        let attempts = 4
        for i in 0..<attempts {
            do {
                try await ChatService.shared.enqueueOutgoingTxOperation { [weak self] in
                    _ = try await self?.sendSelfStashPayload(payloadString, from: senderAddress, privateKey: privateKey)
                }
                return
            } catch {
                lastError = error
                if i < attempts - 1 { try? await Task.sleep(nanoseconds: 1_800_000_000) }
            }
        }
        throw lastError ?? NSError(domain: "KaChat", code: -1, userInfo: [NSLocalizedDescriptionKey: "Group invite send failed."])
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
            // Merge, don't clobber. `rows` was snapshotted from the store BEFORE we decrypted;
            // meanwhile catch-up sync / the live block-scan (both @MainActor, same as this write)
            // may have appended newly-arrived messages to the in-memory array. Overwriting with the
            // stale decoded snapshot would drop those just-received messages until the next
            // relaunch - the "reopening the app doesn't reload missed group messages" bug. Keep any
            // in-memory message whose txId isn't in the decoded set (the newest, caught-up ones),
            // appended after the store history so chronological order is preserved.
            let existing = self.groupMessages[groupId] ?? []
            let decodedTxIds = Set(decoded.map { $0.txId })
            let inMemoryOnly = existing.filter { !decodedTxIds.contains($0.txId) }
            self.groupMessages[groupId] = inMemoryOnly.isEmpty ? decoded : decoded + inMemoryOnly
        }
    }

    /// Admins can derive any past epoch's root on demand (they hold groupSeed); non-admins only
    /// retain the current epoch's root - by design, this is the protocol's forward-secrecy
    /// boundary, not a bug.
    private func groupRootEpoch(for epoch: UInt64, bag: GroupBag, groupId: Data) -> Data? {
        if epoch == bag.currentEpoch, let root = Data(hexString: bag.groupRootEpoch) {
            return root
        }
        // A member who kept the old root can still read the old messages. Checked BEFORE the
        // seed fallback because only the admin has a seed - for everyone else this archive is
        // the only way history survives a membership change. See `GroupBag.previousRoots`.
        if let archived = bag.previousRoots?[String(epoch)], let root = Data(hexString: archived) {
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
            // Backup-restored rows carry decrypted plaintext (UTF-8 bytes) under the negative
            // epoch sentinel - no group key involved. Preserves history the indexer may have pruned.
            if row.isImportedPlaintext {
                guard let plaintext = String(data: row.contentEncrypted, encoding: .utf8) else { continue }
                decoded.append(GroupMessage(
                    id: UUID(), groupId: groupId, txId: row.txId, senderAddress: row.senderAddress,
                    senderIdHex: row.senderIdHex, content: plaintext, timestamp: Date(timeIntervalSince1970: Double(row.blockTime) / 1000),
                    blockTime: row.blockTime, isOutgoing: row.isOutgoing, deliveryStatus: row.deliveryStatus
                ))
                continue
            }
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
        // Scan only when this wallet actually HAS at least one group. The block stream is the
        // single biggest data consumer in the app (~every block, ~10x/sec, full transaction
        // payloads), and a wallet with zero groups was paying that cost purely for `gctl_root`
        // direct-add invite discovery. That discovery no longer needs the stream:
        // `performCatchUpSync` runs `catchUpGroupControlByRecipient` UNCONDITIONALLY (even with
        // zero local groups, cursor-based, addressed to our own wallet), on every app-active
        // AND at most once a minute via the foreground sweep ride-along (see
        // `ChatService.startForegroundContactSweep`), so an invite lands within ~60s while the
        // app is open instead of instantly - an accepted tradeoff for not streaming every block.
        // Every group create/join/leave path already calls this method, so the stream starts
        // with the first group and stops with the last.
        //
        // On an expensive (cellular/hotspot/Low Data Mode) path, never stream blocks at all,
        // groups or not - the same 60s cursored catch-up carries group MESSAGES too, so group
        // chat on cellular is up to ~60s latent unless a push delivers sooner. WiFi keeps the
        // live stream. The expensive-path sink in `init` re-evaluates this on path changes.
        //
        // Also gated on activeNodeCount > 0: starting the instant the wallet loads (right at cold
        // app launch, before the pool has found any healthy node yet) forced subscribeBlockAdded
        // to compete with the pool's own cold-start discovery/probing for connection resources -
        // real contention that visibly delayed the app connecting to any nodes at all (found via
        // the same issue on Android's mirrored GroupScanningService). Waiting for at least one
        // active node means this only starts once there's already a healthy connection to piggyback on.
        let shouldScan = hasActiveWallet
            && !groups.isEmpty
            && !NetworkEpochMonitor.shared.isExpensivePath
            && NodePoolService.shared.activeNodeCount > 0
        guard shouldScan != isScanningActive else { return }
        isScanningActive = shouldScan
        isScanningActiveMirror = shouldScan
        if shouldScan {
            if blockNotificationHandlerId == nil {
                blockNotificationHandlerId = NodePoolService.shared.addNotificationHandler { [weak self] type, data in
                    guard type == .blockAdded else { return }
                    // Cheap gate FIRST: unsubscribeBlockAdded only flips a wanted-flag - blocks
                    // keep arriving forever once anyone subscribed - so without this the full
                    // parse below would run ~10x/sec even with scanning off.
                    guard self?.isScanningActiveMirror == true else { return }
                    // Blocks arrive ~10x/sec continuously. Deserializing the ENTIRE block and
                    // prefix-scanning every tx payload used to run on the main actor per block -
                    // a permanent main-thread tax (jank, worst under screen recording). A single
                    // SERIAL utility queue (not one detached Task per block) parses off-main so
                    // slow blocks can't stack into unbounded concurrency; the MainActor is only
                    // touched for the rare block that actually carries group traffic.
                    Self.blockScanQueue.async {
                        let hits = Self.extractBlockScanHits(from: data)
                        guard !hits.isEmpty else { return }
                        Task { @MainActor in
                            self?.ingestBlockScanHits(hits)
                        }
                    }
                }
            }
            Task { await NodePoolService.shared.subscribeBlockAdded(client: "group-scan") }
        } else {
            Task { await NodePoolService.shared.unsubscribeBlockAdded(client: "group-scan") }
        }
    }

    /// A block-scan candidate extracted OFF the main actor - only what the MainActor ingest needs.
    private enum BlockScanHit {
        case gcomm(parsed: GroupCipher.ParsedGroupMessage, txId: String, blockTime: Int64)
        case gctl(payload: String, senderAddress: String, blockTime: Int64)
    }

    /// One serial lane for all block parsing - bounds concurrency to a single off-main worker.
    private nonisolated static let blockScanQueue = DispatchQueue(label: "com.kachat.groupBlockScan", qos: .utility)

    /// Runs off-main (pure parsing: protobuf deserialize, prefix filter, hex/UTF-8 decode, gcomm
    /// parse, gctl sender-address derivation - no actor state touched). See the handler above.
    private nonisolated static func extractBlockScanHits(from data: Data) -> [BlockScanHit] {
        guard let notification = try? Protowire_BlockAddedNotificationMessage(serializedBytes: data) else { return [] }
        var hits: [BlockScanHit] = []
        for tx in notification.block.transactions {
            let payloadHex = tx.payload
            // Dual-read: new `kchat:` hex root and legacy `ciph_msg:` hex root.
            let matchesGcomm = payloadHex.hasPrefix(Self.gcommPrefixHex) || payloadHex.hasPrefix(Self.legacyGcommPrefixHex)
            let matchesGctl = payloadHex.hasPrefix(Self.gctlPrefixHex) || payloadHex.hasPrefix(Self.legacyGctlPrefixHex)
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
                hits.append(.gcomm(parsed: parsed, txId: txId, blockTime: blockTime))
            } else if matchesGctl {
                // Settings read only HERE, on an actual gctl hit (rare) - reading them per block
                // did ~20 contended cross-thread refcount ops 10x/sec against strings the main
                // thread also touches.
                let hrp = AppSettings.load().networkType == .mainnet ? "kaspa" : "kaspatest"
                guard let firstOutput = tx.outputs.first,
                      let scriptData = CryptoUtils.hexToData(firstOutput.scriptPublicKey.scriptPublicKey),
                      let senderAddress = KaspaAddress.address(fromScriptPublicKey: scriptData, hrp: hrp) else { continue }
                hits.append(.gctl(payload: Self.normalizeControlPayload(payloadString), senderAddress: senderAddress, blockTime: blockTime))
            }
        }
        return hits
    }

    /// MainActor ingest of pre-extracted candidates - the only per-block work left on main, and it
    /// only runs for blocks that actually carry group traffic.
    private func ingestBlockScanHits(_ hits: [BlockScanHit]) {
        guard isScanningActive else { return }
        for hit in hits {
            switch hit {
            case .gcomm(let parsed, let txId, let blockTime):
                handleIncomingGroupMessage(parsed, txId: txId, blockTime: blockTime)
            case .gctl(let payload, let senderAddress, let blockTime):
                handleIncomingControlMessage(payload, senderAddress: senderAddress, blockTime: blockTime > 0 ? UInt64(blockTime) : 0)
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
                let isOwnReaction = senderAddress == WalletManager.shared.currentWallet?.publicAddress
                // Replay check BEFORE applying: catch-up re-serves the same reaction txs on every
                // cursor overlap, and an already-indexed identical reaction must never re-notify.
                // The in-memory index is loaded for every group at wallet set (see setCurrentWallet).
                let alreadyKnown = reactionsByGroupId[group.id]?[reaction.targetTxId]?.contains {
                    $0.reactorAddress == senderAddress && $0.emoji == reaction.emoji
                } ?? false
                if reaction.action == "add" {
                    applyLocalGroupReaction(targetTxId: reaction.targetTxId, groupId: group.id, reactorAddress: senderAddress, emoji: reaction.emoji)
                    store.upsertGroupReaction(targetTxId: reaction.targetTxId, groupId: group.id, reactorAddress: senderAddress, emoji: reaction.emoji, reactionTxId: txId, blockTime: blockTime)
                    if !isOwnReaction, !alreadyKnown {
                        maybePostGroupReactionNotification(
                            group: group, reactorAddress: senderAddress, emoji: reaction.emoji,
                            targetTxId: reaction.targetTxId, txId: txId, blockTime: blockTime
                        )
                    }
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
            // Own message echoed back (sent from another device of this wallet, or self-stash
            // catch-up): keep the extension's own-txId list fresh so reactions to it are
            // recognized as personal in the push path. Rare (dedup drops re-served own sends
            // above), so the UserDefaults write doesn't run per catch-up row.
            if message.isOutgoing {
                SharedDataManager.syncOwnGroupTxIdsForExtension()
            }
            // Global notification center: list incoming messages that @mention one of the
            // wallet's own KNS domains (deduped by txId inside the center).
            if !message.isOutgoing {
                GlobalNotificationCenter.shared.recordGroupMentionIfNeeded(
                    groupId: group.id, groupName: group.name, senderAddress: senderAddress,
                    text: plaintext, txId: txId, timestampMs: blockTime
                )
            }
            // Already looking at this group's thread right now - keep it marked read instead of
            // letting the badge tick up for a message the user is actively seeing arrive live
            // (mirrors ChatService's identical `isUserViewing` check). Covers both this live
            // block-scan path and catch-up sync, which also routes through this function.
            if !message.isOutgoing {
                if activeGroupId == group.id, UIApplication.shared.applicationState == .active {
                    markGroupAsRead(group.id)
                } else {
                    // Foreground policy: notifications fire while the app is OPEN too (chat list,
                    // another chat) - the ONLY suppression is the group thread currently on screen
                    // (the branch above, mirroring ChatService's active-conversation rule for 1:1).
                    // Deduped against any banner the notification-service extension already handled
                    // for this txId, and a push arriving after this local banner is dropped in
                    // willPresent via the group_local_posted_txids ledger.
                    maybePostGroupLocalNotification(group: group, message: message)
                }
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
    private nonisolated static func normalizeControlPayload(_ payloadString: String) -> String {
        // Dual-read: accept either root, then ALWAYS re-root to the canonical `kchat:` gctl
        // prefix so the downstream `dropFirst(gctlPrefix.count)` is correct for old and new.
        let root: String
        if payloadString.hasPrefix(gctlPrefix) { root = gctlPrefix }
        else if payloadString.hasPrefix(legacyGctlPrefix) { root = legacyGctlPrefix }
        else { return payloadString }
        let rest = payloadString.dropFirst(root.count)
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 64,
              parts[0].allSatisfy({ $0.isHexDigit }) else {
            return gctlPrefix + rest
        }
        return gctlPrefix + parts[1]
    }

    private func handleIncomingControlMessage(_ payloadString: String, senderAddress: String, blockTime: UInt64 = 0) {
        guard let wallet = WalletManager.shared.currentWallet, let privateKey = WalletManager.shared.getPrivateKey() else { return }
        // Normally we ignore our own echoed controls — EXCEPT the self-addressed recovery root
        // (sender == us, carries group_seed), which is exactly how a seedless import rebuilds an
        // admin group. Non-recovery self-echoes still short-circuit below.
        let isSelfSent = wallet.publicAddress == senderAddress
        let hexPayload = String(payloadString.dropFirst(Self.gctlPrefix.count))
        guard let plaintext = try? KasiaCipher.decryptHex(hexPayload, privateKey: privateKey),
              let jsonData = plaintext.data(using: .utf8) else { return }

        // A self-addressed delete marker — honor ONLY our own (signed by + addressed to us).
        if let tomb = try? JSONDecoder().decode(GroupCipher.GroupTombstonePayload.self, from: jsonData), tomb.type == "gctl_tombstone" {
            let myPub = WalletManager.shared.getPrivateKey().flatMap { try? schnorrXOnlyPublicKey(from: $0).hexString }
            if tomb.signingPub == myPub, GroupCipher.verifyTombstonePayload(tomb) {
                recordGroupTombstone(tomb.groupId, published: true)
                if store.group(id: tomb.groupId) != nil { deleteLocalGroupForTombstone(tomb.groupId) }
            }
            return
        }
        // An admin-set group photo — apply ONLY if signed by THIS group's known admin.
        if let photo = try? JSONDecoder().decode(GroupCipher.GroupPhotoPayload.self, from: jsonData), photo.type == "gctl_photo" {
            guard let group = store.group(id: photo.groupId) else { return }
            if photo.signingPub == group.adminXOnlyPubKeyHex, GroupCipher.verifyPhotoPayload(photo) {
                // Ignore any photo control strictly older than the last one we applied. This makes
                // re-scans (cursor reset / by-sender M-copy fan-out) no-ops and is the primary guard
                // against the duplicate "removed the group photo" flood.
                if blockTime > 0, blockTime < (groupPhotoUpdatedAt[photo.groupId] ?? 0) { return }
                let newHex = photo.photo.isEmpty ? nil : photo.photo
                let changed = groupPhotos[photo.groupId] != newHex
                setLocalGroupPhoto(photo.groupId, hex: newHex)
                if blockTime > 0 { groupPhotoUpdatedAt[photo.groupId] = blockTime; persistGroupPhotoUpdatedAt() }
                if changed {
                    // "You" on the admin's own other devices; the admin's name for regular members.
                    let who = group.isAdmin ? "You" : groupMemberLabel(group.adminAddress, fallback: nil)
                    // Stable per-control key (block time) so a re-delivery can't duplicate the line.
                    insertGroupSystemLine(photo.groupId, newHex == nil ? "\(who) removed the group photo" : "\(who) changed the group photo", stableKey: "photo_\(blockTime)")
                }
            }
            return
        }
        if let rootPayload = try? JSONDecoder().decode(GroupCipher.GroupRootPayload.self, from: jsonData), rootPayload.type == "gctl_root" {
            if isSelfSent && rootPayload.groupSeed == nil { return } // our own member-copy echo — ignore
            guard GroupCipher.verifyRootPayload(rootPayload) else { return }
            completeJoin(from: rootPayload)
        }
        // gctl_epoch is an advance-notice heads-up only (spec: state updates on gctl_root
        // arrival, not on gctl_epoch) - no local state change needed here in the data layer;
        // Phase 3 UI may surface it as a transient "membership changing..." hint.
    }

    /// Applies a verified `gctl_root` payload: creates or updates the local GroupBag + roster.
    /// Refuses to downgrade to an older epoch than what's already stored (replay protection).
    /// Removes a group locally when a tombstone for it arrives (the tombstone itself is already
    /// recorded by the caller). Deliberately does NOT call deleteGroup, which would re-publish.
    private func deleteLocalGroupForTombstone(_ groupId: String) {
        try? keychain.deleteGroupBag(groupId: groupId)
        store.deleteGroup(id: groupId)
        groups.removeAll { $0.id == groupId }
        groupMessages.removeValue(forKey: groupId)
        SharedDataManager.syncGroupsForExtension()
        updateScanningStateIfNeeded()
    }

    private func completeJoin(from payload: GroupCipher.GroupRootPayload) {
        // A tombstoned group must never be re-added — this makes a delete survive a seedless
        // re-import against the recovery invite.
        if isGroupTombstoned(payload.groupId) { return }
        // Refuse to downgrade to an older epoch than what's already stored locally (replay
        // protection); otherwise apply (covers both "brand new group" and "legitimate advance").
        if let existingBag = try? keychain.loadGroupBag(groupId: payload.groupId),
           existingBag.currentEpoch > payload.epoch {
            return
        }
        applyRootPayload(payload)
    }

    private func applyRootPayload(_ payload: GroupCipher.GroupRootPayload) {
        // Roster + name we held BEFORE this root updates them — used to emit "X was added/removed"
        // and "renamed" system lines. nil on a first-time join (no baseline → no false storm).
        let previousGroupForDiff = store.group(id: payload.groupId)
        let previousRosterForDiff = previousGroupForDiff?.members
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
        // Admin self-recovery: a self-addressed root carries the group seed. Trust it ONLY if it
        // re-derives the SIGNED group_id + blinding_key (that binding authenticates the otherwise
        // unsigned seed). When valid, this is our own group and we hold admin secrets again.
        var recoveredSeedHex: String? = nil
        let myXOnlyPubHex: String? = WalletManager.shared.getPrivateKey().flatMap { try? schnorrXOnlyPublicKey(from: $0).hexString }
        if let seedHex = payload.groupSeed, let seed = Data(hexString: seedHex),
           let gid = Data(hexString: payload.groupId),
           let myPub = myXOnlyPubHex, payload.adminSigningPub == myPub {
            let derivedId = GroupCipher.deriveGroupId(groupSeed: seed).hexString
            let derivedBlinding = GroupCipher.deriveBlindingKey(groupSeed: seed, groupId: gid).hexString
            if derivedId == payload.groupId && derivedBlinding == payload.blindingKey { recoveredSeedHex = seedHex }
        }
        // Archive the root being replaced. This is THE line that keeps a non-admin member's
        // history: without it, the arrival of a rotated root made every message from the previous
        // epoch undecryptable and the thread rendered empty from that moment on.
        var previousRoots = existingBag?.previousRoots ?? [:]
        if let existingBag, existingBag.currentEpoch != payload.epoch, !existingBag.groupRootEpoch.isEmpty {
            previousRoots[String(existingBag.currentEpoch)] = existingBag.groupRootEpoch
        }
        let bag = GroupBag(
            groupId: payload.groupId,
            groupSeed: recoveredSeedHex ?? existingBag?.groupSeed,
            groupRootEpoch: payload.groupRootEpoch,
            blindingKey: payload.blindingKey,
            currentEpoch: payload.epoch,
            deviceId: deviceId,
            msgCounter: preservedCounter,
            // A recovered admin group already has its recovery invite on chain for this epoch.
            selfInviteEpoch: recoveredSeedHex != nil ? payload.epoch : existingBag?.selfInviteEpoch,
            previousRoots: previousRoots.isEmpty ? nil : previousRoots
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
        if let prev = previousRosterForDiff {
            insertMembershipSystemMessages(groupId: group.id, oldMembers: prev, newMembers: members)
        }
        // Rename line for members (the admin emits its own in renameGroup); "You" on the admin's
        // own other devices.
        if let previous = previousGroupForDiff, previous.name != group.name {
            let who = group.isAdmin ? "You" : groupMemberLabel(group.adminAddress, fallback: nil)
            insertGroupSystemLine(group.id, "\(who) changed the group name to \"\(group.name)\"")
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

        // Backfill recovery invites for any admin group that lacks one for its current epoch —
        // i.e. every group created before this feature existed. One-time per group per epoch;
        // once on chain, a seedless import of this wallet rediscovers the group with no backup.
        if let privateKey = WalletManager.shared.getPrivateKey() {
            for group in groups where group.isAdmin {
                guard let bag = try? keychain.loadGroupBag(groupId: group.id),
                      bag.groupSeed != nil, bag.selfInviteEpoch != bag.currentEpoch else { continue }
                try? await sendSelfRootControlMessage(group: group, bag: bag, privateKey: privateKey)
            }
        }
        // Backfill delete markers for groups deleted while offline (or whose publish failed).
        let tombState = loadTombstoneState()
        for groupId in tombState.deleted where !tombState.published.contains(groupId) {
            try? await publishGroupTombstone(groupId)
        }

        await catchUpGroupControlByRecipient(recipientAddress: wallet.publicAddress)

        // Pass 1 - CONTROL first. gctl carries epoch advances + the new epoch's root (and roster
        // changes). A non-admin who was offline when the admin added/removed a member holds no root
        // for the new epoch, so any message sent at that epoch would be rejected ("no root for
        // epoch") AND its catch-up cursor would advance past it, losing it permanently. Ingesting
        // control before messages guarantees we hold the latest root/roster before decrypting.
        for group in groups where !group.adminAddress.isEmpty {
            await catchUpGroupControl(adminAddress: group.adminAddress)
        }

        // Pass 2 - MESSAGES. Re-read `groups` (control catch-up above may have changed rosters/epoch)
        // so newly-added members are queried too and the current-epoch root is available.
        for group in groups {
            guard let bag = try? keychain.loadGroupBag(groupId: group.id),
                  let blindingKey = Data(hexString: bag.blindingKey) else { continue }

            for member in group.members {
                guard let memberPubKey = Data(hexString: member.xOnlyPubKeyHex) else { continue }
                let blindedGroupId = GroupCipher.deriveBlindedGroupId(blindingKey: blindingKey, memberXOnlyPubKey: memberPubKey)
                await catchUpGroupMessages(groupId: group.id, blindedGroupIdHex: blindedGroupId.hexString)
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
                handleIncomingControlMessage(payloadString, senderAddress: msg.sender, blockTime: msg.blockTime)
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
                handleIncomingControlMessage(payloadString, senderAddress: msg.sender, blockTime: msg.blockTime)
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
