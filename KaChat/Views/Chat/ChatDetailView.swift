import SwiftUI
import AVFoundation
import AVFAudio
#if canImport(YbridOpus)
import YbridOpus
#endif

struct ChatDetailView: View {
    private final class ScrollViewReference {
        weak var scrollView: UIScrollView?
    }

    private struct PrependViewportSnapshot {
        let contentHeight: CGFloat
        let offsetY: CGFloat
    }

    @State private var contact: Contact
    @State private var showChatInfo = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var toastStyle: ToastStyle = .success

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.colorScheme) private var colorScheme

    init(contact: Contact) {
        _contact = State(initialValue: contact)
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
    @State private var previousMessagesCount = 0
    @State private var lastMessageSnapshotDigest: Int?
    @State private var snapshotRebuildTask: Task<Void, Never>?
    @State private var hasIncomingHandshakeMessage = false
    @State private var hasOutgoingHandshakeMessage = false
    @State private var hasAnyPaymentMessage = false
    @State private var hasAnyIncomingMessage = false
    @State private var isLoadingOlderMessages = false
    @State private var lastOlderPageRequestAt: Date = .distantPast
    @State private var topVisibleMessageId: UUID?
    @State private var isBottomAnchorVisible = false
    @State private var isTopAnchorVisible = false
    @State private var isUserInteractingWithScroll = false
    @State private var scrollInteractionResetWorkItem: DispatchWorkItem?
    @State private var lastAutoBottomScrollAt: Date = .distantPast
    @State private var newMessagesWhileScrolledUp = 0
    @State private var hasLoadedCurrentTopPage = false
    @State private var isPrefetchingOlderMessages = false
    @State private var lastOlderPrefetchAt: Date = .distantPast
    @State private var initialViewportPositioned = false
    @State private var initialScrollAnchorMessageId: UUID?
    @State private var scrollViewReference = ScrollViewReference()
    @State private var pendingPrependViewportSnapshot: PrependViewportSnapshot?
    @State private var storedCountTask: Task<Void, Never>?
    @State private var initialUnreadCount = 0
    @State private var initialReadBlockTime: Int64 = 0
    @State private var isRespondingHandshake = false
    @State private var feeEstimateSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var feeEstimateTask: Task<Void, Never>?
    @State private var inputMode: InputMode = .message
    @State private var amountText = ""
    @State private var recordedAudioURL: URL?
    @State private var recordedAudioPreviewURL: URL?
    @State private var isRecording = false
    @State private var recorder: AVAudioRecorder?
    @State private var recordingTimer: Timer?
    @State private var recordingDuration: TimeInterval = 0
    @State private var recordingFeeSompi: UInt64?
    @State private var recordingFeeTask: Task<Void, Never>?
    @State private var feeShimmerPhase: CGFloat = -1
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewTimer: Timer?
    @State private var previewIsPlaying = false
    @State private var previewLabel = "--:--"
    @State private var isEncodingAudio = false
    @State private var recorderDelegate = AudioRecorderDelegate()
    @State private var hasPerformedInitialSetup = false
    @State private var showModeMenu = false
    @State private var dragLocation: CGPoint = .zero
    @State private var hoveredModeIndex: Int? = nil
    @State private var menuAnchorFrame: CGRect = .zero
    @State private var longPressTimer: Timer? = nil
    @State private var isDraggingMenu = false
    @State private var isMessageFocused = false
    @State private var viewportResetTrigger = UUID()
    @State private var showDustWarning = false
    @State private var pendingDustAmountSompi: UInt64 = 0
    @FocusState private var isPaymentFocused: Bool

    private let maxRecordingDuration: TimeInterval = 10 // seconds
    private let maxAudioBytes: Int = 13_000
    private let opusBitrate: Int32 = 6_000
    private let opusSampleRate: Double = 48_000

    private var conversation: Conversation? {
        chatService.conversations.first { $0.contact.address == contact.address }
    }

    private var isFeeEstimationEnabled: Bool {
        settingsViewModel.settings.feeEstimationEnabled
    }

    private var contactBalanceSompi: UInt64? {
        if let wallet = walletManager.currentWallet, wallet.publicAddress == contact.address {
            return wallet.balanceSompi
        }
        return contactsManager.balanceSompi(for: contact.address)
    }

    private var messages: [ChatMessage] {
        normalizedMessages
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
        hasIncomingHandshakeMessage = deduped.contains {
            $0.messageType == .handshake && !$0.isOutgoing && $0.deliveryStatus != .failed
        }
        hasOutgoingHandshakeMessage = deduped.contains {
            $0.messageType == .handshake && $0.isOutgoing && $0.deliveryStatus != .failed
        }
        hasAnyPaymentMessage = deduped.contains {
            $0.messageType == .payment && $0.deliveryStatus != .failed
        }
        hasAnyIncomingMessage = deduped.contains {
            !$0.isOutgoing && $0.deliveryStatus != .failed
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
        content == "📤 Sent via another device" || content == "[Encrypted message]"
    }

    private var hasPendingHandshake: Bool {
        // If both directions exist, the handshake exchange is complete
        if hasIncomingHandshakeMessage && hasOutgoingHandshakeMessage { return false }
        return hasIncomingHandshakeMessage && !chatService.hasOurAlias(for: contact.address)
    }

    private var hasAnyHandshake: Bool {
        hasIncomingHandshakeMessage || hasOutgoingHandshakeMessage
    }

    private var awaitingOutgoingHandshakeResponse: Bool {
        // If both directions exist, the handshake exchange is complete
        if hasIncomingHandshakeMessage && hasOutgoingHandshakeMessage { return false }
        return hasOutgoingHandshakeMessage && !chatService.hasTheirAlias(for: contact.address)
    }

    private var handshakeComplete: Bool {
        let bothMessages = hasIncomingHandshakeMessage && hasOutgoingHandshakeMessage
        let hasRouting = chatService.hasRoutingState(for: contact.address)
        return bothMessages || hasRouting || (chatService.hasOurAlias(for: contact.address) && chatService.hasTheirAlias(for: contact.address))
    }

    private var isDeclined: Bool {
        chatService.isConversationDeclined(contact.address)
    }

    private var shouldShowUnnotifiedWarning: Bool {
        let hasOutgoing = normalizedMessages.contains { $0.isOutgoing && $0.deliveryStatus != .failed }
        return hasOutgoing
            && !hasIncomingHandshakeMessage
            && !hasOutgoingHandshakeMessage
            && !hasAnyPaymentMessage
            && !hasAnyIncomingMessage
    }

    private let chatCoordinateSpace = "chatCoordinateSpace"

    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
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
                            Color.clear
                                .frame(height: 1)
                                .id("top_anchor")
                                .onAppear {
                                    isTopAnchorVisible = true
                                    triggerTopPaginationIfNeeded(using: proxy)
                                }
                                .onDisappear {
                                    isTopAnchorVisible = false
                                    hasLoadedCurrentTopPage = false
                                }
                            ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                                messageRow(message)
                                    .id(message.id)
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
                            if shouldShowUnnotifiedWarning {
                                unnotifiedMessageBanner
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("bottom_anchor")
                                .onAppear {
                                    isBottomAnchorVisible = true
                                }
                                .onDisappear {
                                    isBottomAnchorVisible = false
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top)
                    }
                    .defaultScrollAnchorCompat(initialScrollAnchorMessageId == nil ? .bottom : .top)
                    .opacity(initialViewportPositioned ? 1 : 0)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 44)
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
                            .padding(.bottom, 76)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .animation(.easeInOut(duration: 0.2), value: isBottomAnchorVisible)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
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
                        guard didInitialScroll else {
                            didInitialScroll = true
                            return
                        }
                        if isBottomAnchorVisible && !isUserInteractingWithScroll {
                            let now = Date()
                            if now.timeIntervalSince(lastAutoBottomScrollAt) > 0.12 {
                                lastAutoBottomScrollAt = now
                                scrollToBottom(using: proxy, animated: false)
                            }
                        } else {
                            newMessagesWhileScrolledUp += 1
                        }
                        didInitialScroll = true
                    }
                    .onChange(of: isBottomAnchorVisible) { visible in
                        if visible {
                            newMessagesWhileScrolledUp = 0
                            hasLoadedCurrentTopPage = false
                        }
                    }
                    .onChange(of: isMessageFocused) { focused in
                        if focused {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                scrollToBottom(using: proxy, animated: true)
                            }
                        }
                    }
                    .onChange(of: isPaymentFocused) { focused in
                        if focused {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                scrollToBottom(using: proxy, animated: true)
                            }
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
                }

                bottomFade
                    .offset(y: 115)

                // Unified Input Bar (floats over content)
                inputBar
                    .padding(.bottom, 2)
            }

            // Drag-selectable mode menu overlay
            if showModeMenu {
                // Tap-to-dismiss background (only active when not dragging)
                if !isDraggingMenu {
                    Color.black.opacity(0.01)
                        .ignoresSafeArea()
                        .onTapGesture {
                            showModeMenu = false
                            hoveredModeIndex = nil
                        }
                }

                dragSelectableMenu
            }
        }
        .coordinateSpace(name: chatCoordinateSpace)
        .toast(message: toastMessage, style: toastStyle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ConnectionStatusIndicator()
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Button {
                        showChatInfo = true
                    } label: {
                        Text(contact.alias)
                            .font(.headline)
                            .foregroundColor(.primary)
                    }

                    if settingsViewModel.settings.showContactBalance, let sompi = contactBalanceSompi {
                        let exact = formatKaspaExact(sompi)
                        let isWallet = walletManager.currentWallet?.publicAddress == contact.address
                        ShimmeringText(
                            text: "\(exact) KAS",
                            font: .caption,
                            color: .secondary,
                            isShimmering: isWallet && walletManager.isBalanceRefreshing
                        )
                        .onTapGesture {
                            UIPasteboard.general.string = exact
                            Haptics.success()
                            showToast("Balance copied to clipboard.")
                            showChatInfo = true
                        }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = contact.address
                    Haptics.success()
                    showToast("Address copied to clipboard.")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .sheet(isPresented: $showChatInfo) {
            ChatInfoView(contact: $contact)
                .environmentObject(contactsManager)
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
        .onChange(of: amountText) { newValue in
            schedulePaymentFee(for: newValue)
        }
        .onChange(of: settingsViewModel.settings.feeEstimationEnabled) { enabled in
            if enabled {
                switch inputMode {
                case .message:
                    scheduleFeeEstimate(for: messageText)
                case .payment:
                    schedulePaymentFee(for: amountText)
                case .audio:
                    updateRecordingFee()
                }
            } else {
                clearFeeEstimationState()
            }
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
                rebuildMessageSnapshotIfNeeded(force: true)
                initialUnreadCount = max(0, conversation?.unreadCount ?? 0)
                let readCursor = chatService.readCursor(for: contact.address)
                initialReadBlockTime = readCursor?.blockTime ?? 0
                configureInitialMessageWindow()
                initialLayoutReady = true
                didInitialScroll = false
                hasPerformedInitialSetup = true
            }
            chatService.enterConversation(for: contact.address)
            if messageText.isEmpty {
                messageText = chatService.draft(for: contact.address)
            }
            previousMessagesCount = messages.count
            // Mark conversation as read once when view appears
            if let conversation = conversation {
                chatService.markConversationAsRead(conversation)
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
            cancelRecording()
            snapshotRebuildTask?.cancel()
            storedCountTask?.cancel()
            scrollInteractionResetWorkItem?.cancel()
            pendingPrependViewportSnapshot = nil
            // Do NOT reset viewport/scroll state here — @State is destroyed
            // automatically on navigation pop, and on tab switches we want
            // to preserve the scroll position and loaded message count.
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { notification in
            guard let targetAddress = notification.userInfo?["contactAddress"] as? String,
                  targetAddress != contact.address else { return }
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
            inputMode = .message
            amountText = ""
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
            rebuildMessageSnapshotIfNeeded(force: true)
            initialUnreadCount = max(0, conversation?.unreadCount ?? 0)
            let readCursor = chatService.readCursor(for: newContact.address)
            initialReadBlockTime = readCursor?.blockTime ?? 0
            configureInitialMessageWindow()
            previousMessagesCount = messages.count
            chatService.enterConversation(for: newContact.address)
            messageText = chatService.draft(for: newContact.address)
            if let conv = chatService.conversations.first(where: { $0.contact.address == newContact.address }) {
                chatService.markConversationAsRead(conv)
            }
            viewportResetTrigger = UUID()
            Task {
                await contactsManager.refreshBalance(for: newContact.address)
            }
        }
        .onChange(of: messages.count) { newCount in
            let oldCount = previousMessagesCount
            previousMessagesCount = newCount
            totalStoredMessages = max(totalStoredMessages, messages.count)
            if initialViewportPositioned,
               newCount > oldCount,
               !isBottomAnchorVisible {
                loadedMessageCount = min(
                    max(loadedMessageCount + (newCount - oldCount), messagePageSize),
                    max(newCount, messagePageSize)
                )
            }
            if loadedMessageCount == 0 {
                configureInitialMessageWindow()
            } else {
                loadedMessageCount = min(max(loadedMessageCount, messagePageSize), max(messages.count, messagePageSize))
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

    private func initialAnchorIndex() -> Int? {
        guard !messages.isEmpty else { return nil }
        // If there are no unread incoming messages, open near the latest context
        // instead of honoring possibly stale read cursors.
        guard initialUnreadCount > 0 else { return nil }

        if initialReadBlockTime > 0 {
            let hasVisibleReadBoundary = messages.contains {
                !$0.isOutgoing && Int64($0.blockTime) <= initialReadBlockTime
            }
            guard hasVisibleReadBoundary else { return nil }

            if let firstUnreadIncomingIndex = messages.firstIndex(where: {
                !$0.isOutgoing && Int64($0.blockTime) > initialReadBlockTime
            }) {
                return max(0, firstUnreadIncomingIndex - 1)
            }
            // Cursor exists but unread boundary not found in this window; do not
            // fall back to txId because it may be stale and place us mid-history.
            return nil
        }

        // Use unreadCount fallback only when read blockTime is unavailable.
        guard initialReadBlockTime <= 0 else { return nil }

        let incomingIndices = messages.enumerated().compactMap { offset, message in
            message.isOutgoing ? nil : offset
        }
        // Use unread count only when it can be mapped into currently loaded incoming messages.
        // If unread count is larger than available incoming messages, it is likely stale for this
        // in-memory window and we should fall back to recent-window open instead of oldest.
        if !incomingIndices.isEmpty, initialUnreadCount < incomingIndices.count {
            let firstUnreadIncomingPosition = incomingIndices[incomingIndices.count - initialUnreadCount]
            return max(0, firstUnreadIncomingPosition - 1)
        }
        return nil
    }

    private func configureInitialMessageWindow() {
        messagePageSize = configuredMessagePageSize()
        if let anchorIndex = initialAnchorIndex() {
            // Open directly at the read anchor: show anchor message at top and newer messages below.
            // Older history is loaded only when user scrolls up.
            loadedMessageCount = min(messages.count, max(1, messages.count - anchorIndex))
            initialScrollAnchorMessageId = messages[anchorIndex].id
        } else {
            let targetWindow = max(initialMessageWindowSize(), messagePageSize)
            loadedMessageCount = min(messages.count, targetWindow)
            initialScrollAnchorMessageId = nil
        }
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
            loadedMessageCount = min(messages.count, loadedMessageCount + batchSize)
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
                loadedMessageCount = min(messages.count, loadedMessageCount + loaded)
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

    private var dragSelectableMenu: some View {
        let items = availableModeMenuItems
        let itemHeight: CGFloat = 44
        let menuWidth: CGFloat = 200
        let menuHeight = CGFloat(items.count) * itemHeight + 16 // padding

        // Position menu above the button, aligned to the right edge of the button
        let menuCenterX = menuAnchorFrame.maxX - menuWidth / 2
        let menuCenterY = menuAnchorFrame.minY - menuHeight / 2 - 8

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack {
                    Image(systemName: item.icon)
                        .frame(width: 24)
                    Text(item.title)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: itemHeight)
                .background(hoveredModeIndex == index ? Color.accentColor.opacity(0.3) : Color.clear)
                .foregroundColor(item.isDestructive ? .red : .primary)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 8)
        .frame(width: menuWidth)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        )
        .position(x: menuCenterX, y: menuCenterY)
        .allowsHitTesting(false) // Gesture is handled by the send button
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

    private struct ModeMenuItem: Identifiable {
        let id = UUID()
        let title: LocalizedStringKey
        let icon: String
        let isDestructive: Bool
        let action: () -> Void
    }

    private var availableModeMenuItems: [ModeMenuItem] {
        if isDeclined {
            return []
        }
        var items: [ModeMenuItem] = [
            ModeMenuItem(title: "Send message", icon: "text.bubble", isDestructive: false) { switchMode(.message) },
            ModeMenuItem(title: "Send KAS", icon: "k.circle", isDestructive: false) { switchMode(.payment) },
            ModeMenuItem(title: "Send audio", icon: "mic", isDestructive: false) { switchMode(.audio) }
        ]
        if !hasOutgoingHandshakeMessage && !hasIncomingHandshakeMessage {
            items.append(ModeMenuItem(title: "Request to communicate", icon: "hand.wave", isDestructive: false) {
                sendHandshake()
            })
        }
        return items
    }

    // MARK: - Unnotified Message Warning

    private var unnotifiedMessageBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
                .padding(.top, 1)
            Text("When you message someone new on KaChat, they won’t get a notification and your message stays hidden until they message you back or add as well. This protects against spam and increases your privacy. If you want them to be notified, hold the send button and slide up to request to communicate. This will cost 0.2 KAS. (Note: all non KaChat messaging apps will require a request to communicate)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
        .padding(.top, 8)
    }

    // MARK: - Unified Input Bar (handles all handshake states)

    private var inputBar: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 12) {
                    inputFieldWithState

                    sendButtonWithMenu
                }

                if shouldShowFeeRow && !isDeclined {
                    feeBubble
                        .offset(x: 32, y: -26)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var bottomFade: some View {
        let fadeColor = colorScheme == .dark ? Color.black : Color.white
        return Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.clear, fadeColor.opacity(1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 160)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
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

    private var sendButtonWithMenu: some View {
        Group {
            if isDeclined {
                EmptyView()
            } else {
                sendButtonWithGesture(
                    tapAction: { handleSend() },
                    isDisabled: !canSend
                )
            }
        }
    }

    private func sendButtonWithGesture(tapAction: @escaping () -> Void, isDisabled: Bool) -> some View {
        GeometryReader { geometry in
            sendButtonLabel
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(glassBackground(cornerRadius: 14))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(chatCoordinateSpace))
                        .onChanged { value in
                            dragLocation = value.location

                            // Start long press timer on first touch (always allowed, even when disabled)
                            if longPressTimer == nil && !showModeMenu {
                                let buttonFrame = geometry.frame(in: .named(chatCoordinateSpace))
                                longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
                                    DispatchQueue.main.async {
                                        Haptics.impact(.medium)
                                        menuAnchorFrame = buttonFrame
                                        showModeMenu = true
                                        isDraggingMenu = true
                                    }
                                }
                            }

                            // Update hovered item if menu is showing
                            if showModeMenu {
                                updateHoveredItem(at: value.location)
                            }
                        }
                        .onEnded { value in
                            let wasMenuShowing = showModeMenu
                            let hadTimer = longPressTimer != nil

                            // Cancel timer
                            longPressTimer?.invalidate()
                            longPressTimer = nil

                            if wasMenuShowing && isDraggingMenu {
                                // Menu was shown - execute selected item or dismiss
                                if let index = hoveredModeIndex {
                                    let items = availableModeMenuItems
                                    if index < items.count {
                                        Haptics.impact(.light)
                                        items[index].action()
                                    }
                                }
                                showModeMenu = false
                                hoveredModeIndex = nil
                                isDraggingMenu = false
                            } else if !wasMenuShowing && hadTimer && !isDisabled {
                                // Was a short tap - execute tap action (only if not disabled)
                                tapAction()
                            }
                        }
                )
                .opacity(isDisabled ? 0.5 : 1.0)
        }
        .frame(width: 44, height: 44)
    }

    private func updateHoveredItem(at location: CGPoint) {
        let items = availableModeMenuItems
        let itemHeight: CGFloat = 44
        let menuWidth: CGFloat = 200
        let menuHeight = CGFloat(items.count) * itemHeight + 16

        // Same positioning as dragSelectableMenu
        let menuCenterX = menuAnchorFrame.maxX - menuWidth / 2
        let menuCenterY = menuAnchorFrame.minY - menuHeight / 2 - 8

        let menuLeft = menuCenterX - menuWidth / 2
        let menuRightEdge = menuCenterX + menuWidth / 2
        let menuTop = menuCenterY - menuHeight / 2

        // Check if within horizontal bounds
        if location.x >= menuLeft && location.x <= menuRightEdge {
            let relativeY = location.y - menuTop - 8 // account for padding
            let index = Int(relativeY / itemHeight)

            if index >= 0 && index < items.count {
                if hoveredModeIndex != index {
                    Haptics.selection()
                    hoveredModeIndex = index
                }
            } else {
                hoveredModeIndex = nil
            }
        } else {
            hoveredModeIndex = nil
        }
    }

    private var sendButtonLabel: some View {
        Group {
            if isSendActionBusy {
                ProgressView()
                    .font(.title)
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
            return true
        case .payment:
            return canSendPayment
        case .audio:
            return !isSending
        }
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
            contactsManager.setContactArchived(address: contact.address, isArchived: true)
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
        feeEstimateSompi = nil
        isEstimatingFee = false

        Task {
            do {
                try await chatService.sendMessage(to: contact, content: text)
            } catch {
                if shouldPromptGiftClaim(for: error) {
                    await MainActor.run {
                        NotificationCenter.default.post(name: .showGiftClaim, object: nil)
                    }
                }
                let errorMsg = error.localizedDescription
                NSLog("[ChatDetailView] Send message failed: %@", errorMsg)
                await MainActor.run {
                    self.error = displayErrorMessage(error)
                }
            }
        }
    }

    private var paymentField: some View {
        HStack {
            TextField("Amount (KAS)", text: $amountText)
                .keyboardType(.decimalPad)
                .focused($isPaymentFocused)
                .onChange(of: amountText) { newValue in
                    amountText = sanitizedAmount(newValue)
                }
            Button("Max") {
                Task {
                    do {
                        let maxSompi = try await chatService.estimateMaxPaymentAmount(to: contact)
                        await MainActor.run {
                            let kas = Double(maxSompi) / 100_000_000.0
                            amountText = String(format: "%.8f", kas)
                        }
                    } catch {
                        print("[ChatDetail] Max calculation failed: \(error)")
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
                ComposerTextView(
                    text: $messageText,
                    isFocused: $isMessageFocused,
                    onTextChange: { newValue in
                        scheduleFeeEstimate(for: newValue)
                        if inputMode == .message {
                            chatService.setDraft(newValue, for: contact.address)
                        }
                    },
                    onSubmit: { handleSend() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(glassBackground(cornerRadius: 20))
            case .payment:
                paymentField
            case .audio:
                HStack {
                    if isRecording {
                        ProgressView()
                        Text("Recording… \(Int(recordingDuration))s")
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
                        Text("Audio ready • \(previewLabel)")
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

    private var feeBubble: some View {
        HStack(spacing: 6) {
            if isEstimatingFee {
                Text("fee: ---- sompi")
            } else if let fee = feeEstimateSompi ?? recordingFeeSompi {
                Text("fee: \(fee) sompi")
            } else {
                Text("fee: -- sompi")
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
        .onAppear {
            updateFeeShimmer()
        }
        .onChange(of: isEstimatingFee) { _ in
            updateFeeShimmer()
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

    private struct FeeShimmerOverlay: View {
        let phase: CGFloat

        var body: some View {
            GeometryReader { geo in
                let width = geo.size.width
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.0),
                                Color.white.opacity(0.22),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .rotationEffect(.degrees(20))
                    .offset(x: phase * width * 1.5)
            }
        }
    }

    private func switchMode(_ mode: InputMode) {
        // Check if keyboard is currently open
        let wasKeyboardOpen = isMessageFocused || isPaymentFocused

        inputMode = mode
        feeEstimateSompi = nil
        isEstimatingFee = false
        if mode != .payment { amountText = "" }
        if mode != .message { messageText = "" }
        if mode != .audio {
            cancelRecording()
        }

        // Transfer focus to keep keyboard open when switching between message and payment
        if wasKeyboardOpen {
            // Small delay to let SwiftUI update the view hierarchy
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
            sendMessage()
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
                    feeEstimateSompi = nil
                    isEstimatingFee = false
                }
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
        MessageBubbleView(
            message: message,
            onCopy: showToast,
            onRetry: retryOutgoingMessage,
            onAcceptHandshake: needsHandshakeResponse ? { acceptHandshake() } : nil,
            onDeclineHandshake: needsHandshakeResponse ? { declineHandshake() } : nil
        )
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

    private var shouldShowFeeRow: Bool {
        guard isFeeEstimationEnabled else { return false }
        switch inputMode {
        case .message:
            return !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .payment:
            return !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .audio:
            return isRecording || isEncodingAudio || recordedAudioPreviewURL != nil
        }
    }

    private func scheduleFeeEstimate(for text: String) {
        feeEstimateTask?.cancel()
        guard isFeeEstimationEnabled else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }

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
                let estimate = try await chatService.estimateMessageFee(to: contact, content: trimmed)
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

    private func schedulePaymentFee(for text: String) {
        feeEstimateTask?.cancel()
        guard isFeeEstimationEnabled else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }

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
                    self.isEncodingAudio = false
                    self.recordingDuration = 0
                    self.feeEstimateSompi = nil
                    self.recordingFeeSompi = nil
                    self.isEstimatingFee = self.isFeeEstimationEnabled
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

    private func sendAudio() {
        Task { await sendAudioAsync() }
    }

    private func preparePreview() {
        guard let audioURL = recordedAudioURL else { return }
        stopPreview()
        do {
            // Decode WebM/Opus to CAF for preview playback (same quality as recipient will hear)
            let audioData = try Data(contentsOf: audioURL)
            let decoded = try decodeWebMForPreview(data: audioData)

            // Clean up old preview file
            if let oldPreview = recordedAudioPreviewURL {
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
            if recordingDuration >= maxRecordingDuration {
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
        guard isFeeEstimationEnabled else {
            recordingFeeSompi = nil
            if inputMode == .audio {
                feeEstimateSompi = nil
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
                let payload: [String: Any] = [
                    "type": "file",
                    "name": fileName,
                    "size": fileSize,
                    "mimeType": mime,
                    "content": contentString
                ]
                let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
                guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
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
            self.isEstimatingFee = self.isFeeEstimationEnabled
            self.isEncodingAudio = true
        }
        await waitForRecordingFile(url)
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
                #if canImport(YbridOpus) || OPUS_CATALYST
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

    private func formatKaspa(sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
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
            NSLog("[ChatDetailView] Secure delete failed for %@: %@", url.lastPathComponent, error.localizedDescription)
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
        let lowered = message.lowercased()
        return !(lowered.contains("planned spend")
                 && lowered.contains("available balance")
                 && lowered.contains("less than required"))
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

private struct ScrollViewIntrospector: UIViewRepresentable {
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

private final class ScrollViewIntrospectorView: UIView {
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

#if canImport(YbridOpus) || OPUS_CATALYST
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

private struct WebMOpusEncoder {
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

    private static func formatDescription(_ format: AVAudioFormat) -> String {
        let interleaved = format.isInterleaved ? "interleaved" : "non-interleaved"
        let common: String
        switch format.commonFormat {
        case .pcmFormatInt16:
            common = "int16"
        case .pcmFormatInt32:
            common = "int32"
        case .pcmFormatFloat32:
            common = "float32"
        case .pcmFormatFloat64:
            common = "float64"
        case .otherFormat:
            common = "other"
        @unknown default:
            common = "unknown"
        }
        return "\(common) \(format.sampleRate)Hz ch=\(format.channelCount) \(interleaved)"
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

private struct WebMOpusEncoder {
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
