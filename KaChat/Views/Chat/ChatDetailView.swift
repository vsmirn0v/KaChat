import SwiftUI
import AVFoundation
import AVFAudio
import PhotosUI
import CoreImage.CIFilterBuiltins
#if canImport(YbridOpus)
import YbridOpus
#endif

/// Holds a weak reference to the raw `UIScrollView` backing a SwiftUI `ScrollView`, resolved via
/// `ScrollViewIntrospector` below - shared by `ChatDetailView` and `GroupChatDetailView` (each
/// keeps its own instance) since both need to drive the real scroll view directly during a
/// keyboard-focus transition, where `ScrollViewProxy.scrollTo` alone doesn't reliably land.
final class ScrollViewReference {
    weak var scrollView: UIScrollView?
}

struct ChatDetailView: View {
    private struct PrependViewportSnapshot {
        let contentHeight: CGFloat
        let offsetY: CGFloat
    }

    @State private var contact: Contact
    @State private var showChatInfo = false
    /// Local-only multi-select for deleting individual messages (never the whole conversation -
    /// see `deleteConversation` for that) - toggled from the toolbar's "Select" button.
    @State private var isSelectingMessages = false
    @State private var selectedMessageIDs: Set<String> = []
    @State private var showDeleteMessagesConfirmation = false
    @State private var reactiveReadMarkPending = false
    @State private var toastMessage: String?
    /// Message whose reactor list is on screen, by txId.
    @State private var reactionsSheetTarget: ReactionsSheetTarget?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var portfolioViewModel = PortfolioViewModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    private var myAddress: String? {
        walletManager.currentWallet?.publicAddress
    }

    /// True only when the chatting-address balance is a CONFIRMED zero - see
    /// `WalletManager.hasConfirmedZeroChattingBalance` (shared with group chats, broadcast
    /// channels, and KaPosts). An unknown/still-loading balance never triggers the gate; it
    /// tears down reactively the moment any refresh/UTXO push reports funds.
    private var isChattingBalanceZero: Bool {
        walletManager.hasConfirmedZeroChattingBalance
    }

    init(contact: Contact, startInPaymentMode: Bool = false) {
        _contact = State(initialValue: contact)
        _inputMode = State(initialValue: startInPaymentMode ? .payment : .message)
    }

    @State private var messageText = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var didInitialScroll = false
    @State private var initialLayoutReady = false
    @State private var loadedMessageCount = 0
    @State private var messagePageSize = 40
    @State private var totalStoredMessages = 0
    @State private var normalizedMessages: [ChatMessage] = []
    /// Rebuilt only when `normalizedMessages` actually changes (see `rebuildMessageSnapshotIfNeeded`),
    /// not on every render - `messageRow` looks this up instead of calling `ChessGameService.summarize`
    /// itself, which replays the whole game and was previously being re-run for every visible chess
    /// row on every keystroke (any `@State` change on this view re-invokes `body`, and `messageRow`
    /// is a plain function inlined into it, not an independently-diffed `View`).
    @State private var chessSummaryCache: [String: ChessGameSummary] = [:]
    /// Presents the time-control picker step between tapping "Play Chess" and actually sending
    /// the invite - see `composerPlusMenu`'s confirmation dialog.
    @State private var showChessTimeControlPicker = false
    @State private var showComposerPlusSheet = false
    @State private var previousMessagesCount = 0
    @State private var lastMessageSnapshotDigest: Int?
    @State private var snapshotRebuildTask: Task<Void, Never>?
    @State private var hasOutgoingHandshakeMessage = false
    @State private var hasIncomingHandshakeMessage = false
    /// "Genuine" = a real message either side actually sent (contextual/audio/payment), not a
    /// handshake and not a failed send. Both flags true == the relationship is established and
    /// the handshake banner has nothing left to warn about.
    @State private var hasGenuineIncomingMessage = false
    @State private var hasGenuineOutgoingMessage = false
    @State private var isLoadingOlderMessages = false
    @State private var lastOlderPageRequestAt: Date = .distantPast
    @State private var topVisibleMessageId: UUID?
    @State private var isBottomAnchorVisible = false
    @State private var isTopAnchorVisible = false
    /// Measured live from `replyBanner`'s own layout (rather than a guessed constant) so the
    /// scroll-to-bottom button's offset above it stays accurate regardless of how many lines the
    /// quoted preview text wraps to - previously a fixed offset, which left the button sitting on
    /// top of the reply banner's own Cancel (X) button whenever a reply was active.
    @State private var replyBannerHeight: CGFloat = 0
    @State private var bottomAnchorVisibilityWorkItem: DispatchWorkItem?
    @State private var topAnchorVisibilityWorkItem: DispatchWorkItem?
    @State private var isUserInteractingWithScroll = false
    @State private var scrollInteractionResetWorkItem: DispatchWorkItem?
    @State private var lastAutoBottomScrollAt: Date = .distantPast
    @State private var newMessagesWhileScrolledUp = 0
    /// While true the ScrollView's default anchor is re-armed to `.bottom` so a history prepend
    /// (window growth at the head) keeps the viewport pinned through the reflow; the rest of the
    /// time the anchor sits at the inert `.top`, so tail appends from the 2s open-chat poll and
    /// the live mirror can never shift a reader who is scrolled up. Mirrors
    /// `GroupChatDetailView.isGrowingHistoryWindow`.
    @State private var isGrowingHistoryWindow = false
    @State private var historyGrowthAnchorReleaseWorkItem: DispatchWorkItem?
    /// The first message currently rendered by the suffix window. `onChange(of: messages.count)`
    /// re-derives `loadedMessageCount` from this id, so the rendered window's START stays pinned
    /// to the same message across data-model changes: new tail messages extend the window
    /// downward (below the viewport, no reflow above), while background prefetch of OLDER pages
    /// stays hidden backlog instead of silently prepending rendered rows.
    @State private var renderedWindowStartMessageId: UUID?
    /// txId (or id fallback) of the newest message the tail-change handler has already acted on.
    /// Snapshot rebuilds can swap the tail's in-memory identity (txId dedup replacing the
    /// optimistic local copy with the store copy) without any new message arriving; keying on
    /// txId keeps replacements from scrolling or bumping the badge.
    @State private var lastSeenTailMessageKey: String?
    @State private var lastHandledTailCount = 0
    @State private var hasLoadedCurrentTopPage = false
    @State private var isPrefetchingOlderMessages = false
    @State private var lastOlderPrefetchAt: Date = .distantPast
    @State private var initialViewportPositioned = false
    @State private var initialScrollAnchorMessageId: UUID?
    @State private var scrollViewReference = ScrollViewReference()
    @State private var pendingPrependViewportSnapshot: PrependViewportSnapshot?
    @State private var storedCountTask: Task<Void, Never>?
    @State private var isRespondingHandshake = false
    @State private var feeEstimateSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var feeEstimateTask: Task<Void, Never>?
    /// User-set fee, from tapping the fee pill - overrides the live estimate for both display
    /// and the actual send, cleared once that send completes (matches Android's `feeRateOverride`
    /// reset-on-send, though Android's is rate-based; this is a flat sompi total - see
    /// KasiaTransactionBuilder.selectUtxosForContextualMessage's `feeOverride` param).
    @State private var feeOverrideSompi: UInt64?
    @State private var showFeeEditor = false
    @State private var feeEditorText = ""
    @State private var revealOffset: CGFloat = 0
    private let maxRevealOffset: CGFloat = 64
    /// Tap-a-reply-quote-to-jump-to-original - mirrors `GroupChatDetailView`/
    /// `BroadcastChannelView`'s identical pair. `pendingJumpToTxId` is set from inside a message
    /// row (no `ScrollViewProxy` in scope there) and consumed by an `.onChange` inside the
    /// `ScrollViewReader` closure, which does have the proxy.
    @State private var pendingJumpToTxId: String?
    /// Which message (if any) currently has its double-tap quick-reaction bar open - shared
    /// across all rows (not per-bubble state) so a single tap-anywhere-to-dismiss gesture on the
    /// message list can close it regardless of which row it belongs to.
    @State private var activeQuickReactionMessageId: UUID?
    @State private var highlightedMessageID: UUID?
    @State private var inputMode: InputMode = .message
    @State private var amountText = ""
    @State private var spendingBalanceSompi: UInt64?
    /// Post-send retry schedule for the Available pill (see scheduleSpendingBalanceRetries).
    @State private var spendingBalanceRetryTask: Task<Void, Never>?
    @State private var recordedAudioURL: URL?
    @State private var recordedAudioPreviewURL: URL?
    @State private var isRecording = false
    @State private var recorder: AVAudioRecorder?
    @State private var recordingTimer: Timer?
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordingFeeSompi: UInt64?
    /// Untouched copy of the recorder's full-length PCM, kept only in Nextcloud mode — the
    /// on-chain WebM/Opus encode truncates to the ~13KB payload cap (≈9s), and exporting the
    /// M4A from that would silently re-cap a long Nextcloud recording.
    @State private var nextcloudOriginalRecordingURL: URL?
    @State private var recordingFeeTask: Task<Void, Never>?
    @State private var feeShimmerPhase: CGFloat = -1
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewTimer: Timer?
    @State private var previewIsPlaying = false
    @State private var previewLabel = "--:--"
    @State private var isEncodingAudio = false
    @State private var recorderDelegate = AudioRecorderDelegate()
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPhotoPickerFromMenu = false
    @State private var showNextcloudPicker = false
    /// Drives the connected-state composer layout: with a Nextcloud server linked, the + menu
    /// drops Send Photo / Send Audio in favor of "Send from Nextcloud", and the message bar
    /// grows camera + mic buttons whose captures ride the Nextcloud auto-upload send path.
    @ObservedObject private var nextcloudService = NextcloudService.shared
    /// Zero-balance gate: the Claim Gift button reflects live claim state (hidden once claimed).
    @ObservedObject private var giftService = GiftService.shared
    @State private var showCamera = false
    @State private var pendingPhotoImage: UIImage?
    /// The exact bytes the pending photo was attached from (picker/camera/paste/drop), kept so
    /// "Send Media via Nextcloud" can upload the untouched original (HEIC/PNG/JPEG, full
    /// resolution) instead of a re-encode of the decoded UIImage. Cleared with the pending photo.
    @State private var pendingPhotoOriginalData: Data?
    @State private var isCompressingPhoto = false
    @State private var hasPerformedInitialSetup = false
    @State private var isImageDropTarget = false
    @State private var isMessageFocused = false
    @State private var showDesktopEmojiPicker = false
    @State private var emojiInsertionRequest: ComposerTextView.TextInsertionRequest?
    @State private var viewportResetTrigger = UUID()
    @State private var showDustWarning = false
    @State private var pendingDustAmountSompi: UInt64 = 0
    @State private var activeChessGameId: String?
    @FocusState private var isPaymentFocused: Bool

    private let maxRecordingDuration: TimeInterval = 10 // seconds (on-chain payload cap)
    /// Nextcloud-uploaded voice notes aren't payload-bound — only the server carries them —
    /// so the ceiling relaxes to 10 minutes while "Send Media via Nextcloud" is active.
    private let maxNextcloudRecordingDuration: TimeInterval = 600

    private var effectiveMaxRecordingDuration: TimeInterval {
        (nextcloudService.isConnected && nextcloudService.mediaSendEnabled)
            ? maxNextcloudRecordingDuration
            : maxRecordingDuration
    }
    private let maxAudioBytes: Int = 13_000
    private let opusBitrate: Int32 = 6_000
    private let opusSampleRate: Double = 48_000

    private var conversation: Conversation? {
        chatService.conversations.first { $0.contact.address == contact.address }
    }

    /// A chat with your own address — never gated by a handshake (it's you).
    private var isSelfChat: Bool {
        contact.address == WalletManager.shared.currentWallet?.publicAddress
    }

    /// A stranger sent a connect request you haven't accepted yet (no outgoing handshake, no genuine
    /// reply, not declined). Until you accept, their non-handshake messages must stay hidden — the
    /// sync-level gate Android/Desktop already have; iOS fetches them, so we gate at display.
    private var awaitingMyAcceptance: Bool {
        !isSelfChat && hasIncomingHandshakeMessage && !hasOutgoingHandshakeMessage && !hasGenuineOutgoingMessage && !isDeclined
    }

    private var messages: [ChatMessage] {
        // "📤 Sent via another device" placeholders never render: they carry no readable
        // content (an outgoing tx from another device whose text hasn't synced), and showing
        // them added noise without information. The records stay in the store, so when
        // CloudKit later delivers the real text the message appears with content.
        let base = normalizedMessages.filter { !$0.isSentPlaceholder }
        // Before you accept a stranger's request, show only the "wants to connect" handshake (and
        // anything you sent) — never their earlier messages.
        guard awaitingMyAcceptance else { return base }
        return base.filter { $0.isOutgoing || $0.messageType == .handshake }
    }

    /// Drives the toolbar's quick-access chess icon - nil hides it entirely. Reuses
    /// `chessSummaryCache` (already rebuilt whenever `messages` changes, see
    /// `rebuildMessageSnapshotIfNeeded`) instead of re-scanning, so this stays cheap even though
    /// it's read on every toolbar re-render.
    private var activeChessGame: ChessGameSummary? {
        chessSummaryCache.values.first { !$0.status.isGameOver }
    }

    private var shouldShowTopPaginationSpinner: Bool {
        isLoadingOlderMessages && initialViewportPositioned && !displayedMessages.isEmpty
    }

    private func messageSnapshotDigest(for source: [ChatMessage]) -> Int {
        var hasher = Hasher()
        hasher.combine(source.count)
        for message in source {
            hasher.combine(message.id)
            hasher.combine(message.txId)
            hasher.combine(message.timestamp.timeIntervalSinceReferenceDate)
            hasher.combine(message.blockTime)
            hasher.combine(message.deliveryStatus.rawValue)
            hasher.combine(message.isOutgoing)
        }
        return hasher.finalize()
    }

    private func scheduleMessageSnapshotRebuild() {
        snapshotRebuildTask?.cancel()
        snapshotRebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            rebuildMessageSnapshotIfNeeded(force: false)
        }
    }

    private func rebuildMessageSnapshotIfNeeded(force: Bool) {
        let source = conversation?.messages ?? []
        let digest = messageSnapshotDigest(for: source)
        if !force, lastMessageSnapshotDigest == digest {
            return
        }
        lastMessageSnapshotDigest = digest

        let sorted = source.sorted(by: isMessageOrderedBefore)
        var byId: [UUID: ChatMessage] = [:]
        for message in sorted {
            if let existing = byId[message.id] {
                if shouldPrefer(message, over: existing) {
                    byId[message.id] = message
                }
            } else {
                byId[message.id] = message
            }
        }

        var byTxId: [String: ChatMessage] = [:]
        for message in byId.values {
            let key = message.txId.isEmpty ? message.id.uuidString : message.txId
            if let existing = byTxId[key] {
                if shouldPrefer(message, over: existing) {
                    byTxId[key] = message
                }
            } else {
                byTxId[key] = message
            }
        }
        let deduped = byTxId.values.sorted(by: isMessageOrderedBefore)
        normalizedMessages = deduped

        if let myAddress {
            let gameIds = Set(deduped.compactMap { ChessCodec.parseAny(MessageReplyCodec.unwrappedText($0.content))?.gameId })
            if gameIds.isEmpty {
                if !chessSummaryCache.isEmpty { chessSummaryCache = [:] }
            } else {
                var updated: [String: ChessGameSummary] = [:]
                for gameId in gameIds {
                    updated[gameId] = ChessGameService.summarize(gameId: gameId, in: deduped, myAddress: myAddress, contactAddress: contact.address)
                }
                chessSummaryCache = updated
            }
        } else if !chessSummaryCache.isEmpty {
            chessSummaryCache = [:]
        }

        hasOutgoingHandshakeMessage = deduped.contains {
            $0.messageType == .handshake && $0.isOutgoing && $0.deliveryStatus != .failed
        }
        hasIncomingHandshakeMessage = deduped.contains {
            $0.messageType == .handshake && !$0.isOutgoing && $0.deliveryStatus != .failed
        }
        hasGenuineIncomingMessage = deduped.contains {
            !$0.isOutgoing && $0.messageType != .handshake && $0.deliveryStatus != .failed
        }
        hasGenuineOutgoingMessage = deduped.contains {
            $0.isOutgoing && $0.messageType != .handshake && $0.deliveryStatus != .failed
        }
    }

    private func isMessageOrderedBefore(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.blockTime != rhs.blockTime {
            return lhs.blockTime < rhs.blockTime
        }
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.id != rhs.id {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.txId < rhs.txId
    }

    private var displayedMessages: [ChatMessage] {
        guard initialLayoutReady else { return [] }
        guard !messages.isEmpty else { return [] }
        if loadedMessageCount <= 0 {
            return Array(messages.suffix(min(initialMessageWindowSize(), messages.count)))
        }
        return Array(messages.suffix(min(loadedMessageCount, messages.count)))
    }

    private var displayedTimelineItems: [ChatTimelineItem] {
        ChatTimelineLayout.items(for: displayedMessages)
    }

    private func shouldPrefer(_ candidate: ChatMessage, over existing: ChatMessage) -> Bool {
        let existingPlaceholder = isPlaceholderContent(existing.content)
        let candidatePlaceholder = isPlaceholderContent(candidate.content)
        if existingPlaceholder != candidatePlaceholder {
            return !candidatePlaceholder
        }
        if existing.deliveryStatus != candidate.deliveryStatus {
            if candidate.deliveryStatus.priority != existing.deliveryStatus.priority {
                return candidate.deliveryStatus.priority > existing.deliveryStatus.priority
            }
        }
        return isMessageOrderedBefore(existing, candidate)
    }

    private func isPlaceholderContent(_ content: String) -> Bool {
        ChatService.isPlaceholderContent(content)
    }

    private var isDeclined: Bool {
        chatService.isConversationDeclined(contact.address)
    }

    /// Cross-platform semantics (matches desktop's `relationshipState == "established"`): both
    /// sides have exchanged at least one genuine, non-handshake message. Until then the recipient
    /// may never see what we send, which is exactly what `handshakeNoticeBanner` explains.
    private var hasEstablishedRelationship: Bool {
        hasGenuineIncomingMessage && hasGenuineOutgoingMessage
    }

    /// Shown from the moment a 1:1 chat opens - deliberately NOT gated on having typed or sent
    /// anything - and retired once the relationship is established OR a handshake FROM them
    /// exists: their handshake (whether accepting ours or initiating their own) proves their
    /// side has the conversation and can see what we send, so waiting for a genuine reply made
    /// the banner outlive a completed handshake. A sent-but-unanswered handshake keeps it up.
    /// Group threads route through `GroupChatDetailView`, so everything here is already 1:1.
    private var shouldShowHandshakeNotice: Bool {
        // `hasPerformedInitialSetup` only defers the decision past the first frame (the message
        // snapshot that feeds the relationship flags is built in `onAppear`), so an established
        // chat never flashes the banner on open.
        hasPerformedInitialSetup && !hasEstablishedRelationship && !hasIncomingHandshakeMessage && !isDeclined
    }

    var body: some View {
        ZStack {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                        ScrollViewIntrospector { scrollView in
                            if scrollViewReference.scrollView !== scrollView {
                                scrollViewReference.scrollView = scrollView
                            }
                        }
                        .frame(height: 0)
                        .allowsHitTesting(false)

                        LazyVStack(spacing: 8) {
                            // Debounced rather than setting `isTopAnchorVisible` directly: this
                            // 1pt marker can appear/disappear many times per second during a fast
                            // scroll/fling as it crosses the lazy-loaded viewport edge, and each
                            // flip was cascading into pagination retries and (for the bottom
                            // anchor below) a full animated transition - rapid-fire enough to pin
                            // the main thread and freeze the app. Coalescing to the settled state
                            // keeps pagination/animation responsive without the storm.
                            Color.clear
                                .frame(height: 1)
                                .id("top_anchor")
                                .onAppear {
                                    topAnchorVisibilityWorkItem?.cancel()
                                    let workItem = DispatchWorkItem {
                                        isTopAnchorVisible = true
                                        triggerTopPaginationIfNeeded(using: proxy)
                                    }
                                    topAnchorVisibilityWorkItem = workItem
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                                }
                                .onDisappear {
                                    topAnchorVisibilityWorkItem?.cancel()
                                    let workItem = DispatchWorkItem {
                                        isTopAnchorVisible = false
                                        hasLoadedCurrentTopPage = false
                                    }
                                    topAnchorVisibilityWorkItem = workItem
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                                }
                            // `displayedTimelineItems` (see `ChatTimelineLayout`) already computes
                            // `displayedMessages` exactly once internally, so day separators are
                            // resolved up front rather than re-checked per row.
                            ForEach(displayedTimelineItems) { item in
                                switch item {
                                case .daySeparator(let day):
                                    daySeparator(day)
                                case .message(let index, let message):
                                    messageRow(message)
                                        .id(message.id)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(highlightedMessageID == message.id ? Color.accentColor.opacity(0.18) : Color.clear)
                                        )
                                        .onAppear {
                                            if index == 0 {
                                                topVisibleMessageId = message.id
                                                triggerTopPaginationIfNeeded(using: proxy)
                                            }
                                            if initialViewportPositioned, index <= nearTopPrefetchThresholdIndex() {
                                                scheduleOlderPrefetchIfNeeded()
                                            }
                                        }
                                        .onDisappear {
                                            if index == 0, topVisibleMessageId == message.id {
                                                topVisibleMessageId = nil
                                                hasLoadedCurrentTopPage = false
                                            }
                                        }
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("bottom_anchor")
                                .onAppear {
                                    bottomAnchorVisibilityWorkItem?.cancel()
                                    let workItem = DispatchWorkItem {
                                        isBottomAnchorVisible = true
                                    }
                                    bottomAnchorVisibilityWorkItem = workItem
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                                }
                                .onDisappear {
                                    bottomAnchorVisibilityWorkItem?.cancel()
                                    let workItem = DispatchWorkItem {
                                        isBottomAnchorVisible = false
                                    }
                                    bottomAnchorVisibilityWorkItem = workItem
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                                }
                        }
                        .padding(.horizontal)
                        .padding(.top)
                    }
                    // .bottom ONLY while the initial viewport is being positioned or a history
                    // prepend is reflowing - the rest of the time the anchor sits at the inert
                    // .top. A permanently-armed .bottom default anchor (the previous state; the
                    // condition was always .bottom in practice) makes iOS 17+ re-anchor the
                    // viewport bottom-relative on EVERY content size change, so each message the
                    // 2s open-chat poll or live mirror appended shifted a scrolled-up reader's
                    // rows by the new row's height - the up/down yanking while reading history.
                    // Mirrors GroupChatDetailView's identical conditional anchor.
                    .defaultScrollAnchorCompat(!initialViewportPositioned || isGrowingHistoryWindow ? .bottom : .top)
                    .opacity(initialViewportPositioned ? 1 : 0)
                    // The header rides above the list as a pinned inset, not as a toolbar item:
                    // a 64pt avatar over a name capsule is far taller than a principal item is
                    // given, which is what was drawing it clipped in the first place.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        // Pulled up into the navigation bar's own row, so the avatar sits level
                        // with the back button and the connection dot rather than starting below
                        // them. The negative top padding is what closes that gap - the bar's
                        // height is fixed, so the header has to reach up into it.
                        chatTitleChip
                            // Reaches up into the navigation bar's row so the avatar sits level
                            // with the back button. Bounded at -52: the inset is measured from
                            // BELOW the safe area, so it can never reach the notch no matter the
                            // device - going further would only eat into the bar's own buttons.
                            .padding(.top, -52)
                            .padding(.bottom, 2)
                            .frame(maxWidth: .infinity)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        // Hosting the compose bar as a real `safeAreaInset` (rather than a
                        // floating ZStack overlay with a manually-tracked keyboard offset) is
                        // what guarantees it always sits flush above the keyboard on every
                        // device - this is the mechanism SwiftUI itself uses for keyboard
                        // avoidance, so there's no custom math to get wrong.
                        VStack(spacing: 0) {
                            if shouldShowHandshakeNotice {
                                // Pinned above the composer (not scrolled away inside the
                                // message list) so it's visible the instant the chat opens,
                                // for as long as the relationship isn't established.
                                handshakeNoticeBanner
                                    .transition(.opacity)
                            }
                            if isChattingBalanceZero {
                                // Zero-balance gate: reading messages above stays fully
                                // usable (the card is part of the bottom inset, never an
                                // overlay on the list) - only composing is blocked.
                                zeroBalanceGateCard
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            inputBar
                                .disabled(isChattingBalanceZero)
                                .allowsHitTesting(!isChattingBalanceZero)
                                .grayscale(isChattingBalanceZero ? 1 : 0)
                                .opacity(isChattingBalanceZero ? 0.45 : 1)
                        }
                        .animation(.easeInOut(duration: 0.25), value: isChattingBalanceZero)
                        .animation(.easeInOut(duration: 0.25), value: shouldShowHandshakeNotice)
                        .padding(.bottom, 2)
                    }
                    .overlay(alignment: .top) {
                        if shouldShowTopPaginationSpinner {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.top, 8)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !isBottomAnchorVisible && initialViewportPositioned {
                            Button {
                                Haptics.impact(.light)
                                scrollToBottom(using: proxy, animated: true)
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Circle()
                                        .fill(.regularMaterial)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                                        )
                                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.primary)
                                        )

                                    if newMessagesWhileScrolledUp > 0 {
                                        Text("\(min(newMessagesWhileScrolledUp, 99))")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.accentColor))
                                            .offset(x: 6, y: -6)
                                    }
                                }
                            }
                            .padding(.trailing, 12)
                            // Base 76pt clears the composer alone; when a reply is active, the
                            // reply banner sits above the composer too, so its live-measured
                            // height (+ the input bar's own 8pt VStack spacing) is added on top -
                            // otherwise this button sits directly on the reply banner's Cancel (X).
                            .padding(.bottom, 76 + (chatService.replyingTo != nil ? replyBannerHeight + 8 : 0))
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .animation(.easeInOut(duration: 0.2), value: isBottomAnchorVisible)
                            .animation(.easeInOut(duration: 0.2), value: chatService.replyingTo != nil)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: pendingJumpToTxId) { txId in
                        guard let txId else { return }
                        jumpToReplyOriginal(txId: txId, using: proxy)
                        pendingJumpToTxId = nil
                    }
                    .onAppear {
                        positionInitialViewport(using: proxy)
                    }
                    .onChange(of: initialLayoutReady) { _ in
                        positionInitialViewport(using: proxy)
                    }
                    .onChange(of: displayedMessages.count) { _ in
                        positionInitialViewport(using: proxy)
                        scheduleOlderPrefetchIfNeeded()
                    }
                    .onChange(of: viewportResetTrigger) { _ in
                        positionInitialViewport(using: proxy)
                    }
                    .onChange(of: messages.last?.id) { _ in
                        let tail = messages.last
                        let tailKey = tail.map { $0.txId.isEmpty ? $0.id.uuidString : $0.txId }
                        let newCount = messages.count
                        let grew = newCount > lastHandledTailCount
                        lastHandledTailCount = newCount
                        guard didInitialScroll else {
                            // First population: positionInitialViewport already jumps to the
                            // bottom instantly (unanimated), so only seed the trackers here.
                            didInitialScroll = true
                            lastSeenTailMessageKey = tailKey
                            return
                        }
                        // Keyed on txId (not in-memory id): snapshot rebuilds can swap the tail's
                        // identity when txId dedup replaces the optimistic local copy with the
                        // store/indexer copy, and that replacement must never scroll or bump the
                        // badge. Requiring growth means deletes never scroll either.
                        let isNewTailMessage = grew && tailKey != lastSeenTailMessageKey
                        lastSeenTailMessageKey = tailKey
                        guard isNewTailMessage, let tail else { return }
                        if tail.isOutgoing && tail.txId.hasPrefix("pending_") {
                            // A send initiated on THIS device: every local send path (message,
                            // audio, payment, handshake) inserts its optimistic row with a
                            // provisional "pending_" txId before broadcast, and provisional ids
                            // never travel through sync or the shared archive (phantom scrub) -
                            // so this is exactly "you just hit send here", and sending implies
                            // returning to now. An own message mirrored in from another device
                            // arrives under its real txId and falls through to the same
                            // near-bottom gate as incoming messages, so it never yanks the
                            // viewport while you're reading history.
                            lastAutoBottomScrollAt = Date()
                            scrollToBottom(using: proxy, animated: true)
                        } else if shouldAutoScrollForArrival() {
                            let now = Date()
                            if now.timeIntervalSince(lastAutoBottomScrollAt) > 0.12 {
                                lastAutoBottomScrollAt = now
                                scrollToBottom(using: proxy, animated: true)
                            }
                        } else {
                            newMessagesWhileScrolledUp += 1
                        }
                    }
                    .onChange(of: isBottomAnchorVisible) { visible in
                        if visible {
                            newMessagesWhileScrolledUp = 0
                            hasLoadedCurrentTopPage = false
                        }
                    }
                    .onChange(of: isMessageFocused) { focused in
                        if focused {
                            pinToBottomThroughKeyboardTransition()
                        }
                    }
                    .onChange(of: isPaymentFocused) { focused in
                        if focused {
                            pinToBottomThroughKeyboardTransition()
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { _ in
                                markUserScrollInteractionBegan()
                            }
                            .onEnded { _ in
                                markUserScrollInteractionEndedSoon()
                            }
                    )
                    .simultaneousGesture(
                        // Swipe-left-to-reveal-timestamps (iMessage-style, matches broadcast
                        // rooms): dragging left shifts every message row left together,
                        // uncovering each message's time; releasing snaps back. Only engages for
                        // mostly-horizontal drags so vertical scrolling is unaffected.
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                revealOffset = min(max(value.translation.width, -maxRevealOffset), 0)
                            }
                            .onEnded { _ in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    revealOffset = 0
                                }
                            }
                    )
                    .simultaneousGesture(
                        // Tapping anywhere in the message list dismisses whichever bubble's
                        // quick-reaction bar is currently open, same as tapping outside a menu
                        // elsewhere in this app dismisses it - runs alongside (not instead of)
                        // whatever else that tap does, since this is a `simultaneousGesture`.
                        TapGesture().onEnded {
                            if activeQuickReactionMessageId != nil {
                                activeQuickReactionMessageId = nil
                            }
                        }
                    )
            }
        }
        .onDrop(
            of: ChatImageAttachmentLoader.supportedDropTypeIdentifiers,
            isTargeted: $isImageDropTarget,
            perform: handleImageDrop
        )
        .toast(message: toastMessage, style: toastStyle)
        // Reactive read-marking: the once-at-appear mark silently no-ops when a notification
        // tap opens this chat BEFORE the conversation has loaded (cold start / mid-catch-up),
        // leaving the badge stuck. Whenever unread is nonzero while this chat is open, clear
        // it - covers late loads, catch-up bumps, and CloudKit merges alike.
        .onChange(of: conversation?.unreadCount ?? 0) { count in
            // DEBOUNCED: catch-up sync can bump unread once per arriving message - marking
            // read per bump (store fetch + CloudKit read-status + notification sweep each
            // time) stormed the main thread into a ~1min hang on resume. One mark after the
            // burst quiets down.
            guard count > 0, conversation != nil, !reactiveReadMarkPending else { return }
            reactiveReadMarkPending = true
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                reactiveReadMarkPending = false
                if let current = conversation, current.unreadCount > 0 {
                    await chatService.markConversationAsRead(current)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ConnectionStatusIndicator()
            }

            if let activeChessGame, !isSelectingMessages {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        activeChessGameId = activeChessGame.gameId
                    } label: {
                        Image(systemName: "checkerboard.rectangle")
                            .font(.caption)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.secondary.opacity(0.15)))
                    }
                    .accessibilityLabel(Text("Open active chess game"))
                }
            }
            // Entry point into select mode is a message's long-press "Select" menu item (see
            // `enterSelectMode(with:)`), not a toolbar button - this only ever shows Cancel/Delete
            // once already selecting.
            if isSelectingMessages {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button("Cancel") {
                            isSelectingMessages = false
                            selectedMessageIDs = []
                        }
                        Button {
                            showDeleteMessagesConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                        .disabled(selectedMessageIDs.isEmpty)
                    }
                }
            }
        }
        .alert(
            deleteMessagesAlertTitle,
            isPresented: $showDeleteMessagesConfirmation
        ) {
            Button("Delete", role: .destructive) {
                chatService.deleteMessages(selectedMessageIDs, from: contact)
                isSelectingMessages = false
                selectedMessageIDs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only deletes the message from this device - the recipient still has their own copy, and the encrypted transaction remains permanently on the Kaspa blockchain, visible to anyone but unreadable without your keys. This cannot be undone.")
        }
        .sheet(item: $reactionsSheetTarget) { target in
            // In a 1:1 chat there are only ever two people, so the name is either yours or
            // theirs - no roster lookup needed.
            ReactionsSheet(
                entries: (chatService.reactionsByTxId[target.txId] ?? [])
                    .map { ReactionsSheet.Entry(emoji: $0.emoji, reactorAddress: $0.reactorAddress) },
                myAddress: walletManager.currentWallet?.publicAddress ?? "",
                displayName: { _ in contact.alias },
                avatarURL: { knsService.profileCache[$0]?.avatarURL }
            )
        }
        .sheet(isPresented: $showChatInfo) {
            ChatInfoView(contact: $contact)
                .environmentObject(contactsManager)
        }
        .fullScreenCover(isPresented: Binding(
            get: { activeChessGameId != nil },
            set: { if !$0 { activeChessGameId = nil } }
        )) {
            if let activeChessGameId {
                ChessGameView(gameId: activeChessGameId, contact: contact)
                    .environmentObject(chatService)
                    .environmentObject(walletManager)
            }
        }
        .alert("Failed to Send", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            if let error = error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .font(.body)

                    if shouldShowRetryHint(for: error) {
                        Text("Please check your network connection and try again.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .confirmationDialog("Small Amount", isPresented: $showDustWarning, titleVisibility: .visible) {
            Button("Send Anyway") {
                executePayment(amountSompi: pendingDustAmountSompi)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sending less than 0.1 KAS may fail due to the network dust protection limit.")
        }
        .alert("Adjust Network Fee", isPresented: $showFeeEditor) {
            TextField("Fee (KAS)", text: $feeEditorText)
                .keyboardType(.decimalPad)
                .numericKeyboardDoneButton()
            Button("Save") { commitFeeOverride() }
            Button("Use Default") {
                feeOverrideSompi = nil
                scheduleFeeEstimate(for: messageText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the network is busy, a higher fee can help your transaction confirm faster.")
        }
        .onChange(of: amountText) { newValue in
            schedulePaymentFee(for: newValue)
        }
        .onAppear {
            if !hasPerformedInitialSetup {
                // Full setup on first appearance (fresh navigation push)
                initialLayoutReady = false
                topVisibleMessageId = nil
                isBottomAnchorVisible = false
                isTopAnchorVisible = false
                isUserInteractingWithScroll = false
                scrollInteractionResetWorkItem?.cancel()
                lastAutoBottomScrollAt = .distantPast
                hasLoadedCurrentTopPage = false
                newMessagesWhileScrolledUp = 0
                isPrefetchingOlderMessages = false
                lastOlderPrefetchAt = .distantPast
                initialViewportPositioned = false
                initialScrollAnchorMessageId = nil
                pendingPrependViewportSnapshot = nil
                historyGrowthAnchorReleaseWorkItem?.cancel()
                isGrowingHistoryWindow = false
                renderedWindowStartMessageId = nil
                lastSeenTailMessageKey = nil
                lastHandledTailCount = 0
                rebuildMessageSnapshotIfNeeded(force: true)
                configureInitialMessageWindow()
                initialLayoutReady = true
                didInitialScroll = false
                hasPerformedInitialSetup = true
            }
            chatService.enterConversation(for: contact.address)
            if messageText.isEmpty {
                messageText = chatService.draft(for: contact.address)
            }
            attachPendingShareImageIfAvailable(for: contact.address)
            previousMessagesCount = messages.count
            // Mark conversation as read once when view appears
            if let conversation = conversation {
                Task {
                    await chatService.markConversationAsRead(conversation)
                }
            }
            Task {
                await contactsManager.refreshBalance(for: contact.address)
            }
        }
        .onChange(of: conversation?.messages) { _ in
            scheduleMessageSnapshotRebuild()
            if !initialLayoutReady {
                configureInitialMessageWindow()
                initialLayoutReady = true
            }
        }
        .onDisappear {
            chatService.leaveConversation()
            chatService.cancelReply()
            cancelRecording()
            snapshotRebuildTask?.cancel()
            storedCountTask?.cancel()
            scrollInteractionResetWorkItem?.cancel()
            pendingPrependViewportSnapshot = nil
            // Do NOT reset viewport/scroll state here — @State is destroyed
            // automatically on navigation pop, and on tab switches we want
            // to preserve the scroll position and loaded message count.
        }
        .onChange(of: chatService.replyingTo) { newValue in
            scheduleFeeEstimate(for: messageText)
            if newValue == nil {
                replyBannerHeight = 0
            }
        }
        .task(id: myAddress) {
            // Matches broadcast rooms' room-level own-avatar fetch - resolves regardless of who's
            // messaged, since it's always needed for our own outgoing bubbles.
            guard let myAddress, knsService.profileCache[myAddress] == nil else { return }
            _ = await knsService.fetchProfile(for: myAddress)
        }
        .task(id: inputMode) {
            // Payments spend from the current spending (primary) address, not the chatting
            // address - the "Available" bubble shown while composing a payment should match,
            // not the identity wallet's own balance.
            guard inputMode == .payment else { return }
            await loadSpendingBalance()
        }
        .task(id: walletManager.currentWallet?.spendingAddressIndex) {
            // Live re-fetch when the PRIMARY spending address changes while composing - e.g.
            // "Set as Primary Address" inside the Manage Addresses sheet opened from the
            // Available bubble. setActiveSpendingAddress republishes currentWallet with the new
            // spendingAddressIndex, which re-keys this task; without it the bubble kept showing
            // the old primary's balance until payment mode was re-entered or a send completed.
            guard inputMode == .payment else { return }
            await loadSpendingBalance()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ownAddressUtxoActivity)) { notification in
            // Change landing on the (possibly just-rotated) primary spending address. This is
            // the always-post event - the user-notification path deliberately suppresses
            // self-send change, which is exactly what a private-mode payment's rotation
            // produces, so without this the pill sat at 0 until payment mode was re-entered.
            guard inputMode == .payment else { return }
            guard let involved = notification.userInfo?[AddressActivityNotifier.utxoActivityAddressesKey] as? [String],
                  let primary = walletManager.currentSpendingAddress(),
                  involved.contains(primary) else { return }
            Task { await loadSpendingBalance() }
        }
        .task(id: contact.address) {
            guard knsService.profileCache[contact.address] == nil else { return }
            _ = await knsService.fetchProfile(for: contact.address)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { notification in
            guard let targetAddress = notification.userInfo?["contactAddress"] as? String else { return }
            if targetAddress == contact.address {
                // Share-sheet handoff into the chat that's already open: refresh the composer
                // pre-fill in place (the draft was just written by the share intake) and attach
                // any staged shared image.
                let draft = chatService.draft(for: contact.address)
                if !draft.isEmpty && draft != messageText {
                    messageText = draft
                }
                attachPendingShareImageIfAvailable(for: contact.address)
                chatService.pendingChatNavigation = nil
                return
            }
            let startInPaymentMode = notification.userInfo?["paymentMode"] as? Bool ?? false
            // Find the target contact
            let target: Contact?
            if let c = contactsManager.contacts.first(where: { $0.address == targetAddress }) {
                target = c
            } else if let conv = chatService.conversations.first(where: { $0.contact.address == targetAddress }) {
                target = conv.contact
            } else {
                target = nil
            }
            guard let newContact = target else { return }
            // Dismiss any active sheet/fullScreenCover before swapping contacts - this view
            // instance is reused in place (no `.id()`, to preserve scroll position) rather than
            // torn down and rebuilt, so a still-presented modal whose content is scoped to the
            // OLD contact (chess chief among them - its gameId won't exist in the new contact's
            // conversation, so `ChessGameView` would spin on a `nil` summary forever) would
            // otherwise stay stuck on screen, silently swallowing this navigation.
            activeChessGameId = nil
            showChatInfo = false
            showFeeEditor = false
            showDustWarning = false
            showCamera = false
            // Tear down current conversation (same as onDisappear)
            chatService.setDraft(messageText, for: contact.address)
            chatService.leaveConversation()
            cancelRecording()
            snapshotRebuildTask?.cancel()
            storedCountTask?.cancel()
            feeEstimateTask?.cancel()
            recordingFeeTask?.cancel()
            scrollInteractionResetWorkItem?.cancel()
            pendingPrependViewportSnapshot = nil
            clearFeeEstimationState()
            chatService.pendingChatNavigation = nil
            // Swap contact in-place and rebuild synchronously.
            // initialViewportPositioned is set to false so
            // positionInitialViewport will scroll and reveal content.
            // viewportResetTrigger fires onChange inside ScrollViewReader
            // to call positionInitialViewport with the proxy.
            contact = newContact
            messageText = ""
            inputMode = startInPaymentMode ? .payment : .message
            amountText = ""
            fiatAmountState.reset()
            initialViewportPositioned = false
            didInitialScroll = false
            topVisibleMessageId = nil
            isBottomAnchorVisible = true
            isTopAnchorVisible = false
            isUserInteractingWithScroll = false
            lastAutoBottomScrollAt = .distantPast
            hasLoadedCurrentTopPage = false
            newMessagesWhileScrolledUp = 0
            isPrefetchingOlderMessages = false
            lastOlderPrefetchAt = .distantPast
            initialScrollAnchorMessageId = nil
            lastMessageSnapshotDigest = nil
            totalStoredMessages = 0
            historyGrowthAnchorReleaseWorkItem?.cancel()
            isGrowingHistoryWindow = false
            renderedWindowStartMessageId = nil
            lastSeenTailMessageKey = nil
            lastHandledTailCount = 0
            rebuildMessageSnapshotIfNeeded(force: true)
            configureInitialMessageWindow()
            previousMessagesCount = messages.count
            chatService.enterConversation(for: newContact.address)
            messageText = chatService.draft(for: newContact.address)
            attachPendingShareImageIfAvailable(for: newContact.address)
            if let conv = chatService.conversations.first(where: { $0.contact.address == newContact.address }) {
                Task {
                    await chatService.markConversationAsRead(conv)
                }
            }
            viewportResetTrigger = UUID()
            Task {
                await contactsManager.refreshBalance(for: newContact.address)
            }
        }
        .onChange(of: messages.count) { newCount in
            let oldCount = previousMessagesCount
            previousMessagesCount = newCount
            // A delete shrinks the array without moving the tail id; clamp the tail-change
            // handler's growth tracker so the NEXT genuine arrival still registers as growth.
            if newCount < lastHandledTailCount {
                lastHandledTailCount = newCount
            }
            totalStoredMessages = max(totalStoredMessages, messages.count)
            if initialViewportPositioned, newCount > oldCount {
                // Pin the rendered window's START to the same message across data-model growth.
                // The previous grow-by-delta treated EVERY count increase as tail growth, so a
                // background prefetch of OLDER history (which is supposed to stay hidden
                // backlog) silently prepended its whole page into the rendered window with no
                // viewport restore - and, because the backlog then never accumulated, prefetch
                // kept fetching page after page while the user was scrolled up, reflowing the
                // rows they were reading in a loop. Re-deriving loadedMessageCount from the
                // pinned start id handles both directions correctly: tail arrivals extend the
                // window downward (newest message always rendered), head prepends stay hidden.
                if let startId = renderedWindowStartMessageId,
                   let startIndex = messages.firstIndex(where: { $0.id == startId }) {
                    loadedMessageCount = min(
                        max(messages.count - startIndex, messagePageSize),
                        messages.count
                    )
                } else {
                    // Start id unknown or replaced by dedup - fall back to grow-by-delta so the
                    // tail stays covered, then re-pin below.
                    loadedMessageCount = min(
                        max(loadedMessageCount + (newCount - oldCount), messagePageSize),
                        max(newCount, messagePageSize)
                    )
                }
            }
            if loadedMessageCount == 0 {
                configureInitialMessageWindow()
            } else {
                loadedMessageCount = min(max(loadedMessageCount, messagePageSize), max(messages.count, messagePageSize))
                rememberRenderedWindowStart()
                refreshStoredMessageCountAsync()
            }
        }
    }

    private func initialMessageWindowSize() -> Int {
        let rowsPerScreen = max(12, Int(UIScreen.main.bounds.height / 68.0))
        return max(24, Int(Double(rowsPerScreen) * 1.5))
    }

    private func configuredMessagePageSize() -> Int {
        let base = max(20, Int(UIScreen.main.bounds.height / 68.0))
        // Larger page to reduce visible pagination churn while scrolling older history.
        return max(24, Int(ceil(Double(base) * 1.3)))
    }

    private func olderHistoryBatchSize() -> Int {
        // Larger burst for smoother continuous upward scrolling.
        max(messagePageSize * 3, 1)
    }

    private func nearTopPrefetchThresholdIndex() -> Int {
        let count = displayedMessages.count
        guard count > 0 else { return 0 }
        return min(max(12, Int(Double(messagePageSize) * 0.9)), count - 1)
    }

    /// Always opens at the bottom (most recent message) rather than resuming at the first unread
    /// message - anchoring to a read cursor meant a new message arriving mid-conversation could
    /// silently open the chat scrolled up into older history instead of showing the newest
    /// content immediately, which was more confusing than helpful.
    private func configureInitialMessageWindow() {
        messagePageSize = configuredMessagePageSize()
        let targetWindow = max(initialMessageWindowSize(), messagePageSize)
        loadedMessageCount = min(messages.count, targetWindow)
        rememberRenderedWindowStart()
        initialScrollAnchorMessageId = nil
        totalStoredMessages = max(totalStoredMessages, messages.count)
        refreshStoredMessageCountAsync()
    }

    private func positionInitialViewport(using proxy: ScrollViewProxy) {
        guard initialLayoutReady else { return }
        guard !initialViewportPositioned else { return }
        guard !displayedMessages.isEmpty else { return }

        let targetMessageId: UUID? = {
            if let anchorMessageId = initialScrollAnchorMessageId,
               displayedMessages.contains(where: { $0.id == anchorMessageId }) {
                return anchorMessageId
            }
            return nil
        }()
        let anchor: UnitPoint = targetMessageId == nil ? .bottom : .top

        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                if let targetMessageId {
                    proxy.scrollTo(targetMessageId, anchor: anchor)
                } else {
                    proxy.scrollTo("bottom_anchor", anchor: anchor)
                }
            }
            hasLoadedCurrentTopPage = false
            initialViewportPositioned = true
        }
    }

    private func triggerTopPaginationIfNeeded(using proxy: ScrollViewProxy) {
        guard initialViewportPositioned else { return }
        guard isTopAnchorVisible else { return }
        guard !hasLoadedCurrentTopPage else { return }
        hasLoadedCurrentTopPage = true
        let started = loadMoreMessagesPage(using: proxy)
        if !started {
            hasLoadedCurrentTopPage = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                triggerTopPaginationIfNeeded(using: proxy)
            }
        }
    }

    private func markUserScrollInteractionBegan() {
        scrollInteractionResetWorkItem?.cancel()
        isUserInteractingWithScroll = true
    }

    private func markUserScrollInteractionEndedSoon() {
        scrollInteractionResetWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            isUserInteractingWithScroll = false
        }
        scrollInteractionResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    /// Re-pins `renderedWindowStartMessageId` to the first message of the current suffix window.
    /// Derived from `messages` directly (not `displayedMessages`) so it also works before
    /// `initialLayoutReady`.
    private func rememberRenderedWindowStart() {
        guard loadedMessageCount > 0, !messages.isEmpty else {
            renderedWindowStartMessageId = nil
            return
        }
        let startIndex = max(0, messages.count - loadedMessageCount)
        renderedWindowStartMessageId = messages[startIndex].id
    }

    /// Re-arms the `.bottom` default anchor for the duration of a history-window growth so the
    /// prepend reflow keeps the viewport pinned (SwiftUI holds the bottom-relative offset), then
    /// releases back to the inert `.top`. The release is a cancellable work item so back-to-back
    /// pagination bursts keep the anchor armed continuously instead of dropping it mid-growth.
    private func armHistoryGrowthAnchor() {
        historyGrowthAnchorReleaseWorkItem?.cancel()
        isGrowingHistoryWindow = true
        let workItem = DispatchWorkItem {
            isGrowingHistoryWindow = false
        }
        historyGrowthAnchorReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Whether the reader's viewport bottom is within about one bubble row of the newest content.
    /// Read straight off the introspected UIScrollView, so at tail-arrival time this measures the
    /// PRE-insert baseline (the new row hasn't been laid out yet) - a reader pinned to the end
    /// keeps passing this gate through a multi-message catch-up batch.
    private func isNearBottomOfContent() -> Bool {
        guard let scrollView = scrollViewReference.scrollView else {
            // No geometry yet - fall back to the debounced bottom-anchor marker.
            return isBottomAnchorVisible
        }
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height
            - scrollView.adjustedContentInset.bottom
        let distanceFromBottom = scrollView.contentSize.height - visibleBottom
        return distanceFromBottom <= 120
    }

    /// At-bottom gate for an ARRIVING message (incoming, or an own message mirrored in from
    /// another device): auto-scroll only when the reader is effectively at the end and not
    /// actively touching the list. A reading position anywhere above stays rock-solid; the
    /// scroll-to-latest button badge picks the message up instead.
    private func shouldAutoScrollForArrival() -> Bool {
        guard !isUserInteractingWithScroll else { return false }
        if let scrollView = scrollViewReference.scrollView,
           scrollView.isTracking || scrollView.isDragging {
            return false
        }
        // Mid-flight of a just-fired auto-scroll animation the geometry briefly reads as
        // not-at-bottom; treat the burst as still pinned so catch-up batches keep following.
        if Date().timeIntervalSince(lastAutoBottomScrollAt) < 0.8 { return true }
        return isNearBottomOfContent()
    }

    private func refreshStoredMessageCountAsync() {
        storedCountTask?.cancel()
        let contactAddress = contact.address
        storedCountTask = Task(priority: .utility) {
            let storedCount = await chatService.storedMessageCountAsync(for: contactAddress)
            guard !Task.isCancelled else { return }
            totalStoredMessages = max(storedCount, messages.count)
        }
    }

    private func capturePrependViewportSnapshot() {
        guard let scrollView = scrollViewReference.scrollView else { return }
        pendingPrependViewportSnapshot = PrependViewportSnapshot(
            contentHeight: scrollView.contentSize.height,
            offsetY: scrollView.contentOffset.y
        )
    }

    private func restoreViewportFromPrependSnapshotIfPossible() -> Bool {
        guard let snapshot = pendingPrependViewportSnapshot else { return false }
        guard let scrollView = scrollViewReference.scrollView else { return false }

        // Never jam contentOffset while the user's finger owns the scroll or a fling is live -
        // a programmatic setContentOffset mid-gesture kills the drag/momentum and reads as a
        // freeze-then-jump. On iOS 17+ the re-armed bottom anchor (armHistoryGrowthAnchor)
        // already holds the viewport through the prepend reflow, so the snapshot can simply be
        // dropped. On iOS 16 there is no default anchor to lean on, so only skip while the
        // finger is literally down (tracking/dragging) and still restore through deceleration -
        // stopping the fling is the lesser evil there versus losing the reading position.
        if #available(iOS 17.0, *) {
            if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                pendingPrependViewportSnapshot = nil
                return true
            }
        } else if scrollView.isTracking || scrollView.isDragging {
            pendingPrependViewportSnapshot = nil
            return true
        }

        let deltaHeight = scrollView.contentSize.height - snapshot.contentHeight
        // Wait for layout/content size to settle.
        guard abs(deltaHeight) > 0.5 else { return false }

        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let targetOffsetY = min(max(snapshot.offsetY + deltaHeight, minOffsetY), maxOffsetY)
        if abs(scrollView.contentOffset.y - targetOffsetY) > 0.5 {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY), animated: false)
        }
        pendingPrependViewportSnapshot = nil
        return true
    }

    private func restoreViewportAfterPrepend(
        using proxy: ScrollViewProxy,
        fallbackAnchorMessageId: UUID?,
        attemptsLeft: Int = 4
    ) {
        DispatchQueue.main.async {
            if restoreViewportFromPrependSnapshotIfPossible() {
                return
            }
            guard attemptsLeft > 0 else {
                pendingPrependViewportSnapshot = nil
                preserveViewport(using: proxy, anchorMessageId: fallbackAnchorMessageId)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                restoreViewportAfterPrepend(
                    using: proxy,
                    fallbackAnchorMessageId: fallbackAnchorMessageId,
                    attemptsLeft: attemptsLeft - 1
                )
            }
        }
    }

    private func preserveViewport(using proxy: ScrollViewProxy, anchorMessageId: UUID?) {
        guard let anchorMessageId else { return }
        DispatchQueue.main.async {
            // Same drag-safety split as the snapshot restore: on iOS 17+ never fight any active
            // gesture (the armed bottom anchor held position); on iOS 16 only skip while the
            // finger is down.
            if let scrollView = scrollViewReference.scrollView {
                if #available(iOS 17.0, *) {
                    if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
                        return
                    }
                } else if scrollView.isTracking || scrollView.isDragging {
                    return
                }
            }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(anchorMessageId, anchor: .top)
            }
        }
    }

    @discardableResult
    private func loadMoreMessagesPage(using proxy: ScrollViewProxy) -> Bool {
        let viewportAnchorMessageId = topVisibleMessageId ?? displayedMessages.first?.id
        let batchSize = olderHistoryBatchSize()
        if loadedMessageCount < messages.count {
            let now = Date()
            guard now.timeIntervalSince(lastOlderPageRequestAt) > 0.25 else { return false }
            lastOlderPageRequestAt = now
            capturePrependViewportSnapshot()
            armHistoryGrowthAnchor()
            loadedMessageCount = min(messages.count, loadedMessageCount + batchSize)
            rememberRenderedWindowStart()
            restoreViewportAfterPrepend(using: proxy, fallbackAnchorMessageId: viewportAnchorMessageId)
            hasLoadedCurrentTopPage = false
            if isTopAnchorVisible {
                triggerTopPaginationIfNeeded(using: proxy)
            }
            scheduleOlderPrefetchIfNeeded()
            return true
        }

        guard !isLoadingOlderMessages else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastOlderPageRequestAt) > 0.08 else { return false }
        lastOlderPageRequestAt = now

        if totalStoredMessages <= messages.count {
            refreshStoredMessageCountAsync()
        }

        capturePrependViewportSnapshot()
        isLoadingOlderMessages = true
        Task { @MainActor in
            let loaded = await chatService.loadOlderMessagesPageAsync(for: contact.address, pageSize: batchSize)
            isLoadingOlderMessages = false

            if loaded > 0 {
                armHistoryGrowthAnchor()
                loadedMessageCount = min(messages.count, loadedMessageCount + loaded)
                rememberRenderedWindowStart()
                restoreViewportAfterPrepend(using: proxy, fallbackAnchorMessageId: viewportAnchorMessageId)
                hasLoadedCurrentTopPage = false
                if isTopAnchorVisible {
                    triggerTopPaginationIfNeeded(using: proxy)
                }
            } else {
                // Keep local upper bound in sync to avoid repeated no-op fetch attempts.
                totalStoredMessages = max(totalStoredMessages, messages.count)
                pendingPrependViewportSnapshot = nil
            }
            refreshStoredMessageCountAsync()
            scheduleOlderPrefetchIfNeeded()
        }
        return true
    }

    private func scheduleOlderPrefetchIfNeeded() {
        DispatchQueue.main.async {
            prefetchOlderMessagesIfNeeded()
        }
    }

    private func prefetchOlderMessagesIfNeeded() {
        guard initialViewportPositioned else { return }
        guard !isLoadingOlderMessages else { return }
        guard !isPrefetchingOlderMessages else { return }

        let batchSize = olderHistoryBatchSize()
        let hiddenBacklog = max(0, messages.count - loadedMessageCount)
        // Keep 2-3 pages hidden so top-scroll fetches stay invisible.
        guard hiddenBacklog < (batchSize * 3) else { return }

        let now = Date()
        guard now.timeIntervalSince(lastOlderPrefetchAt) > 0.08 else { return }
        lastOlderPrefetchAt = now

        if totalStoredMessages <= messages.count {
            refreshStoredMessageCountAsync()
        }
        guard messages.count < totalStoredMessages else { return }

        isPrefetchingOlderMessages = true
        Task { @MainActor in
            _ = await chatService.loadOlderMessagesPageAsync(for: contact.address, pageSize: batchSize)
            isPrefetchingOlderMessages = false
            refreshStoredMessageCountAsync()
        }
    }

    private enum InputMode {
        case message
        case payment
        case audio

        var icon: String {
            switch self {
            case .message: return "arrow.up.circle.fill"
            case .payment: return "k.circle.fill"
            case .audio: return "mic.circle.fill"
            }
        }
    }

    // MARK: - New-chat handshake notice

    /// Copy is byte-identical to desktop's banner - keep the two in sync if either changes. The
    /// last sentence is the privacy caveat: a handshake is a direct on-chain transaction between
    /// the two chatting addresses, publicly linking them, unlike ordinary aliased traffic.
    private var handshakeNoticeBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.wave")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text("The recipient won't see your messages until they message you or you ping them with a handshake. Handshakes cost 0.2 KAS and are returned to you if they accept. You lose privacy if you ping them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                handshakeNoticeSendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassBackground(cornerRadius: 12))
        .padding(.horizontal)
        // The fee/available pills float ~26pt above the composer's own top edge; this clearance
        // keeps them off the banner instead of letting them sit on its text.
        .padding(.bottom, shouldShowComposerHelperRow ? 22 : 4)
    }

    /// Shortcut to the exact same action as the "+" menu's "Send Handshake" row - `sendHandshake()`
    /// -> `ChatService.sendHandshake(to:isResponse:)`, which owns the whole send/fee flow and
    /// surfaces failures through this view's `error` alert. No extra confirmation here: that path
    /// doesn't show one, and adding a second prompt would diverge from the menu entry.
    private var handshakeNoticeSendButton: some View {
        Button {
            sendHandshake()
        } label: {
            HStack(spacing: 6) {
                if isRespondingHandshake {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: hasUnansweredOutgoingHandshake ? "arrow.clockwise" : "hand.wave.fill")
                        .font(.caption2)
                }
                // Says what already happened once the request is out, so the unchanged banner
                // (it stays up until they reply) can't read as "the tap did nothing".
                Text(hasUnansweredOutgoingHandshake ? "Handshake sent - send again" : "Send Handshake")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(!canSendRequestToCommunicate)
        .opacity(canSendRequestToCommunicate ? 1 : 0.55)
    }

    // MARK: - Unified Input Bar (handles all handshake states)

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let reply = chatService.replyingTo {
                replyBanner(for: reply)
            }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 12) {
                    inputFieldWithState

                    if shouldShowDesktopEmojiButton {
                        desktopEmojiButton
                    }

                    sendButtonArea
                }

                if shouldShowComposerHelperRow && !isDeclined {
                    // One compact row, width-constrained so it can NEVER overflow the screen
                    // edge (the old free-floating .offset(x:) row let a third pill clip off
                    // narrow screens). The fee pill keeps its natural size (layoutPriority);
                    // the available pill absorbs any squeeze by tail-truncating its text. The
                    // fresh-address indicator lives INSIDE the available pill now (small accent
                    // arrow) instead of being a third pill.
                    HStack(spacing: 6) {
                        if shouldShowFeeBubble {
                            feeBubble
                                .layoutPriority(1)
                        }
                        if shouldShowAvailableBalanceBubble {
                            // No allowsHitTesting(false) here: the bubble is tappable (opens
                            // Manage Addresses), and hit-testing disabled on an ancestor can't
                            // be re-enabled from inside the bubble itself.
                            availableBalanceBubble
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 32)
                    .padding(.trailing, 12)
                    .offset(y: -26)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .overlay {
            if isImageDropTarget && canAcceptImageAttachment {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(pendingPhotoReturnShortcutButton)
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onCapture: { data in
                    showCamera = false
                    _ = attachImageData(data)
                },
                onCancel: { showCamera = false },
                // Video mode only exists when the Nextcloud media route can carry the file —
                // there is no on-chain path that fits a video.
                onCaptureVideo: (nextcloudService.isConnected && nextcloudService.mediaSendEnabled)
                    ? { fileURL in
                        showCamera = false
                        sendNextcloudVideo(fileURL)
                    }
                    : nil
            )
            .ignoresSafeArea()
        }
    }

    /// Pre-seeds the link-preview cache with what we just uploaded — the sender's own bubble
    /// renders the media card instantly with zero network, no probe round trip needed (we
    /// KNOW the kind/name/size; only recipients have to discover them).
    private func seedNextcloudPreview(for shareURL: URL, kind: NextcloudMediaKind, title: String, byteSize: Int) async {
        guard let endpoints = LinkPreviewService.nextcloudShareEndpoints(for: shareURL) else { return }
        await LinkPreviewService.shared.seed(LinkPreviewData(
            url: shareURL,
            title: title,
            description: nil,
            imageURLString: endpoints.previewURL.absoluteString,
            siteName: shareURL.host.map { "Nextcloud · \($0)" } ?? "Nextcloud",
            nextcloudMedia: kind,
            mediaDownloadURLString: endpoints.downloadURL.absoluteString,
            mediaByteSize: Int64(byteSize)
        ))
    }

    /// Uploads a just-recorded camera clip to Nextcloud and sends its share link — the
    /// recipient's preview renders it as a playable video bubble. On failure the clip can't
    /// fall back on-chain (videos don't fit a payload), so the error surfaces directly.
    private func sendNextcloudVideo(_ fileURL: URL) {
        Task {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let data = try Data(contentsOf: fileURL)
                let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension.lowercased()
                let contentType = ext == "mp4" ? "video/mp4" : "video/quicktime"
                let videoFilename = "video_\(Int(Date().timeIntervalSince1970)).\(ext)"
                let shareURL = try await NextcloudService.shared.uploadMediaAndShare(
                    data: data,
                    filename: videoFilename,
                    contentType: contentType
                )
                await seedNextcloudPreview(for: shareURL, kind: .video, title: videoFilename, byteSize: data.count)
                try await chatService.sendMessage(to: contact, content: shareURL.absoluteString, feeOverride: nil)
            } catch {
                AppLog.log("[ChatDetailView] Nextcloud video send failed: %@", error.localizedDescription)
                await MainActor.run {
                    self.error = displayErrorMessage(error)
                }
            }
        }
    }

    private func takePhoto() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            self.error = "Camera not available on this device."
        }
    }

    @ViewBuilder
    private var pendingPhotoReturnShortcutButton: some View {
        if shouldInstallPendingPhotoReturnShortcut {
            Button {
                handleSend()
            } label: {
                Color.clear
                    .frame(width: 1, height: 1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityHidden(true)
        }
    }

    private var shouldInstallPendingPhotoReturnShortcut: Bool {
        ChatSendKeyboardShortcutPolicy.shouldInstallReturnShortcut(
            hasPendingPhoto: pendingPhotoImage != nil,
            isSending: isSending,
            isCompressingPhoto: isCompressingPhoto,
            isDeclined: isDeclined
        )
    }

    private var inputFieldWithState: some View {
        Group {
            if isDeclined {
                disabledTextField(placeholder: "Conversation declined")
            } else {
                inputField
            }
        }
    }

    private func disabledTextField(placeholder: String) -> some View {
        Text(placeholder)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(glassBackground(cornerRadius: 20).opacity(0.7))
    }

    private var sendButtonArea: some View {
        Group {
            if isDeclined {
                EmptyView()
            } else if inputMode == .message && pendingPhotoImage == nil && messageText.isEmpty {
                composerPlusMenu
            } else if shouldShowComposerQuickActions {
                composerQuickActions
            } else if shouldShowAudioModeSwitchActions {
                HStack(spacing: 8) {
                    audioModeSwitchActions
                    sendButton(
                        tapAction: { handleSend() },
                        isDisabled: !canSend
                    )
                }
            } else {
                sendButton(
                    tapAction: { handleSend() },
                    isDisabled: !canSend
                )
            }
        }
    }

    /// Entry point for every "other than a plain text message" thing you can send — matches
    /// Android 3.0's "+" composer menu (Pay in Kaspa / Photo / Audio Message / Send Handshake),
    /// replacing the old row of always-visible quick-action pills + a separate standalone photo
    /// button that used to clutter this same spot.
    /// The chat's title: avatar and name as one tappable chip into Chat Info.
    ///
    /// It was a VStack - a 36pt avatar with the name underneath - which is taller than the
    /// navigation bar gives a principal item, so the avatar was drawn clipped at the top and
    /// only settled once the bar re-laid out. Side by side fits the bar's height, which lets the
    /// avatar be BIGGER rather than smaller, and the glass capsule is what says "this is a
    /// button" - iMessage's header has the same affordance.
    private var chatTitleChip: some View {
        Button {
            showChatInfo = true
        } label: {
            VStack(spacing: -12) {
                KNSAvatarView(
                    avatarURLString: knsService.profileCache[contact.address]?.avatarURL,
                    fallbackText: contact.alias,
                    size: 46,
                    contactAddress: contact.address
                )
                // Drawn over the capsule, which tucks under it - the negative spacing is what
                // makes the two read as one piece rather than a stack.
                .zIndex(1)

                HStack(spacing: 4) {
                    Text(contact.alias)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 15)
                .padding(.bottom, 5)
                .background(
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Chat info for \(contact.alias)"))
    }

    private var composerPlusMenu: some View {
        Button {
            Haptics.impact(.light)
            showComposerPlusSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)
                .background(glassBackground(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More options"))
        .sheet(isPresented: $showComposerPlusSheet) { composerPlusSheet }
        // Second step after "Play Chess": pick a time control. The blitz presets send the tc
        // fields on the invite; "Casual" omits them entirely, which is the exact legacy wire
        // shape - so casual games with old-version contacts stay byte-compatible.
        .confirmationDialog("Play Chess", isPresented: $showChessTimeControlPicker, titleVisibility: .visible) {
            Button("3 | 2 Blitz") { startChessGame(timeControl: ChessTimeControl(minutes: 3, incSeconds: 2)) }
            Button("2 | 1 Bullet") { startChessGame(timeControl: ChessTimeControl(minutes: 2, incSeconds: 1)) }
            Button("1 | 1 Bullet") { startChessGame(timeControl: ChessTimeControl(minutes: 1, incSeconds: 1)) }
            Button("Casual (no timer)") { startChessGame(timeControl: nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Timed games count down only while the board is open on your turn.")
        }
        .photosPicker(isPresented: $showPhotoPickerFromMenu, selection: $photoPickerItem, matching: .images)
        .sheet(isPresented: $showNextcloudPicker) {
            NextcloudPickerView { url, file in
                stageNextcloudLink(url, file: file)
            }
        }
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                defer { photoPickerItem = nil }
                guard let data = try? await newItem.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        self.error = "Couldn't load that photo. Please try another."
                    }
                    return
                }
                await MainActor.run {
                    _ = attachImageData(data)
                }
            }
        }
    }

    /// The composer's "+" options, as a half sheet - each with a line saying what it does.
    private var composerPlusSheet: some View {
        VStack(spacing: 12) {
            // With "Send Media via Nextcloud" toggled on, the composer bar's own camera/mic
            // buttons cover native capture (uploading via the server), so the menu offers only
            // the server browser. Toggle off keeps the classic Send Photo / Send Audio entries
            // (plus the browser row whenever a server is connected).
            Text("Send")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            // With "Send Media via Nextcloud" toggled on, the composer bar's own camera/mic
            // buttons cover native capture (uploading via the server), so this offers only the
            // server browser. Toggle off keeps the classic Send Photo / Send Audio entries.
            if nextcloudService.isConnected {
                ActionSheetRow(
                    title: "Send from Nextcloud",
                    subtitle: "Pick a file from your connected server.",
                    systemImage: "externaldrive.connected.to.line.below"
                ) {
                    showComposerPlusSheet = false
                    DispatchQueue.main.async { showNextcloudPicker = true }
                }
            }
            if !(nextcloudService.isConnected && nextcloudService.mediaSendEnabled) {
                ActionSheetRow(
                    title: "Send Photo",
                    subtitle: "Pick an image from your library.",
                    systemImage: "photo"
                ) {
                    showComposerPlusSheet = false
                    DispatchQueue.main.async { showPhotoPickerFromMenu = true }
                }
                ActionSheetRow(
                    title: "Send Audio Message",
                    subtitle: "Record a voice message and send it.",
                    systemImage: "mic.circle.fill"
                ) {
                    showComposerPlusSheet = false
                    switchMode(.audio)
                    startRecording()
                }
            }
            // Send Kaspa left this menu: the Kaspa logo inside the input bubble is the
            // one entry point to payment mode now.
            ActionSheetRow(
                title: "Play Chess",
                subtitle: "Invite this contact to a game on chain.",
                systemImage: "checkerboard.rectangle"
            ) {
                showComposerPlusSheet = false
                DispatchQueue.main.async { showChessTimeControlPicker = true }
            }
            if canSendRequestToCommunicate {
                ActionSheetRow(
                    title: "Send Handshake",
                    subtitle: "Asks to open an encrypted conversation.",
                    systemImage: "hand.wave"
                ) {
                    showComposerPlusSheet = false
                    sendHandshake()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.visible)
    }


    private var shouldShowDesktopEmojiButton: Bool {
        !isDeclined
            && inputMode == .message
            && pendingPhotoImage == nil
            && EmojiInputSupport.shouldShowDesktopEmojiButton
    }

    private var desktopEmojiButton: some View {
        Button {
            showDesktopEmojiPicker.toggle()
            isMessageFocused = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.title3)
                .foregroundColor(.primary)
                .frame(width: 44, height: 44)
                .background(glassBackground(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Emoji picker"))
        .popover(isPresented: $showDesktopEmojiPicker, arrowEdge: .bottom) {
            DesktopEmojiPickerView { emoji in
                insertDesktopEmoji(emoji)
            }
        }
    }

    private var shouldShowComposerQuickActions: Bool {
        switch inputMode {
        case .message:
            return pendingPhotoImage == nil && messageText.isEmpty
        case .payment:
            return amountText.isEmpty
        case .audio:
            return false
        }
    }

    private var shouldShowAudioModeSwitchActions: Bool {
        inputMode == .audio && !hasAudioDraft
    }

    private var hasAudioDraft: Bool {
        isRecording || isEncodingAudio || recordedAudioPreviewURL != nil || recordedAudioURL != nil
    }

    /// A handshake we sent that they have not answered - no handshake back, no genuine message
    /// back. Their answer (either kind) makes the option available again.
    private var hasUnansweredOutgoingHandshake: Bool {
        hasOutgoingHandshakeMessage && !hasIncomingHandshakeMessage && !hasGenuineIncomingMessage
    }

    /// Available in the "+" menu even once the handshake exchange has completed - unlike Android,
    /// which hides it at that point - because a fresh ping is a legitimate thing to send an
    /// established contact.
    ///
    /// What it will NOT do is send a second one while the first is still unanswered. A handshake
    /// costs 0.2 KAS, and the notice banner deliberately stays up until they reply, so the screen
    /// looks identical before and after a send: tapping again (reasonably, since nothing appeared
    /// to happen) simply spent another 0.2 KAS. The button now says the request is out instead.
    /// A handshake can always be sent again while it is unanswered.
    ///
    /// This used to be blocked once one was out. But a handshake is a transaction, and
    /// transactions get dropped, arrive at a wallet that was not listening, or land while the
    /// other person is reinstalling - and the only recovery the app offered was to wait
    /// indefinitely for a reply that was never coming. The button says "Handshake sent" so the
    /// state is still visible; it just is not a dead end any more.
    ///
    /// The only thing still held is a send already in flight, which is about not submitting the
    /// same transaction twice, not about rationing attempts.
    private var canSendRequestToCommunicate: Bool {
        // Never for a chat with yourself: a handshake is a request to open an encrypted
        // conversation WITH SOMEONE, and there is nobody on the other side of your own chatting
        // address to accept it. Reachable after importing the same wallet on a second device,
        // where your own address is among the contacts.
        !isRespondingHandshake && contact.address != walletManager.currentWallet?.publicAddress
    }

    /// Only ever reached for `.payment` now — the `.message` entry point moved to
    /// composerPlusMenu, and `.audio` has nothing to show here (see shouldShowComposerQuickActions).
    /// Deliberately no mic here: the message button is the only mode exit from payment mode —
    /// audio stays reachable through message mode's in-bubble mic and "+" menu as usual.
    private var composerQuickActions: some View {
        HStack(spacing: 8) {
            switch inputMode {
            case .message, .audio:
                EmptyView()
            case .payment:
                composerQuickActionButton(
                    title: "Send message",
                    icon: "text.bubble.fill"
                ) {
                    switchMode(.message)
                }
            }
        }
    }

    private var audioModeSwitchActions: some View {
        HStack(spacing: 8) {
            composerQuickActionButton(
                title: "Send message",
                icon: "text.bubble.fill"
            ) {
                switchMode(.message)
            }

            composerQuickActionButton(
                title: "Send KAS",
                icon: "KaspaLogo",
                isAssetImage: true
            ) {
                switchMode(.payment)
            }
        }
    }

    private func composerQuickActionButton(
        title: LocalizedStringKey,
        icon: String,
        isAssetImage: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isAssetImage {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
            }
            .frame(width: 44, height: 44)
            .background(glassBackground(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func sendButton(tapAction: @escaping () -> Void, isDisabled: Bool) -> some View {
        Button(action: tapAction) {
            sendButtonLabel
                .frame(width: 44, height: 44)
                .background(glassBackground(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    private var sendButtonLabel: some View {
        Group {
            if isSendActionBusy {
                ProgressView()
                    .font(.title)
            } else if inputMode == .payment {
                Image("KaspaLogo")
                    .resizable()
                    .scaledToFit()
                    .padding(9)
            } else {
                Image(systemName: currentButtonIcon)
                    .font(.title)
                    .foregroundColor(currentButtonEnabled ? .accentColor : .secondary)
            }
        }
    }

    private var currentButtonIcon: String {
        if inputMode == .payment {
            return "k.circle.fill"
        }
        if inputMode == .audio {
            // While recording, this button's only job is "stop early" - in case the full
            // ~10s auto-cutoff is more than the user wants. Once there's a finished preview,
            // it's a real send action, so it should read as send, not still show a mic.
            if isRecording {
                return "stop.circle.fill"
            }
            if recordedAudioPreviewURL != nil {
                return "arrow.up.circle.fill"
            }
        }
        return inputMode.icon
    }

    private var currentButtonEnabled: Bool {
        return canSend
    }

    private var isSendActionBusy: Bool {
        if isRespondingHandshake {
            return true
        }
        if isSending && inputMode != .message {
            return true
        }
        return false
    }

    private var canSendPayment: Bool {
        return true
    }

    private var canSend: Bool {
        switch inputMode {
        case .message:
            // A pending photo isn't cleared from state until its send actually finishes (unlike
            // text, which clears `messageText` immediately), so without this the button stays
            // tappable for the whole compress+upload window and a second tap starts a fully
            // concurrent duplicate send of the same photo.
            if pendingPhotoImage != nil {
                return !isSending && !isCompressingPhoto
            }
            return true
        case .payment:
            return canSendPayment
        case .audio:
            return !isSending
        }
    }

    private var canAcceptImageAttachment: Bool {
        !isDeclined
            && inputMode == .message
            && pendingPhotoImage == nil
            && !isCompressingPhoto
            && !isSending
    }

    // MARK: - Handshake Actions

    private func sendHandshake() {
        Task { @MainActor in
            isRespondingHandshake = true
            defer { isRespondingHandshake = false }
            do {
                try await chatService.sendHandshake(to: contact, isResponse: false)
            } catch {
                self.error = displayErrorMessage(error)
            }
        }
    }

    private func acceptHandshake() {
        Task { @MainActor in
            isRespondingHandshake = true
            defer { isRespondingHandshake = false }
            do {
                try await chatService.respondToHandshake(for: contact, accept: true)
            } catch {
                self.error = displayErrorMessage(error)
            }
        }
    }

    private func declineHandshake() {
        Task { @MainActor in
            isRespondingHandshake = true
            defer { isRespondingHandshake = false }
            try? await chatService.respondToHandshake(for: contact, accept: false)
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if text == "!!HANDSHAKE!!" {
            messageText = ""
            chatService.clearDraft(for: contact.address)
            sendHandshake()
            return
        }

        messageText = ""
        chatService.clearDraft(for: contact.address)
        let feeOverride = feeOverrideSompi
        feeEstimateSompi = nil
        feeOverrideSompi = nil
        isEstimatingFee = false

        Task {
            do {
                try await chatService.sendMessage(to: contact, content: text, feeOverride: feeOverride)
            } catch {
                if shouldPromptGiftClaim(for: error) {
                    await MainActor.run {
                        NotificationCenter.default.post(name: .showGiftClaim, object: nil)
                    }
                }
                let errorMsg = error.localizedDescription
                AppLog.log("[ChatDetailView] Send message failed: %@", errorMsg)
                await MainActor.run {
                    self.error = displayErrorMessage(error)
                }
            }
        }
    }

    /// Sends a just-created Nextcloud share link as a normal text message — the recipient's
    /// link-preview feature renders it as tappable media. Same send path and error handling as
    /// a typed message; the link is tiny, so no fee override machinery is needed.
    /// Stages a picked file's share link in the composer instead of auto-sending — the user
    /// reviews it in the input bubble and taps send themselves. The link-preview cache is
    /// seeded from the picker's own metadata so the bubble renders its media card instantly
    /// once sent.
    private func stageNextcloudLink(_ url: URL, file: NextcloudFile) {
        let kind: NextcloudMediaKind
        if file.isImage {
            kind = .image
        } else if file.isVideo {
            kind = .video
        } else {
            switch (file.name as NSString).pathExtension.lowercased() {
            case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus": kind = .audio
            case "pdf": kind = .pdf
            default: kind = .file
            }
        }
        if let size = file.size {
            Task { await seedNextcloudPreview(for: url, kind: kind, title: file.name, byteSize: Int(size)) }
        }
        switchMode(.message)
        messageText = messageText.isEmpty ? url.absoluteString : messageText + " " + url.absoluteString
        isMessageFocused = true
    }

    private var paymentField: some View {
        HStack {
            // Toggles KAS/fiat entry mode, matching Cold Storage's send flow - the leading icon is
            // the toggle now, so the conversion label further along is purely informational.
            Button {
                fiatAmountState.toggleMode(priceInCurrency: portfolioViewModel.currentPriceUsd)
            } label: {
                if fiatAmountState.isFiatMode {
                    Text(currencySymbol(for: portfolioViewModel.currentCurrency))
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 22, height: 22)
                } else {
                    Image("KaspaLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                }
            }
            .buttonStyle(.plain)

            TextField(
                fiatAmountState.isFiatMode ? portfolioViewModel.currentCurrency.code : "Amount (KAS)",
                text: Binding(
                    get: { fiatAmountState.displayText },
                    set: { newValue in
                        let sanitized = sanitizedAmount(newValue)
                        amountText = fiatAmountState.onDisplayTextChange(sanitized, priceInCurrency: portfolioViewModel.currentPriceUsd)
                    }
                )
            )
                .keyboardType(.decimalPad)
                .numericKeyboardDoneButton()
                .focused($isPaymentFocused)
            if let conversionLabel = fiatAmountState.conversionLabelText(
                priceInCurrency: portfolioViewModel.currentPriceUsd,
                currency: portfolioViewModel.currentCurrency
            ) {
                Text(conversionLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Button("Max") {
                Task {
                    do {
                        let maxSompi = try await chatService.estimateMaxPaymentAmount(to: contact)
                        await MainActor.run {
                            let kas = Double(maxSompi) / 100_000_000.0
                            amountText = fiatAmountState.setMaxKas(kas, priceInCurrency: portfolioViewModel.currentPriceUsd)
                        }
                    } catch {
                        AppLog.log("[ChatDetail] Max calculation failed: %@", error.localizedDescription)
                    }
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(glassBackground(cornerRadius: 20))
    }

    private var inputField: some View {
        Group {
            switch inputMode {
            case .message:
                if let pendingPhotoImage {
                    pendingPhotoRow(pendingPhotoImage)
                } else {
                    HStack(spacing: 4) {
                        ComposerTextView(
                            text: $messageText,
                            isFocused: $isMessageFocused,
                            onTextChange: { newValue in
                                scheduleFeeEstimate(for: newValue)
                                if inputMode == .message {
                                    chatService.setDraft(newValue, for: contact.address)
                                }
                            },
                            onSubmit: { handleSend() },
                            insertionRequest: emojiInsertionRequest,
                            onInsertionHandled: { requestID in
                                if emojiInsertionRequest?.id == requestID {
                                    emojiInsertionRequest = nil
                                }
                            },
                            onPasteImageData: handlePastedImageData
                        )

                        // Quick-access camera, replacing what used to be a "Camera" entry in the
                        // "+" menu - living right in the compose bubble instead since it's the
                        // most common non-text action. When "Send Media via Nextcloud" is on,
                        // captures ride the auto-upload send path automatically.
                        Button {
                            takePhoto()
                        } label: {
                            Image(systemName: "camera")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Take Photo"))

                        // Its voice-note sibling: one tap starts recording, same as the old
                        // "+"-menu entry — and the finished note likewise uploads via Nextcloud
                        // whenever the toggle is on.
                        Button {
                            switchMode(.audio)
                            startRecording()
                        } label: {
                            Image(systemName: "mic")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                        .accessibilityLabel(Text("Record Voice Message"))

                        // Third inline shortcut: jump straight into payment mode - the same
                        // switchMode(.payment) path as the "+" menu's Send Kaspa entry, which
                        // stays available too. In payment mode the whole input row is replaced
                        // by paymentField, so this icon disappears with the rest of the bubble.
                        Button {
                            switchMode(.payment)
                        } label: {
                            Image("KaspaLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                        .accessibilityLabel(Text("Send KAS"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(glassBackground(cornerRadius: 20))
                }
            case .payment:
                paymentField
            case .audio:
                HStack {
                    if isRecording {
                        ProgressView()
                        Text("\(String(localized: "Recording...")) \(Int(recordingDuration))s")
                        Spacer()
                        Button {
                            cancelRecording()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    } else if isEncodingAudio {
                        ProgressView()
                        Text("Encoding…")
                        Spacer()
                        Button {
                            cancelRecording()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    } else if recordedAudioPreviewURL != nil {
                        Button {
                            togglePreviewPlayback()
                        } label: {
                            Image(systemName: previewIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        Text("\(String(localized: "Audio ready")) • \(previewLabel)")
                        Spacer()
                        Button {
                            cancelRecording()
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    } else {
                        Text("Tap send to record")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(glassBackground(cornerRadius: 20))
            }
        }
    }

    private func pendingPhotoRow(_ image: UIImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            if isCompressingPhoto {
                ProgressView()
                Text("Sending…")
                    .foregroundColor(.secondary)
            } else {
                Text("Photo")
                    .foregroundColor(.primary)
            }

            Spacer()

            Button {
                cancelPendingPhoto()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .disabled(isCompressingPhoto)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(glassBackground(cornerRadius: 20))
    }

    private var feeBubble: some View {
        HStack(spacing: 6) {
            if isEstimatingFee {
                Text("fee: -------- KAS")
            } else if let fee = feeOverrideSompi ?? feeEstimateSompi ?? recordingFeeSompi {
                Text(localizedFeeText(fee))
                    .underline()
            } else {
                Text("fee: -- KAS")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(glassBackground(cornerRadius: 14))
        .overlay {
            if isEstimatingFee {
                FeeShimmerOverlay(phase: feeShimmerPhase)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(true)
        .onTapGesture {
            guard !isEstimatingFee, let currentFee = feeOverrideSompi ?? feeEstimateSompi ?? recordingFeeSompi else { return }
            feeEditorText = formatKaspaExact(currentFee)
            showFeeEditor = true
        }
        .onAppear {
            updateFeeShimmer()
        }
        .onChange(of: isEstimatingFee) { _ in
            updateFeeShimmer()
        }
    }

    /// Drives the Manage Addresses sheet opened from the available-balance bubble below.
    @State private var showManageAddresses = false

    /// True while the next payment to this contact will go to a fresh pool address (see
    /// ChatService+PaymentPools) - refreshed on entering payment mode and after each send.
    @State private var paysToFreshPoolAddress = false

    /// True while this account's Chats Payment Privacy toggle is ON - payments fund from the
    /// primary spending address; OFF funds them from the chatting address (see
    /// `ChatService.paymentFundingSourceAddress`). Read live so a Settings change applies on
    /// the next render.
    private var isChatsPaymentPrivacyOn: Bool {
        guard let myAddress else { return true }
        return AppSettings.chatsPrivacyEnabled(for: myAddress)
    }

    /// Privacy ON - tappable: opens Manage Spending Addresses as a sheet (ManageAddressesView
    /// is normally pushed from Profile, but a push would navigate away from the chat - a sheet
    /// keeps the conversation and its active payment mode untouched underneath). Styled exactly
    /// like the feeBubble's tappable fee display: the value text itself is underlined (same
    /// caption2/secondary treatment), the whole glass pill is the tap target via onTapGesture.
    ///
    /// Privacy OFF - payments fund from the CHATTING address, so the pill shows the wallet's
    /// main published chatting balance (already kept fresh by the normal refresh/UTXO-push
    /// cycle), drops the underline, and is not tappable: Manage Spending Addresses is
    /// irrelevant to chatting-address sends.
    private var availableBalanceBubble: some View {
        let privacyOn = isChatsPaymentPrivacyOn
        let balanceSompi = privacyOn ? spendingBalanceSompi : walletManager.currentWallet?.balanceSompi
        return HStack(spacing: 6) {
            if privacyOn {
                Text(localizedAvailableBalanceText(balanceSompi))
                    .underline()
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(localizedAvailableBalanceText(balanceSompi))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Fresh-address indicator, merged into this pill (used to be its own third pill
            // that clipped off narrow screens): a small accent arrow, same accessibility
            // label the standalone pill carried.
            if paysToFreshPoolAddress {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .accessibilityLabel(Text("Payment goes to a fresh address this contact shared, so it cannot be linked to their chat address on-chain"))
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(glassBackground(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(privacyOn)
        .onTapGesture {
            guard isChatsPaymentPrivacyOn else { return }
            showManageAddresses = true
        }
        .sheet(
            isPresented: $showManageAddresses,
            onDismiss: {
                // Catch-all refresh: covers balance changes made in the sheet that don't move
                // the primary index (consolidation, withdrawals) - the primary-change case is
                // additionally covered live by the .task keyed on spendingAddressIndex.
                Task { await loadSpendingBalance() }
            }
        ) {
            // Own NavigationStack: ManageAddressesView relies on navigationTitle and pushes
            // its per-address detail screens via NavigationLink.
            NavigationStack {
                ManageAddressesView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { showManageAddresses = false }
                        }
                    }
            }
        }
    }

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    // MARK: - Zero-Balance Chat Gate

    /// Shown above the (disabled) composer when the chatting address holds a confirmed 0 KAS -
    /// offers the gift-claim flow, plus the address itself (QR + copy) so the user can fund it
    /// from anywhere. Disappears automatically once `balanceSompi` goes positive (reactive via
    /// `walletManager.currentWallet`). The card body lives in the shared
    /// `ZeroBalanceFundingCardView` (bottom of this file), reused by group chats, broadcast
    /// channels, and KaPosts.
    private var zeroBalanceGateCard: some View {
        ZeroBalanceFundingCardView(
            address: myAddress,
            onCopied: { showToast($0.addressCopiedToastText) }
        )
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func updateFeeShimmer() {
        if isEstimatingFee {
            feeShimmerPhase = -1
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                feeShimmerPhase = 1
            }
        } else {
            feeShimmerPhase = -1
        }
    }

    private func clearFeeEstimationState() {
        feeEstimateTask?.cancel()
        recordingFeeTask?.cancel()
        feeEstimateSompi = nil
        recordingFeeSompi = nil
        isEstimatingFee = false
    }

    private func switchMode(_ mode: InputMode) {
        // Check if keyboard is currently open
        let wasKeyboardOpen = isMessageFocused || isPaymentFocused

        feeEstimateSompi = nil
        isEstimatingFee = false
        if mode != .payment {
            amountText = ""
            fiatAmountState.reset()
        }
        if mode != .message { messageText = "" }
        if mode != .audio {
            cancelRecording()
        }

        // Transfer focus to keep keyboard open when switching between message and payment.
        // This must land in the same SwiftUI update pass as the `inputMode` change below -
        // deferring it to a later run-loop turn leaves a gap where the old field has already
        // resigned (removed from the view hierarchy) but the new one hasn't requested focus
        // yet, which drops the tab bar into view and blanks the content behind it before the
        // new keyboard slides back up from scratch.
        if wasKeyboardOpen {
            switch mode {
            case .message:
                isPaymentFocused = false
                isMessageFocused = true
            case .payment:
                isMessageFocused = false
                isPaymentFocused = true
            case .audio:
                // Close keyboard for audio mode
                isMessageFocused = false
                isPaymentFocused = false
            }
        }

        inputMode = mode
        if mode == .payment {
            paysToFreshPoolAddress = chatService.willPayViaFreshPoolAddress(contactAddress: contact.address)
        }
    }

    private func sanitizedAmount(_ value: String) -> String {
        let allowed = "0123456789.,"
        let filtered = value.filter { allowed.contains($0) }
        var result = ""
        var ch_tmp:Character = " "
        var dotSeen = false
        var numAfterDot = 0
        for ch in filtered {
            if ch == "," {
                ch_tmp = "."
            } else {
                ch_tmp = ch
            }
            if dotSeen && ch_tmp.isNumber {
                numAfterDot += 1
            }
            if ch_tmp == "." || numAfterDot > 8  {
                if dotSeen { continue }
                dotSeen = true
            }
            result.append(ch_tmp)
        }
        return result
    }

    private func handleSend() {
        switch inputMode {
        case .message:
            if pendingPhotoImage != nil {
                sendPendingPhoto()
            } else {
                sendMessage()
            }
        case .payment:
            let normalized = amountText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            let amountSompi = parseAmountSompi(normalized)
            guard amountSompi > 0 else { return }
            // 0.10000001 KAS = 10_000_001 sompi (network dust limit)
            if amountSompi < 10_000_001 {
                pendingDustAmountSompi = amountSompi
                showDustWarning = true
                return
            }
            executePayment(amountSompi: amountSompi)
        case .audio:
            if isRecording {
                stopRecording()
            } else if isEncodingAudio {
                return
            } else if recordedAudioPreviewURL != nil {
                if recordedAudioURL == nil {
                    error = "Audio encoding failed. Please record again."
                    return
                }
                sendAudio()
            } else {
                startRecording()
            }
        }
    }

    private func executePayment(amountSompi: UInt64) {
        isSending = true
        Task {
            do {
                try await chatService.sendPayment(to: contact, amountSompi: amountSompi, note: "")
                await MainActor.run {
                    amountText = ""
                    fiatAmountState.reset()
                    feeEstimateSompi = nil
                    isEstimatingFee = false
                    // The send may have consumed the contact's last unused pool address.
                    paysToFreshPoolAddress = chatService.willPayViaFreshPoolAddress(contactAddress: contact.address)
                }
                // The active spending address rotates to a fresh one after a successful send -
                // refresh so "Available" reflects that new address, not the one just spent from.
                // The immediate fetch usually races the change UTXO landing (it reads 0), so a
                // couple of short retries follow as a backstop in case the push event is missed -
                // Kaspa confirms in about a second, so these converge quickly.
                await loadSpendingBalance()
                scheduleSpendingBalanceRetries()
            } catch {
                await MainActor.run {
                    self.error = displayErrorMessage(error)
                }
            }
            await MainActor.run {
                isSending = false
            }
        }
    }

    private func loadSpendingBalance() async {
        // Chats Payment Privacy OFF: payments fund from the chatting address, whose balance is
        // the wallet's main published one - this spending-index-keyed fetch is inert.
        guard isChatsPaymentPrivacyOn else { return }
        guard let address = walletManager.currentSpendingAddress() else {
            spendingBalanceSompi = nil
            return
        }
        let utxos = (try? await NodePoolService.shared.getUtxosByAddresses([address])) ?? []
        spendingBalanceSompi = utxos.reduce(UInt64(0)) { $0 + $1.amount }
    }

    /// Post-send backstop for the Available pill: a private-mode payment rotates the primary to
    /// a fresh address whose change UTXO takes about a second to land, so the immediate
    /// post-send fetch reads 0. The `.ownAddressUtxoActivity` event normally fixes that
    /// push-style; these two short refetches (~1.5s and ~4s after send) cover a missed event.
    /// Cancellable so a newer send's schedule replaces an older one.
    private func scheduleSpendingBalanceRetries() {
        spendingBalanceRetryTask?.cancel()
        spendingBalanceRetryTask = Task {
            for delayNs: UInt64 in [1_500_000_000, 2_500_000_000] {
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                await loadSpendingBalance()
            }
        }
    }

    private func pinToBottomThroughKeyboardTransition() {
        // Re-pin only when the reader is already at (or near) the bottom, measured BEFORE the
        // keyboard rises - focusing the composer while scrolled up reading history must not
        // yank the viewport; the keyboard just rises over the list and the position stays.
        guard isBottomAnchorVisible || isNearBottomOfContent() else { return }
        // Keeps the chat pinned to the bottom when the composer gains focus and the keyboard rises.
        // A previous version snapped `contentOffset` at 30 Hz for 1.2 s, which fought SwiftUI's
        // keyboard-driven safe-area animation frame-by-frame and produced a sustained screen shake
        // on iOS 18 (it fires more intermediate inset updates during the transition). Instead scroll
        // to the bottom once, after the keyboard-raise animation has settled, so the OS animation
        // and our scroll never disagree. `scrollViewReference` is the raw UIScrollView because
        // `ScrollViewProxy.scrollTo` doesn't reliably land mid-transition.
        DispatchQueue.main.asyncAfter(deadline: .now() + keyboardPinSettleDelay) {
            guard let scrollView = scrollViewReference.scrollView else { return }
            let minOffsetY = -scrollView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            if abs(scrollView.contentOffset.y - maxOffsetY) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: maxOffsetY), animated: true)
            }
        }
    }

    /// Delay before the one-shot keyboard bottom-pin, chosen to land just after the keyboard-raise
    /// / safe-area animation settles (~0.25s) so the pin never overlaps and shakes the transition.
    private var keyboardPinSettleDelay: TimeInterval { 0.35 }

    /// Tap-a-reply-quote-to-jump-to-original. `displayedMessages` is a suffix window of `messages`
    /// (see `loadedMessageCount`) - if the target isn't currently windowed in, grow the window to
    /// include it before scrolling, rather than requiring the user to manually paginate up first.
    private func jumpToReplyOriginal(txId: String, using proxy: ScrollViewProxy) {
        if let target = displayedMessages.first(where: { $0.txId == txId }) {
            scrollAndHighlight(target.id, using: proxy)
            return
        }
        guard let targetIndex = messages.firstIndex(where: { $0.txId == txId }) else {
            showToast("Original message not available.", style: .error)
            return
        }
        let target = messages[targetIndex]
        armHistoryGrowthAnchor()
        loadedMessageCount = max(loadedMessageCount, messages.count - targetIndex)
        rememberRenderedWindowStart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            scrollAndHighlight(target.id, using: proxy)
        }
    }

    private func scrollAndHighlight(_ id: UUID, using proxy: ScrollViewProxy) {
        withAnimation {
            proxy.scrollTo(id, anchor: .center)
        }
        highlightedMessageID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.5)) {
                if highlightedMessageID == id {
                    highlightedMessageID = nil
                }
            }
        }
    }

    private func scrollToBottom(
        using proxy: ScrollViewProxy,
        animated: Bool,
        retryAfter: TimeInterval? = nil
    ) {
        DispatchQueue.main.async {
            if animated {
                withAnimation {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }

        guard let retryAfter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryAfter) {
            if animated {
                withAnimation {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        let needsHandshakeResponse = message.messageType == .handshake
            && !message.isOutgoing
            && !hasOutgoingHandshakeMessage
            && !isDeclined
        let replyQuote = MessageReplyCodec.parse(message.content)
        let senderAddress = message.isOutgoing ? myAddress : contact.address
        let chessEnvelope = ChessCodec.parseAny(MessageReplyCodec.unwrappedText(message.content))
        let chessSummary = chessEnvelope.flatMap { chessSummaryCache[$0.gameId] }
        // Equivalent to ChessGameService.isLatestChessMessage(message, in: messages), but reuses
        // the cached summary's lastMessageTxId (set during the same replay) instead of a fresh
        // O(N) scan over every message per row per render.
        let isLatestChess = chessEnvelope != nil && message.txId == chessSummary?.lastMessageTxId

        // Built as its own statement (rather than inline inside the ZStack below) so the type
        // checker isn't solving this already-huge multi-argument call *together* with the
        // selection-overlay's conditional content in one expression - that combination is what
        // triggered "unable to type-check in reasonable time" once the overlay was added. Further
        // split from its own trailing modifiers (a second statement below) for the same reason -
        // the combined call-plus-modifiers was still too much for the checker on its own.
        let rawBubble = MessageBubbleView(
            message: message,
            onCopy: showToast,
            onRetry: retryOutgoingMessage,
            onRetryReaction: { reaction in
                Task {
                    try? await chatService.retryReaction(to: contact, targetTxId: reaction.targetTxId, emoji: reaction.emoji, action: reaction.failedAction ?? "add")
                }
            },
            onAcceptHandshake: needsHandshakeResponse ? { acceptHandshake() } : nil,
            onDeclineHandshake: needsHandshakeResponse ? { declineHandshake() } : nil,
            replyQuote: replyQuote,
            replySenderDisplayName: replyQuote.map { replyDisplayName(for: $0.replyToSender) },
            onReply: { chatService.startReplyTo(message) },
            onSelect: { enterSelectMode(with: message.txId) },
            reactions: chatService.reactionsByTxId[message.txId] ?? [],
            myReactorAddress: walletManager.currentWallet?.publicAddress ?? "",
            onShowReactions: { reactionsSheetTarget = ReactionsSheetTarget(txId: message.txId) },
            onReact: { emoji in
                let myAddress = walletManager.currentWallet?.publicAddress ?? ""
                let existing = chatService.reactionsByTxId[message.txId]?.first { $0.reactorAddress == myAddress }
                let action = existing?.emoji == emoji ? "remove" : "add"
                Task {
                    try? await chatService.sendReaction(to: contact, targetTxId: message.txId, emoji: emoji, action: action)
                }
            },
            activeQuickReactionMessageId: $activeQuickReactionMessageId,
            onJumpToReply: replyQuote != nil ? { pendingJumpToTxId = replyQuote?.replyToId } : nil,
            avatarURLString: senderAddress.flatMap { knsService.profileCache[$0]?.avatarURL },
            avatarDisplayName: replyDisplayName(for: senderAddress ?? contact.address),
            revealOffset: revealOffset,
            maxRevealOffset: maxRevealOffset,
            photosBlocked: !contactsManager.shouldAutoDisplayPhotos(for: contact, settings: settingsViewModel.settings),
            linkPreviewsAutoLoad: contactsManager.isAcceptedContact(contact),
            chessEnvelope: chessEnvelope,
            chessSummary: chessSummary,
            isLatestChessMessage: isLatestChess,
            onRespondToChessInvite: (chessEnvelope != nil && !message.isOutgoing)
                ? { accepted in respondToChessInvite(gameId: chessEnvelope!.gameId, accepted: accepted) }
                : nil,
            onOpenChessGame: chessEnvelope != nil ? { activeChessGameId = chessEnvelope!.gameId } : nil
        )
        let bubble = rawBubble
            .allowsHitTesting(!isSelectingMessages)
            .padding(.leading, isSelectingMessages ? 28 : 0)

        ZStack(alignment: .leading) {
            bubble
            selectionOverlay(for: message.txId)
        }
    }

    /// Selection-mode tap catcher + indicator, split out of `messageRow` (see its own comment) -
    /// disables the bubble's own gestures (link taps, double-tap-to-react, long-press menu) while
    /// selecting, since those would otherwise fire alongside/instead of toggling selection.
    ///
    /// Entry point into select mode - triggered from a message's long-press "Select" menu item
    /// (not a toolbar button), pre-selecting whichever message was long-pressed.
    private func enterSelectMode(with txId: String) {
        isSelectingMessages = true
        selectedMessageIDs.insert(txId)
    }

    /// Pulled out of the `.alert(...)` call site as a plain computed property - an inline ternary
    /// nested inside string interpolation there was making the compiler unable to type-check the
    /// `.alert` expression in reasonable time (same fix as `ChatListView`'s bulk-delete alert).
    private var deleteMessagesAlertTitle: String {
        "Delete \(selectedMessageIDs.count) Message\(selectedMessageIDs.count == 1 ? "" : "s")?"
    }

    @ViewBuilder
    private func selectionOverlay(for txId: String) -> some View {
        if isSelectingMessages {
            HStack(spacing: 8) {
                Image(systemName: selectedMessageIDs.contains(txId) ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selectedMessageIDs.contains(txId) ? .accentColor : .secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if selectedMessageIDs.contains(txId) {
                    selectedMessageIDs.remove(txId)
                } else {
                    selectedMessageIDs.insert(txId)
                }
            }
        }
    }

    private func respondToChessInvite(gameId: String, accepted: Bool) {
        Task {
            try? await ChessGameService.respond(gameId: gameId, accepted: accepted, to: contact)
        }
    }

    /// Starting a new game always supersedes whichever one is currently active against this
    /// contact - only one active chess game per contact is allowed, so an existing in-progress/
    /// pending-response game is auto-resigned first rather than left orphaned alongside a second
    /// one. Uses `ChessGameService.activeGame` (not `chessSummaryCache`) so this check is correct
    /// even if the cache hasn't rebuilt since the very latest message yet.
    private func startChessGame(timeControl: ChessTimeControl?) {
        Task {
            if let myAddress = walletManager.currentWallet?.publicAddress,
               let existing = ChessGameService.activeGame(in: messages, myAddress: myAddress, contactAddress: contact.address) {
                try? await ChessGameService.resign(gameId: existing.gameId, to: contact)
            }
            try? await ChessGameService.startGame(with: contact, timeControl: timeControl)
        }
    }

    /// "You" for our own address, else the contact's alias - matches broadcast rooms'
    /// `displayName(for:)`, simplified since a 1:1 chat only ever has two possible senders.
    private func replyDisplayName(for address: String) -> String {
        if address == walletManager.currentWallet?.publicAddress {
            return "You"
        }
        return contact.alias.isEmpty ? Contact.generateDefaultAlias(from: address) : contact.alias
    }

    private func replyBanner(for reply: ChatMessage) -> some View {
        let replyQuote = MessageReplyCodec.parse(reply.content)
        let previewText = replyQuote?.text ?? reply.content
        return HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(replyDisplayName(for: reply.senderAddress))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
                Text(MessageReplyCodec.previewText(for: previewText))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                chatService.cancelReply()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { replyBannerHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { replyBannerHeight = $0 }
            }
        )
    }

    private func daySeparator(_ day: Date) -> some View {
        let isToday = MessageDaySeparatorFormatter.isToday(day)
        let label = MessageDaySeparatorFormatter.label(for: day)
        return HStack {
            Spacer(minLength: 0)
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    Capsule()
                        .fill(isToday ? Color.accentColor.opacity(0.12) : Color(.systemGray6))
                }
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
                .accessibilityLabel(label)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func retryOutgoingMessage(_ message: ChatMessage) {
        guard message.isOutgoing else { return }
        Task { @MainActor in
            isSending = true
            defer { isSending = false }
            do {
                try await chatService.retryOutgoingMessage(message, contact: contact)
            } catch {
                self.error = displayErrorMessage(error)
            }
        }
    }

    private var shouldShowFeeBubble: Bool {
        guard settingsViewModel.settings.showFeeEstimate else { return false }
        switch inputMode {
        case .message:
            return pendingPhotoImage != nil || !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .payment:
            return !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .audio:
            return isRecording || isEncodingAudio || recordedAudioPreviewURL != nil
        }
    }

    private var shouldShowAvailableBalanceBubble: Bool {
        inputMode == .payment
    }

    private var shouldShowComposerHelperRow: Bool {
        shouldShowFeeBubble || shouldShowAvailableBalanceBubble
    }

    private func commitFeeOverride() {
        guard let kas = Double(feeEditorText), kas >= 0 else { return }
        feeOverrideSompi = UInt64((kas * 100_000_000).rounded())
        scheduleFeeEstimate(for: messageText)
    }

    private func scheduleFeeEstimate(for text: String) {
        feeEstimateTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }

        guard inputMode == .message else { return }

        isEstimatingFee = true
        feeEstimateTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let estimate = try await chatService.estimateMessageFee(to: contact, content: trimmed, feeOverride: feeOverrideSompi)
                if Task.isCancelled { return }
                await MainActor.run {
                    feeEstimateSompi = estimate
                    isEstimatingFee = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    feeEstimateSompi = nil
                    isEstimatingFee = false
                }
            }
        }
    }

    /// Rough live estimate for a picked-but-not-yet-compressed photo, matching Android's
    /// formula - the real send always measures the actual compressed bytes.
    private func schedulePhotoFeeEstimate() {
        feeEstimateTask?.cancel()
        guard let wallet = walletManager.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }
        // Via Nextcloud, the chain only carries the ~80-byte share link — the photo bytes live
        // on the server — so the fee shown is the link-message fee, not the envelope fee.
        let payloadSize = (nextcloudService.isConnected && nextcloudService.mediaSendEnabled)
            ? Self.nextcloudLinkPayloadSize
            : ImagePrep.estimatedWirePayloadSize(
                targetBytes: settingsViewModel.settings.chatPhotoQualityPreset.targetBytes
            )
        feeEstimateSompi = KasiaTransactionBuilder.estimateContextualMessageFee(
            payload: Data(count: payloadSize),
            inputCount: 1,
            senderScriptPubKey: senderScriptPubKey
        )
        isEstimatingFee = false
    }

    /// Representative encrypted-payload size of a Nextcloud `/s/TOKEN` share-link message.
    private static let nextcloudLinkPayloadSize = 96

    private func schedulePaymentFee(for text: String) {
        feeEstimateTask?.cancel()

        let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard inputMode == .payment else { return }
        let amountSompi = parseAmountSompi(normalized)
        guard amountSompi > 0 else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }

        isEstimatingFee = true
        feeEstimateTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            do {
                let estimate = try await chatService.estimatePaymentFee(to: contact, amountSompi: amountSompi, note: "")
                if Task.isCancelled { return }
                await MainActor.run {
                    feeEstimateSompi = estimate
                    isEstimatingFee = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    feeEstimateSompi = nil
                    isEstimatingFee = false
                }
            }
        }
    }

    private func startRecording() {
        Task {
            let granted = await requestRecordPermission()
            guard granted else {
                await MainActor.run {
                    self.error = "Microphone access denied."
                }
                return
            }

            let session = AVAudioSession.sharedInstance()
            do {
                try await MainActor.run {
                    try session.setPreferredSampleRate(opusSampleRate)
                    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try session.setActive(true)
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kasia-audio-\(UUID().uuidString).caf")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: opusSampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false
                ]

                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.delegate = recorderDelegate
                recorderDelegate.onFinish = { recorder, success in
                    Task { @MainActor in
                        if !success {
                            self.isEncodingAudio = false
                            self.error = "Recording failed. Please try again."
                            return
                        }
                        self.recordedAudioPreviewURL = recorder.url
                        self.isRecording = false
                        self.recorder = nil
                    }
                    if success {
                        Task {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            await encodeRecording(from: recorder.url)
                            await MainActor.run {
                                preparePreview()
                                updateRecordingFee()
                            }
                        }
                    }
                }
                recorder.prepareToRecord()
                recorder.record()

                await MainActor.run {
                    if let previewURL = self.recordedAudioPreviewURL {
                        secureDeleteTempFile(previewURL)
                    }
                    if let encodedURL = self.recordedAudioURL {
                        secureDeleteTempFile(encodedURL)
                    }
                    self.recordingFeeTask?.cancel()
                    self.recorder = recorder
                    self.isRecording = true
                    self.recordedAudioURL = nil
                    self.recordedAudioPreviewURL = nil
                    if let stale = self.nextcloudOriginalRecordingURL {
                        self.secureDeleteTempFile(stale)
                        self.nextcloudOriginalRecordingURL = nil
                    }
                    self.isEncodingAudio = false
                    self.recordingDuration = 0
                    self.feeEstimateSompi = nil
                    self.recordingFeeSompi = nil
                    self.isEstimatingFee = true
                    startRecordingTimer()
                    stopPreview()
                    previewLabel = "--:--"
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = recorder?.currentTime ?? recordingDuration
        isRecording = false
    }

    private func cancelRecording() {
        recorder?.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil
        if let url = recorder?.url {
            secureDeleteTempFile(url)
        }
        if let url = recordedAudioPreviewURL {
            secureDeleteTempFile(url)
        }
        if let url = recordedAudioURL {
            secureDeleteTempFile(url)
        }
        if let originalURL = nextcloudOriginalRecordingURL {
            secureDeleteTempFile(originalURL)
            nextcloudOriginalRecordingURL = nil
        }
        recorder = nil
        recordedAudioURL = nil
        recordedAudioPreviewURL = nil
        isRecording = false
        isEncodingAudio = false
        recorderDelegate.onFinish = nil
        recordingDuration = 0
        recordingFeeTask?.cancel()
        recordingFeeSompi = nil
        isEstimatingFee = false
        feeEstimateSompi = nil
        stopPreview()
        previewLabel = "--:--"
    }

    private func cancelPendingPhoto() {
        pendingPhotoImage = nil
        pendingPhotoOriginalData = nil
        photoPickerItem = nil
        feeEstimateSompi = nil
        isEstimatingFee = false
    }

    /// Attaches an image staged by the Share Extension handoff (see
    /// `ChatService.pendingShareImage(for:)`) as the composer's pending photo. Leaves the image
    /// staged when the composer can't take an attachment right now (e.g. another photo pending);
    /// it will be retried the next time this chat appears.
    private func attachPendingShareImageIfAvailable(for address: String) {
        guard canAcceptImageAttachment,
              let data = chatService.pendingShareImage(for: address) else { return }
        chatService.clearPendingShareImage(for: address)
        _ = attachImageData(data)
    }

    @discardableResult
    private func attachImageData(_ data: Data) -> Bool {
        guard canAcceptImageAttachment else { return false }
        guard let image = ChatImageAttachmentLoader.image(from: data) else {
            self.error = "Couldn't load that photo. Please try a PNG, JPEG, or HEIF image."
            return false
        }

        pendingPhotoImage = image
        pendingPhotoOriginalData = data
        isMessageFocused = false
        schedulePhotoFeeEstimate()
        return true
    }

    private func handlePastedImageData(_ data: Data) -> Bool {
        attachImageData(data)
    }

    private func insertDesktopEmoji(_ emoji: String) {
        isMessageFocused = true
        emojiInsertionRequest = ComposerTextView.TextInsertionRequest(id: UUID(), text: emoji)
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canAcceptImageAttachment,
              let provider = providers.first(where: { ChatImageAttachmentLoader.canLoadImage(from: $0) }) else {
            return false
        }

        Task {
            do {
                let data = try await ChatImageAttachmentLoader.loadImageData(from: provider)
                await MainActor.run {
                    _ = attachImageData(data)
                }
            } catch {
                await MainActor.run {
                    self.error = "Couldn't load that photo. Please try a PNG, JPEG, or HEIF image."
                }
            }
        }
        return true
    }

    private func sendPendingPhoto() {
        Task { await sendPendingPhotoAsync() }
    }

    private func sendPendingPhotoAsync() async {
        // Guards against double-send: the button stays tappable during the compress+upload
        // window (see `canSend`), and `pendingPhotoImage` itself isn't cleared until the send
        // actually finishes, so without this a second tap mid-send would start a second,
        // fully concurrent send of the same photo.
        guard let image = pendingPhotoImage, !isSending, !isCompressingPhoto else { return }
        isCompressingPhoto = true
        isSending = true
        defer {
            isCompressingPhoto = false
            isSending = false
        }

        // "Send Media via Nextcloud" (1:1 chats only — this view; groups/broadcasts keep their
        // own send paths): upload the best-quality bytes we have and send the public share link
        // as a normal text message (the recipient's link-preview feature renders it as a media
        // bubble). Any upload/share failure falls back to the on-chain envelope below, with a
        // toast so the sender knows the full-quality upload didn't happen.
        if NextcloudService.shared.mediaSendEnabled, NextcloudService.shared.isConnected {
            var shareURL: URL?
            do {
                guard let upload = nextcloudPhotoUpload(for: image) else {
                    throw KasiaError.networkError("Couldn't encode the photo for upload.")
                }
                shareURL = try await NextcloudService.shared.uploadMediaAndShare(
                    data: upload.data,
                    filename: upload.filename,
                    contentType: upload.contentType
                )
                if let shareURL {
                    await seedNextcloudPreview(for: shareURL, kind: .image, title: upload.filename, byteSize: upload.data.count)
                }
            } catch {
                AppLog.log("[ChatDetailView] Nextcloud photo upload failed, falling back to on-chain: %@",
                           error.localizedDescription)
                await MainActor.run {
                    showToast("Nextcloud upload failed — sending on-chain instead", style: .error)
                }
            }
            if let shareURL {
                do {
                    try await chatService.sendMessage(to: contact, content: shareURL.absoluteString, feeOverride: nil)
                    await MainActor.run {
                        pendingPhotoImage = nil
                        pendingPhotoOriginalData = nil
                        photoPickerItem = nil
                        feeEstimateSompi = nil
                        isEstimatingFee = false
                    }
                } catch {
                    // The chain send itself failed — an on-chain image envelope would fail the
                    // same way, so surface the error instead of falling back.
                    if shouldPromptGiftClaim(for: error) {
                        await MainActor.run {
                            NotificationCenter.default.post(name: .showGiftClaim, object: nil)
                        }
                    }
                    await MainActor.run {
                        self.error = displayErrorMessage(error)
                    }
                }
                return
            }
            // No share link — fall through to the on-chain envelope path.
        }

        do {
            let preparedImage = try ImagePrep.prepareForChatMessage(
                image,
                targetBytes: settingsViewModel.settings.chatPhotoQualityPreset.targetBytes
            )
            try await chatService.sendImage(
                to: contact,
                imageData: preparedImage.data,
                fileName: preparedImage.fileName,
                mimeType: preparedImage.mimeType
            )
            await MainActor.run {
                pendingPhotoImage = nil
                pendingPhotoOriginalData = nil
                photoPickerItem = nil
                feeEstimateSompi = nil
                isEstimatingFee = false
            }
        } catch {
            if shouldPromptGiftClaim(for: error) {
                await MainActor.run {
                    NotificationCenter.default.post(name: .showGiftClaim, object: nil)
                }
            }
            await MainActor.run {
                self.error = displayErrorMessage(error)
            }
        }
    }

    private func sendAudio() {
        Task { await sendAudioAsync() }
    }

    private func preparePreview() {
        guard let audioURL = recordedAudioURL else { return }
        stopPreview()

        // Nextcloud mode: preview the full-length original — that's what actually uploads.
        // The WebM decode below reflects only the payload-capped on-chain encode (~9s), which
        // would make a long recording sound truncated in preview while sending fine.
        if NextcloudService.shared.mediaSendEnabled, NextcloudService.shared.isConnected,
           let originalURL = nextcloudOriginalRecordingURL,
           FileManager.default.fileExists(atPath: originalURL.path) {
            do {
                if let oldPreview = recordedAudioPreviewURL, oldPreview != originalURL {
                    secureDeleteTempFile(oldPreview)
                }
                recordedAudioPreviewURL = originalURL
                try setPlaybackSession()
                let player = try AVAudioPlayer(contentsOf: originalURL, fileTypeHint: AVFileType.caf.rawValue)
                previewPlayer = player
                previewLabel = formatDuration(player.duration)
                return
            } catch {
                // Original unreadable for some reason — fall through to the WebM-decode preview.
            }
        }

        do {
            // Decode WebM/Opus to CAF for preview playback (same quality as recipient will hear)
            let audioData = try Data(contentsOf: audioURL)
            let decoded = try decodeWebMForPreview(data: audioData)

            // Clean up old preview file (never the stashed Nextcloud original — the upload
            // path still needs it).
            if let oldPreview = recordedAudioPreviewURL, oldPreview != nextcloudOriginalRecordingURL {
                secureDeleteTempFile(oldPreview)
            }
            recordedAudioPreviewURL = decoded.url

            try setPlaybackSession()
            let player = try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
            previewPlayer = player
            previewLabel = formatDuration(decoded.duration)
        } catch {
            previewLabel = "--:--"
        }
    }

    private func togglePreviewPlayback() {
        guard let url = recordedAudioPreviewURL else { return }

        if previewIsPlaying {
            stopPreview()
            return
        }

        do {
            if previewPlayer?.url != url {
                try setPlaybackSession()
                previewPlayer = try AVAudioPlayer(contentsOf: url, fileTypeHint: AVFileType.caf.rawValue)
            }
            previewPlayer?.prepareToPlay()
            if previewPlayer?.play() != true {
                self.error = "Failed to play audio."
                return
            }
            previewIsPlaying = true
            startPreviewTimer()
        } catch {
            self.error = "Failed to play audio: \(error.localizedDescription)"
        }
    }

    private func decodeWebMForPreview(data: Data) throws -> (url: URL, duration: TimeInterval) {
        let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
        return (decoded.url, decoded.duration)
    }

    // MARK: - Nextcloud media send helpers ("Send Media via Nextcloud" toggle)

    /// Human-sortable timestamp for uploaded media filenames (photo_20260811-101502.jpg).
    private static let mediaTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// The best-quality photo bytes available for a Nextcloud upload: the exact original data
    /// the photo was attached from (untouched HEIC/PNG/JPEG at full resolution) when the
    /// composer still holds it, else a high-quality JPEG re-encode of the decoded image.
    /// Nil only if even the JPEG re-encode fails (caller treats that as an upload failure).
    private func nextcloudPhotoUpload(for image: UIImage) -> (data: Data, filename: String, contentType: String)? {
        let stamp = Self.mediaTimestampFormatter.string(from: Date())
        if let original = pendingPhotoOriginalData {
            let format = Self.sniffImageFormat(original)
            return (original, "photo_\(stamp).\(format.ext)", format.contentType)
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return (jpeg, "photo_\(stamp).jpg", "image/jpeg")
    }

    /// Magic-byte sniff so the uploaded file keeps an extension matching its actual container —
    /// Nextcloud derives the served Content-Type from the extension, and the recipient's media
    /// card branches on that Content-Type. Unknown formats default to .jpg: any image/* type
    /// still renders as an image card, and UIImage decodes from the real bytes regardless.
    private static func sniffImageFormat(_ data: Data) -> (ext: String, contentType: String) {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return ("jpg", "image/jpeg") }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("png", "image/png") }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("gif", "image/gif") }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data[data.startIndex + 8 ..< data.startIndex + 12] == Data("WEBP".utf8) {
            return ("webp", "image/webp")
        }
        if data.count >= 12, data[data.startIndex + 4 ..< data.startIndex + 8] == Data("ftyp".utf8) {
            return ("heic", "image/heic")
        }
        return ("jpg", "image/jpeg")
    }

    /// Builds an AAC .m4a of the current recording for the Nextcloud upload. PCM source: the
    /// already-decoded preview CAF when it exists (decoded from the same Opus bytes the
    /// recipient would have heard), else the WebM payload is decoded again on the spot.
    private func exportRecordingAsM4A(webmData: Data) async throws -> URL {
        let pcmURL: URL
        let deletePCMAfter: Bool
        if let originalURL = nextcloudOriginalRecordingURL,
           FileManager.default.fileExists(atPath: originalURL.path) {
            // The pre-encode original: full length, never truncated by the payload cap.
            pcmURL = originalURL
            deletePCMAfter = false // cleaned up by the send/cancel paths, not here
        } else if let previewURL = recordedAudioPreviewURL, FileManager.default.fileExists(atPath: previewURL.path) {
            pcmURL = previewURL
            deletePCMAfter = false
        } else {
            pcmURL = try decodeWebMForPreview(data: webmData).url
            deletePCMAfter = true
        }
        defer {
            if deletePCMAfter { secureDeleteTempFile(pcmURL) }
        }

        guard let export = AVAssetExportSession(asset: AVURLAsset(url: pcmURL),
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw KasiaError.networkError("Audio export is unavailable on this device.")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kachat-voice-\(UUID().uuidString).m4a")
        export.outputURL = outputURL
        export.outputFileType = .m4a
        // AVAssetExportSession isn't Sendable, but this is safe: after exportAsynchronously
        // starts, the session is only touched from its own one-shot completion callback —
        // `nonisolated(unsafe)` records that reasoning for the strict-concurrency checker.
        nonisolated(unsafe) let session = export
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: session.error
                        ?? KasiaError.networkError("Audio export failed."))
                }
            }
        }
        return outputURL
    }

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            guard let player = previewPlayer else { return }
            previewLabel = "\(formatDuration(player.currentTime))/\(formatDuration(player.duration))"
            if !player.isPlaying {
                stopPreview()
            }
        }
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        previewIsPlaying = false
    }

    private func setPlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let current = recorder?.currentTime {
                recordingDuration = current
            } else {
                recordingDuration += 1
            }
            if recordingDuration >= effectiveMaxRecordingDuration {
                stopRecording()
            }
            updateRecordingFee()
        }
    }

    private func estimateEncodedSize(forDuration duration: TimeInterval) -> Int {
        // WebM Opus overhead estimation:
        // - EBML + track headers: ~200 bytes
        // - Container overhead ~400 bytes/sec
        // - Audio bytes/sec derived from opus bitrate
        // - Ensure estimates can reach maxAudioBytes at max duration
        let headerSize = 200
        let containerOverheadPerSecond = 400
        let audioBytesPerSecond = Int(Double(opusBitrate) / 8.0)
        let bitrateEstimate = audioBytesPerSecond + containerOverheadPerSecond
        let targetBytesPerSecond = Int(Double(maxAudioBytes - headerSize) / maxRecordingDuration)
        let bytesPerSecond = max(bitrateEstimate, targetBytesPerSecond)
        let estimatedSize = headerSize + Int(duration * Double(bytesPerSecond))
        return min(estimatedSize, maxAudioBytes)
    }

    private func updateRecordingFee() {
        recordingFeeTask?.cancel()

        // Via Nextcloud, the recording uploads to the server and the chain only carries the
        // share link — the fee is the link-message fee regardless of recording length.
        if nextcloudService.isConnected && nextcloudService.mediaSendEnabled {
            if let wallet = walletManager.currentWallet,
               let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) {
                recordingFeeSompi = KasiaTransactionBuilder.estimateContextualMessageFee(
                    payload: Data(count: Self.nextcloudLinkPayloadSize),
                    inputCount: 1,
                    senderScriptPubKey: senderScriptPubKey
                )
            }
            isEstimatingFee = false
            return
        }

        // During recording, estimate based on duration
        // After encoding, use actual file data
        let contentString: String
        let fileName: String
        let fileSize: Int
        let mime: String

        if let url = recordedAudioURL {
            // Use actual encoded file with real base64 content
            guard let data = try? Data(contentsOf: url) else {
                isEstimatingFee = false
                return
            }
            let base64 = data.base64EncodedString()
            fileName = url.lastPathComponent
            fileSize = data.count
            mime = mimeType(for: url)
            contentString = "data:\(mime);base64,\(base64)"
        } else if isRecording || isEncodingAudio {
            // Estimate based on current recording duration using dummy content
            let estimatedSize = estimateEncodedSize(forDuration: recordingDuration)
            let dummyContent = String(repeating: "x", count: estimatedSize)
            fileName = "audio.webm"
            fileSize = estimatedSize
            mime = "audio/webm"
            contentString = "data:\(mime);base64,\(dummyContent)"
        } else {
            return
        }

        isEstimatingFee = true
        recordingFeeTask = Task {
            do {
                // Same deterministic envelope the real send uses, so the estimate sizes the
                // exact bytes that will go on the wire - see MediaFileEnvelope.
                let jsonString = MediaFileEnvelope.json(
                    name: fileName,
                    size: fileSize,
                    mimeType: mime,
                    dataUrlContent: contentString
                )
                let estimate = try await chatService.estimateMessageFee(to: contact, content: jsonString)
                await MainActor.run {
                    self.recordingFeeSompi = estimate
                    self.feeEstimateSompi = estimate
                    self.isEstimatingFee = false
                }
            } catch {
                await MainActor.run {
                    self.recordingFeeSompi = nil
                    self.isEstimatingFee = false
                }
            }
        }
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
    }

    private func encodeRecording(from url: URL) async {
        await MainActor.run {
            self.isEstimatingFee = true
            self.isEncodingAudio = true
        }
        await waitForRecordingFile(url)
        // Nextcloud mode: stash the full-length original BEFORE the payload-capped encode —
        // the M4A upload exports from this copy so long recordings survive intact.
        if NextcloudService.shared.mediaSendEnabled, NextcloudService.shared.isConnected {
            let keepURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kachat-voice-original-\(UUID().uuidString).caf")
            if (try? FileManager.default.copyItem(at: url, to: keepURL)) != nil {
                await MainActor.run {
                    if let stale = nextcloudOriginalRecordingURL { secureDeleteTempFile(stale) }
                    nextcloudOriginalRecordingURL = keepURL
                }
            }
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-\(UUID().uuidString).webm")
        do {
            do {
                try await WebMOpusEncoder.encode(
                    pcmURL: url,
                    outputURL: outputURL,
                    bitrate: opusBitrate,
                    sampleRate: opusSampleRate,
                    maxBytes: maxAudioBytes
                )
            } catch let error as WebMOpusEncodingError {
                #if canImport(YbridOpus) || OPUS_BRIDGE || OPUS_CATALYST
                if case .audioReadFailed = error {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    try await WebMOpusEncoder.encode(
                        pcmURL: url,
                        outputURL: outputURL,
                        bitrate: opusBitrate,
                        sampleRate: opusSampleRate,
                        maxBytes: maxAudioBytes
                    )
                } else {
                    throw error
                }
                #else
                throw error
                #endif
            }
            await MainActor.run {
                self.recordedAudioURL = outputURL
                self.isEstimatingFee = false
                self.isEncodingAudio = false
            }
        } catch {
            secureDeleteTempFile(outputURL)
            await MainActor.run {
                self.recordedAudioURL = nil
                self.isEstimatingFee = false
                self.isEncodingAudio = false
                self.error = "Failed to encode audio: \(error.localizedDescription)"
            }
        }
    }

    private func waitForRecordingFile(_ url: URL) async {
        var lastSize: Int?
        for _ in 0..<5 {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
               size > 0 {
                if let last = lastSize, last == size {
                    return
                }
                lastSize = size
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "webm":
            return "audio/webm"
        case "ogg":
            return "audio/ogg"
        case "caf":
            return "audio/x-caf"
        default:
            return "audio/webm"
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }

    private func localizedFeeText(_ feeSompi: UInt64) -> String {
        let template = AppLocalization.string("fee: %@ KAS")
        return String(format: template, locale: AppLocalization.locale, formatKaspaExact(feeSompi))
    }

    private func localizedAvailableBalanceText(_ balanceSompi: UInt64?) -> String {
        let template = AppLocalization.string("available: %@ KAS")
        let value = balanceSompi.map(formatKaspaExact) ?? "--"
        return String(format: template, locale: AppLocalization.locale, value)
    }

    private func parseAmountSompi(_ text: String) -> UInt64 {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let decimal = Decimal(string: normalized) else { return 0 }
        let scaled = decimal * Decimal(100_000_000)
        return NSDecimalNumber(decimal: scaled).uint64Value
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "--:--" }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @MainActor
    private func sendAudioAsync() async {
        guard let url = recordedAudioURL else {
            self.error = "Audio is still being prepared. Please try again."
            return
        }

        do {
            let payloadData = try Data(contentsOf: url)
            let mime = mimeType(for: url)

            // "Send Media via Nextcloud" (1:1 chats only — this view): upload an AAC .m4a of
            // the recording and send the public share link instead of the on-chain WebM/Opus
            // envelope. The .m4a re-export matters: the recipient's link-preview audio card
            // streams through AVPlayer, which cannot decode WebM/Opus, so uploading the
            // envelope bytes verbatim would produce an unplayable card. Any failure falls
            // back to the on-chain path below, with a toast.
            if NextcloudService.shared.mediaSendEnabled, NextcloudService.shared.isConnected {
                recordingFeeTask?.cancel()
                isSending = true
                var shareURL: URL?
                do {
                    let m4aURL = try await exportRecordingAsM4A(webmData: payloadData)
                    let m4aData = try Data(contentsOf: m4aURL)
                    secureDeleteTempFile(m4aURL)
                    if let originalURL = nextcloudOriginalRecordingURL {
                        secureDeleteTempFile(originalURL)
                        nextcloudOriginalRecordingURL = nil
                    }
                    let stamp = Self.mediaTimestampFormatter.string(from: Date())
                    let voiceFilename = "voice_\(stamp).m4a"
                    shareURL = try await NextcloudService.shared.uploadMediaAndShare(
                        data: m4aData,
                        filename: voiceFilename,
                        contentType: "audio/mp4"
                    )
                    if let shareURL {
                        await seedNextcloudPreview(for: shareURL, kind: .audio, title: voiceFilename, byteSize: m4aData.count)
                    }
                } catch {
                    AppLog.log("[ChatDetailView] Nextcloud audio upload failed, falling back to on-chain: %@",
                               error.localizedDescription)
                    showToast("Nextcloud upload failed — sending on-chain instead", style: .error)
                }
                if let shareURL {
                    do {
                        try await chatService.sendMessage(to: contact, content: shareURL.absoluteString, feeOverride: nil)
                        if let previewURL = recordedAudioPreviewURL {
                            secureDeleteTempFile(previewURL)
                        }
                        if let encodedURL = recordedAudioURL {
                            secureDeleteTempFile(encodedURL)
                        }
                        recordedAudioURL = nil
                        recordedAudioPreviewURL = nil
                        recordingFeeSompi = nil
                        feeEstimateSompi = nil
                        stopPreview()
                        previewLabel = "--:--"
                        // Back to the normal text composer — staying in audio mode after a
                        // successful send left the "tap send to record" bar up.
                        switchMode(.message)
                    } catch {
                        // The chain send itself failed — an on-chain audio envelope would fail
                        // the same way, so surface the error instead of falling back.
                        if shouldPromptGiftClaim(for: error) {
                            NotificationCenter.default.post(name: .showGiftClaim, object: nil)
                        }
                        self.error = displayErrorMessage(error)
                    }
                    isSending = false
                    return
                }
                isSending = false
                // No share link — fall through to the on-chain envelope path.
            }

            recordingFeeTask?.cancel()
            isSending = true
            Task {
                do {
                    try await chatService.sendAudio(
                        to: contact,
                        audioData: payloadData,
                        fileName: url.lastPathComponent,
                        mimeType: mime
                    )
                    await MainActor.run {
                        if let previewURL = recordedAudioPreviewURL {
                            secureDeleteTempFile(previewURL)
                        }
                        if let encodedURL = recordedAudioURL {
                            secureDeleteTempFile(encodedURL)
                        }
                        recordedAudioURL = nil
                        recordedAudioPreviewURL = nil
                        recordingFeeSompi = nil
                        feeEstimateSompi = nil
                        stopPreview()
                        previewLabel = "--:--"
                        // Back to the normal text composer — staying in audio mode after a
                        // successful send left the "tap send to record" bar up.
                        switchMode(.message)
                    }
                } catch {
                    if shouldPromptGiftClaim(for: error) {
                        await MainActor.run {
                            NotificationCenter.default.post(name: .showGiftClaim, object: nil)
                        }
                    }
                    await MainActor.run {
                        self.error = displayErrorMessage(error)
                    }
                }
                await MainActor.run {
                    isSending = false
                }
            }
        } catch {
            self.error = "Failed to prepare audio: \(error.localizedDescription)"
        }
    }

    private func showToast(_ message: String, style: ToastStyle = .success) {
        let token = UUID()
        toastToken = token
        toastStyle = style
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func secureDeleteTempFile(_ url: URL?) {
        guard let url else { return }
        do {
            try secureDeleteFile(at: url)
        } catch {
            AppLog.log("[ChatDetailView] Secure delete failed for %@: %@", url.lastPathComponent, error.localizedDescription)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func secureDeleteFile(at url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if resourceValues.isRegularFile == true, let fileSize = resourceValues.fileSize, fileSize > 0 {
            let chunkSize = 64 * 1024
            let zeroChunk = Data(repeating: 0, count: chunkSize)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }

            try handle.seek(toOffset: 0)
            var remaining = fileSize
            while remaining > 0 {
                let bytesToWrite = min(remaining, chunkSize)
                if bytesToWrite == chunkSize {
                    try handle.write(contentsOf: zeroChunk)
                } else {
                    try handle.write(contentsOf: zeroChunk.prefix(bytesToWrite))
                }
                remaining -= bytesToWrite
            }
            try handle.synchronize()
        }

        try fileManager.removeItem(at: url)
    }

    private func displayErrorMessage(_ error: Error) -> String {
        if case let KasiaError.networkError(message) = error {
            return message
        }
        return error.localizedDescription
    }

    private func shouldShowRetryHint(for message: String) -> Bool {
        // Must match `ChatService+Conversations.formatInsufficientBalanceError`'s own lookup
        // (`AppLocalization`, not `NSLocalizedString`) - that's the language `message` was
        // actually generated in, which isn't necessarily the device's system language.
        let template = AppLocalization.string(
            "Planned spend %@ KAS, but available balance %@ KAS is less than required."
        ).lowercased()
        let parts = template.components(separatedBy: "%@").filter { !$0.isEmpty }
        if parts.isEmpty { return true }

        let lowered = message.lowercased()
        var searchStart = lowered.startIndex
        for part in parts {
            guard let range = lowered.range(of: part, range: searchStart..<lowered.endIndex) else {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private func shouldPromptGiftClaim(for error: Error) -> Bool {
        if case let KasiaError.networkError(message) = error {
            let lowered = message.lowercased()
            return lowered.contains("zero balance") || lowered.contains("available balance 0 kas")
        }
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("zero balance") || lowered.contains("available balance 0 kas")
    }

}

private extension View {
    @ViewBuilder
    func defaultScrollAnchorCompat(_ anchor: UnitPoint) -> some View {
        if #available(iOS 17.0, *) {
            self.defaultScrollAnchor(anchor)
        } else {
            self
        }
    }
}

struct ScrollViewIntrospector: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> ScrollViewIntrospectorView {
        let view = ScrollViewIntrospectorView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ScrollViewIntrospectorView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfNeeded()
    }
}

final class ScrollViewIntrospectorView: UIView {
    var onResolve: ((UIScrollView) -> Void)?
    private weak var resolvedScrollView: UIScrollView?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveIfNeeded()
    }

    func resolveIfNeeded() {
        var candidate: UIView? = self
        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                guard scrollView !== resolvedScrollView else { return }
                resolvedScrollView = scrollView
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    self.onResolve?(scrollView)
                }
                return
            }
            candidate = view.superview
        }
    }
}

#if canImport(YbridOpus) || OPUS_BRIDGE || OPUS_CATALYST
private enum WebMOpusEncodingError: LocalizedError {
    case invalidFormat(String)
    case conversionFailed(String)
    case audioReadFailed(String)
    case encoderInitFailed(Int32)
    case encoderSettingFailed(Int32)
    case encoderFailed(Int32)
    case noSamples

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let details):
            return "Unsupported audio format. \(details)"
        case .conversionFailed(let details):
            return "Audio conversion failed. \(details)"
        case .audioReadFailed(let details):
            return "Audio read failed. \(details)"
        case .encoderInitFailed(let code):
            return "Opus encoder init failed (\(code))."
        case .encoderSettingFailed(let code):
            return "Opus encoder setting failed (\(code))."
        case .encoderFailed(let code):
            return "Opus encoding failed (\(code))."
        case .noSamples:
            return "No audio samples to encode."
        }
    }
}

struct WebMOpusEncoder {
    static func encode(pcmURL: URL, outputURL: URL, bitrate: Int32, sampleRate: Double, maxBytes: Int? = nil) async throws {
        let pcmSamples = try await readFloatSamples(from: pcmURL, sampleRate: sampleRate)

        let totalFrames = pcmSamples.count
        guard totalFrames > 0 else {
            throw WebMOpusEncodingError.noSamples
        }

        var opusError: Int32 = 0
        guard let encoder = opus_encoder_create(Int32(sampleRate), 1, OPUS_APPLICATION_VOIP, &opusError) else {
            throw WebMOpusEncodingError.encoderInitFailed(opusError)
        }
        defer { opus_encoder_destroy(encoder) }

        let bitrateStatus = opus_encoder_set_bitrate(encoder, bitrate)
        if bitrateStatus != OPUS_OK {
            throw WebMOpusEncodingError.encoderSettingFailed(bitrateStatus)
        }
        _ = opus_encoder_set_vbr(encoder, 0)

        var lookahead: Int32 = 0
        _ = opus_encoder_get_lookahead(encoder, &lookahead)

        // Pre-skip must be in 48kHz samples per RFC 7845
        let preSkip48k = UInt16(clamping: Int(Double(lookahead) * 48000.0 / sampleRate))
        let opusHead = makeOpusHead(
            channels: 1,
            preSkip: preSkip48k,
            sampleRate: UInt32(sampleRate),
            outputGain: 0
        )

        let frameSize = max(1, Int(sampleRate / 50.0))
        var offset = 0
        var frameBuffer = [Float](repeating: 0, count: frameSize)
        var outputBuffer = [UInt8](repeating: 0, count: 1500)
        var packets: [Data] = []

        while offset < totalFrames {
            let remaining = totalFrames - offset
            let currentFrame = min(frameSize, remaining)
            frameBuffer.withUnsafeMutableBufferPointer { bufferPointer in
                if let base = bufferPointer.baseAddress {
                    memset(base, 0, frameSize * MemoryLayout<Float>.size)
                    pcmSamples.withUnsafeBufferPointer { samples in
                        if let source = samples.baseAddress?.advanced(by: offset) {
                            memcpy(base, source, currentFrame * MemoryLayout<Float>.size)
                        }
                    }
                }
            }

            let encodedSize = frameBuffer.withUnsafeBufferPointer { inputPointer in
                guard let baseAddress = inputPointer.baseAddress else {
                    return OPUS_BAD_ARG
                }
                return opus_encode_float(
                    encoder,
                    baseAddress,
                    Int32(frameSize),
                    &outputBuffer,
                    Int32(outputBuffer.count)
                )
            }
            if encodedSize < 0 {
                throw WebMOpusEncodingError.encoderFailed(encodedSize)
            }

            let packet = Data(outputBuffer[0..<Int(encodedSize)])
            packets.append(packet)
            offset += currentFrame
        }

        let durationSeconds = Double(totalFrames) / sampleRate
        let frameDurationMs = Int64((Double(frameSize) / sampleRate) * 1000.0)

        var webmData = buildWebM(
            packets: packets,
            opusHead: opusHead,
            sampleRate: sampleRate,
            durationSeconds: durationSeconds,
            frameDurationMs: frameDurationMs
        )

        if let maxBytes = maxBytes {
            while webmData.count > maxBytes, packets.count > 1 {
                packets.removeLast()
                webmData = buildWebM(
                    packets: packets,
                    opusHead: opusHead,
                    sampleRate: sampleRate,
                    durationSeconds: durationSeconds,
                    frameDurationMs: frameDurationMs
                )
            }
        }

        try webmData.write(to: outputURL, options: .atomic)
    }

    private static func readFloatSamples(from url: URL, sampleRate: Double) async throws -> [Float] {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue == 0 {
            throw WebMOpusEncodingError.noSamples
        }

        let asset = AVAsset(url: url)
        let track: AVAssetTrack
        if #available(iOS 16.0, *) {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let first = tracks.first else {
                throw WebMOpusEncodingError.audioReadFailed("No audio track found.")
            }
            track = first
        } else {
            guard let first = asset.tracks(withMediaType: .audio).first else {
                throw WebMOpusEncodingError.audioReadFailed("No audio track found.")
            }
            track = first
        }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WebMOpusEncodingError.audioReadFailed(error.localizedDescription)
        }
        guard reader.canAdd(output) else {
            throw WebMOpusEncodingError.audioReadFailed("Unable to add reader output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            let details = reader.error?.localizedDescription ?? "Reader start failed."
            throw WebMOpusEncodingError.audioReadFailed(details)
        }

        var samples = [Float]()
        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
            if status != kCMBlockBufferNoErr || dataPointer == nil || length == 0 {
                continue
            }
            let count = length / MemoryLayout<Float>.size
            let floatPointer = dataPointer!.withMemoryRebound(to: Float.self, capacity: count) { $0 }
            samples.append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: count))
        }
        if reader.status == .failed {
            let details = reader.error?.localizedDescription ?? "Reader failed."
            throw WebMOpusEncodingError.audioReadFailed(details)
        }
        return samples
    }

    private static func makeOpusHead(channels: UInt8, preSkip: UInt16, sampleRate: UInt32, outputGain: Int16) -> Data {
        var data = Data()
        data.append(contentsOf: Array("OpusHead".utf8))
        data.append(1)
        data.append(channels)
        data.append(contentsOf: le16(preSkip))
        data.append(contentsOf: le32(sampleRate))
        data.append(contentsOf: le16(UInt16(bitPattern: outputGain)))
        data.append(0)
        return data
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ]
    }

    private static func buildWebM(
        packets: [Data],
        opusHead: Data,
        sampleRate: Double,
        durationSeconds: Double,
        frameDurationMs: Int64
    ) -> Data {
        let ebmlHeader = makeEBMLHeader()
        let info = makeInfo(durationSeconds: durationSeconds)
        let tracks = makeTracks(opusHead: opusHead, sampleRate: sampleRate, channels: 1)
        let clusters = makeClusters(packets: packets, frameDurationMs: frameDurationMs)

        var segmentPayload = Data()
        segmentPayload.append(info)
        segmentPayload.append(tracks)
        segmentPayload.append(clusters)

        var segment = Data()
        segment.append(contentsOf: [0x18, 0x53, 0x80, 0x67])
        segment.append(encodeVint(UInt64(segmentPayload.count)))
        segment.append(segmentPayload)

        var output = Data()
        output.append(ebmlHeader)
        output.append(segment)
        return output
    }

    private static func makeEBMLHeader() -> Data {
        let elements = [
            makeElement(id: [0x42, 0x86], uint: 1),
            makeElement(id: [0x42, 0xF7], uint: 1),
            makeElement(id: [0x42, 0xF2], uint: 4),
            makeElement(id: [0x42, 0xF3], uint: 8),
            makeElement(id: [0x42, 0x82], string: "webm"),
            makeElement(id: [0x42, 0x87], uint: 4),
            makeElement(id: [0x42, 0x85], uint: 2)
        ]
        return makeElement(id: [0x1A, 0x45, 0xDF, 0xA3], payload: join(elements))
    }

    private static func makeInfo(durationSeconds: Double) -> Data {
        let timecodeScale: UInt64 = 1_000_000
        let durationMs = durationSeconds * 1000.0
        let elements = [
            makeElement(id: [0x2A, 0xD7, 0xB1], uint: timecodeScale),
            makeElement(id: [0x44, 0x89], float: durationMs),
            makeElement(id: [0x4D, 0x80], string: "kasia-ios"),
            makeElement(id: [0x57, 0x41], string: "kasia-ios")
        ]
        return makeElement(id: [0x15, 0x49, 0xA9, 0x66], payload: join(elements))
    }

    private static func makeTracks(opusHead: Data, sampleRate: Double, channels: UInt8) -> Data {
        let trackUID = UInt64(UInt32.random(in: UInt32.min...UInt32.max))
        let audio = makeElement(
            id: [0xE1],
            payload: join([
                makeElement(id: [0xB5], float: sampleRate),
                makeElement(id: [0x9F], uint: UInt64(channels))
            ])
        )

        let entryElements = [
            makeElement(id: [0xD7], uint: 1),
            makeElement(id: [0x73, 0xC5], uint: trackUID),
            makeElement(id: [0x83], uint: 2),
            makeElement(id: [0x86], string: "A_OPUS"),
            makeElement(id: [0x63, 0xA2], payload: opusHead),
            audio
        ]
        let entry = makeElement(id: [0xAE], payload: join(entryElements))
        return makeElement(id: [0x16, 0x54, 0xAE, 0x6B], payload: entry)
    }

    private static func join(_ parts: [Data]) -> Data {
        var data = Data()
        data.reserveCapacity(parts.reduce(0) { $0 + $1.count })
        for part in parts {
            data.append(part)
        }
        return data
    }

    private static func makeClusters(packets: [Data], frameDurationMs: Int64) -> Data {
        var clusters = Data()
        var timecode: Int64 = 0
        for packet in packets {
            clusters.append(makeCluster(timecodeMs: timecode, packet: packet))
            timecode += frameDurationMs
        }
        return clusters
    }

    private static func makeCluster(timecodeMs: Int64, packet: Data) -> Data {
        let timecodeElement = makeElement(id: [0xE7], uint: UInt64(timecodeMs))
        let simpleBlock = makeSimpleBlock(packet: packet)
        let payload = timecodeElement + simpleBlock
        return makeElement(id: [0x1F, 0x43, 0xB6, 0x75], payload: payload)
    }

    private static func makeSimpleBlock(packet: Data) -> Data {
        var block = Data()
        block.append(0x81) // Track number 1 (VINT)
        block.append(contentsOf: be16(0)) // Relative timecode
        block.append(0x00) // Flags
        block.append(packet)
        return makeElement(id: [0xA3], payload: block)
    }

    private static func makeElement(id: [UInt8], payload: Data) -> Data {
        var data = Data(id)
        data.append(encodeVint(UInt64(payload.count)))
        data.append(payload)
        return data
    }

    private static func makeElement(id: [UInt8], uint: UInt64) -> Data {
        makeElement(id: id, payload: encodeUnsigned(uint))
    }

    private static func makeElement(id: [UInt8], float: Double) -> Data {
        makeElement(id: id, payload: encodeFloat64(float))
    }

    private static func makeElement(id: [UInt8], string: String) -> Data {
        makeElement(id: id, payload: Data(string.utf8))
    }

    private static func encodeUnsigned(_ value: UInt64) -> Data {
        var bytes = [UInt8]()
        var temp = value
        repeat {
            bytes.insert(UInt8(temp & 0xFF), at: 0)
            temp >>= 8
        } while temp > 0
        return Data(bytes)
    }

    private static func encodeFloat64(_ value: Double) -> Data {
        let bits = value.bitPattern
        return Data([
            UInt8((bits >> 56) & 0xFF),
            UInt8((bits >> 48) & 0xFF),
            UInt8((bits >> 40) & 0xFF),
            UInt8((bits >> 32) & 0xFF),
            UInt8((bits >> 24) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8(bits & 0xFF)
        ])
    }

    private static func encodeVint(_ value: UInt64) -> Data {
        for length in 1...8 {
            let maxValue = (UInt64(1) << (7 * length)) - 1
            if value <= maxValue {
                var bytes = [UInt8](repeating: 0, count: length)
                var temp = value
                for i in 0..<length {
                    bytes[length - 1 - i] = UInt8(temp & 0xFF)
                    temp >>= 8
                }
                bytes[0] |= UInt8(1 << (8 - length))
                return Data(bytes)
            }
        }
        return unknownSize()
    }

    private static func unknownSize() -> Data {
        // EBML unknown size for length=8: 0x01 followed by 7x 0xFF.
        return Data([0x01] + Array(repeating: 0xFF, count: 7))
    }

    private static func be16(_ value: Int16) -> [UInt8] {
        let unsigned = UInt16(bitPattern: value)
        return [UInt8((unsigned >> 8) & 0xFF), UInt8(unsigned & 0xFF)]
    }
}
#else
private enum WebMOpusEncodingError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio encoding is not supported on this platform."
    }
}

struct WebMOpusEncoder {
    static func encode(pcmURL: URL, outputURL: URL, bitrate: Int32, sampleRate: Double, maxBytes: Int? = nil) async throws {
        throw WebMOpusEncodingError.unsupportedPlatform
    }
}
#endif

private final class AudioRecorderDelegate: NSObject, AVAudioRecorderDelegate {
    var onFinish: ((AVAudioRecorder, Bool) -> Void)?

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        onFinish?(recorder, flag)
    }
}


#Preview {
    NavigationStack {
        ChatDetailView(contact: Contact(
            address: "kaspa:qr1234567890abcdef1234567890abcdef12345678",
            alias: "Alice"
        ))
        .environmentObject(ChatService.shared)
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(SettingsViewModel())
    }
}

// MARK: - Shared Zero-Balance Funding Card

/// The zero-balance funding card - "fund your chatting address" title, gift-state-aware Claim
/// Gift, QR of the chatting address, and the address itself with a copy affordance. Shared by
/// the 1:1 chat gate (this file), `GroupChatDetailView`, `BroadcastChannelView`, and KaPosts'
/// compose/reply interception (`ZeroBalanceFundingSheetView` below). Lives in this file rather
/// than its own to avoid pbxproj churn - see the repo's dangling-reference history.
struct ZeroBalanceFundingCardView: View {
    let address: String?
    /// Called after the address hits the pasteboard so the host can show its own toast; when
    /// nil (sheet contexts without a toast helper) the copy icon flips to a checkmark instead.
    var onCopied: ((String) -> Void)? = nil
    /// Overrides the Claim Gift action. Default (nil) posts `.showGiftClaim`, which
    /// `MainTabView` turns into the existing `GiftClaimView` sheet - the right mechanism when
    /// the card is inline. Sheet hosts pass their own handler since MainTabView can't present
    /// while another sheet is already up.
    var onClaimGift: (() -> Void)? = nil

    @ObservedObject private var giftService = GiftService.shared
    @State private var qrImage: UIImage?
    @State private var showCopiedCheckmark = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Fund your chatting address to start chatting")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Claim Gift only while it's actually claimable — GiftService remembers a past
            // claim (persisted flag + live claimState), so a claimed/ineligible gift shows
            // an inert note instead of a button that would dead-end.
            switch giftService.claimState {
            case .claimed, .alreadyClaimed:
                Label("Gift already claimed", systemImage: "gift")
                    .font(.caption)
                    .foregroundColor(.secondary)
            default:
                Button {
                    Haptics.impact(.light)
                    if let onClaimGift {
                        onClaimGift()
                    } else {
                        // Re-triggers the existing gift-claim flow - MainTabView listens for
                        // this (same mechanism as `shouldPromptGiftClaim`-driven posts in
                        // ChatDetailView).
                        NotificationCenter.default.post(name: .showGiftClaim, object: nil)
                    }
                } label: {
                    Label("Claim Gift", systemImage: "gift.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            }

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .padding(8)
                    // Solid white behind the QR keeps it scannable in dark mode, where the
                    // glass material alone would leave the light modules too dim.
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
            }

            if let address {
                HStack(spacing: 8) {
                    Text(address)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        UIPasteboard.general.string = address
                        Haptics.success()
                        if let onCopied {
                            onCopied(address)
                        } else {
                            showCopiedCheckmark = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                showCopiedCheckmark = false
                            }
                        }
                    } label: {
                        Image(systemName: showCopiedCheckmark ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(6)
                            .background(cardGlassBackground(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy chatting address"))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardGlassBackground(cornerRadius: 20))
        .task(id: address) {
            guard let address else {
                qrImage = nil
                return
            }
            qrImage = Self.makeChattingAddressQRCode(from: address)
        }
    }

    /// Same glass treatment as the chat views' private `glassBackground` helpers.
    private func cardGlassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    /// Same CIFilter QR pattern as `ChatInfoView.makeQRCodeImage` - plain string payload, so
    /// any wallet/scanner reads the address directly.
    static func makeChattingAddressQRCode(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Sheet host for the funding card - used where the zero-balance gate intercepts an action
/// (KaPosts' new-post and reply entry points) instead of locking an always-visible composer.
/// Presents `GiftClaimView` in a nested sheet (MainTabView's `.showGiftClaim` listener can't
/// present its sheet while this one is up), and auto-dismisses the moment the chatting
/// balance turns positive.
struct ZeroBalanceFundingSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walletManager = WalletManager.shared
    @State private var showGiftClaimSheet = false

    var body: some View {
        ScrollView {
            ZeroBalanceFundingCardView(
                address: walletManager.currentWallet?.publicAddress,
                onClaimGift: { showGiftClaimSheet = true }
            )
            .padding(.horizontal)
            .padding(.top, 20)
            .padding(.bottom, 16)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showGiftClaimSheet) {
            GiftClaimView()
        }
        .onChange(of: walletManager.currentWallet?.balanceSompi) { balance in
            if let balance, balance > 0 { dismiss() }
        }
    }
}
