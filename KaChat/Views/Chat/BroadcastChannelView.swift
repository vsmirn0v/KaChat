import SwiftUI

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
    @ObservedObject private var knsService = KNSService.shared
    @StateObject private var recorder = BroadcastAudioRecorder()

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

    private var myAddress: String? {
        walletManager.currentWallet?.publicAddress
    }

    var body: some View {
        messageList
            // Hosting the compose bar as a real `safeAreaInset` (rather than a floating ZStack
            // overlay with a manually-tracked keyboard offset) is what guarantees it always sits
            // flush above the keyboard on every device - this is the mechanism SwiftUI itself
            // uses for keyboard avoidance, so there's no custom math to get wrong. See
            // ChatDetailView's identical fix for why the old floating approach left a gap.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composeBar
                    .padding(.bottom, 2)
            }
        .navigationTitle("#\(channelName)")
        .navigationBarTitleDisplayMode(.inline)
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
                                        onHideSender: { broadcastService.hideSender(message.senderAddress) },
                                        onReply: { broadcastService.startReplyTo(message) },
                                        onCopyMessage: {
                                            UIPasteboard.general.string = displayContent(for: message).text
                                            showToast("Message copied.")
                                        },
                                        onRetry: { broadcastService.retryBroadcast(message) },
                                        revealOffset: revealOffset,
                                        maxRevealOffset: maxRevealOffset
                                    )
                                    .id(message.id)
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
                        .onAppear {
                            scrollToBottom(using: proxy, animated: false)
                        }
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
                        .allowsHitTesting(false)
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
            guard elapsed >= BroadcastAudioRecorder.maxDuration, recorder.state == .recording else { return }
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
        if recorder.state == .recording || recorder.state == .encoding { return true }
        return !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var feeBubble: some View {
        Group {
            if isEstimatingFee {
                Text("fee: -------- KAS")
            } else if let feeEstimateSompi {
                Text(localizedFeeText(feeEstimateSompi))
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
        .onAppear {
            updateFeeShimmer()
        }
        .onChange(of: isEstimatingFee) { _ in
            updateFeeShimmer()
        }
    }

    private func localizedFeeText(_ feeSompi: UInt64) -> String {
        let template = NSLocalizedString(
            "fee: %@ KAS",
            comment: "Fee label with resolved fee amount in KAS"
        )
        return String(format: template, locale: Locale.current, formatKaspaExact(feeSompi))
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
                let estimate = try await broadcastService.estimateBroadcastFee(channel: channelName, content: trimmed)
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

    /// Live estimate while a voice message is still being recorded, matching Android's
    /// `VoiceMessage.estimatedWirePayloadSize` heuristic (final size isn't known until encoding).
    private func updateRecordingFeeEstimate(elapsedSeconds: TimeInterval) {
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
        Task {
            do {
                let recorded = try await recorder.stopAndEncode()
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
        Task {
            do {
                try await broadcastService.sendBroadcast(channel: channelName, content: trimmed)
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
    let revealOffset: CGFloat
    let maxRevealOffset: CGFloat

    @State private var showFullText = false

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
                    Text(isOwnMessage ? "You" : displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)

                    if let replyQuote {
                        replyQuoteView(replyQuote)
                    }

                    bubble
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

    private var bubble: some View {
        // Computed once here rather than letting `bubbleContent` and this context menu each call
        // the (uncached) `VoiceMessageSniff.decode` independently - that decode does a full
        // JSONSerialization parse + base64 decode of the whole audio payload, so evaluating it
        // twice per row doubled that cost on every render.
        let voicePayload = self.voicePayload
        return bubbleContent(voicePayload: voicePayload)
            .background(isOwnMessage ? Color.accentColor : Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 280, alignment: isOwnMessage ? .trailing : .leading)
            .overlay(alignment: .bottomTrailing) {
                if isOwnMessage {
                    deliveryBadge
                        .offset(x: 4, y: 4)
                }
            }
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
            .tint(.accentColor)
            // `.simultaneousGesture` rather than `.onTapGesture(count: 2)`: the latter is a
            // discrete, exclusive gesture that a Button descendant (the truncated-text preview's
            // "Show More" tap target) would always win the race against, since a Button's tap
            // fires immediately on touch-up. Matches the fix already applied to the private-chat
            // text bubble/image bubble for the same reason.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                onReply()
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
