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
    /// Local-only multi-select for deleting individual messages (never the whole group - see
    /// `GroupChatInfoView`'s delete for that) - toggled from the toolbar's "Select" button.
    @State private var isSelectingMessages = false
    @State private var selectedMessageIDs: Set<String> = []
    @State private var showDeleteMessagesConfirmation = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    // Plain @State (not @FocusState) - ComposerTextView takes a normal `Binding<Bool>` for focus
    // itself (matching 1:1/broadcast's identical `isMessageFocused`), it doesn't use the
    // `.focused()` modifier that @FocusState's own binding type is specifically for.
    @State private var isComposerFocused = false
    @State private var scrollViewReference = ScrollViewReference()
    @Environment(\.dismiss) private var dismiss

    /// Tap-a-reply-quote-to-jump-to-original - mirrors `ChatDetailView`/`BroadcastChannelView`'s
    /// identical pair. `pendingJumpToTxId` is set from inside a message row (no `ScrollViewProxy`
    /// in scope there) and consumed by an `.onChange` inside the `ScrollViewReader` closure, which
    /// does have the proxy.
    @State private var pendingJumpToTxId: String?
    /// Which message (if any) currently has its double-tap quick-reaction bar open - mirrors 1:1
    /// chat's identical `ChatDetailView.activeQuickReactionMessageId`.
    @State private var activeQuickReactionMessageId: UUID?
    @State private var highlightedMessageID: UUID?

    /// Scroll-to-bottom floating button, matching 1:1/broadcast's identical debounced-visibility
    /// pattern - shown once the bottom of the thread scrolls out of view.
    @State private var isBottomAnchorVisible = true
    @State private var bottomAnchorVisibilityWorkItem: DispatchWorkItem?

    /// Guards the initial scroll-to-bottom settle: the ScrollView is kept hidden (`opacity`) and
    /// `.onChange(of: messages.count)`'s own scroll is suppressed until this flips true, so a
    /// group history that loads in multiple async batches on cold open can't have its
    /// scroll-to-bottom calls race/interrupt each other and leave the thread resting somewhere
    /// other than the bottom (see `positionInitialViewport`).
    @State private var initialViewportPositioned = false

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
    @State private var showCamera = false
    @State private var pendingPhotoImage: UIImage?
    @State private var isSendingPhoto = false
    @StateObject private var recorder = BroadcastAudioRecorder()

    /// `@mention` inline autocomplete - see `GroupMentionCodec`'s doc comment for the wire
    /// format. `mentionQuery` is the text typed after an unclosed "@" at the cursor (reported by
    /// `ComposerTextView.onMentionQuery`), driving `mentionSuggestions`'s visibility/filtering;
    /// nil means the cursor isn't currently in a mention context.
    @State private var mentionQuery: String?
    @State private var mentionInsertionRequest: ComposerTextView.TextInsertionRequest?
    /// Widest row's measured width in the current `mentionSuggestions` list - see that view's doc
    /// comment for why this is measured explicitly rather than relying on child views to just not
    /// ask for more width than they need.
    @State private var mentionListWidth: CGFloat?

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
                    ScrollViewIntrospector { scrollView in
                        if scrollViewReference.scrollView !== scrollView {
                            scrollViewReference.scrollView = scrollView
                        }
                    }
                    .frame(height: 0)
                    .allowsHitTesting(false)

                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(timelineItems) { item in
                            switch item {
                            case .daySeparator(let day):
                                daySeparator(day)
                            case .message(let message):
                                groupMessageRow(message)
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
                .defaultScrollAnchorCompat(.bottom)
                .opacity(initialViewportPositioned ? 1 : 0)
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
                .simultaneousGesture(
                    // Tapping anywhere in the message list dismisses whichever bubble's
                    // quick-reaction bar is open - mirrors 1:1 chat's identical gesture.
                    TapGesture().onEnded {
                        if activeQuickReactionMessageId != nil {
                            activeQuickReactionMessageId = nil
                        }
                    }
                )
                .onChange(of: messages.count) { _ in
                    guard initialViewportPositioned else { return }
                    // Only auto-scroll for the user's OWN new message, or when they're already at the
                    // bottom. Previously this scrolled unconditionally on any count change, yanking the
                    // user away from older messages they were reading whenever a new message arrived.
                    // Matches 1:1 chat's gated behavior.
                    if messages.last?.isOutgoing == true || isBottomAnchorVisible {
                        scrollToBottom(using: proxy, animated: true)
                    }
                }
                .onChange(of: isComposerFocused) { focused in
                    if focused {
                        pinToBottomThroughKeyboardTransition()
                    }
                }
                .onAppear {
                    positionInitialViewport(using: proxy)
                }
                // Host the compose bar as a real safeAreaInset ON the ScrollView (the mechanism
                // SwiftUI itself uses for keyboard avoidance), rather than as a sibling below the
                // ScrollView in the outer VStack. On iOS 18 the sibling layout let SwiftUI animate
                // the whole container's safe-area inset, producing the keyboard/screen shake - this
                // matches 1:1 chat's ChatDetailView fix exactly.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomComposeArea
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
                    // Clear the compose bar (now hosted in the ScrollView's bottom safeAreaInset, so
                    // this button's ZStack extends down behind it): ~76pt for the composer, plus an
                    // allowance when the reply banner + mention row are stacked above it too.
                    .padding(.bottom, 76 + (groupChatService.replyingTo != nil ? 60 : 0))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .animation(.easeInOut(duration: 0.2), value: isBottomAnchorVisible)
                    .animation(.easeInOut(duration: 0.2), value: groupChatService.replyingTo != nil)
                }
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ConnectionStatusIndicator()
            }
            if !isSelectingMessages {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
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
                groupChatService.deleteMessages(selectedMessageIDs, groupId: group.id)
                isSelectingMessages = false
                selectedMessageIDs = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only deletes the message from this device - other members still have their own copy, and the encrypted transaction remains permanently on the Kaspa blockchain, visible to anyone but unreadable without your keys. This cannot be undone.")
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
            // Warm every member's explicit-primary-KNS status before the user starts typing, so
            // the @mention autocomplete doesn't come up empty on a freshly-opened thread.
            await knsService.refreshIfNeeded(for: group.members.map(\.address))
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

    /// Everything that sits above the keyboard - error, reply banner, mention suggestions, and the
    /// compose bar - hosted together in the ScrollView's bottom `safeAreaInset` (see the body) so
    /// keyboard avoidance is driven by SwiftUI's own inset mechanism instead of animating the whole
    /// outer container (the iOS-18 shake fix, matching 1:1 chat).
    private var bottomComposeArea: some View {
        VStack(spacing: 0) {
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
            mentionSuggestions
            composeBar
        }
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(
                onCapture: { data in
                    showCamera = false
                    guard let image = UIImage(data: data) else {
                        errorMessage = "Couldn't load that photo. Please try another."
                        return
                    }
                    isComposerFocused = false
                    pendingPhotoImage = image
                    schedulePhotoFeeEstimate()
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
    }

    private func takePhoto() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showCamera = true
        } else {
            errorMessage = "Camera not available on this device."
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
        let template = AppLocalization.string("fee: %@ KAS")
        return String(format: template, locale: AppLocalization.locale, formatKaspaExact(feeSompi))
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

    /// Members mentionable via the inline "@" autocomplete - only those with an explicit
    /// primary KNS domain set (see `KNSAddressInfo.explicitPrimaryDomain`'s doc comment for why
    /// this can't reuse the general fallback-inclusive `primaryDomain`/`displayName(for:)`),
    /// excluding self, filtered by `query` (case-insensitive substring match against the
    /// domain) when non-empty.
    private func mentionCandidates(for query: String) -> [(member: GroupMember, domain: String)] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return group.members.compactMap { member -> (member: GroupMember, domain: String)? in
            guard member.address != myAddress,
                  let domain = knsService.domainCache[member.address]?.explicitPrimaryDomain,
                  !domain.isEmpty else {
                return nil
            }
            guard normalizedQuery.isEmpty || domain.lowercased().contains(normalizedQuery) else {
                return nil
            }
            return (member, domain)
        }
    }

    /// Safety cap on how many matches are considered at all, well above what anyone would
    /// realistically scroll through - `visibleMentionRows`/scrolling (below) is what actually
    /// bounds the on-screen list for a large group.
    private static let maxMentionSuggestions = 30
    /// More than this many matches and the list scrolls instead of growing taller.
    private static let visibleMentionRows = 5
    /// Approximate single-row height (subheadline text + 8pt vertical padding on each side) used
    /// to size the scroll viewport to exactly `visibleMentionRows` rows - doesn't need to be
    /// pixel-perfect, it's just clipping the scrollable area.
    private static let mentionRowHeight: CGFloat = 38
    /// Upper bound on the measured width below, so one absurdly long domain can't make the list
    /// span almost the whole screen.
    private static let maxMentionListWidth: CGFloat = 280

    @ViewBuilder
    private var mentionSuggestions: some View {
        if let mentionQuery {
            let candidates = Array(mentionCandidates(for: mentionQuery).prefix(Self.maxMentionSuggestions))
            if !candidates.isEmpty {
                // Width is measured explicitly via a PreferenceKey rather than just omitting
                // `frame(maxWidth: .infinity)` from each row - that alone wasn't enough, because
                // `Divider()` (used between rows below) *always* stretches to fill whatever width
                // its container is proposed, by design, regardless of its siblings' content. That
                // greedy child alone was enough to pull the whole VStack (and its background) back
                // out to the full proposed width even with the Text's own frame removed. Measuring
                // each row's actual rendered width via GeometryReader and explicitly constraining
                // the VStack to the widest one sidesteps that entirely - nothing inside can force a
                // wider layout than what was actually measured.
                let rows = VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates, id: \.member.id) { candidate in
                        Button {
                            mentionInsertionRequest = ComposerTextView.TextInsertionRequest(
                                id: UUID(),
                                text: "@\(candidate.domain) ",
                                replacesMentionToken: true
                            )
                            self.mentionQuery = nil
                        } label: {
                            Text(candidate.domain)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: MentionRowWidthKey.self, value: proxy.size.width)
                                    }
                                )
                        }
                        .buttonStyle(.plain)
                        if candidate.member.id != candidates.last?.member.id {
                            Divider()
                        }
                    }
                }
                .onPreferenceChange(MentionRowWidthKey.self) { mentionListWidth = $0 }

                // Deliberately no ScrollView/fixed frame(maxHeight:) for a short list - a
                // ScrollView sizes itself to fill up to its max height regardless of how little
                // content it holds, which left a large empty gap under e.g. a 2-row list. A plain
                // VStack hugs its actual content instead. Once there are more candidates than fit
                // in `visibleMentionRows` though, an *exact* (not max) height is handed to a real
                // ScrollView - exact, not max, so it isn't the same "grows to fill regardless of
                // content" trap, since here there's always guaranteed to be enough content to
                // fill it.
                Group {
                    if candidates.count > Self.visibleMentionRows {
                        ScrollView {
                            rows
                        }
                        .frame(height: Self.mentionRowHeight * CGFloat(Self.visibleMentionRows))
                    } else {
                        rows
                    }
                }
                .frame(width: mentionListWidth.map { min($0, Self.maxMentionListWidth) })
                .background(glassBackground(cornerRadius: 14))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var textRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(spacing: 4) {
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
                    onPasteImageData: handlePastedImageData,
                    onMentionQuery: { mentionQuery = $0 }
                )

                // Quick-access camera, replacing what used to be a "Camera" entry in the "+" menu
                // - living right in the compose bubble instead since it's the most common
                // non-text action. Matches 1:1 chat's textRow.
                Button {
                    takePhoto()
                } label: {
                    Image(systemName: "camera")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Take Photo"))
            }
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

    /// "+" menu - Camera, Send Photo, Send Audio Message only, deliberately no "Send Kaspa"/chess
    /// (see file doc).
    /// Mentioning someone is no longer here - type "@" in the composer instead, see
    /// `mentionSuggestions`.
    private var plusMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Send Photo", systemImage: "photo")
            }
            Button {
                feeEstimateSompi = nil
                recorder.start()
            } label: {
                Label("Send Audio Message", systemImage: "mic.circle.fill")
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
        // Primary-KNS-only, matching what the autocomplete actually inserts (see
        // mentionCandidates(for:)) - not the general displayName(for:) fallback chain used for
        // *rendering* (decodeForDisplay), which stays permissive so historical mentions still
        // show something sensible. A member with no explicit primary returns "" here, which
        // GroupMentionCodec.encodeForSending already skips.
        GroupMentionCodec.encodeForSending(text, members: group.members) { address in
            knsService.domainCache[address]?.explicitPrimaryDomain ?? ""
        }
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

    /// Settles the initial scroll position on cold open. A single fixed-delay retry (the previous
    /// approach) wasn't reliably enough for a large/slow-loading group history - the LazyVStack
    /// might still not have "bottom_anchor" materialized by the time it fires, silently leaving
    /// `scrollTo` a no-op and the thread resting wherever the ScrollView's default (top) landed
    /// it. This cascades through several increasing delays to keep correcting the position if a
    /// group's history arrives in more than one async batch shortly after opening (local cache,
    /// then a network catch-up merging in a few more messages).
    ///
    /// The ScrollView used to stay hidden (`opacity`, see `body`) until the *last* of these ran,
    /// unconditionally - so every cold open waited the full ~650ms before showing anything, even
    /// for a 3-message group with nothing left to correct. A later scroll-to-bottom correction is
    /// imperceptible even while visible (it's a sub-pixel-scale jump at most), whereas holding a
    /// black/blank screen for that long is not, so this now reveals right after the *first*
    /// attempt instead, while the rest keep running in the background as a safety net.
    private func positionInitialViewport(using proxy: ScrollViewProxy) {
        guard !initialViewportPositioned else { return }
        let delays: [TimeInterval] = [0, 0.15, 0.35, 0.65]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            initialViewportPositioned = true
        }
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

    /// Drives the real `UIScrollView` directly instead of `ScrollViewProxy.scrollTo`, which
    /// doesn't reliably land while the keyboard-driven safe-area change is still settling -
    /// verbatim copy of `ChatDetailView`'s identical fix for the same problem there.
    private func pinToBottomThroughKeyboardTransition() {
        // Single settle-then-scroll instead of a 30 Hz snapping loop, to avoid fighting SwiftUI's
        // keyboard-driven safe-area animation (which shook the screen on iOS 18). Verbatim copy of
        // `ChatDetailView`'s fix - see there for the full rationale.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
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
                // In-place resend of the SAME failed message - does not create a new/duplicate one.
                try await groupChatService.retryGroupMessage(message)
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
    /// Built as its own function (rather than inlined in the `ForEach`'s switch case) so the type
    /// checker isn't solving this already-huge multi-argument `GroupMessageBubbleRow` call
    /// *together* with the selection-overlay's conditional content in one expression - matches
    /// 1:1 chat's identical `messageRow`/`selectionOverlay` split in `ChatDetailView.swift`, which
    /// fixed the same "unable to type-check in reasonable time" once the overlay was added there.
    private func groupMessageRow(_ message: GroupMessage) -> some View {
        let bubble = GroupMessageBubbleRow(
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
            onSelect: { enterSelectMode(with: message.txId) },
            reactions: groupChatService.reactionsByGroupId[group.id]?[message.txId] ?? [],
            myReactorAddress: myAddress ?? "",
            onRetryReaction: { reaction in
                Task {
                    try? await groupChatService.retryGroupReaction(targetTxId: reaction.targetTxId, groupId: group.id, emoji: reaction.emoji, action: reaction.failedAction ?? "add")
                }
            },
            onReact: { emoji in
                let existing = groupChatService.reactionsByGroupId[group.id]?[message.txId]?.first { $0.reactorAddress == myAddress }
                let action = existing?.emoji == emoji ? "remove" : "add"
                Task {
                    try? await groupChatService.sendGroupReaction(targetTxId: message.txId, groupId: group.id, emoji: emoji, action: action)
                }
            },
            activeQuickReactionMessageId: $activeQuickReactionMessageId,
            onJumpToReply: { pendingJumpToTxId = $0 },
            revealOffset: revealOffset,
            maxRevealOffset: maxRevealOffset
        )
        .allowsHitTesting(!isSelectingMessages)
        .padding(.leading, isSelectingMessages ? 28 : 0)

        return ZStack(alignment: .leading) {
            bubble
            groupSelectionOverlay(for: message.txId)
        }
    }

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

    /// Selection-mode tap catcher + indicator, split out of `groupMessageRow` (see its own
    /// comment) - disables the bubble's own gestures while selecting.
    @ViewBuilder
    private func groupSelectionOverlay(for txId: String) -> some View {
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
    /// Enters the chat's message multi-select mode with this message pre-selected - nil disables
    /// the "Select" context-menu action entirely (matches 1:1 chat's identical convention).
    var onSelect: (() -> Void)? = nil
    /// This message's current reactions (one per reactor), for the pill shown on its corner.
    var reactions: [GroupStore.ReactionSnapshot] = []
    /// The local wallet's address, used to find *my* reaction among `reactions` so the pill can show
    /// my reaction's status (pending → nothing, sent → green check, failed → red error + Retry).
    var myReactorAddress: String = ""
    /// Retries the local user's failed reaction on this message (nil disables the reaction Retry).
    var onRetryReaction: ((GroupStore.ReactionSnapshot) -> Void)? = nil
    /// Sends/toggles a reaction on this message - nil disables the double-tap quick-reaction bar
    /// entirely (matches 1:1 chat's `MessageBubbleView.onReact`).
    var onReact: ((String) -> Void)?
    /// Shared across every bubble in the conversation (not per-bubble `@State`) - mirrors 1:1
    /// chat's identical `MessageBubbleView.activeQuickReactionMessageId` binding.
    var activeQuickReactionMessageId: Binding<UUID?> = .constant(nil)
    private var showQuickReactionBar: Bool {
        activeQuickReactionMessageId.wrappedValue == message.id
    }
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
    /// Long-pressing a link surfaces this instead of `.contextMenu` (which never fires there -
    /// mirrors `MessageBubbleView`'s identical fix) - matches 1:1 chat's own `linkMenuURL`.
    @State private var linkMenuURL: URL?

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

    /// The local user's own reaction on this message that failed to send, if any. Only our own
    /// reactions ever carry a `.failed` status, so this uniquely finds the reaction needing the
    /// error icon + Retry (works for reactions on incoming messages too).
    private var localReaction: GroupStore.ReactionSnapshot? {
        reactions.first { $0.reactorAddress == myReactorAddress }
    }

    /// Status to show on the reaction pill. Same as `localReaction`'s status, except the green
    /// "sent" checkmark is dropped once the reaction is older than 10 minutes - it's a recent
    /// confirmation, not a permanent badge (pending/failed are always shown).
    private var pillReactionStatus: ChatMessage.DeliveryStatus? {
        guard let localReaction else { return nil }
        guard localReaction.deliveryStatus == .sent else { return localReaction.deliveryStatus }
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - localReaction.blockTime
        return ageMs < 600_000 ? .sent : nil
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
                // Sits directly above the bubble in normal layout flow, same as 1:1 chat's
                // `MessageBubbleView` - an `.overlay` with a manual offset gets cropped by the
                // ScrollView's own clipping instead of rendering cleanly above the row.
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
                    .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
                }

                Text(senderName)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 4)

                if let replyQuote {
                    replyQuoteView(replyQuote)
                }

                // Grouped separately from `replyQuote` above so the reaction pill's overlay
                // (attached to just this Group) anchors to the actual bubble's own corner -
                // attaching it to the whole VStack instead would size/position it against
                // whichever sibling is widest, which for a reply is usually the quote banner, not
                // the (often much narrower) bubble underneath it.
                Group {
                    if let media, media.isImage {
                        LazyImageBubble(
                            media: media,
                            txId: message.txId,
                            shouldShowRetry: shouldShowRetry,
                            photosBlocked: false,
                            senderDisplayName: senderName,
                            onCopy: onCopy,
                            onRetry: shouldShowRetry ? { onRetry() } : nil,
                            onReply: onReply,
                            onDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : nil,
                            onSelect: onSelect
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
                            onReply: onReply,
                            onSelect: onSelect
                        )
                        .simultaneousGesture(TapGesture(count: 2).onEnded { activeQuickReactionMessageId.wrappedValue = message.id })
                    } else if let linkURL = MessageTextRenderPlan.firstHTTPLink(in: displayContent), MessageTextRenderPlan.isEntirelyLink(displayContent) {
                        // Message is nothing but a link - the preview card replaces the plain-text
                        // bubble entirely (matches iMessage) instead of showing both. `fallbackText`
                        // keeps the raw link visible/tappable if no preview data is ever found,
                        // rather than the message rendering as nothing at all.
                        LinkPreviewCardView(url: linkURL, txId: message.txId, fallbackText: displayContent, onSelect: onSelect, onDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : nil)
                    } else {
                        Group {
                            if MessageTextRenderPlan.requiresLinkTextView(displayContent) {
                                LinkifiedMessageTextView(
                                    text: displayContent,
                                    isOutgoing: message.isOutgoing,
                                    isSingleEmojiOnly: false,
                                    onLinkLongPress: { url in
                                        linkMenuURL = url
                                    },
                                    onLinkDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : {}
                                )
                            } else {
                                Text(displayContent)
                                    .font(.body)
                                    .foregroundColor(message.isOutgoing ? .white : .primary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(message.isOutgoing ? Self.bubbleColor : Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { activeQuickReactionMessageId.wrappedValue = message.id })
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
                            if let onSelect {
                                Button {
                                    onSelect()
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                            }
                        }
                        .tint(.accentColor)
                        .confirmationDialog(
                            "Link",
                            isPresented: Binding(get: { linkMenuURL != nil }, set: { if !$0 { linkMenuURL = nil } }),
                            presenting: linkMenuURL
                        ) { url in
                            Button("Open Link") {
                                UIApplication.shared.open(url)
                            }
                            Button("Copy Link") {
                                onCopy(url.absoluteString, .success)
                                UIPasteboard.general.string = url.absoluteString
                            }
                            Button("Reply") {
                                onReply()
                            }
                        } message: { url in
                            Text(url.absoluteString)
                        }
                    }
                }
                .overlay(alignment: message.isOutgoing ? .bottomLeading : .bottomTrailing) {
                    if !reactions.isEmpty {
                        ReactionPillView(emojis: reactions.map { $0.emoji }, localReactionStatus: pillReactionStatus)
                            .offset(y: 10)
                    }
                }
                // Reserve the overlay pill's ~10pt overhang so it doesn't overlap the next message.
                .padding(.bottom, reactions.isEmpty ? 0 : 16)

                if media == nil,
                   !MessageTextRenderPlan.isEntirelyLink(displayContent),
                   let linkURL = MessageTextRenderPlan.firstHTTPLink(in: displayContent) {
                    LinkPreviewCardView(url: linkURL, txId: message.txId, onSelect: onSelect, onDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : nil)
                }

                if message.isOutgoing {
                    if shouldShowRetry {
                        // Tappable "Retry" next to the red error icon, so a failed send can be
                        // resent with one tap instead of only via the long-press menu.
                        HStack(spacing: 4) {
                            statusIcon
                            Text("Retry")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.red)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onRetry() }
                    } else {
                        statusIcon
                    }
                }

                // A reaction (not the message) that failed to send - shown for reactions on any
                // message (yours or another member's), unlike the message-status row above.
                if let localReaction, localReaction.deliveryStatus == .failed {
                    Text("Retry")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.red)
                        .contentShape(Rectangle())
                        .onTapGesture { onRetryReaction?(localReaction) }
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

private extension View {
    /// Matches ChatDetailView's identical compat wrapper (file-private there, so duplicated here
    /// rather than shared) - has the ScrollView start already anchored to the bottom on its very
    /// first layout pass on iOS 17+, instead of relying purely on an imperative `scrollTo` racing
    /// against the LazyVStack's own layout.
    @ViewBuilder
    func defaultScrollAnchorCompat(_ anchor: UnitPoint) -> some View {
        if #available(iOS 17.0, *) {
            self.defaultScrollAnchor(anchor)
        } else {
            self
        }
    }
}

/// Reports the widest measured row width up the view tree - see `mentionSuggestions`'s doc
/// comment for why this explicit measurement is needed instead of just sizing-to-content.
private struct MentionRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
