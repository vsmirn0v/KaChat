import SwiftUI
import AVFoundation

/// A single broadcast channel's message stream + compose bar.
/// Public and unencrypted - anyone who has joined the same channel name can read and
/// post here. Reuses iOS's existing row/compose visual language rather than mirroring
/// Android's screen design, while matching its feature set (replies, per-message actions,
/// avatar actions, delivery status, date dividers, scroll-to-bottom).
struct BroadcastChannelView: View {
    let channelName: String

    @EnvironmentObject var broadcastService: BroadcastService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject private var knsService = KNSService.shared
    /// Drives the "Send Media via Nextcloud" voice path, mirroring 1:1/group chat: with the
    /// toggle active, mic captures upload to the server and the room only carries the share link.
    @ObservedObject private var nextcloudService = NextcloudService.shared
    @StateObject private var recorder = BroadcastAudioRecorder()

    /// Nextcloud-uploaded voice notes aren't payload-bound - only the server carries them - so
    /// the recording ceiling relaxes to 10 minutes while "Send Media via Nextcloud" is active,
    /// mirroring `ChatDetailView.effectiveMaxRecordingDuration`.
    private var effectiveMaxRecordingDuration: TimeInterval {
        (nextcloudService.isConnected && nextcloudService.mediaSendEnabled)
            ? 600
            : BroadcastAudioRecorder.maxDuration
    }

    @State private var messageText = ""
    @State private var isMessageFocused = false
    @State private var showDesktopEmojiPicker = false
    @State private var emojiInsertionRequest: ComposerTextView.TextInsertionRequest?
    @State private var isSending = false
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var openContact: Contact?
    @State private var openContactInPaymentMode = false
    @State private var profileContact: Contact?
    @State private var isBottomAnchorVisible = true
    @State private var bottomAnchorVisibilityWorkItem: DispatchWorkItem?
    @State private var feeEstimateSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var feeEstimateTask: Task<Void, Never>?
    @State private var feeShimmerPhase: CGFloat = -1
    @State private var revealOffset: CGFloat = 0
    private let maxRevealOffset: CGFloat = 64
    /// User-set fee, from tapping the fee pill - see ChatDetailView.feeOverrideSompi's doc comment.
    @State private var feeOverrideSompi: UInt64?
    @State private var showFeeEditor = false
    @State private var feeEditorText = ""
    /// Tap-a-reply-quote-to-jump-to-original - mirrors `ChatDetailView`/`GroupChatDetailView`'s
    /// identical pair. `BroadcastMessage.id` is already the wire txId, unlike 1:1/group's `UUID`
    /// row ids, so this stays a `String` throughout.
    @State private var pendingJumpToTxId: String?
    @State private var showHiddenUsers = false
    @State private var highlightedMessageID: String?
    /// Which message (if any) currently has its double-tap quick-reaction bar open - mirrors
    /// group chat's identical `GroupChatDetailView.activeQuickReactionMessageId`, except broadcast
    /// row ids are the wire txId `String` rather than a local `UUID`.
    @State private var activeQuickReactionMessageId: String?

    private var myAddress: String? {
        walletManager.currentWallet?.publicAddress
    }

    /// Zero-balance compose gate - same trigger as 1:1 chat (confirmed 0 KAS only, never on an
    /// unknown/still-loading balance). See `WalletManager.hasConfirmedZeroChattingBalance`.
    private var isChattingBalanceZero: Bool {
        walletManager.hasConfirmedZeroChattingBalance
    }

    /// Indexer-tracked curated channel (#kaspa / #kachat-bugs): history comes from the
    /// broadcast indexer and retention is fixed at 3 days.
    private var isIndexedChannel: Bool {
        BroadcastService.featuredChannels.contains(BroadcastChannelName.normalize(channelName))
    }

    var body: some View {
        messageList
            // Hosting the compose bar as a real `safeAreaInset` (rather than a floating ZStack
            // overlay with a manually-tracked keyboard offset) is what guarantees it always sits
            // flush above the keyboard on every device - this is the mechanism SwiftUI itself
            // uses for keyboard avoidance, so there's no custom math to get wrong. See
            // ChatDetailView's identical fix for why the old floating approach left a gap.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if isChattingBalanceZero {
                        // Zero-balance gate: reading stays fully usable (the card is part of
                        // the bottom inset, never an overlay on the message list) - only
                        // composing is blocked. Mirrors 1:1 chat's gate exactly.
                        ZeroBalanceFundingCardView(
                            address: myAddress,
                            onCopied: { _ in showToast("Address copied to clipboard.") }
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composeBar
                        .disabled(isChattingBalanceZero)
                        .allowsHitTesting(!isChattingBalanceZero)
                        .grayscale(isChattingBalanceZero ? 1 : 0)
                        .opacity(isChattingBalanceZero ? 0.45 : 1)
                }
                .animation(.easeInOut(duration: 0.25), value: isChattingBalanceZero)
                .padding(.bottom, 2)
            }
            // Permanent notice on the indexed channels - pinned above the messages, never
            // dismissable.
            .safeAreaInset(edge: .top, spacing: 0) {
                if isIndexedChannel {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                        Text("All messages are public and are stored for 3 days only.")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
                }
            }
        .navigationTitle("#\(channelName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ConnectionStatusIndicator()
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showHiddenUsers = true
                } label: {
                    Image(systemName: "person.crop.circle.badge.xmark")
                }
                .accessibilityLabel("Hidden users in this room")
            }
        }
        .sheet(isPresented: $showHiddenUsers) {
            NavigationStack {
                HiddenBroadcastSendersView(channel: channelName)
            }
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: Binding(
            get: { openContact != nil },
            set: { if !$0 { openContact = nil } }
        )) {
            if let openContact {
                ChatDetailView(contact: openContact, startInPaymentMode: openContactInPaymentMode)
            } else {
                EmptyView()
            }
        }
        .sheet(isPresented: Binding(
            get: { profileContact != nil },
            set: { if !$0 { profileContact = nil } }
        )) {
            if let contact = profileContact {
                NavigationStack {
                    ChatInfoView(
                        contact: Binding(
                            get: { profileContact ?? contact },
                            set: { profileContact = $0 }
                        ),
                        title: "User Info",
                        showsNotificationSettings: false
                    )
                }
            }
        }
        .toast(message: toastMessage, style: .success)
        .alert("Adjust Network Fee", isPresented: $showFeeEditor) {
            TextField("Fee (KAS)", text: $feeEditorText)
                .keyboardType(.decimalPad)
            Button("Save") { commitFeeOverride() }
            Button("Use Default") {
                feeOverrideSompi = nil
                scheduleFeeEstimate(for: messageText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the network is busy, a higher fee can help your transaction confirm faster.")
        }
        .onAppear {
            broadcastService.acquire(channelName)
        }
        .onDisappear {
            broadcastService.release(channelName)
        }
        .task {
            // Keeps retention feeling "live" while this room is open - a message actually
            // disappears a few seconds after it expires instead of only on next open/send.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                broadcastService.pruneNowAndRefresh(forChannel: channelName)
            }
        }
        .task(id: myAddress) {
            // Your own avatar always resolves regardless of the auto-avatar-search toggle (that
            // toggle only gates *other* senders, for privacy) - fetched once at the room level
            // rather than per-row, since a per-row `.task` can get cancelled/restarted as its
            // bubble scrolls in and out of the lazy message list's visible viewport.
            guard broadcastService.showKnsAvatarsEnabled, let myAddress,
                  knsService.profileCache[myAddress] == nil else { return }
            _ = await knsService.fetchProfile(for: myAddress)
        }
        .onChange(of: recorder.state) { state in
            switch state {
            case .failed(let message):
                showToast(message)
                feeEstimateSompi = nil
            case .recording:
                updateRecordingFeeEstimate(elapsedSeconds: 0)
            case .idle:
                feeEstimateSompi = nil
            case .encoding:
                break
            }
        }
    }

    private var messageList: some View {
        let messages = broadcastService.messages(forChannel: channelName)
        return Group {
            if messages.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                    if shouldShowDateDivider(at: index, in: messages) {
                                        dateDivider(for: message.blockTime)
                                    }
                                    let messageReplyQuote = replyQuote(for: message)
                                    BroadcastMessageRow(
                                        message: message,
                                        isOwnMessage: message.senderAddress == myAddress,
                                        avatarURLString: broadcastService.showKnsAvatarsEnabled
                                            ? knsService.profileCache[message.senderAddress]?.avatarURL
                                            : nil,
                                        displayName: displayName(for: message.senderAddress),
                                        replyQuote: messageReplyQuote,
                                        replySenderDisplayName: messageReplyQuote.map { displayName(for: $0.replyToSender) },
                                        onViewProfile: { viewProfile(message.senderAddress) },
                                        onOpenChat: { openChat(with: message.senderAddress) },
                                        onPayInKaspa: { openChat(with: message.senderAddress, paymentMode: true) },
                                        onCopyAddress: {
                                            UIPasteboard.general.string = message.senderAddress
                                            showToast("Address copied.")
                                        },
                                        onHideSender: { broadcastService.hideSender(message.senderAddress, inChannel: channelName) },
                                        onReply: { broadcastService.startReplyTo(message) },
                                        onCopyMessage: {
                                            UIPasteboard.general.string = displayContent(for: message).text
                                            showToast("Message copied.")
                                        },
                                        onRetry: { broadcastService.retryBroadcast(message) },
                                        onJumpToReply: messageReplyQuote != nil ? { pendingJumpToTxId = messageReplyQuote?.replyToId } : nil,
                                        reactions: broadcastService.reactions(forChannel: channelName)[message.id] ?? [],
                                        myReactorAddress: myAddress ?? "",
                                        onRetryReaction: { reaction in
                                            Task {
                                                try? await broadcastService.retryBroadcastReaction(
                                                    channel: channelName,
                                                    targetTxId: reaction.targetTxId,
                                                    emoji: reaction.emoji,
                                                    action: reaction.failedAction ?? "add"
                                                )
                                            }
                                        },
                                        onReact: { emoji in
                                            let existing = broadcastService.reactions(forChannel: channelName)[message.id]?
                                                .first { $0.reactorAddress == myAddress }
                                            let action = existing?.emoji == emoji ? "remove" : "add"
                                            Task {
                                                try? await broadcastService.sendBroadcastReaction(
                                                    channel: channelName,
                                                    targetTxId: message.id,
                                                    emoji: emoji,
                                                    action: action
                                                )
                                            }
                                        },
                                        activeQuickReactionMessageId: $activeQuickReactionMessageId,
                                        revealOffset: revealOffset,
                                        maxRevealOffset: maxRevealOffset
                                    )
                                    .id(message.id)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(highlightedMessageID == message.id ? Color.accentColor.opacity(0.18) : Color.clear)
                                    )
                                    .task(id: message.senderAddress) {
                                        // Own address is always fetched by the room-level `.task`
                                        // above; this only opts *other* senders in when the
                                        // KNS avatars toggle is on.
                                        guard broadcastService.showKnsAvatarsEnabled,
                                              message.senderAddress != myAddress,
                                              knsService.profileCache[message.senderAddress] == nil else { return }
                                        _ = await knsService.fetchProfile(for: message.senderAddress)
                                    }
                                }
                                // Debounced rather than setting `isBottomAnchorVisible` directly:
                                // this 1pt marker can appear/disappear many times per second
                                // during a fast scroll/fling as it crosses the lazy-loaded
                                // viewport edge, and since it drives an `.animation(value:)` below,
                                // each flip was re-triggering a full transition rapid-fire enough
                                // to pin the main thread and freeze the app.
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom_anchor")
                                    .onAppear {
                                        bottomAnchorVisibilityWorkItem?.cancel()
                                        let workItem = DispatchWorkItem { isBottomAnchorVisible = true }
                                        bottomAnchorVisibilityWorkItem = workItem
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                                    }
                                    .onDisappear {
                                        bottomAnchorVisibilityWorkItem?.cancel()
                                        let workItem = DispatchWorkItem { isBottomAnchorVisible = false }
                                        bottomAnchorVisibilityWorkItem = workItem
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
                                    }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: messages.count) { _ in
                            scrollToBottom(using: proxy, animated: true)
                        }
                        .onChange(of: pendingJumpToTxId) { id in
                            guard let id else { return }
                            jumpToReplyOriginal(id: id, in: messages, using: proxy)
                            pendingJumpToTxId = nil
                        }
                        .onAppear {
                            scrollToBottom(using: proxy, animated: false)
                        }
                        // Same interactive drag-down keyboard dismissal as ChatDetailView - the
                        // room's keyboard had no way down other than sending a message.
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(
                            // Swipe-left-to-reveal-timestamps (iMessage-style), matching Android:
                            // dragging left across the message list shifts every row left by the
                            // same amount, uncovering each message's time on the right; releasing
                            // snaps everything back. Only engages for mostly-horizontal drags so
                            // the ScrollView's own vertical scrolling still works normally.
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
                            // quick-reaction bar is open - mirrors 1:1/group chat's identical gesture.
                            TapGesture().onEnded {
                                if activeQuickReactionMessageId != nil {
                                    activeQuickReactionMessageId = nil
                                }
                            }
                        )

                        if !isBottomAnchorVisible {
                            Button {
                                Haptics.impact(.light)
                                scrollToBottom(using: proxy, animated: true)
                            } label: {
                                Circle()
                                    .fill(.regularMaterial)
                                    .overlay(
                                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                                    )
                                    .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.primary)
                                    )
                            }
                            .padding(.trailing, 12)
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .animation(.easeInOut(duration: 0.2), value: isBottomAnchorVisible)
                        }
                    }
                }
            }
        }
    }

    /// Tap-a-reply-quote-to-jump-to-original - broadcast has no pagination (the full room
    /// history is already in `messages`), so a jump either finds the target right away or it's
    /// genuinely gone (pruned/undelivered).
    private func jumpToReplyOriginal(id: String, in messages: [BroadcastMessage], using proxy: ScrollViewProxy) {
        guard messages.contains(where: { $0.id == id }) else {
            showToast("Original message not available.")
            return
        }
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

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo("bottom_anchor", anchor: .bottom) }
            } else {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }
    }

    private func shouldShowDateDivider(at index: Int, in messages: [BroadcastMessage]) -> Bool {
        guard index > 0 else { return true }
        let previous = Date(timeIntervalSince1970: Double(messages[index - 1].blockTime) / 1000)
        let current = Date(timeIntervalSince1970: Double(messages[index].blockTime) / 1000)
        return !Calendar.current.isDate(previous, inSameDayAs: current)
    }

    private func dateDivider(for blockTime: Int64) -> some View {
        let date = Date(timeIntervalSince1970: Double(blockTime) / 1000)
        return HStack {
            Spacer()
            Text(formatDateDivider(date))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func formatDateDivider(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return SharedFormatting.chatDay.string(from: date)
    }

    /// Reply text -> the underlying content, or voice-message placeholder if applicable.
    private func displayContent(for message: BroadcastMessage) -> (text: String, replyQuote: MessageReplyContent?) {
        if let reply = MessageReplyCodec.parse(message.content) {
            return (reply.text, reply)
        }
        return (message.content, nil)
    }

    private func replyQuote(for message: BroadcastMessage) -> MessageReplyContent? {
        MessageReplyCodec.parse(message.content)
    }

    private func displayName(for address: String) -> String {
        if let contact = contactsManager.getContact(byAddress: address), !contact.alias.isEmpty {
            return contact.alias
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No messages yet")
                .font(.headline)
            Text("Be the first to post in #\(channelName).")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var composeBar: some View {
        VStack(spacing: 8) {
            if let reply = broadcastService.replyingTo {
                replyBanner(for: reply)
            }
            ZStack(alignment: .topLeading) {
                if recorder.state == .recording || recorder.state == .encoding {
                    recordingBar
                } else {
                    HStack(spacing: 12) {
                        ComposerTextView(
                            text: $messageText,
                            isFocused: $isMessageFocused,
                            onTextChange: { newValue in
                                scheduleFeeEstimate(for: newValue)
                            },
                            onSubmit: { send() },
                            placeholder: "Message #\(channelName)",
                            insertionRequest: emojiInsertionRequest,
                            onInsertionHandled: { requestID in
                                if emojiInsertionRequest?.id == requestID {
                                    emojiInsertionRequest = nil
                                }
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(glassBackground(cornerRadius: 20))

                        if EmojiInputSupport.shouldShowDesktopEmojiButton {
                            desktopEmojiButton
                        }

                        // Only a mic/voice-message icon here, matching 1:1 chat's look but
                        // deliberately without its photo picker - broadcasts don't support
                        // photo attachments (only text and voice messages).
                        sendOrRecordButton
                    }
                }

                if shouldShowFeeBubble {
                    feeBubble
                        .offset(x: 32, y: -26)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: broadcastService.replyingTo) { _ in
            scheduleFeeEstimate(for: messageText)
        }
        .onChange(of: recorder.elapsedSeconds) { elapsed in
            updateRecordingFeeEstimate(elapsedSeconds: elapsed)
            guard elapsed >= effectiveMaxRecordingDuration, recorder.state == .recording else { return }
            stopAndSendRecording()
        }
    }

    private var desktopEmojiButton: some View {
        Button {
            showDesktopEmojiPicker.toggle()
            isMessageFocused = true
        } label: {
            Image(systemName: "face.smiling")
                .font(.title3)
                .foregroundColor(.primary)
                .frame(width: 36, height: 36)
                .background(glassBackground(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Emoji picker"))
        .popover(isPresented: $showDesktopEmojiPicker, arrowEdge: .bottom) {
            DesktopEmojiPickerView { emoji in
                insertDesktopEmoji(emoji)
            }
        }
    }

    private func insertDesktopEmoji(_ emoji: String) {
        isMessageFocused = true
        emojiInsertionRequest = ComposerTextView.TextInsertionRequest(id: UUID(), text: emoji)
    }

    private var sendOrRecordButton: some View {
        Group {
            if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    recorder.start()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                        .frame(width: 36, height: 36)
                        .background(glassBackground(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Record voice message"))
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundColor(isSending ? .secondary : .accentColor)
                        .frame(width: 36, height: 36)
                        .background(glassBackground(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityLabel(Text("Send"))
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

    private var shouldShowFeeBubble: Bool {
        guard settingsViewModel.settings.showFeeEstimate else { return false }
        if recorder.state == .recording || recorder.state == .encoding { return true }
        return !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var feeBubble: some View {
        Group {
            if isEstimatingFee {
                Text("fee: -------- KAS")
            } else if let fee = feeOverrideSompi ?? feeEstimateSompi {
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
            guard !isEstimatingFee, let currentFee = feeOverrideSompi ?? feeEstimateSompi else { return }
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

    private func commitFeeOverride() {
        guard let kas = Double(feeEditorText), kas >= 0 else { return }
        feeOverrideSompi = UInt64((kas * 100_000_000).rounded())
        scheduleFeeEstimate(for: messageText)
    }

    private func localizedFeeText(_ feeSompi: UInt64) -> String {
        let template = AppLocalization.string("fee: %@ KAS")
        return String(format: template, locale: AppLocalization.locale, formatKaspaExact(feeSompi))
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

    private func scheduleFeeEstimate(for text: String) {
        feeEstimateTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }
        isEstimatingFee = true
        feeEstimateTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                let estimate = try await broadcastService.estimateBroadcastFee(channel: channelName, content: trimmed, feeOverride: feeOverrideSompi)
                guard !Task.isCancelled else { return }
                feeEstimateSompi = estimate
                isEstimatingFee = false
            } catch {
                guard !Task.isCancelled else { return }
                feeEstimateSompi = nil
                isEstimatingFee = false
            }
        }
    }

    /// A Nextcloud share link's worst-case payload size in bytes - matches
    /// `ChatDetailView.nextcloudLinkPayloadSize` (private there; small local copy per this
    /// file's convention).
    private static let nextcloudLinkPayloadSize = 96

    /// Live estimate while a voice message is still being recorded, matching Android's
    /// `VoiceMessage.estimatedWirePayloadSize` heuristic (final size isn't known until encoding).
    private func updateRecordingFeeEstimate(elapsedSeconds: TimeInterval) {
        // Via Nextcloud, the recording uploads to the server and the chain only carries the
        // share link - the fee is the link-message fee regardless of recording length,
        // mirroring 1:1 chat's identical branch.
        if nextcloudService.isConnected && nextcloudService.mediaSendEnabled {
            isEstimatingFee = false
            feeEstimateSompi = broadcastService.estimateBroadcastFee(
                channel: channelName,
                payloadByteCount: Self.nextcloudLinkPayloadSize
            )
            return
        }
        let baseOverheadBytes = 150.0
        let bytesPerSecondOfRecording = 2870.0
        let estimatedBytes = Int(baseOverheadBytes + elapsedSeconds * bytesPerSecondOfRecording)
        isEstimatingFee = false
        feeEstimateSompi = broadcastService.estimateBroadcastFee(channel: channelName, payloadByteCount: estimatedBytes)
    }

    private var recordingBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    recorder.cancel()
                    feeEstimateSompi = nil
                } label: {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)

                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundColor(.red)

                Text(recorder.state == .encoding ? "Encoding…" : "Recording... \(Int(recorder.elapsedSeconds))s")
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(glassBackground(cornerRadius: 20))

            Button {
                stopAndSendRecording()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundColor(recorder.state == .encoding ? .secondary : .accentColor)
                    .frame(width: 36, height: 36)
                    .background(glassBackground(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(recorder.state == .encoding)
        }
    }

    private func stopAndSendRecording() {
        // Snapshot once, so the toggle flipping mid-send can't strand the stashed original -
        // mirrors `GroupChatDetailView.sendRecording`.
        let nextcloudActive = nextcloudService.mediaSendEnabled && nextcloudService.isConnected
        let recordedSeconds = recorder.elapsedSeconds
        Task {
            // Nextcloud mode: stash the full-length original PCM BEFORE the payload-capped WebM
            // encode - the encode truncates to ~13KB (≈9s), and exporting the M4A from that
            // would silently re-cap a long recording. The copy lives only for this send; the
            // defer below is its single cleanup site.
            let originalPCMURL: URL? = nextcloudActive
                ? FileManager.default.temporaryDirectory
                    .appendingPathComponent("kachat-broadcast-voice-original-\(UUID().uuidString).caf")
                : nil
            defer {
                if let originalPCMURL {
                    try? FileManager.default.removeItem(at: originalPCMURL)
                }
            }
            do {
                let recorded = try await recorder.stopAndEncode(keepOriginalPCMAt: originalPCMURL)

                // "Send Media via Nextcloud": upload an AAC .m4a of the recording and send the
                // public share link as a plain text broadcast (the link-preview feature renders
                // it as a playable audio card). The .m4a re-export matters: the recipients'
                // audio card streams through AVPlayer, which cannot decode WebM/Opus. Mirrors
                // `ChatDetailView.sendAudioAsync`/`GroupChatDetailView.sendRecording`.
                if nextcloudActive {
                    var shareURL: URL?
                    var voiceFilename = ""
                    var uploadedByteCount = 0
                    do {
                        let m4aURL = try await exportRecordingAsM4A(originalPCMURL: originalPCMURL, webmData: recorded.data)
                        let m4aData = try Data(contentsOf: m4aURL)
                        try? FileManager.default.removeItem(at: m4aURL)
                        let stamp = Self.mediaTimestampFormatter.string(from: Date())
                        voiceFilename = "voice_\(stamp).m4a"
                        uploadedByteCount = m4aData.count
                        shareURL = try await NextcloudService.shared.uploadMediaAndShare(
                            data: m4aData,
                            filename: voiceFilename,
                            contentType: "audio/mp4"
                        )
                    } catch {
                        AppLog.log("[BroadcastChannelView] Nextcloud audio upload failed, falling back to on-chain: %@",
                                   error.localizedDescription)
                        // The on-chain envelope is payload-capped (~9s) - a longer Nextcloud-mode
                        // recording would arrive silently truncated, so surface an error instead
                        // of falling back.
                        if recordedSeconds > BroadcastAudioRecorder.maxDuration {
                            showToast("Nextcloud upload failed, and the recording is too long to send on-chain.")
                            return
                        }
                        showToast("Nextcloud upload failed — sending on-chain instead")
                    }
                    if let shareURL {
                        // Seed the preview BEFORE the send so the sender's own bubble renders
                        // the audio card instantly, with zero network - see
                        // `ChatDetailView.seedNextcloudPreview`.
                        await seedNextcloudPreview(for: shareURL, kind: .audio, title: voiceFilename, byteSize: uploadedByteCount)
                        try await broadcastService.sendBroadcast(channel: channelName, content: shareURL.absoluteString)
                        return
                    }
                    // No share link - fall through to the on-chain envelope path.
                }

                try await broadcastService.sendBroadcastAudio(
                    channel: channelName,
                    audioData: recorded.data,
                    fileName: recorded.fileName,
                    mimeType: recorded.mimeType
                )
            } catch {
                showToast("Failed to send voice message: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Nextcloud media send helpers ("Send Media via Nextcloud" toggle)

    /// Human-sortable timestamp for uploaded media filenames (voice_20260811-101502.m4a) -
    /// duplicated from `ChatDetailView` (private there), matching this file's convention of
    /// small local copies over widened access.
    private static let mediaTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Pre-seeds the link-preview cache with what we just uploaded - the sender's own bubble
    /// renders the media card instantly with zero network, no probe round trip needed (we
    /// KNOW the kind/name/size; only recipients have to discover them). Mirrors
    /// `ChatDetailView.seedNextcloudPreview`.
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

    /// Builds an AAC .m4a of the current recording for the Nextcloud upload. PCM source: the
    /// stashed full-length original (never truncated by the payload cap) when it exists, else
    /// the WebM payload is decoded on the spot. Mirrors `GroupChatDetailView.exportRecordingAsM4A`.
    private func exportRecordingAsM4A(originalPCMURL: URL?, webmData: Data) async throws -> URL {
        let pcmURL: URL
        let deletePCMAfter: Bool
        if let originalPCMURL, FileManager.default.fileExists(atPath: originalPCMURL.path) {
            pcmURL = originalPCMURL
            deletePCMAfter = false // stopAndSendRecording's defer owns this copy, not here
        } else {
            pcmURL = try WebMOpusDecoder.decodeToPCMFile(data: webmData).url
            deletePCMAfter = true
        }
        defer {
            if deletePCMAfter { try? FileManager.default.removeItem(at: pcmURL) }
        }

        guard let export = AVAssetExportSession(asset: AVURLAsset(url: pcmURL),
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw KasiaError.networkError("Audio export is unavailable on this device.")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kachat-broadcast-voice-\(UUID().uuidString).m4a")
        export.outputURL = outputURL
        export.outputFileType = .m4a
        // AVAssetExportSession isn't Sendable, but this is safe: after exportAsynchronously
        // starts, the session is only touched from its own one-shot completion callback -
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

    private func replyBanner(for reply: BroadcastMessage) -> some View {
        let content = displayContent(for: reply)
        return HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(displayName(for: reply.senderAddress))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
                Text(MessageReplyCodec.previewText(for: content.text))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                broadcastService.cancelReply()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func send() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messageText = ""
        isSending = true
        let feeOverride = feeOverrideSompi
        feeEstimateSompi = nil
        feeOverrideSompi = nil
        Task {
            do {
                try await broadcastService.sendBroadcast(channel: channelName, content: trimmed, feeOverride: feeOverride)
            } catch {
                showToast("Failed to send: \(error.localizedDescription)")
            }
            isSending = false
        }
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        let kas = Double(sompi) / 100_000_000.0
        return String(format: "%.8f", kas)
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if toastToken == token {
                withAnimation(.easeIn(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func openChat(with address: String, paymentMode: Bool = false) {
        guard address != myAddress else { return }
        let contact = contactsManager.getContact(byAddress: address)
            ?? contactsManager.getOrCreateContact(address: address)
        _ = chatService.getOrCreateConversation(for: contact)
        openContactInPaymentMode = paymentMode
        openContact = contact
    }

    private func viewProfile(_ address: String) {
        let contact = contactsManager.getContact(byAddress: address)
            ?? contactsManager.getOrCreateContact(address: address)
        profileContact = contact
    }
}

private struct BroadcastMessageRow: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    let message: BroadcastMessage
    let isOwnMessage: Bool
    let avatarURLString: String?
    let displayName: String
    let replyQuote: MessageReplyContent?
    let replySenderDisplayName: String?
    let onViewProfile: () -> Void
    let onOpenChat: () -> Void
    let onPayInKaspa: () -> Void
    let onCopyAddress: () -> Void
    let onHideSender: () -> Void
    let onReply: () -> Void
    let onCopyMessage: () -> Void
    let onRetry: () -> Void
    /// Tapping the reply quote (if any) jumps to and highlights the original message - nil when
    /// `replyQuote` is nil, since there's nothing to jump to.
    var onJumpToReply: (() -> Void)?
    /// This message's current reactions (one per reactor), for the pill shown on its corner -
    /// same `GroupStore.ReactionSnapshot` shape group bubbles use (see `BroadcastStore.fetchReactions`).
    var reactions: [GroupStore.ReactionSnapshot] = []
    /// The local wallet's address, used to find *my* reaction among `reactions` so the pill can
    /// show my reaction's status (pending → nothing, sent → green check, failed → red error + Retry).
    var myReactorAddress: String = ""
    /// Retries the local user's failed reaction on this message (nil disables the reaction Retry).
    var onRetryReaction: ((GroupStore.ReactionSnapshot) -> Void)? = nil
    /// Sends/toggles a reaction on this message - nil disables the double-tap quick-reaction bar
    /// entirely (matches group chat's `GroupMessageBubbleRow.onReact`).
    var onReact: ((String) -> Void)?
    /// Shared across every bubble in the room (not per-bubble `@State`) - mirrors group chat's
    /// identical binding, keyed by the broadcast row's `String` txId.
    var activeQuickReactionMessageId: Binding<String?> = .constant(nil)
    let revealOffset: CGFloat
    let maxRevealOffset: CGFloat

    @State private var showFullText = false

    private var showQuickReactionBar: Bool {
        activeQuickReactionMessageId.wrappedValue == message.id
    }

    /// The local user's own reaction on this message, if any - only our own reactions ever carry
    /// a pending/failed status, so this uniquely finds the one needing the status icon + Retry.
    private var localReaction: GroupStore.ReactionSnapshot? {
        reactions.first { $0.reactorAddress == myReactorAddress }
    }

    /// Status to show on the reaction pill. Same as `localReaction`'s status, except the green
    /// "sent" checkmark is dropped once the reaction is older than 10 minutes - it's a recent
    /// confirmation, not a permanent badge (pending/failed are always shown). Matches
    /// `GroupMessageBubbleRow.pillReactionStatus`.
    private var pillReactionStatus: ChatMessage.DeliveryStatus? {
        guard let localReaction else { return nil }
        guard localReaction.deliveryStatus == .sent else { return localReaction.deliveryStatus }
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - localReaction.blockTime
        return ageMs < 600_000 ? .sent : nil
    }

    /// See `MessageBubbleView.inlineTextTruncationThreshold`'s doc comment - broadcast rooms are
    /// public/unencrypted, so a huge wall of text (e.g. stray base64) landing here is if anything
    /// more likely than in a private chat.
    private static let inlineTextTruncationThreshold = 2_000
    private static let truncatedPreviewLength = 500

    private var displayText: String {
        replyQuote?.text ?? message.content
    }

    private var voicePayload: VoiceMessageSniff.Payload? {
        VoiceMessageSniff.decode(displayText)
    }

    private var timeText: String {
        SharedFormatting.chatTime.string(from: Date(timeIntervalSince1970: Double(message.blockTime) / 1000))
    }

    /// 0 at rest, 1 once fully dragged open - matches Android's `-revealOffsetPx / maxRevealOffsetPx`.
    private var revealProgress: CGFloat {
        min(max(-revealOffset / maxRevealOffset, 0), 1)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(timeText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.trailing, 12)
                .opacity(revealProgress)

            HStack(alignment: .bottom, spacing: 8) {
                if !isOwnMessage {
                    avatarButton
                } else {
                    Spacer(minLength: 40)
                }

                VStack(alignment: isOwnMessage ? .trailing : .leading, spacing: 3) {
                    // Sits directly above the bubble in normal layout flow, same as 1:1/group
                    // chat - an `.overlay` with a manual offset gets cropped by the ScrollView's
                    // own clipping instead of rendering cleanly above the row.
                    if showQuickReactionBar, let onReact {
                        QuickReactionBarView(
                            emojis: settingsViewModel.settings.effectiveQuickReactionEmojis,
                            onReact: { emoji in
                                onReact(emoji)
                                activeQuickReactionMessageId.wrappedValue = nil
                            },
                            onReply: {
                                onReply()
                                activeQuickReactionMessageId.wrappedValue = nil
                            }
                        )
                        .frame(maxWidth: .infinity, alignment: isOwnMessage ? .trailing : .leading)
                    }

                    Text(isOwnMessage ? "You" : displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)

                    if let replyQuote {
                        replyQuoteView(replyQuote)
                    }

                    bubble

                    trailingLinkPreview

                    // A reaction (not the message) that failed to send - shown for reactions on
                    // any message (yours or another sender's), matching group chat.
                    if let localReaction, localReaction.deliveryStatus == .failed {
                        Text("Retry")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                            .contentShape(Rectangle())
                            .onTapGesture { onRetryReaction?(localReaction) }
                    }
                }

                if isOwnMessage {
                    avatarButton
                } else {
                    Spacer(minLength: 40)
                }
            }
            .offset(x: revealOffset)
        }
    }

    private var avatarButton: some View {
        Menu {
            Button {
                onViewProfile()
            } label: {
                Label("View Profile", systemImage: "person.crop.circle")
            }
            if !isOwnMessage {
                Button {
                    onOpenChat()
                } label: {
                    Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
                }
            }
            Button {
                onCopyAddress()
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            if !isOwnMessage {
                Button {
                    onPayInKaspa()
                } label: {
                    Label {
                        Text("Pay in Kaspa")
                    } icon: {
                        Image("KaspaLogo")
                            .resizable()
                            .scaledToFit()
                    }
                }
            }
            if !isOwnMessage {
                Button(role: .destructive) {
                    onHideSender()
                } label: {
                    Label("Hide User", systemImage: "eye.slash")
                }
            }
        } label: {
            KNSAvatarView(avatarURLString: avatarURLString, fallbackText: displayName, size: 32)
        }
        .tint(.accentColor)
    }

    private func replyQuoteView(_ reply: MessageReplyContent) -> some View {
        VStack(alignment: isOwnMessage ? .trailing : .leading, spacing: 2) {
            Text(replySenderDisplayName ?? String(reply.replyToSender.suffix(10)))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            Text(reply.replyToPreview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(isOwnMessage ? .trailing : .leading)
        }
        .padding(8)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 240, alignment: isOwnMessage ? .trailing : .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onJumpToReply?()
        }
    }

    /// The first link in the message, if any - offered as "Open Link"/"Copy Link" entries in the
    /// same long-press menu as the rest of the message's actions, rather than a separate gesture
    /// competing with that menu (a plain tap never opens a link here; only this menu can).
    private var firstLink: URL? {
        MessageTextRenderPlan.firstHTTPLink(in: displayText)
    }

    @ViewBuilder
    private func bubbleContent(voicePayload: VoiceMessageSniff.Payload?) -> some View {
        if let voicePayload {
            BroadcastAudioBubble(data: voicePayload.data, isOwnMessage: isOwnMessage)
        } else if displayText.utf8.count > Self.inlineTextTruncationThreshold {
            truncatedTextContent
        } else if MessageTextRenderPlan.requiresLinkTextView(displayText) {
            LinkifiedMessageTextView(
                text: displayText,
                isOutgoing: isOwnMessage,
                isSingleEmojiOnly: false,
                onLinkLongPress: { _ in },
                tapOpensLink: false
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            Text(displayText)
                .foregroundColor(isOwnMessage ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var truncatedTextContent: some View {
        Button {
            showFullText = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(displayText.prefix(Self.truncatedPreviewLength)) + "…")
                    .foregroundColor(isOwnMessage ? .white : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Show More")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isOwnMessage ? Color.white.opacity(0.85) : Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showFullText) {
            FullMessageTextView(text: displayText) {
                onCopyMessage()
            }
        }
    }

    /// The trailing preview card for a link embedded in a longer text message - rendered below
    /// the text bubble, exactly like 1:1/group bubbles. (A message that is NOTHING but a link is
    /// handled inside `bubble` instead: the card replaces the text bubble entirely.) The
    /// `{`-prefix guard skips JSON envelopes (voice payloads etc.) without paying their decode.
    @ViewBuilder
    private var trailingLinkPreview: some View {
        if displayText.first != "{",
           !MessageTextRenderPlan.isEntirelyLink(displayText),
           let linkURL = MessageTextRenderPlan.firstHTTPLink(in: displayText) {
            LinkPreviewCardView(
                url: linkURL,
                txId: message.id,
                onDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : nil
            )
        }
    }

    private var bubble: some View {
        // Computed once here rather than letting `bubbleContent` and this context menu each call
        // the (uncached) `VoiceMessageSniff.decode` independently - that decode does a full
        // JSONSerialization parse + base64 decode of the whole audio payload, so evaluating it
        // twice per row doubled that cost on every render.
        let voicePayload = self.voicePayload
        // Message is nothing but a link - the preview card replaces the plain-text bubble
        // entirely (matches iMessage and group/1:1 chat) instead of showing both. `fallbackText`
        // keeps the raw link visible/tappable if no preview data is ever found.
        let loneLinkURL: URL? = (voicePayload == nil
            && displayText.utf8.count <= Self.inlineTextTruncationThreshold
            && MessageTextRenderPlan.isEntirelyLink(displayText))
            ? MessageTextRenderPlan.firstHTTPLink(in: displayText)
            : nil
        return Group {
            if let loneLinkURL {
                LinkPreviewCardView(
                    url: loneLinkURL,
                    txId: message.id,
                    fallbackText: displayText,
                    onDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : nil
                )
            } else {
                bubbleContent(voicePayload: voicePayload)
                    .background(isOwnMessage ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    // Only the plain bubble gets this menu - `LinkPreviewCardView` carries its
                    // own (Open Link / Copy Link / View in Explorer), and stacking a second
                    // `.contextMenu` on top of it would fight it. Matches group bubbles.
                    .contextMenu {
                        if let firstLink {
                            Button {
                                UIApplication.shared.open(firstLink)
                            } label: {
                                Label("Open Link", systemImage: "safari")
                            }
                            Button {
                                UIPasteboard.general.string = firstLink.absoluteString
                            } label: {
                                Label("Copy Link", systemImage: "link")
                            }
                        }
                        if voicePayload == nil {
                            Button {
                                onCopyMessage()
                            } label: {
                                Label("Copy Message", systemImage: "doc.on.doc")
                            }
                        }
                        if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: message.id) {
                            Link(destination: url) {
                                Label("View in Explorer", systemImage: "safari")
                            }
                        }
                        if isOwnMessage && message.deliveryStatus == .failed {
                            Button {
                                onRetry()
                            } label: {
                                Label("Retry Send", systemImage: "arrow.clockwise")
                            }
                        }
                    }
            }
        }
            // Overlays are attached HERE - to the content-hugging Group, BEFORE the
            // `.frame(maxWidth: 280)` below - exactly like 1:1's `MessageBubbleView` and group
            // chat anchor theirs to the bubble itself. That frame EXPANDS to fill up to 280pt
            // regardless of how narrow the bubble is, so anything overlaid after it anchors to
            // the frame's screen-side corner and visibly floats away from a short bubble.
            .overlay(alignment: .bottomTrailing) {
                if isOwnMessage {
                    deliveryBadge
                        .offset(x: 4, y: 4)
                }
            }
            .overlay(alignment: isOwnMessage ? .bottomLeading : .bottomTrailing) {
                if !reactions.isEmpty {
                    ReactionPillView(emojis: reactions.map { $0.emoji }, localReactionStatus: pillReactionStatus)
                        .offset(y: 10)
                }
            }
            // The pill is an overlay (no layout footprint) offset ~10pt below the bubble, so
            // reserve that space when reactions exist - otherwise it overlaps the next message.
            .padding(.bottom, reactions.isEmpty ? 0 : 16)
            .frame(maxWidth: 280, alignment: isOwnMessage ? .trailing : .leading)
            .tint(.accentColor)
            // `.simultaneousGesture` rather than `.onTapGesture(count: 2)`: the latter is a
            // discrete, exclusive gesture that a Button descendant (the truncated-text preview's
            // "Show More" tap target) would always win the race against, since a Button's tap
            // fires immediately on touch-up. Matches the fix already applied to the private-chat
            // text bubble/image bubble for the same reason.
            // Double-tap opens the quick-reaction bar (reactions + a reply shortcut) instead of
            // jumping straight into reply mode - matching 1:1/group bubbles' identical change.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if onReact != nil {
                    activeQuickReactionMessageId.wrappedValue = message.id
                } else {
                    onReply()
                }
            })
    }

    private var deliveryBadge: some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: 14, height: 14)
            switch message.deliveryStatus {
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            case .pending:
                Image(systemName: "clock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            case .sent:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            }
        }
    }
}

#Preview {
    NavigationStack {
        BroadcastChannelView(channelName: "kaspa")
            .environmentObject(BroadcastService.shared)
            .environmentObject(ContactsManager.shared)
            .environmentObject(ChatService.shared)
            .environmentObject(WalletManager.shared)
    }
}
