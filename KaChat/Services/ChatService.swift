import Foundation
import Combine
import UIKit
import UserNotifications
import CryptoKit

/// RPC connection status for the status indicator
enum RpcConnectionStatus {
    case connected      // UTXO subscription confirmed (green)
    case connecting     // Connection is being established (orange)
    case disconnected   // Not connected (red)

    var color: String {
        switch self {
        case .connected: return "green"
        case .connecting: return "orange"
        case .disconnected: return "red"
        }
    }

    var description: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        }
    }
}

enum CatchUpSyncTrigger: String {
    case appActive = "app-active"
    case subscriptionRestart = "subscription-restart"
    case rpcSubscriptionsRestored = "rpc-subscriptions-restored"
    case pushMarkedUnreliable = "push-marked-unreliable"
}

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published var conversations: [Conversation] = [] {
        didSet {
            scheduleBadgeUpdate()
        }
    }
    @Published var isLoading = false
    @Published var error: KasiaError?
    @Published var declinedContacts: Set<String> = []
    var settingsViewModel: SettingsViewModel?
    var cachedSettings = SettingsViewModel.loadSettings()
    @Published var activeConversationAddress: String?
    enum ChatFetchState {
        case loading
        case failed
    }
    @Published var chatFetchStates: [String: ChatFetchState] = [:]

    enum ContactFetchResult {
        case success(added: Bool)
        case failure
    }

    var chatFetchCounts: [String: Int] = [:]
    var chatFetchFailed: Set<String> = []

    /// Pending navigation from notification tap (used when app launches from terminated state)
    @Published var pendingChatNavigation: String?

    // Connection status properties
    @Published var isRpcSubscribed = false
    @Published var lastSuccessfulSyncDate: Date?
    @Published var currentConnectedNode: String?
    @Published var currentNodeLatencyMs: Int?

    struct QueuedUtxoNotification {
        let parsed: ParsedUtxosChangedNotification
        let txIds: Set<String>
    }

    enum OutgoingAttemptPhase {
        case queued
        case submitting
        case submitted
        case failed
    }

    struct OutgoingTxAttempt {
        let messageId: UUID
        let pendingTxId: String
        let contactAddress: String
        let messageType: ChatMessage.MessageType
        var txId: String?
        var phase: OutgoingAttemptPhase
        var updatedAt: Date
    }

    struct SyncObjectCursor: Codable {
        var lastFetchedBlockTime: UInt64
    }

    enum PushReliabilityState: String {
        case disabled
        case unknown
        case reliable
        case unreliable
    }

    struct PendingPushObservation {
        let txId: String
        let senderAddress: String
        let observedAt: Date
    }

    struct KNSTransferChatHint {
        let txId: String
        let domainName: String
        let domainId: String
        let counterpartyAddress: String
        let isOutgoing: Bool
        let timestampMs: UInt64
    }

    /// Computed connection status based on node subscription state
    var connectionStatus: RpcConnectionStatus {
        let nodePoolState = NodePoolService.shared.subscriptionState
        switch nodePoolState {
        case .subscribed:
            return .connected
        case .connecting, .failover:
            return .connecting
        case .disconnected, .failed:
            break
        }
        if isRpcSubscribed {
            return .connected
        }
        return .disconnected
    }

    let apiClient = KasiaAPIClient.shared
    let contactsManager = ContactsManager.shared
    let userDefaults = UserDefaults.standard
    let messageStore = MessageStore.shared
    var messageSyncTask: Task<Void, Never>?
    var messageStoreReloadTask: Task<Void, Never>?
    var messageStoreReloadPending = false
    var lastMessageStoreReloadAt: Date = .distantPast
#if targetEnvironment(macCatalyst)
    let messageStoreReloadMinInterval: TimeInterval = 2.5
#else
    let messageStoreReloadMinInterval: TimeInterval = 1.0
#endif
    // Keep only a recent in-memory slice per conversation by default.
    // Older pages are loaded on demand in ChatDetailView.
    let inMemoryConversationWindowSize = 160
    struct PendingOutgoingRef {
        let txId: String
        let messageType: ChatMessage.MessageType
        let timestamp: Date
    }
    var pendingOutgoingQueue: [String: [PendingOutgoingRef]] = [:]
    var olderHistoryPageTasks: [String: Task<Int, Never>] = [:]
    var olderHistoryExhaustedContacts: Set<String> = []
    var needsMessageStoreSyncAfterBatch = false
    var lastMessageStoreSyncScheduledAt: Date?
    let messageStoreSyncMinInterval: TimeInterval = 5.0
    var dirtyConversationAddresses = Set<String>()
    var lastFullStoreMaintenanceAt: Date = .distantPast
    let fullStoreMaintenanceInterval: TimeInterval = 600
    var pendingCloudKitExport = false
    var remoteChangeObserver: NSObjectProtocol?
    var cloudRefreshTimer: Timer?
    var legacyMigrationScheduled = false
    var cloudKitImportFirstAttemptAt: [String: Date] = [:]
    var cloudKitImportLastObservedAt: [String: Date] = [:]
    var cloudKitImportRetryTokenByTxId: [String: UUID] = [:]
    let cloudKitImportMaxWaitSeconds: TimeInterval = 180
    var resolveRetryCounts: [String: Int] = [:]
    var resolveRetryTasks: [String: Task<Void, Never>] = [:]
    var incomingResolutionPendingTxIds = Set<String>()
    var incomingResolutionWarningTxIds = Set<String>()
    var incomingResolutionAmountHints: [String: UInt64] = [:]
    var hiddenPaymentTxIdTimestamps: [String: UInt64] = [:]
    var knsTransferHintsByTxId: [String: KNSTransferChatHint] = [:]
    let incomingResolutionMaxAdditionalRetries = 10
    let incomingResolutionBaseDelayNs: UInt64 = 2_000_000_000
    let incomingResolutionMaxDelayNs: UInt64 = 300_000_000_000
    let hiddenPaymentTxMaxAgeMs: UInt64 = 30 * 24 * 60 * 60 * 1000
    var selfStashRetryCounts: [String: Int] = [:]
    var selfStashFirstAttemptAt: [String: Date] = [:]
    var mempoolResolveInFlight = Set<String>()
    var mempoolResolvedTxIds = Set<String>()
    var mempoolPayloadByTxId: [String: String] = [:]
    var contextualFetchInFlight = Set<String>()
    var handshakeFetchTasks: [String: Task<[HandshakeResponse], Error>] = [:]
    var paymentFetchTasks: [String: Task<[PaymentResponse], Error>] = [:]
    let messagesKey = "kachat_messages"
    let draftsKey = "kachat_message_drafts"
    let aliasesKey = "kachat_conversation_aliases"
    let ourAliasesKey = "kachat_our_aliases"
    let conversationPrimaryAliasesKey = "kachat_conversation_aliases_primary"
    let ourPrimaryAliasesKey = "kachat_our_aliases_primary"
    let conversationAliasUpdatedAtKey = "kachat_conversation_aliases_updated_at"
    let ourAliasUpdatedAtKey = "kachat_our_aliases_updated_at"
    let conversationIdsKey = "kachat_conversation_ids"
    let declinedContactsKey = "kachat_declined_contacts"
    let lastPollTimeKey = "kachat_last_poll_time"
    let syncCursorsKey = "kachat_sync_object_cursors"
    let pendingSelfStashKey = "kachat_pending_self_stash"
    let routingStatesKey = "kachat_routing_states"
    let deterministicMigrationDoneKey = "kachat_deterministic_migration_done"
    let pushReliabilityStateKey = "kachat_push_reliability_state"
    let pushConsecutiveMissesKey = "kachat_push_consecutive_misses"
    let pushLastCatchUpSyncAtKey = "kachat_push_last_catchup_sync_at"
    let pushLastReregisterAtKey = "kachat_push_last_reregister_at"
    let hiddenPaymentTxIdsKey = "kachat_hidden_payment_tx_ids_v1"
    let syncReorgBufferMs: UInt64 = 600_000

    var activeContacts: [Contact] {
        contactsManager.activeContacts
    }

    var currentSettings: AppSettings {
        settingsViewModel?.settings ?? cachedSettings
    }

    /// Delay between syncs when UTXO subscription is inactive (60 seconds after last sync completes)
    let pollDelayAfterSync: TimeInterval = 60.0

    var pollTask: Task<Void, Never>?
    var lastPollTime: UInt64 = 0
    var syncObjectCursors: [String: SyncObjectCursor] = [:]
    var syncObjectCursorsDirty = false
    @Published var isSyncInProgress = false
    var syncMaxBlockTime: UInt64?
    var isConfigured = false
    /// True after startPolling() completes its full initial sync (Phases 1-4).
    /// Prevents redundant heavy re-sync on Mac Catalyst window reopen.
    var hasCompletedInitialSync = false
    var contactsCancellable: AnyCancellable?
    var settingsCancellable: AnyCancellable?
    var pingLatencyCancellable: AnyCancellable?
    var nodePoolSubscriptionStateCancellable: AnyCancellable?
    var nodePoolPrimaryEndpointCancellable: AnyCancellable?

    // UTXO subscription state for real-time payment notifications
    var utxoSubscriptionToken: UUID?
    var isUtxoSubscribed = false {
        didSet {
            isRpcSubscribed = isUtxoSubscribed
            if !isUtxoSubscribed {
                currentConnectedNode = nil
                currentNodeLatencyMs = nil
            }
        }
    }
    var utxoFetchInFlight = false
    var queuedUtxoNotifications: [QueuedUtxoNotification] = []
    var lastPaymentFetchTime: UInt64 = 0

    // Track in-flight resolve operations to prevent duplicates from multiple UTXO notifications
    let inFlightResolveTracker = InFlightResolveTracker()

    // Track if we've ever been subscribed (to detect restarts vs initial setup)
    var hasEverBeenSubscribed = false

    // Track subscribed address count to detect when resubscription is needed
    var lastSubscribedAddressCount = 0
    var lastSubscribedAddresses: Set<String> = []
    var pendingResubscriptionTask: Task<Void, Never>?
    var needsResubscriptionAfterSync = false
    var catchUpSyncInFlight = false

    // Push-channel reliability tracking (UTXO txId -> matching APNs delivery).
    var pushReliabilityState: PushReliabilityState = .disabled
    var pushConsecutiveMisses = 0
    var pendingPushObservations: [String: PendingPushObservation] = [:]
    var pushObservationTasks: [String: Task<Void, Never>] = [:]
    var pushSeenByTxId: [String: Date] = [:]
    var lastCatchUpSyncAt: Date?
    var lastPushReregisterAt: Date?
    let pushObservationGraceInterval: TimeInterval = 60
    let pushLeadMatchTolerance: TimeInterval = 30
    let pushObservationRetention: TimeInterval = 600
    let reliablePushCatchUpDebounce: TimeInterval = 600
    let pushReregisterCooldown: TimeInterval = 600

    var badgeUpdateTask: Task<Void, Never>?
    var pendingLastMessageUpdates: [UUID: Date] = [:]
    var pendingLastMessageUpdateWorkItem: DispatchWorkItem?
    let lastMessageBatchDelay: TimeInterval = 0.8

    // Serialize all outgoing tx sends to avoid UTXO contention/orphan errors.
    var outgoingTxTail: Task<Void, Never>?
    var reservedMessageOutpoints: [String: Date] = [:]
    var pendingMessageUtxos: [String: (utxo: UTXO, expiresAt: Date)] = [:]
    let pendingMessageUtxoTTL: TimeInterval = 120
    var outgoingAttemptsByMessageId: [UUID: OutgoingTxAttempt] = [:]
    var outgoingAttemptByPendingTxId: [String: UUID] = [:]
    var outgoingAttemptByRealTxId: [String: UUID] = [:]
    let outgoingAttemptTTL: TimeInterval = 900
    var scheduledSendRetries = Set<String>()
    var noInputRetryCounts: [String: Int] = [:]
    let spendableFundsRetryAttempts = 5
    let spendableFundsRetryBaseDelay: TimeInterval = 0.1
    var lastMessageCompactionAt: Date = .distantPast
    let messageCompactionCooldown: TimeInterval = 30
    let messageCompactionInputThreshold = 4
    let messageCompactionFeeThresholdSompi: UInt64 = 5_000
    let messageCompactionMaxInputs = 8
    let messageCompactionTargetBurstMessages = 8

    // Spam detection: track irrelevant TX notifications per contact (20+ in 1 minute = noisy)
    var contactTxNotifications: [String: [Date]] = [:]  // address -> timestamps
    var dismissedSpamWarnings: Set<String> = []  // addresses dismissed until app restart
    @Published var noisyContactWarning: NoisyContactWarning?

    // Periodic polling for contacts with realtime updates disabled
    var disabledContactsPollingTask: Task<Void, Never>?
    let disabledContactsPollingInterval: TimeInterval = 60  // 1 minute

    // Suppress notifications during initial sync after wallet import/create
    var suppressNotificationsUntilSynced = false

    // Maps contact address -> their aliases (for fetching their messages TO us)
    var conversationAliases: [String: Set<String>] = [:]
    // Maps contact address -> most recent incoming alias
    var conversationPrimaryAliases: [String: String] = [:]
    var conversationAliasUpdatedAt: [String: UInt64] = [:]
    // Maps contact address -> OUR aliases (for fetching our messages TO them)
    var ourAliases: [String: Set<String>] = [:]
    // Maps contact address -> most recent outgoing alias
    var ourPrimaryAliases: [String: String] = [:]
    var ourAliasUpdatedAt: [String: UInt64] = [:]
    // Deterministic alias routing state per contact
    var routingStates: [String: ConversationRoutingState] = [:]
    // Maps contact address -> conversation id from handshake
    var conversationIds: [String: String] = [:]
    // Drafts keyed by contact address
    var messageDrafts: [String: String] = [:]
    // Pending self-stash jobs that couldn't be sent due to missing UTXOs
    var pendingSelfStash: [PendingSelfStash] = []
    var cachedUtxos: [UTXO] = []
    var cachedUtxosTimestamp: Date?
    let utxoCacheInterval: TimeInterval = 20

    var rpcReconnectObserver: NSObjectProtocol?
    var conversationCountCancellable: AnyCancellable?

    private init() {
        lastPollTime = UInt64(userDefaults.integer(forKey: lastPollTimeKey))
        migrateLegacyMessagesIfNeeded()
        Task { @MainActor [weak self] in
            self?.loadMessagesFromStoreIfNeeded(onlyIfEmpty: true)
        }
        loadMessageDrafts()
        loadConversationAliases()
        loadOurAliases()
        loadConversationIds()
        loadRoutingStates()
        loadSyncObjectCursors()
        loadPendingSelfStash()
        loadDeclinedContacts()
        loadPushReliabilityState()
        loadHiddenPaymentTxIds()
        observeContacts()
        observeSettings()
        observeRpcReconnection()
        observePingLatency()
        observeNodePoolConnectionState()
        observeConversationCount()
        observeRemoteStoreChanges()
        messageStore.applyRetention(SettingsViewModel.loadSettings().messageRetention)
        cloudRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadMessagesFromStoreIfNeeded(onlyIfEmpty: false)
            }
        }
    }

    /// Observe conversation count changes to trigger resubscription when new chats are added
    private func observeConversationCount() {
        conversationCountCancellable = $conversations
            .map { $0.count }
            .removeDuplicates()
            .dropFirst()  // Skip initial value
            .sink { [weak self] _ in
                self?.checkAndResubscribeIfNeeded()
            }
    }

    /// Observe NodePoolService ping latency for real-time latency updates
    private func observePingLatency() {
        pingLatencyCancellable = NodePoolService.shared.$lastPingLatencyMs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latencyMs in
                guard let latency = latencyMs else { return }
                self?.currentNodeLatencyMs = latency
            }
    }

    /// Observe NodePool subscription/primary endpoint as the source of truth for status UI
    private func observeNodePoolConnectionState() {
        nodePoolPrimaryEndpointCancellable = NodePoolService.shared.$primaryEndpoint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] endpoint in
                self?.currentConnectedNode = endpoint?.url
            }

        nodePoolSubscriptionStateCancellable = NodePoolService.shared.$subscriptionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .subscribed:
                    if !self.isUtxoSubscribed {
                        self.isUtxoSubscribed = true
                    }
                case .disconnected, .failed:
                    if self.isUtxoSubscribed {
                        self.isUtxoSubscribed = false
                    }
                case .connecting, .failover:
                    break
                }
            }
    }

    /// Observe RPC reconnection to sync after connection is restored
    var rpcReconnectedObserver: NSObjectProtocol?
    let chatHistoryArchiveVersion = 1

    private func observeRpcReconnection() {
        // Listen for subscription restoration (fetch missed messages)
        rpcReconnectObserver = NotificationCenter.default.addObserver(
            forName: .rpcSubscriptionsRestored,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSLog("[ChatService] RPC subscriptions restored - syncing to catch any missed messages")
            Task { @MainActor in
                await self?.maybeRunCatchUpSync(trigger: .rpcSubscriptionsRestored)
            }
        }

        // Listen for connection restoration (re-subscribe)
        rpcReconnectedObserver = NotificationCenter.default.addObserver(
            forName: .rpcReconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSLog("[ChatService] RPC reconnected - re-subscribing to UTXOs...")
            Task { @MainActor in
                self?.isUtxoSubscribed = false  // Reset subscription state
                await self?.setupUtxoSubscription()
            }
        }
    }

    /// Clear all chat data (called when clearing app data)
    /// - Parameter skipStoreClear: If true, skips calling messageStore.clearAll() (use when store was already cleared)
    func clearAllData(skipStoreClear: Bool = false) {
        stopPolling()
        resetForNewWallet(skipStoreClear: skipStoreClear)
        contactsCancellable?.cancel()
        contactsCancellable = nil
        settingsCancellable?.cancel()
        settingsCancellable = nil
        pingLatencyCancellable?.cancel()
        pingLatencyCancellable = nil
        nodePoolSubscriptionStateCancellable?.cancel()
        nodePoolSubscriptionStateCancellable = nil
        nodePoolPrimaryEndpointCancellable?.cancel()
        nodePoolPrimaryEndpointCancellable = nil
        conversationCountCancellable?.cancel()
        conversationCountCancellable = nil
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = nil
        if let observer = rpcReconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            rpcReconnectObserver = nil
        }
    }

    func wipeIncomingMessagesAndResync() async {
        var updatedConversations = conversations
        for index in updatedConversations.indices {
            updatedConversations[index].messages.removeAll(where: { !$0.isOutgoing })
            updatedConversations[index].unreadCount = 0
        }
        conversations = updatedConversations
        MessageStore.shared.clearIncomingMessages()
        MessageStore.shared.clearDpiCorruptionWarning()
        lastPollTime = 0
        lastPaymentFetchTime = 0
        userDefaults.removeObject(forKey: lastPollTimeKey)
        clearSyncObjectCursors()
        saveMessages()
        await fetchNewMessages(forActiveOnly: nil)
    }

    /// Reset chat state for new/imported wallet - clears data but keeps polling active
    /// - Parameter skipStoreClear: If true, skips calling messageStore.clearAll() (use when switching to a fresh wallet store)
    func resetForNewWallet(skipStoreClear: Bool = false) {
        subscriptionRetryTask?.cancel()
        subscriptionRetryTask = nil
        pendingResubscriptionTask?.cancel()
        pendingResubscriptionTask = nil
        conversations = []
        lastSubscribedAddressCount = 0
        lastSubscribedAddresses = []
        needsResubscriptionAfterSync = false
        conversationAliases = [:]
        conversationPrimaryAliases = [:]
        conversationAliasUpdatedAt = [:]
        ourAliases = [:]
        ourPrimaryAliases = [:]
        ourAliasUpdatedAt = [:]
        conversationIds = [:]
        pendingSelfStash = []
        declinedContacts = []
        lastPollTime = 0
        syncObjectCursors = [:]
        syncObjectCursorsDirty = false
        lastPaymentFetchTime = 0
        isConfigured = false
        isUtxoSubscribed = false
        hasEverBeenSubscribed = false
        cachedUtxos = []
        cachedUtxosTimestamp = nil
        catchUpSyncInFlight = false
        pushReliabilityState = .disabled
        pushConsecutiveMisses = 0
        pendingPushObservations.removeAll()
        for task in pushObservationTasks.values {
            task.cancel()
        }
        pushObservationTasks.removeAll()
        pushSeenByTxId.removeAll()
        lastCatchUpSyncAt = nil
        lastPushReregisterAt = nil
        resolveRetryCounts = [:]
        for (_, task) in resolveRetryTasks {
            task.cancel()
        }
        resolveRetryTasks = [:]
        incomingResolutionPendingTxIds = []
        incomingResolutionWarningTxIds = []
        incomingResolutionAmountHints = [:]
        hiddenPaymentTxIdTimestamps = [:]
        knsTransferHintsByTxId = [:]
        suppressNotificationsUntilSynced = true  // Suppress notifications during initial sync
        hasCompletedInitialSync = false  // Allow full re-sync for new wallet
        userDefaults.removeObject(forKey: lastPollTimeKey)
        userDefaults.removeObject(forKey: syncCursorsKey)
        userDefaults.removeObject(forKey: messagesKey)
        userDefaults.removeObject(forKey: aliasesKey)
        userDefaults.removeObject(forKey: conversationPrimaryAliasesKey)
        userDefaults.removeObject(forKey: conversationAliasUpdatedAtKey)
        userDefaults.removeObject(forKey: ourAliasesKey)
        userDefaults.removeObject(forKey: ourPrimaryAliasesKey)
        userDefaults.removeObject(forKey: ourAliasUpdatedAtKey)
        userDefaults.removeObject(forKey: conversationIdsKey)
        userDefaults.removeObject(forKey: pendingSelfStashKey)
        userDefaults.removeObject(forKey: declinedContactsKey)
        userDefaults.removeObject(forKey: routingStatesKey)
        userDefaults.removeObject(forKey: deterministicMigrationDoneKey)
        userDefaults.removeObject(forKey: pushReliabilityStateKey)
        userDefaults.removeObject(forKey: pushConsecutiveMissesKey)
        userDefaults.removeObject(forKey: pushLastCatchUpSyncAtKey)
        userDefaults.removeObject(forKey: pushLastReregisterAtKey)
        userDefaults.removeObject(forKey: hiddenPaymentTxIdsKey)
        routingStates = [:]
        if !skipStoreClear {
            messageStore.clearAll()
        }
    }

    // MARK: - Public Methods

    /// Start message sync - uses RPC notifications when available, polling as fallback
    /// Start fallback polling loop when UTXO subscription is unavailable
    /// Waits 60 seconds after each sync completes before starting next one
    /// Setup UTXO subscription for real-time payment and message notifications
    /// Task for subscription retry
    var subscriptionRetryTask: Task<Void, Never>?

    /// Debounce state for CloudKit import on remote store change
    var cloudKitImportTimer: Timer?
    var lastCloudKitImportAt: Date?
    var lastLocalSaveAt: Date?
    #if targetEnvironment(macCatalyst)
    let cloudKitImportMinInterval: TimeInterval = 30.0 // Catalyst imports are slower; reduce churn.
    #else
    let cloudKitImportMinInterval: TimeInterval = 10.0
    #endif

}
