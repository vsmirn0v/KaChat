import SwiftUI
import PhotosUI

/// `@mention` support for group chat - no protocol/wire-format change: a mention is embedded in
/// the plaintext as `@{fullKaspaAddress}` (unambiguous - real addresses always carry a
/// `kaspa:`/`kaspatest:` prefix, so this can't collide with someone typing a literal "@word"),
/// swapped for the mentioned member's resolved display name only at render time. This is why
/// composing shows a friendly `@Alice` while typing but the text actually sent/encrypted embeds
/// her address - `encodeForSending` does that swap right before send, `decodeForDisplay` reverses
/// it for every place a group message's content is shown.
enum GroupMentionCodec {
    static func encodeForSending(_ text: String, members: [GroupMember], resolveDisplayName: (String) -> String) -> String {
        var result = text
        // Longest name first, so e.g. "@Alice2" doesn't get partially clobbered by a "@Alice" replacement first.
        for member in members.sorted(by: { resolveDisplayName($0.address).count > resolveDisplayName($1.address).count }) {
            let name = resolveDisplayName(member.address)
            guard !name.isEmpty else { continue }
            result = result.replacingOccurrences(of: "@\(name)", with: "@\(member.address)")
        }
        return result
    }

    static func decodeForDisplay(_ text: String, members: [GroupMember], resolveDisplayName: (String) -> String) -> String {
        var result = text
        for member in members {
            let name = resolveDisplayName(member.address)
            guard !name.isEmpty else { continue }
            result = result.replacingOccurrences(of: "@\(member.address)", with: "@\(name)")
        }
        return result
    }

    static func mentions(_ address: String, in text: String) -> Bool {
        text.contains("@\(address)")
    }
}

/// Group chat thread view - mirrors 1:1 chat's look (avatars, "+" send-mode menu, photo/audio
/// bubbles via the same `MediaFile`/`LazyImageBubble`/`LazyAudioBubble` components
/// `MessageBubbleView.swift` uses) with two deliberate differences: no in-thread payments (the
/// group protocol has no shared-wallet/escrow concept, same reason broadcast rooms don't support
/// them - "Pay in Kaspa" isn't in the "+" menu here), and audio recording reuses
/// `BroadcastAudioRecorder`'s simpler engine (broadcast already proved out group-shaped media
/// without 1:1's payment-integrated fee-estimation machinery).
struct GroupChatDetailView: View {
    let group: GroupChat
    var onDeleted: (() -> Void)? = nil
    @EnvironmentObject var groupChatService: GroupChatService
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var draft = ""
    @State private var showInfo = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    // Plain @State (not @FocusState) - ComposerTextView takes a normal `Binding<Bool>` for focus
    // itself (matching 1:1/broadcast's identical `isMessageFocused`), it doesn't use the
    // `.focused()` modifier that @FocusState's own binding type is specifically for.
    @State private var isComposerFocused = false
    @Environment(\.dismiss) private var dismiss

    /// Tap-a-reply-quote-to-jump-to-original - mirrors `ChatDetailView`/`BroadcastChannelView`'s
    /// identical pair. `pendingJumpToTxId` is set from inside a message row (no `ScrollViewProxy`
    /// in scope there) and consumed by an `.onChange` inside the `ScrollViewReader` closure, which
    /// does have the proxy.
    @State private var pendingJumpToTxId: String?
    @State private var highlightedMessageID: UUID?

    /// Scroll-to-bottom floating button, matching 1:1/broadcast's identical debounced-visibility
    /// pattern - shown once the bottom of the thread scrolls out of view.
    @State private var isBottomAnchorVisible = true
    @State private var bottomAnchorVisibilityWorkItem: DispatchWorkItem?

    /// Swipe-left-to-reveal-timestamps, matching 1:1 chat's `ChatDetailView`/broadcast rooms'
    /// identical gesture.
    @State private var revealOffset: CGFloat = 0
    private let maxRevealOffset: CGFloat = 64

    // Avatar menu destinations - "View Profile"/"Open Chat"/"Pay in Kaspa" for a tapped member,
    // matching BroadcastChannelView's identical avatarButton pattern.
    @State private var openContact: Contact?
    @State private var openContactInPaymentMode = false
    @State private var profileContact: Contact?

    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var pendingPhotoImage: UIImage?
    @State private var isSendingPhoto = false
    @StateObject private var recorder = BroadcastAudioRecorder()

    /// `@mention` picker - see `GroupMentionCodec`'s doc comment for the wire format.
    @State private var showMentionPicker = false
    @State private var mentionInsertionRequest: ComposerTextView.TextInsertionRequest?

    // Live "fee: N KAS" preview above the composer - matches 1:1/broadcast's identical bubble.
    @State private var feeEstimateSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var feeEstimateTask: Task<Void, Never>?
    @State private var feeShimmerPhase: CGFloat = -1
    /// User-set fee, from tapping the fee pill - see ChatDetailView.feeOverrideSompi's doc comment.
    @State private var feeOverrideSompi: UInt64?
    @State private var showFeeEditor = false
    @State private var feeEditorText = ""

    /// Smaller than 1:1's `ImagePrep.defaultChatTargetBytes` (15,000) - group's `gcomm` payload
    /// hex-encodes the whole ciphertext (vs. 1:1's base64) plus fixed per-message overhead
    /// (blinded_group_id/sender_id/sender_pub/msg_id/signature, all hex), so the same raw photo
    /// size lands as a noticeably larger on-chain payload/fee in a group message.
    private static let groupPhotoTargetBytes = 10_000

    private var myAddress: String? { walletManager.currentWallet?.publicAddress }

    private var messages: [GroupMessage] {
        let hidden = groupChatService.hiddenMemberAddresses(for: group.id)
        return (groupChatService.groupMessages[group.id] ?? [])
            .filter { message in
                guard let sender = message.senderAddress else { return true }
                return !hidden.contains(sender)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private enum GroupTimelineItem: Identifiable {
        case daySeparator(Date)
        case message(GroupMessage)

        var id: String {
            switch self {
            case .daySeparator(let day):
                return "day-\(Int(day.timeIntervalSince1970))"
            case .message(let message):
                return "message-\(message.id.uuidString)"
            }
        }
    }

    /// Day-separator grouping, mirroring `ChatTimelineLayout` - not shared with it directly since
    /// that's typed to `[ChatMessage]`, not `[GroupMessage]`.
    private var timelineItems: [GroupTimelineItem] {
        var items: [GroupTimelineItem] = []
        var previousDay: Date?
        let calendar = Calendar.autoupdatingCurrent
        for message in messages {
            let messageDay = calendar.startOfDay(for: message.timestamp)
            if previousDay.map({ calendar.isDate($0, inSameDayAs: messageDay) }) != true {
                items.append(.daySeparator(messageDay))
                previousDay = messageDay
            }
            items.append(.message(message))
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(timelineItems) { item in
                            switch item {
                            case .daySeparator(let day):
                                daySeparator(day)
                            case .message(let message):
                                GroupMessageBubbleRow(
                                    message: message,
                                    group: group,
                                    avatarURLString: message.senderAddress.flatMap { knsService.profileCache[$0]?.avatarURL },
                                    senderDisplayName: message.senderAddress.map { $0 == myAddress ? "You" : displayName(for: $0) } ?? "Unknown",
                                    myAvatarURLString: myAddress.flatMap { knsService.profileCache[$0]?.avatarURL },
                                    replySenderDisplayName: MessageReplyCodec.parse(message.content).map { replyDisplayName(for: $0.replyToSender) },
                                    onCopy: showToast,
                                    onViewProfile: viewProfile,
                                    onOpenChat: { openChat(with: $0) },
                                    onPayInKaspa: { openChat(with: $0, paymentMode: true) },
                                    onCopyAddress: copyAddress,
                                    onHideSender: { hideSender($0) },
                                    onMuteSender: { muteSender($0) },
                                    onRetry: { retry(message) },
                                    onReply: { groupChatService.startReplyTo(message) },
                                    onJumpToReply: { pendingJumpToTxId = $0 },
                                    revealOffset: revealOffset,
                                    maxRevealOffset: maxRevealOffset
                                )
                                .id(message.id)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(highlightedMessageID == message.id ? Color.accentColor.opacity(0.18) : Color.clear)
                                )
                                .task(id: message.senderAddress) {
                                    guard let address = message.senderAddress, address != myAddress,
                                          knsService.profileCache[address] == nil else { return }
                                    _ = await knsService.fetchProfile(for: address)
                                }
                            }
                        }
                        // Debounced rather than setting `isBottomAnchorVisible` directly, matching
                        // broadcast rooms exactly - this 1pt marker can appear/disappear rapidly
                        // during a fast scroll/fling right at the lazy-loaded viewport edge.
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
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .onChange(of: pendingJumpToTxId) { txId in
                    guard let txId else { return }
                    jumpToReplyOriginal(txId: txId, using: proxy)
                    pendingJumpToTxId = nil
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    // Swipe-left-to-reveal-timestamps, matching 1:1 chat exactly: dragging left
                    // shifts every message row left together, uncovering each message's time.
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
                .onChange(of: messages.count) { _ in
                    scrollToBottom(using: proxy, animated: true)
                }
                .onAppear {
                    scrollToBottom(using: proxy, animated: false, retryAfter: 0.3)
                }

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

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }

            if let reply = groupChatService.replyingTo {
                replyBanner(for: reply)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            composeBar
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            GroupChatInfoView(group: group, onDeleted: {
                dismiss()
                onDeleted?()
            })
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
        .task {
            groupChatService.loadMessages(for: group.id)
            groupChatService.enterGroup(group.id)
            groupChatService.markGroupAsRead(group.id)
            if let myAddress, knsService.profileCache[myAddress] == nil {
                _ = await knsService.fetchProfile(for: myAddress)
            }
        }
        .onDisappear {
            groupChatService.exitGroup()
        }
        .onChange(of: recorder.state) { state in
            if case .failed(let message) = state {
                errorMessage = message
            }
        }
        .toast(message: toastMessage, style: .success)
        .alert("Adjust Network Fee", isPresented: $showFeeEditor) {
            TextField("Fee (KAS)", text: $feeEditorText)
                .keyboardType(.decimalPad)
            Button("Save") { commitFeeOverride() }
            Button("Use Default") {
                feeOverrideSompi = nil
                scheduleTextFeeEstimate(for: draft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If the network is busy, a higher fee can help your transaction confirm faster.")
        }
    }

    // MARK: - Compose bar

    private func replyBanner(for reply: GroupMessage) -> some View {
        let replyQuote = MessageReplyCodec.parse(reply.content)
        let previewText = replyQuote?.text ?? reply.content
        return HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.caption)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(replyDisplayName(for: reply.senderAddress ?? ""))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
                Text(GroupMentionCodec.decodeForDisplay(MessageReplyCodec.previewText(for: previewText), members: group.members, resolveDisplayName: displayName(for:)))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                groupChatService.cancelReply()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var composeBar: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let pendingPhotoImage {
                    photoPreviewRow(pendingPhotoImage)
                } else if recorder.state == .recording || recorder.state == .encoding {
                    recordingRow
                } else {
                    textRow
                }
            }

            if shouldShowFeeBubble {
                feeBubble
                    .offset(x: 32, y: -26)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: recorder.elapsedSeconds) { elapsed in
            updateRecordingFeeEstimate(elapsedSeconds: elapsed)
        }
    }

    // MARK: - Fee estimation

    private var shouldShowFeeBubble: Bool {
        guard settingsViewModel.settings.showFeeEstimate else { return false }
        if recorder.state == .recording || recorder.state == .encoding { return true }
        if pendingPhotoImage != nil { return true }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        scheduleTextFeeEstimate(for: draft)
    }

    private func localizedFeeText(_ feeSompi: UInt64) -> String {
        let template = NSLocalizedString("fee: %@ KAS", comment: "Fee label with resolved fee amount in KAS")
        return String(format: template, locale: Locale.current, formatKaspaExact(feeSompi))
    }

    private func formatKaspaExact(_ sompi: UInt64) -> String {
        String(format: "%.8f", Double(sompi) / 100_000_000.0)
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

    private func scheduleTextFeeEstimate(for text: String) {
        feeEstimateTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            feeEstimateSompi = nil
            isEstimatingFee = false
            return
        }
        isEstimatingFee = true
        let estimatedText = encodeMentions(trimmed)
        feeEstimateTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            do {
                let estimate = try await groupChatService.estimateGroupMessageFee(estimatedText, for: group.id, feeOverride: feeOverrideSompi)
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

    private func schedulePhotoFeeEstimate() {
        feeEstimateTask?.cancel()
        isEstimatingFee = false
        feeEstimateSompi = groupChatService.estimateGroupMediaFee(rawBytes: Self.groupPhotoTargetBytes)
    }

    /// Raw encoded-Opus-bytes/sec estimate for `BroadcastAudioRecorder`'s fixed 6kbps/48kHz
    /// config (bitrate/8 + WebM container overhead) - matches `ChatDetailView.estimateEncodedSize`'s
    /// identical heuristic for the same recorder settings.
    private func updateRecordingFeeEstimate(elapsedSeconds: TimeInterval) {
        guard recorder.state == .recording else { return }
        let rawBytesPerSecond = 1_150.0
        let estimatedRawBytes = min(Int(elapsedSeconds * rawBytesPerSecond), 13_000)
        feeEstimateSompi = groupChatService.estimateGroupMediaFee(rawBytes: estimatedRawBytes)
        isEstimatingFee = false
    }

    private var canAcceptImageAttachment: Bool {
        pendingPhotoImage == nil && !isSendingPhoto && recorder.state != .recording && recorder.state != .encoding
    }

    /// Wired into `ComposerTextView.onPasteImageData` - see its doc comment on `textRow` for why
    /// this is needed here at all (Cmd+V on macOS).
    private func handlePastedImageData(_ data: Data) -> Bool {
        guard canAcceptImageAttachment else { return false }
        guard let image = ChatImageAttachmentLoader.image(from: data) else {
            errorMessage = "Couldn't load that photo. Please try a PNG, JPEG, or HEIF image."
            return false
        }
        pendingPhotoImage = image
        isComposerFocused = false
        schedulePhotoFeeEstimate()
        return true
    }

    /// Inserts `@DisplayName ` (human-readable) at the cursor - `send()` swaps it for the
    /// machine-readable `@{address}` form right before the message actually goes out, see
    /// `GroupMentionCodec`.
    private func insertMention(for address: String) {
        isComposerFocused = true
        mentionInsertionRequest = ComposerTextView.TextInsertionRequest(id: UUID(), text: "@\(displayName(for: address)) ")
    }

    private var textRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // ComposerTextView (not a plain TextField) so Cmd+V image paste works on macOS,
            // matching 1:1/broadcast - a plain TextField only ever intercepts text paste.
            ComposerTextView(
                text: $draft,
                isFocused: $isComposerFocused,
                onTextChange: { newValue in
                    scheduleTextFeeEstimate(for: newValue)
                },
                onSubmit: { send() },
                placeholder: "Message",
                insertionRequest: mentionInsertionRequest,
                onInsertionHandled: { requestID in
                    if mentionInsertionRequest?.id == requestID {
                        mentionInsertionRequest = nil
                    }
                },
                onPasteImageData: handlePastedImageData
            )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(glassBackground(cornerRadius: 20))

            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plusMenu
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    /// "+" menu - Photo and Audio Message only, deliberately no "Pay in Kaspa" (see file doc).
    private var plusMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
            Button {
                feeEstimateSompi = nil
                recorder.start()
            } label: {
                Label("Audio Message", systemImage: "mic.circle.fill")
            }
            if group.members.contains(where: { $0.address != myAddress }) {
                Button {
                    showMentionPicker = true
                } label: {
                    Label("Mention Someone", systemImage: "at")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(glassBackground(cornerRadius: 14))
        }
        .tint(.accentColor)
        .accessibilityLabel(Text("More options"))
        .confirmationDialog("Mention", isPresented: $showMentionPicker, titleVisibility: .visible) {
            ForEach(group.members.filter { $0.address != myAddress }) { member in
                Button(displayName(for: member.address)) {
                    insertMention(for: member.address)
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { newItem in
            guard let newItem else { return }
            Task {
                defer { photoPickerItem = nil }
                guard let data = try? await newItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    await MainActor.run { errorMessage = "Couldn't load that photo. Please try another." }
                    return
                }
                await MainActor.run {
                    isComposerFocused = false
                    pendingPhotoImage = image
                    schedulePhotoFeeEstimate()
                }
            }
        }
    }

    private func photoPreviewRow(_ image: UIImage) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(isSendingPhoto ? "Sending photo…" : "Photo ready to send")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Button {
                pendingPhotoImage = nil
                feeEstimateSompi = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .disabled(isSendingPhoto)

            Button {
                sendPendingPhoto()
            } label: {
                if isSendingPhoto {
                    ProgressView()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.accentColor)
                }
            }
            .disabled(isSendingPhoto)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(glassBackground(cornerRadius: 20))
    }

    private var recordingRow: some View {
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
                sendRecording()
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
        .onChange(of: recorder.elapsedSeconds) { elapsed in
            guard elapsed >= BroadcastAudioRecorder.maxDuration, recorder.state == .recording else { return }
            sendRecording()
        }
    }

    /// Swaps any `@DisplayName` the user typed/picked for the machine-readable `@{address}` form
    /// - see `GroupMentionCodec`'s doc comment.
    private func encodeMentions(_ text: String) -> String {
        GroupMentionCodec.encodeForSending(text, members: group.members, resolveDisplayName: displayName(for:))
    }

    private func send() {
        let text = encodeMentions(draft.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return }
        draft = ""
        errorMessage = nil
        let feeOverride = feeOverrideSompi
        feeOverrideSompi = nil
        feeEstimateSompi = nil
        Task {
            do {
                try await groupChatService.sendGroupMessage(text, to: group.id, feeOverride: feeOverride)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sendPendingPhoto() {
        guard let pendingPhotoImage else { return }
        isSendingPhoto = true
        errorMessage = nil
        Task {
            do {
                let prepared = try ImagePrep.prepareForChatMessage(pendingPhotoImage, targetBytes: Self.groupPhotoTargetBytes)
                try await groupChatService.sendGroupImage(prepared.data, to: group.id, fileName: prepared.fileName, mimeType: prepared.mimeType)
                await MainActor.run {
                    self.pendingPhotoImage = nil
                    self.isSendingPhoto = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isSendingPhoto = false
                }
            }
        }
    }

    private func sendRecording() {
        Task {
            do {
                let recorded = try await recorder.stopAndEncode()
                try await groupChatService.sendGroupAudio(recorded.data, to: group.id, fileName: recorded.fileName, mimeType: recorded.mimeType)
            } catch {
                await MainActor.run { errorMessage = "Failed to send voice message: \(error.localizedDescription)" }
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

    private func copyAddress(_ address: String) {
        UIPasteboard.general.string = address
        showToast("Address copied.", style: .success)
    }

    private func hideSender(_ address: String) {
        groupChatService.hideMember(address, in: group.id)
        showToast("User hidden.", style: .success)
    }

    private func muteSender(_ address: String) {
        if groupChatService.mutedMemberAddresses(for: group.id).contains(address) {
            groupChatService.unmuteMember(address, in: group.id)
            showToast("User unmuted.", style: .success)
        } else {
            groupChatService.muteMember(address, in: group.id)
            showToast("User muted.", style: .success)
        }
    }

    /// Resolves a member's name the same way 1:1/broadcast do (contact alias, then KNS domain,
    /// then a generated fallback) - NOT `group.members[].displayName`, which is only a one-time
    /// snapshot taken when the roster was built/received (via `createGroup`'s local
    /// `contactsManager` lookup, or `applyRootPayload`'s wire payload, which carries no display
    /// names at all) and never updated afterward. That snapshot is why only whichever members
    /// happened to already be named contacts at that moment ever showed a real name - everyone
    /// else was stuck on their truncated address forever, even after adding/renaming them.
    private func displayName(for address: String) -> String {
        if let contact = contactsManager.getContact(byAddress: address), !contact.alias.isEmpty {
            return contact.alias
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    private func replyDisplayName(for address: String) -> String {
        address == myAddress ? "You" : displayName(for: address)
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool, retryAfter: TimeInterval? = nil) {
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo("bottom_anchor", anchor: .bottom) }
            } else {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }
        // The very first call on cold open can land before the LazyVStack has actually laid out
        // "bottom_anchor" yet (a large group history takes a moment), which makes `scrollTo`
        // silently no-op - a retry a beat later (matching ChatDetailView's identical
        // `retryAfter` pattern) catches that case instead of leaving the thread open at the top.
        guard let retryAfter else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryAfter) {
            if animated {
                withAnimation { proxy.scrollTo("bottom_anchor", anchor: .bottom) }
            } else {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }
    }

    /// Group chat has no pagination (the full history is already in `messages`, unlike 1:1's
    /// windowed `displayedMessages`), so a jump either finds the target right away or it's
    /// genuinely gone (pruned/undelivered).
    private func jumpToReplyOriginal(txId: String, using proxy: ScrollViewProxy) {
        guard let target = messages.first(where: { $0.txId == txId }) else {
            showToast("Original message not available.", style: .error)
            return
        }
        withAnimation {
            proxy.scrollTo(target.id, anchor: .center)
        }
        highlightedMessageID = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.5)) {
                if highlightedMessageID == target.id {
                    highlightedMessageID = nil
                }
            }
        }
    }

    /// Group messages don't have an in-place "retry" record the way 1:1 does - resends the same
    /// content (works uniformly for text/photo/audio, since all three are just a content string)
    /// as a fresh message rather than mutating the failed one, which stays in history marked failed.
    private func retry(_ message: GroupMessage) {
        errorMessage = nil
        Task {
            do {
                try await groupChatService.sendGroupMessage(message.content, to: group.id)
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func showToast(_ message: String, style: ToastStyle) {
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

    private func glassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
    }

    /// "Today"/"Yesterday"/date pill between message groups - visually identical to 1:1 chat's
    /// `ChatDetailView.daySeparator(_:)`.
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
}

private struct GroupMessageBubbleRow: View {
    let message: GroupMessage
    let group: GroupChat
    let avatarURLString: String?
    /// Resolved by `GroupChatDetailView` (which has live `contactsManager`/`knsService` access,
    /// and knows the wallet's own address for "You") - matches 1:1/broadcast's identical
    /// pattern of resolving names in the parent rather than this row re-deriving them from the
    /// group roster's frozen `displayName` snapshot.
    let senderDisplayName: String
    /// Own avatar, shown on outgoing messages - matches broadcast's `BroadcastMessageRow`
    /// showing `avatarButton` on both sides depending on `isOwnMessage`.
    let myAvatarURLString: String?
    let replySenderDisplayName: String?
    let onCopy: (String, ToastStyle) -> Void
    let onViewProfile: (String) -> Void
    let onOpenChat: (String) -> Void
    let onPayInKaspa: (String) -> Void
    let onCopyAddress: (String) -> Void
    let onHideSender: (String) -> Void
    let onMuteSender: (String) -> Void
    let onRetry: () -> Void
    let onReply: () -> Void
    /// Called with the original message's txId when the reply quote (if any) is tapped -
    /// `GroupChatDetailView` scrolls to and highlights it.
    let onJumpToReply: (String) -> Void
    /// Shared horizontal offset driven by the message list's swipe-left-to-reveal-timestamp
    /// gesture (see `GroupChatDetailView`'s drag gesture) - 0 at rest, negative while revealed.
    var revealOffset: CGFloat = 0
    var maxRevealOffset: CGFloat = 64

    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var knsService = KNSService.shared

    private static let bubbleColor = Color(red: 112.0 / 255.0, green: 199.0 / 255.0, blue: 186.0 / 255.0)

    /// Same resolution as `GroupChatDetailView.displayName(for:)` - duplicated rather than
    /// threaded down as a closure, matching this file's existing pattern of each row/screen
    /// owning a small local copy (see `GroupChatInfoView`/`HiddenGroupMembersView`).
    private func resolveDisplayName(for address: String) -> String {
        if let contact = contactsManager.getContact(byAddress: address), !contact.alias.isEmpty {
            return contact.alias
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    private var senderName: String { senderDisplayName }

    private var shouldShowRetry: Bool {
        message.isOutgoing && message.deliveryStatus == .failed
    }

    /// Parsed once per row - present only when `message.content` is a reply envelope (matches
    /// 1:1 chat's `MessageBubbleView.replyQuote`).
    private var replyQuote: MessageReplyContent? {
        MessageReplyCodec.parse(message.content)
    }

    /// The reply's own text, or the raw content when this isn't a reply - with any `@{address}`
    /// mentions swapped back to friendly `@DisplayName` form, see `GroupMentionCodec`.
    private var displayContent: String {
        let raw = replyQuote?.text ?? message.content
        return GroupMentionCodec.decodeForDisplay(raw, members: group.members, resolveDisplayName: resolveDisplayName(for:))
    }

    /// Parsed once per row - `nil` for a plain-text message, matching 1:1 chat's content-shape
    /// sniffing (`MediaFile.from`) rather than a stored message-type field.
    private var media: MediaFile? {
        MediaFile.from(displayContent, cacheKey: message.txId)
    }

    private var timeText: String {
        SharedFormatting.chatTime.string(from: message.timestamp)
    }

    /// 0 at rest, 1 once fully dragged open.
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

            messageContent
                .offset(x: revealOffset)
        }
    }

    private var messageContent: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !message.isOutgoing {
                avatarButton
            } else {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(senderName)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 4)

                if let replyQuote {
                    replyQuoteView(replyQuote)
                }

                if let media, media.isImage {
                    LazyImageBubble(
                        media: media,
                        txId: message.txId,
                        shouldShowRetry: shouldShowRetry,
                        photosBlocked: false,
                        senderDisplayName: senderName,
                        onCopy: onCopy,
                        onRetry: shouldShowRetry ? { onRetry() } : nil,
                        onReply: onReply
                    )
                } else if let media, media.isAudio, let data = media.fileData(cacheKey: message.txId) {
                    LazyAudioBubble(
                        data: data,
                        mimeType: media.mimeType,
                        isOutgoing: message.isOutgoing,
                        fileName: media.name,
                        txId: message.txId,
                        onCopy: onCopy,
                        onRetry: shouldShowRetry ? { onRetry() } : nil,
                        onReply: onReply
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onReply() })
                } else {
                    Text(displayContent)
                        .font(.body)
                        .foregroundColor(message.isOutgoing ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.isOutgoing ? Self.bubbleColor : Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onReply() })
                        .contextMenu {
                            Button {
                                onReply()
                            } label: {
                                Label("Reply", systemImage: "arrowshape.turn.up.left")
                            }
                            Button {
                                onCopy(displayContent, .success)
                                UIPasteboard.general.string = displayContent
                            } label: {
                                Label("Copy Message", systemImage: "doc.on.doc")
                            }
                            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: message.txId) {
                                Link(destination: url) {
                                    Label("View in Explorer", systemImage: "safari")
                                }
                            }
                            if shouldShowRetry {
                                Button {
                                    onRetry()
                                } label: {
                                    Label("Retry Send", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                        .tint(.accentColor)
                }

                if message.isOutgoing {
                    statusIcon
                }
            }

            if message.isOutgoing {
                avatarButton
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    /// Quoted-original preview shown above a reply's own bubble - tapping it jumps to and
    /// highlights the original message, matching 1:1 chat's identical tap behavior.
    private func replyQuoteView(_ reply: MessageReplyContent) -> some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            Text(replySenderDisplayName ?? String(reply.replyToSender.suffix(10)))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            Text(GroupMentionCodec.decodeForDisplay(reply.replyToPreview, members: group.members, resolveDisplayName: resolveDisplayName(for:)))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(message.isOutgoing ? .trailing : .leading)
        }
        .padding(8)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 240, alignment: message.isOutgoing ? .trailing : .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onJumpToReply(reply.replyToId)
        }
    }

    /// Avatar with the same View Profile / Open Chat / Pay in Kaspa / Copy Address menu
    /// `BroadcastChannelView`'s `avatarButton` offers for a tapped sender.
    private var avatarButton: some View {
        Menu {
            if let address = message.senderAddress {
                Button {
                    onViewProfile(address)
                } label: {
                    Label("View Profile", systemImage: "person.crop.circle")
                }
                if !message.isOutgoing {
                    Button {
                        onOpenChat(address)
                    } label: {
                        Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                Button {
                    onCopyAddress(address)
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
                if !message.isOutgoing {
                    Button {
                        onPayInKaspa(address)
                    } label: {
                        Label {
                            Text("Pay in Kaspa")
                        } icon: {
                            Image("KaspaLogo")
                                .resizable()
                                .scaledToFit()
                        }
                    }
                    let isMuted = groupChatService.mutedMemberAddresses(for: group.id).contains(address)
                    Button {
                        onMuteSender(address)
                    } label: {
                        Label(isMuted ? "Unmute User" : "Mute User", systemImage: isMuted ? "speaker.wave.2" : "speaker.slash")
                    }
                    Button(role: .destructive) {
                        onHideSender(address)
                    } label: {
                        Label("Hide User", systemImage: "eye.slash")
                    }
                }
            }
        } label: {
            KNSAvatarView(
                avatarURLString: message.isOutgoing ? myAvatarURLString : avatarURLString,
                fallbackText: senderName,
                size: 32
            )
        }
        .tint(.accentColor)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.deliveryStatus {
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        case .warning:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }
}

/// Group membership. Kept intentionally minimal - member add/remove is a natural next step once
/// this is in front of you. No invite-link/join flow - every member is added directly by the
/// admin (see `GroupChatService`'s file doc for why the invite beacon was removed).
struct GroupChatInfoView: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var knsService = KNSService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var profileContact: Contact?
    @State private var showHiddenMembers = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var isRenaming = false
    var onDeleted: (() -> Void)?

    private var myAddress: String? { walletManager.currentWallet?.publicAddress }

    /// Same resolution 1:1/broadcast/the message list use (contact alias, then KNS domain, then
    /// a generated fallback) - not `member.displayName`, which is only a one-time snapshot from
    /// when the roster was built/received and never updated afterward (see `GroupChatDetailView.
    /// displayName(for:)`'s identical doc comment). Applied uniformly to every member, including
    /// the current user's own row, rather than special-casing "You" here the way message bubbles
    /// do - this screen is about who someone *is*, not who sent a given message.
    private func displayName(for address: String) -> String {
        if let contact = contactsManager.getContact(byAddress: address), !contact.alias.isEmpty {
            return contact.alias
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    private var hiddenMemberAddresses: [String] {
        Array(groupChatService.hiddenMemberAddresses(for: group.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Members (\(group.members.count))") {
                    ForEach(group.members) { member in
                        let memberLabel = displayName(for: member.address)
                        Button {
                            profileContact = contactsManager.getContact(byAddress: member.address)
                                ?? contactsManager.getOrCreateContact(address: member.address)
                        } label: {
                            HStack(spacing: 12) {
                                KNSAvatarView(avatarURLString: knsService.profileCache[member.address]?.avatarURL, fallbackText: memberLabel, size: 32)
                                Text(memberLabel)
                                    .foregroundColor(.primary)
                                Spacer()
                                if member.isAdmin {
                                    Text("Admin")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .task {
                            guard knsService.profileCache[member.address] == nil else { return }
                            _ = await knsService.fetchProfile(for: member.address)
                        }
                    }
                }

                Section {
                    Button {
                        showHiddenMembers = true
                    } label: {
                        Label("Hidden Users", systemImage: "eye.slash")
                    }
                }

                Section {
                    Toggle("Only Notify if I'm Mentioned", isOn: Binding(
                        get: { groupChatService.mentionsOnlyNotifications(for: group.id) },
                        set: { groupChatService.setMentionsOnlyNotifications($0, for: group.id) }
                    ))
                } footer: {
                    Text("When on, you'll only get notified about messages that @mention you - other messages still show up in the chat, just silently.")
                }

                if group.isAdmin {
                    Section {
                        Button {
                            renameText = group.name
                            renameError = nil
                            showRename = true
                        } label: {
                            Label("Rename Group", systemImage: "pencil")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Group", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
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
            .sheet(isPresented: $showHiddenMembers) {
                NavigationStack {
                    HiddenGroupMembersView(group: group)
                }
            }
            .alert("Rename Group", isPresented: $showRename) {
                TextField("Group name", text: $renameText)
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isRenaming = true
                    Task {
                        do {
                            try await groupChatService.renameGroup(group.id, to: trimmed)
                        } catch {
                            renameError = error.localizedDescription
                        }
                        isRenaming = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every member will see the new name.")
            }
            .alert("Couldn't Rename Group", isPresented: Binding(
                get: { renameError != nil },
                set: { if !$0 { renameError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(renameError ?? "")
            }
            .alert("Delete \"\(group.name)\"", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    groupChatService.deleteGroup(group.id)
                    dismiss()
                    onDeleted?()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the group and its messages from this device. This cannot be undone, and other members won't be notified.")
            }
        }
    }
}

/// Eye-toggle screen for a group's hidden members - lists everyone currently hidden (see
/// `GroupChatService.groupHiddenMembers`) with a one-tap unhide, matching broadcast rooms' own
/// hidden-senders management screen in spirit (there isn't a literal shared one to reuse, since
/// broadcast's hiding is global across channels while this is scoped to one group).
private struct HiddenGroupMembersView: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @ObservedObject private var knsService = KNSService.shared
    @Environment(\.dismiss) private var dismiss

    private func displayName(for address: String) -> String {
        if let contact = contactsManager.getContact(byAddress: address), !contact.alias.isEmpty {
            return contact.alias
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    var body: some View {
        Form {
            let hidden = Array(groupChatService.hiddenMemberAddresses(for: group.id))
            if hidden.isEmpty {
                Section {
                    Text("No hidden users in this group.")
                        .foregroundColor(.secondary)
                }
            } else {
                Section("Hidden Users") {
                    ForEach(hidden, id: \.self) { address in
                        HStack(spacing: 12) {
                            KNSAvatarView(avatarURLString: knsService.profileCache[address]?.avatarURL, fallbackText: displayName(for: address), size: 32)
                            Text(displayName(for: address))
                            Spacer()
                            Button("Unhide") {
                                groupChatService.unhideMember(address, in: group.id)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hidden Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}
