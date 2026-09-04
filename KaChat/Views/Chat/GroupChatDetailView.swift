import SwiftUI
import PhotosUI
import AVFoundation

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
    /// Hoisted out of the body chain - an inline service call in .onChange tipped the
    /// compiler's type-check budget for this (large) body expression.
    private var currentGroupUnreadCount: Int {
        groupChatService.unreadCount(for: group)
    }

    let group: GroupChat
    var onDeleted: (() -> Void)? = nil
    @EnvironmentObject var groupChatService: GroupChatService
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @State private var draft = ""
    @State private var reactiveReadMarkPending = false
    @State private var showInfo = false
    /// Local-only multi-select for deleting individual messages (never the whole group - see
    /// `GroupChatInfoView`'s delete for that) - toggled from the toolbar's "Select" button.
    @State private var isSelectingMessages = false
    @State private var selectedMessageIDs: Set<String> = []
    @State private var showDeleteMessagesConfirmation = false
    @State private var errorMessage: String?
    @State private var toastMessage: String?
    /// Message whose reactor list is on screen, by txId.
    @State private var reactionsSheetTarget: ReactionsSheetTarget?
    /// Mirrors `ChatDetailView.toastStyle` - the Nextcloud upload-failure toast renders as an
    /// error, everything else keeps the success look the modifier previously hardcoded.
    @State private var toastStyle: ToastStyle = .success
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
    /// The message whose full emoji picker is open. Owned by the SCREEN, not by the reaction bar.
    @State private var emojiPickerTarget: IdentifiedTxId?
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
    /// Mirrors 1:1's identical flag: `displayedMessages` returns [] until this flips true in
    /// `.onAppear`, so the FIRST render pass is an empty list (content size ~0) and the whole
    /// window then fills in ONE update. `.defaultScrollAnchor(.bottom)` pins the bottom natively on
    /// that single 0->N content-size change (its designed behavior, and why 1:1 opens correctly) -
    /// versus rendering everything on the first pass, where the anchor + imperative scrolls race
    /// the LazyVStack's still-estimated row heights and the viewport lands in empty space.
    @State private var initialLayoutReady = false
    /// Bounded render window over the full in-memory history, mirroring 1:1's `displayedMessages`.
    /// Rendering the ENTIRE history in the LazyVStack made `.defaultScrollAnchor(.bottom)` re-resolve
    /// the resting offset against a large, momentarily-wrong estimated content height on every
    /// re-render (each keystroke/reply/reaction), snapping the viewport up. 0 = use the initial
    /// window; grows by a page when the user scrolls to the oldest rendered message.
    @State private var loadedGroupMessageCount = 0
    private let groupMessagePageSize = 40
    /// True only for the brief window while older history is being prepended (scroll-up load) -
    /// the ONE case that still needs `.defaultScrollAnchor(.bottom)`'s auto-pinning. At all other
    /// times after the initial open the anchor is `.top` (inert), because a standing `.bottom`
    /// anchor re-resolves the offset on every tiny compose-bar size change (fee label appearing,
    /// per-keystroke field re-measure), producing random upward jumps while typing. Explicit
    /// scrolls (open positioning, new-message scrollToBottom, keyboard pin) own bottom-pinning.
    @State private var isGrowingHistoryWindow = false

    /// Swipe-left-to-reveal-timestamps, matching 1:1 chat's `ChatDetailView`/broadcast rooms'
    /// identical gesture.
    @State private var revealOffset: CGFloat = 0
    /// Ticks once a minute while the thread is open, purely so expiring system lines disappear
    /// on their own rather than on the next unrelated redraw.
    @State private var systemLineClock = Date()
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
    /// The exact bytes the pending photo was attached from (picker/camera/paste), kept so
    /// "Send Media via Nextcloud" can upload the untouched original (HEIC/PNG/JPEG, full
    /// resolution) instead of a re-encode of the decoded UIImage. Cleared with the pending
    /// photo - mirrors `ChatDetailView.pendingPhotoOriginalData` exactly.
    @State private var pendingPhotoOriginalData: Data?
    @State private var isSendingPhoto = false
    @State private var showNextcloudPicker = false
    @State private var showPlusSheet = false
    /// Drives the connected-state composer layout, mirroring 1:1 chat's `ChatDetailView`: with a
    /// Nextcloud server linked, the + menu drops Send Photo / Send Audio in favor of "Send from
    /// Nextcloud", and the message bar's camera/mic captures ride the Nextcloud auto-upload path.
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

    /// Zero-balance compose gate - same trigger as 1:1 chat (confirmed 0 KAS only, never on an
    /// unknown/still-loading balance). See `WalletManager.hasConfirmedZeroChattingBalance`.
    private var isChattingBalanceZero: Bool {
        walletManager.hasConfirmedZeroChattingBalance
    }

    private var messages: [GroupMessage] {
        let hidden = groupChatService.hiddenMemberAddresses(for: group.id)
        // `systemLineClock` is only read so this recomputes on the minute tick below - without
        // it a membership line inserted while you are looking at the thread would sit there
        // until something else happened to invalidate the view.
        let now = systemLineClock
        return (groupChatService.groupMessages[group.id] ?? [])
            .filter { message in
                // Membership/rename/photo lines are news only while they are recent.
                if GroupChatService.isExpiredSystemMessage(message, now: now) { return false }
                guard let sender = message.senderAddress else { return true }
                return !hidden.contains(sender)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Newest slice of `messages` actually rendered. A bounded window keeps the LazyVStack's content
    /// height stable across re-renders so `.defaultScrollAnchor(.bottom)` doesn't snap the viewport
    /// up on typing/reply/react (see `loadedGroupMessageCount`). The newest message is always in the
    /// window, so "open pinned to bottom" and "new message scrolls to bottom" are unaffected; older
    /// history loads as the window grows on scroll-up, and `.bottom` keeps the bottom pinned as those
    /// older rows prepend, so growing never jumps either.
    private var displayedMessages: [GroupMessage] {
        guard initialLayoutReady else { return [] }
        let all = messages
        let window = loadedGroupMessageCount <= 0 ? groupMessagePageSize * 3 : loadedGroupMessageCount
        guard all.count > window else { return all }
        return Array(all.suffix(window))
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
    /// Rebuilt on every body evaluation - a keystroke in the composer, a reaction landing, an
    /// incoming message - so what it costs per message is what the whole thread costs per frame.
    ///
    /// It used to call `Calendar.startOfDay` AND `isDate(_:inSameDayAs:)` for EVERY message,
    /// every time. Calendar arithmetic is not cheap (timezone and DST resolution per call), and
    /// a few hundred messages meant a few hundred of them per frame while typing. Broadcast rooms
    /// have no day separators at all, which is a good part of why they feel smoother with far
    /// more messages on screen.
    ///
    /// Messages are in ascending order, so the day only has to be resolved when one falls outside
    /// the current day's half-open range: O(distinct days) Calendar calls instead of O(messages),
    /// which for a normal thread is one or two per frame rather than hundreds. Same output.
    private var timelineItems: [GroupTimelineItem] {
        var items: [GroupTimelineItem] = []
        items.reserveCapacity(displayedMessages.count + 8)
        let calendar = Calendar.autoupdatingCurrent
        var currentDayStart: Date?
        var currentDayEnd: Date?
        for message in displayedMessages {
            let timestamp = message.timestamp
            if let start = currentDayStart, let end = currentDayEnd, timestamp >= start, timestamp < end {
                items.append(.message(message))
                continue
            }
            let dayStart = calendar.startOfDay(for: timestamp)
            // `date(byAdding:)` rather than +86400: a DST day is 23 or 25 hours long, and the
            // half-open range has to match the calendar's own idea of the boundary.
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
            currentDayStart = dayStart
            currentDayEnd = dayEnd
            items.append(.daySeparator(dayStart))
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
                                if message.senderAddress == GroupChatService.systemSender {
                                    // iMessage-style membership line — centered, no bubble/avatar.
                                    Text(message.content)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                        .id(message.id)
                                } else {
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
                                    .onAppear {
                                        // Reached the oldest rendered message - grow the window so
                                        // older history loads on scroll-up. `.defaultScrollAnchor(.bottom)`
                                        // keeps the bottom pinned as the older rows prepend, so no jump.
                                        // Gated on initialViewportPositioned (mirroring 1:1's prefetch
                                        // gate): during the initial layout pass the LazyVStack briefly
                                        // realizes the TOP rows before the viewport is scrolled to the
                                        // bottom, and growing the window then cascades (each growth
                                        // re-triggers this) and fights the initial scroll-to-bottom,
                                        // leaving the thread open scrolled to the top.
                                        if initialViewportPositioned,
                                           message.id == displayedMessages.first?.id,
                                           displayedMessages.count < messages.count {
                                            // Re-arm the bottom anchor just for the prepend so the
                                            // viewport stays pinned while older rows load, then
                                            // drop back to the inert .top anchor.
                                            isGrowingHistoryWindow = true
                                            loadedGroupMessageCount = min(displayedMessages.count + groupMessagePageSize, messages.count)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                                isGrowingHistoryWindow = false
                                            }
                                        }
                                    }
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
                .defaultScrollAnchorCompat(!initialViewportPositioned || isGrowingHistoryWindow ? .bottom : .top)
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
                    // Not yet revealed (e.g. the async-decrypted messages just arrived after an
                    // empty first appear) - do the initial bottom-positioning now that content
                    // exists, then reveal. This is what prevents the black-screen-until-swipe.
                    guard initialViewportPositioned else {
                        positionInitialViewport(using: proxy)
                        return
                    }
                    // Only auto-scroll for the user's OWN new message, or when they're already at the
                    // bottom. Previously this scrolled unconditionally on any count change, yanking the
                    // user away from older messages they were reading whenever a new message arrived.
                    // Matches 1:1 chat's gated behavior.
                    if messages.last?.isOutgoing == true || isBottomAnchorVisible {
                        scrollToBottom(using: proxy, animated: true)
                    }
                    // Reactive read-marking, same as ChatDetailView: a notification tap can
                    // open this group before its messages have loaded (cold start /
                    // mid-catch-up), making the one-shot .task mark a no-op and leaving the
                    // badge stuck. Message arrivals are exactly when unread can bump.
                    // DEBOUNCED: catch-up sync delivers messages one by one - marking read per
                    // arrival (badge update + delivered-notification sweep each time) stormed
                    // the main thread on resume. One mark after the burst quiets down.
                    if currentGroupUnreadCount > 0, !reactiveReadMarkPending {
                        reactiveReadMarkPending = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            reactiveReadMarkPending = false
                            if currentGroupUnreadCount > 0 {
                                groupChatService.markGroupAsRead(group.id)
                            }
                        }
                    }
                }
                .onChange(of: isComposerFocused) { focused in
                    if focused {
                        pinToBottomThroughKeyboardTransition()
                        // Final correction once the keyboard has fully settled: the UIKit offset
                        // math in the pin uses contentSize, which can still contain ESTIMATED row
                        // heights shortly after open - overshooting and scrolling the messages out
                        // of view. Landing on the bottom anchor via SwiftUI resolves the TRUE
                        // bottom against realized layout, so the thread ends exactly at the latest
                        // message regardless of estimates. Cross-version safe.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if isComposerFocused {
                                scrollToBottom(using: proxy, animated: false)
                            }
                        }
                    }
                }
                .onAppear {
                    // Flip AFTER the first (empty-list) render pass has been described: the flag
                    // change triggers the single fill update the bottom anchor pins against.
                    initialLayoutReady = true
                    positionInitialViewport(using: proxy)
                    // Fallback: a genuinely-empty group (or one whose decrypt never triggers a
                    // count change) would otherwise stay hidden forever - reveal it after a beat.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !initialViewportPositioned { initialViewportPositioned = true }
                    }
                }
                .onChange(of: initialLayoutReady) { _ in
                    positionInitialViewport(using: proxy)
                }
                // The header rides above the list as a pinned inset, not as a toolbar item: a
                // 46pt photo over a name capsule is far taller than a principal item is given,
                // which is what kept the group header cramped to a 28pt thumbnail while 1:1
                // showed a proper one. Same mechanism, same measurements as ChatDetailView.
                .safeAreaInset(edge: .top, spacing: 0) {
                    groupTitleChip
                        // Reaches up into the navigation bar's row so the photo sits level with
                        // the back button. Bounded at -52 for the same reason as 1:1: the inset
                        // is measured from BELOW the safe area, so it can never reach the notch.
                        .padding(.top, -52)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity)
                }
                // Host the compose bar as a real safeAreaInset ON the ScrollView (the mechanism
                // SwiftUI itself uses for keyboard avoidance), rather than as a sibling below the
                // ScrollView in the outer VStack. On iOS 18 the sibling layout let SwiftUI animate
                // the whole container's safe-area inset, producing the keyboard/screen shake - this
                // matches 1:1 chat's ChatDetailView fix exactly.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if isChattingBalanceZero {
                            // Zero-balance gate: reading stays fully usable (the card is part
                            // of the bottom inset, never an overlay on the message list) -
                            // only composing is blocked. Mirrors 1:1 chat's gate exactly.
                            ZeroBalanceFundingCardView(
                                address: myAddress,
                                onCopied: { showToast($0.addressCopiedToastText, style: .success) }
                            )
                            .padding(.horizontal)
                            .padding(.bottom, 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        bottomComposeArea
                            .disabled(isChattingBalanceZero)
                            .allowsHitTesting(!isChattingBalanceZero)
                            .grayscale(isChattingBalanceZero ? 1 : 0)
                            .opacity(isChattingBalanceZero ? 0.45 : 1)
                    }
                    .animation(.easeInOut(duration: 0.25), value: isChattingBalanceZero)
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
        // Empty: the pinned header carries the name, and a duplicate inline title underneath it
        // would be the same text twice.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The info button is gone: tapping the header opens Group Info, exactly as it does
            // in a 1:1 chat, so the trailing slot is free for the connection dot to sit where
            // 1:1 puts it. Hidden while selecting, where the bar is Cancel/Delete.
            if !isSelectingMessages {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ConnectionStatusIndicator()
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
        .sheet(item: $emojiPickerTarget) { target in
            EmojiReactionPicker { emoji in
                let existing = groupChatService.reactionsByGroupId[group.id]?[target.id]?.first { $0.reactorAddress == myAddress }
                let action = existing?.emoji == emoji ? "remove" : "add"
                Task {
                    try? await groupChatService.sendGroupReaction(targetTxId: target.id, groupId: group.id, emoji: emoji, action: action)
                }
            }
        }
        .sheet(item: $reactionsSheetTarget) { target in
            ReactionsSheet(
                entries: (groupChatService.reactionsByGroupId[group.id]?[target.txId] ?? [])
                    .map { ReactionsSheet.Entry(emoji: $0.emoji, reactorAddress: $0.reactorAddress) },
                myAddress: myAddress ?? "",
                displayName: { displayName(for: $0) },
                avatarURL: { knsService.profileCache[$0]?.avatarURL }
            )
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
        // Expired membership lines disappear on their own while the thread is open, and are
        // pruned from the store so they never accumulate.
        .task(id: group.id) {
            while !Task.isCancelled {
                groupChatService.pruneExpiredSystemMessages(for: group.id)
                systemLineClock = Date()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
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
        .toast(message: toastMessage, style: toastStyle)
        .alert("Adjust Network Fee", isPresented: $showFeeEditor) {
            TextField("Fee (KAS)", text: $feeEditorText)
                .keyboardType(.decimalPad)
                .numericKeyboardDoneButton()
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
                    pendingPhotoOriginalData = data
                    schedulePhotoFeeEstimate()
                },
                onCancel: { showCamera = false },
                // Video mode only exists when the Nextcloud media route can carry the file -
                // there is no on-chain path that fits a video. Mirrors 1:1 chat exactly.
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

    /// Uploads a just-recorded camera clip to Nextcloud and sends its share link - the
    /// recipients' link previews render it as a playable video bubble. On failure the clip can't
    /// fall back on-chain (videos don't fit a payload), so the error surfaces directly. Mirrors
    /// `ChatDetailView.sendNextcloudVideo`, adapted to the group text-send API.
    private func sendNextcloudVideo(_ fileURL: URL) {
        errorMessage = nil
        Task {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            do {
                let data = try Data(contentsOf: fileURL)
                let ext = fileURL.pathExtension.isEmpty ? "mov" : fileURL.pathExtension.lowercased()
                let contentType = ext == "mp4" ? "video/mp4" : "video/quicktime"
                let shareURL = try await NextcloudService.shared.uploadMediaAndShare(
                    data: data,
                    filename: "video_\(Int(Date().timeIntervalSince1970)).\(ext)",
                    contentType: contentType
                )
                try await groupChatService.sendGroupMessage(shareURL.absoluteString, to: group.id)
            } catch {
                AppLog.log("[GroupChatDetailView] Nextcloud video send failed: %@", error.localizedDescription)
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Stages a picked file's share link in the composer instead of auto-sending — the user
    /// reviews it in the input bubble and taps send themselves. Mirrors
    /// `ChatDetailView.stageNextcloudLink`.
    private func stageNextcloudLink(_ url: URL) {
        errorMessage = nil
        draft = draft.isEmpty ? url.absoluteString : draft + " " + url.absoluteString
        isComposerFocused = true
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

    /// Representative raw-payload size of a Nextcloud `/s/TOKEN` share-link message - mirrors
    /// `ChatDetailView.nextcloudLinkPayloadSize` (the group envelope math on top of it is
    /// `estimateGroupMediaFee`'s, a slight overestimate for a plain text link, which is fine for
    /// a preview this small).
    private static let nextcloudLinkPayloadSize = 96

    private func schedulePhotoFeeEstimate() {
        feeEstimateTask?.cancel()
        isEstimatingFee = false
        // Via Nextcloud, the chain only carries the ~80-byte share link - the photo bytes live
        // on the server - so the fee shown is the link-message fee, not the envelope fee.
        let rawBytes = (nextcloudService.isConnected && nextcloudService.mediaSendEnabled)
            ? Self.nextcloudLinkPayloadSize
            : Self.groupPhotoTargetBytes
        feeEstimateSompi = groupChatService.estimateGroupMediaFee(rawBytes: rawBytes)
    }

    /// Raw encoded-Opus-bytes/sec estimate for `BroadcastAudioRecorder`'s fixed 6kbps/48kHz
    /// config (bitrate/8 + WebM container overhead) - matches `ChatDetailView.estimateEncodedSize`'s
    /// identical heuristic for the same recorder settings.
    private func updateRecordingFeeEstimate(elapsedSeconds: TimeInterval) {
        guard recorder.state == .recording else { return }
        // Via Nextcloud, the recording uploads to the server and the chain only carries the
        // share link - the fee is the link-message fee regardless of recording length.
        if nextcloudService.isConnected && nextcloudService.mediaSendEnabled {
            feeEstimateSompi = groupChatService.estimateGroupMediaFee(rawBytes: Self.nextcloudLinkPayloadSize)
            isEstimatingFee = false
            return
        }
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
        pendingPhotoOriginalData = data
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
                // non-text action. Matches 1:1 chat's textRow. When "Send Media via Nextcloud"
                // is on, captures ride the auto-upload send path automatically.
                Button {
                    takePhoto()
                } label: {
                    Image(systemName: "camera")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Take Photo"))

                // Its voice-note sibling: one tap starts recording, same as the "+"-menu entry -
                // and the finished note likewise uploads via Nextcloud whenever the toggle is on.
                // Matches 1:1 chat's textRow mic button.
                Button {
                    feeEstimateSompi = nil
                    recorder.start()
                } label: {
                    Image(systemName: "mic")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .accessibilityLabel(Text("Record Voice Message"))
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
    /// The composer's "+" options, as a half sheet - each with a line saying what it does.
    /// Mirrors 1:1's composerPlusSheet.
    private var plusSheet: some View {
        VStack(spacing: 12) {
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
                    showPlusSheet = false
                    DispatchQueue.main.async { showNextcloudPicker = true }
                }
            }
            if !(nextcloudService.isConnected && nextcloudService.mediaSendEnabled) {
                ActionSheetRow(
                    title: "Send Photo",
                    subtitle: "Pick an image from your library.",
                    systemImage: "photo"
                ) {
                    showPlusSheet = false
                    DispatchQueue.main.async { showPhotoPicker = true }
                }
                ActionSheetRow(
                    title: "Send Audio Message",
                    subtitle: "Record a voice message and send it to the group.",
                    systemImage: "mic.circle.fill"
                ) {
                    showPlusSheet = false
                    feeEstimateSompi = nil
                    recorder.start()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
    }

    private var plusMenu: some View {
        Button {
            Haptics.impact(.light)
            showPlusSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 44, height: 44)
                .background(glassBackground(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More options"))
        .sheet(isPresented: $showPlusSheet) { plusSheet }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
        .sheet(isPresented: $showNextcloudPicker) {
            NextcloudPickerView { url, _ in
                stageNextcloudLink(url)
            }
        }
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
                    pendingPhotoOriginalData = data
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
                pendingPhotoOriginalData = nil
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
            guard elapsed >= effectiveMaxRecordingDuration, recorder.state == .recording else { return }
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
            // "Send Media via Nextcloud": upload the best-quality bytes we have and send the
            // public share link as a normal group text message (the members' link-preview
            // feature renders it as a media bubble). Any upload/share failure falls back to the
            // on-chain envelope below, with a toast so the sender knows the full-quality upload
            // didn't happen. Mirrors `ChatDetailView.sendPendingPhotoAsync`.
            if NextcloudService.shared.mediaSendEnabled, NextcloudService.shared.isConnected {
                var shareURL: URL?
                do {
                    guard let upload = nextcloudPhotoUpload(for: pendingPhotoImage) else {
                        throw KasiaError.networkError("Couldn't encode the photo for upload.")
                    }
                    shareURL = try await NextcloudService.shared.uploadMediaAndShare(
                        data: upload.data,
                        filename: upload.filename,
                        contentType: upload.contentType
                    )
                } catch {
                    AppLog.log("[GroupChatDetailView] Nextcloud photo upload failed, falling back to on-chain: %@",
                               error.localizedDescription)
                    await MainActor.run {
                        showToast("Nextcloud upload failed — sending on-chain instead", style: .error)
                    }
                }
                if let shareURL {
                    do {
                        try await groupChatService.sendGroupMessage(shareURL.absoluteString, to: group.id)
                        await MainActor.run {
                            self.pendingPhotoImage = nil
                            self.pendingPhotoOriginalData = nil
                            self.isSendingPhoto = false
                        }
                    } catch {
                        // The chain send itself failed - an on-chain image envelope would fail
                        // the same way, so surface the error instead of falling back.
                        await MainActor.run {
                            self.errorMessage = error.localizedDescription
                            self.isSendingPhoto = false
                        }
                    }
                    return
                }
                // No share link - fall through to the on-chain envelope path.
            }

            do {
                let prepared = try ImagePrep.prepareForChatMessage(pendingPhotoImage, targetBytes: Self.groupPhotoTargetBytes)
                try await groupChatService.sendGroupImage(prepared.data, to: group.id, fileName: prepared.fileName, mimeType: prepared.mimeType)
                await MainActor.run {
                    self.pendingPhotoImage = nil
                    self.pendingPhotoOriginalData = nil
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
        // Snapshot once, so the toggle flipping mid-send can't strand the stashed original.
        let nextcloudActive = NextcloudService.shared.mediaSendEnabled && NextcloudService.shared.isConnected
        Task {
            // Nextcloud mode: stash the full-length original PCM BEFORE the payload-capped WebM
            // encode - the encode truncates to ~13KB (≈9s), and exporting the M4A from that
            // would silently re-cap a long recording. The copy lives only for this send; the
            // defer below is its single cleanup site (success, upload failure, and send failure
            // all pass through it). Mirrors `ChatDetailView.nextcloudOriginalRecordingURL`.
            let originalPCMURL: URL? = nextcloudActive
                ? FileManager.default.temporaryDirectory
                    .appendingPathComponent("kachat-group-voice-original-\(UUID().uuidString).caf")
                : nil
            defer {
                if let originalPCMURL {
                    try? FileManager.default.removeItem(at: originalPCMURL)
                }
            }
            do {
                let recorded = try await recorder.stopAndEncode(keepOriginalPCMAt: originalPCMURL)

                // "Send Media via Nextcloud": upload an AAC .m4a of the recording and send the
                // public share link instead of the on-chain WebM/Opus envelope. The .m4a
                // re-export matters: the recipients' link-preview audio card streams through
                // AVPlayer, which cannot decode WebM/Opus, so uploading the envelope bytes
                // verbatim would produce an unplayable card. Any failure falls back to the
                // on-chain path below, with a toast. Mirrors `ChatDetailView.sendAudioAsync`.
                if nextcloudActive {
                    var shareURL: URL?
                    do {
                        let m4aURL = try await exportRecordingAsM4A(originalPCMURL: originalPCMURL, webmData: recorded.data)
                        let m4aData = try Data(contentsOf: m4aURL)
                        try? FileManager.default.removeItem(at: m4aURL)
                        let stamp = Self.mediaTimestampFormatter.string(from: Date())
                        shareURL = try await NextcloudService.shared.uploadMediaAndShare(
                            data: m4aData,
                            filename: "voice_\(stamp).m4a",
                            contentType: "audio/mp4"
                        )
                    } catch {
                        AppLog.log("[GroupChatDetailView] Nextcloud audio upload failed, falling back to on-chain: %@",
                                   error.localizedDescription)
                        await MainActor.run {
                            showToast("Nextcloud upload failed — sending on-chain instead", style: .error)
                        }
                    }
                    if let shareURL {
                        try await groupChatService.sendGroupMessage(shareURL.absoluteString, to: group.id)
                        return
                    }
                    // No share link - fall through to the on-chain envelope path (the WebM is
                    // payload-capped, so a long Nextcloud-mode recording arrives truncated -
                    // same trade-off as 1:1's fallback).
                }

                try await groupChatService.sendGroupAudio(recorded.data, to: group.id, fileName: recorded.fileName, mimeType: recorded.mimeType)
            } catch {
                await MainActor.run { errorMessage = "Failed to send voice message: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Nextcloud media send helpers ("Send Media via Nextcloud" toggle)

    /// Human-sortable timestamp for uploaded media filenames (photo_20260811-101502.jpg) -
    /// duplicated from `ChatDetailView` (private there), matching this file's convention of
    /// small local copies over widened access.
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

    /// Magic-byte sniff so the uploaded file keeps an extension matching its actual container -
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
    /// stashed full-length original (never truncated by the payload cap) when it exists, else
    /// the WebM payload is decoded on the spot. Mirrors `ChatDetailView.exportRecordingAsM4A`,
    /// minus the preview-CAF branch (group's recorder has no preview step).
    private func exportRecordingAsM4A(originalPCMURL: URL?, webmData: Data) async throws -> URL {
        let pcmURL: URL
        let deletePCMAfter: Bool
        if let originalPCMURL, FileManager.default.fileExists(atPath: originalPCMURL.path) {
            pcmURL = originalPCMURL
            deletePCMAfter = false // sendRecording's defer owns this copy, not here
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
            .appendingPathComponent("kachat-group-voice-\(UUID().uuidString).m4a")
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
        showToast(address.addressCopiedToastText, style: .success)
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
        if let assigned = contactsManager.getContact(byAddress: address)?.assignedName {
            return assigned
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
    /// Verbatim mirror of ChatDetailView's proven initial-open choreography: the list rendered
    /// EMPTY until `initialLayoutReady` (see its doc comment), the window then fills in one update
    /// with `.defaultScrollAnchor(.bottom)` doing the real bottom-pinning, and this runs a SINGLE
    /// deferred, animation-free scrollTo as a backstop before revealing. The previous multi-delay
    /// retry loop (0/0.15/0.35/0.65s) raced the LazyVStack's row realization - a late retry landed
    /// against estimated heights and stranded the viewport in empty space on open.
    private func positionInitialViewport(using proxy: ScrollViewProxy) {
        guard initialLayoutReady else { return }
        guard !initialViewportPositioned else { return }
        // Group messages are decrypted off the main actor and published asynchronously, so on first
        // appear this list can still be empty. Wait for content before positioning/revealing; the
        // onChange(of: messages.count) below re-invokes this the instant the decrypted messages
        // land, and the onAppear fallback reveals a genuinely-empty thread so it isn't blank forever.
        guard !displayedMessages.isEmpty else { return }
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
            }
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
        let all = messages
        guard let targetIndex = all.firstIndex(where: { $0.txId == txId }) else {
            showToast("Original message not available.", style: .error)
            return
        }
        let target = all[targetIndex]
        // Ensure the target is inside the render window (it may be older than what's currently
        // shown) before scrolling to it - scrollTo only reaches rendered rows.
        let neededWindow = all.count - targetIndex
        if displayedMessages.count < neededWindow {
            loadedGroupMessageCount = min(neededWindow, all.count)
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
        toastStyle = style
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

    /// Group mirror of `ChatDetailView.chatTitleChip`: the group photo drawn over a glass name
    /// capsule that tucks under it, tapping through to Group Info. The negative spacing is what
    /// makes the two read as one piece rather than a stack.
    private var groupTitleChip: some View {
        Button {
            showInfo = true
        } label: {
            VStack(spacing: -12) {
                Group {
                    if let hex = groupChatService.groupPhotos[group.id],
                       let data = Data(hexString: hex),
                       let img = UIImage(data: data) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.2))
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(Circle())
                .zIndex(1)

                HStack(spacing: 4) {
                    Text(group.name)
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
                // iMessage's floating pill: a thin material so the messages scrolling underneath
                // actually show through it (the scroll view extends under this inset, so there IS
                // live content to blur), a hairline edge to keep it legible against a light
                // bubble, and a soft shadow so it reads as sitting above the thread rather than
                // painted onto the bar.
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 2)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Group info for \(group.name)"))
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
            onShowReactions: { reactionsSheetTarget = ReactionsSheetTarget(txId: message.txId) },
            onReact: { emoji in
                let existing = groupChatService.reactionsByGroupId[group.id]?[message.txId]?.first { $0.reactorAddress == myAddress }
                let action = existing?.emoji == emoji ? "remove" : "add"
                Task {
                    try? await groupChatService.sendGroupReaction(targetTxId: message.txId, groupId: group.id, emoji: emoji, action: action)
                }
            },
            onMoreReactions: { emojiPickerTarget = IdentifiedTxId(id: message.txId) },
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
    /// Opens the list of who reacted. Offered from the long-press menu only when there are
    /// reactions to show.
    var onShowReactions: (() -> Void)? = nil
    /// Sends/toggles a reaction on this message - nil disables the double-tap quick-reaction bar
    /// entirely (matches 1:1 chat's `MessageBubbleView.onReact`).
    var onReact: ((String) -> Void)?
    /// Asks the SCREEN to open the full emoji picker - see `QuickReactionBarView.onMore`.
    var onMoreReactions: (() -> Void)?
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
        if let assigned = contactsManager.getContact(byAddress: address)?.assignedName {
            return assigned
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

    /// A link back into KaChat (shared KaPosts post / broadcast-room invite) in this message.
    /// Same rule as 1:1 (`MessageBubbleView.internalLink`), and it has to be claimed BEFORE the
    /// generic link path: the universal-link form is an ordinary https URL, so without this a
    /// shared post would be scraped over the network like a stranger's link instead of
    /// previewing as the post it is.
    private var internalLink: KaChatInternalLink.Match? {
        KaChatInternalLink.match(in: displayContent)
    }


    /// Members actually @mentioned in this message (their `@address` token is present in the raw text).
    private var mentionedMembers: [GroupMember] {
        let raw = replyQuote?.text ?? message.content
        return group.members.filter { raw.contains("@\($0.address)") }
    }

    /// Label to show for a mention: the person's KNS domain (what the user asked to see), else the
    /// friendly display name. Read from the synchronous KNS cache.
    private func mentionLabel(for address: String) -> String {
        if let domain = knsService.domainCache[address]?.explicitPrimaryDomain, !domain.isEmpty { return domain }
        return resolveDisplayName(for: address)
    }

    /// Build the message text as an AttributedString where each @mention renders as the KNS domain,
    /// accent-coloured and TAPPABLE (a `kachat-mention://<address>` link the bubble's OpenURLAction
    /// resolves to a 1:1 chat). Mirrors `KaPostsView.linkified`, but opens a chat, not a profile.
    private func mentionAttributedContent() -> AttributedString {
        // Swap each @address → @label (longest address first for safety), like decodeForDisplay.
        var display = replyQuote?.text ?? message.content
        for m in group.members.sorted(by: { $0.address.count > $1.address.count }) {
            let label = mentionLabel(for: m.address)
            guard !label.isEmpty else { continue }
            display = display.replacingOccurrences(of: "@\(m.address)", with: "@\(label)")
        }
        var attributed = AttributedString(display)
        // Keep any plain URLs tappable too.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let nsText = display as NSString
            for match in detector.matches(in: display, options: [], range: NSRange(location: 0, length: nsText.length)) {
                guard let url = match.url, let sr = Range(match.range, in: display) else { continue }
                let startOffset = display.distance(from: display.startIndex, to: sr.lowerBound)
                let length = display.distance(from: sr.lowerBound, to: sr.upperBound)
                let start = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
                let end = attributed.index(start, offsetByCharacters: length)
                attributed[start..<end].link = url
                attributed[start..<end].underlineStyle = .single
            }
        }
        // Link each mention's @label run to its member address.
        for m in group.members {
            let label = mentionLabel(for: m.address)
            guard !label.isEmpty else { continue }
            let token = "@\(label)"
            let enc = m.address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? m.address
            let url = URL(string: "kachat-mention://\(enc)")
            var searchStart = display.startIndex
            while let r = display.range(of: token, range: searchStart..<display.endIndex) {
                let startOffset = display.distance(from: display.startIndex, to: r.lowerBound)
                let length = display.distance(from: r.lowerBound, to: r.upperBound)
                let start = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
                let end = attributed.index(start, offsetByCharacters: length)
                attributed[start..<end].foregroundColor = message.isOutgoing ? .white : .accentColor
                attributed[start..<end].underlineStyle = .single
                if let url { attributed[start..<end].link = url }
                searchStart = r.upperBound
            }
        }
        return attributed
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
                        },
                        onMore: {
                            // Close the bar and hand off in one go: the screen owns the picker,
                            // so it survives this bar going away.
                            activeQuickReactionMessageId.wrappedValue = nil
                            onMoreReactions?()
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
                    } else if let internalLink {
                        // A link into KaChat: the post/invite card IS the message, exactly as in
                        // 1:1 chats and broadcast rooms - text around the link is not drawn,
                        // since KaPosts' own share text quotes the post above it.
                        KaChatInternalLinkCardView(
                            match: internalLink,
                            txId: message.txId,
                            onSelect: onSelect,
                            onDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : nil
                        )
                    } else if internalLink == nil, let linkURL = MessageTextRenderPlan.firstHTTPLink(in: displayContent), MessageTextRenderPlan.isEntirelyLink(displayContent) {
                        // Message is nothing but a link - the preview card replaces the plain-text
                        // bubble entirely (matches iMessage) instead of showing both. `fallbackText`
                        // keeps the raw link visible/tappable if no preview data is ever found,
                        // rather than the message rendering as nothing at all.
                        LinkPreviewCardView(url: linkURL, txId: message.txId, fallbackText: displayContent, onSelect: onSelect, onDoubleTap: onReact != nil ? { activeQuickReactionMessageId.wrappedValue = message.id } : nil)
                    } else {
                        Group {
                            if !mentionedMembers.isEmpty {
                                // Clickable KNS-domain @mentions → open a 1:1 chat with that person.
                                Text(mentionAttributedContent())
                                    .font(.body)
                                    .foregroundColor(message.isOutgoing ? .white : .primary)
                                    .environment(\.openURL, OpenURLAction { url in
                                        if url.scheme == "kachat-mention" {
                                            let full = url.absoluteString
                                            let enc = full.hasPrefix("kachat-mention://") ? String(full.dropFirst("kachat-mention://".count)) : (url.host ?? "")
                                            let addr = enc.removingPercentEncoding ?? enc
                                            if !addr.isEmpty { onOpenChat(addr) }
                                            return .handled
                                        }
                                        return .systemAction
                                    })
                            } else if MessageTextRenderPlan.requiresLinkTextView(displayContent) {
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
                            // The pill shows WHICH emoji are on the bubble; it has no room to
                            // say how many or from whom. In a group that is the interesting
                            // question.
                            if !reactions.isEmpty, let onShowReactions {
                                Button {
                                    onShowReactions()
                                } label: {
                                    Label("Reactions (\(reactions.count))", systemImage: "heart")
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
                        // Half sheet rather than a confirmation dialog - see LinkActionsSheet.
                        .sheet(item: Binding(get: { linkMenuURL.map(IdentifiedURL.init) }, set: { if $0 == nil { linkMenuURL = nil } })) { wrapper in
                            LinkActionsSheet(
                                url: wrapper.url,
                                onOpen: { UIApplication.shared.open(wrapper.url) },
                                onCopy: {
                                    onCopy(wrapper.url.absoluteString, .success)
                                    UIPasteboard.general.string = wrapper.url.absoluteString
                                },
                                onReply: onReply
                            )
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
                   internalLink == nil,
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
                size: 32,
                contactAddress: message.isOutgoing ? nil : message.senderAddress
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
    @State private var resendMessage: String?
    @State private var showAddMembers = false
    // Members list is a collapsed-by-default dropdown; per-member actions confirm first.
    @State private var membersExpanded = false
    @State private var memberToResend: GroupMember?
    @State private var memberToRemove: GroupMember?
    @State private var showResendAllConfirm = false
    @State private var groupPhotoPickerItem: PhotosPickerItem?
    @State private var pendingPhotoHex: String?
    @State private var showRemovePhotoConfirm = false
    @State private var groupPhotoError: String?

    /// The admin-set group photo decoded to an image, or nil.
    private var groupPhotoImage: UIImage? {
        guard let hex = groupChatService.groupPhotos[group.id], let data = Data(hexString: hex) else { return nil }
        return UIImage(data: data)
    }

    /// Circular group avatar (photo when set, else the name's initial), with an edit badge for admins.
    private var groupHeaderAvatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = groupPhotoImage {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.2))
                        Text(String(group.name.prefix(1)).uppercased())
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(Circle())
            if group.isAdmin {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.accentColor)
                    .background(Circle().fill(Color(.systemBackground)))
            }
        }
    }
    var onDeleted: (() -> Void)?

    /// Re-broadcast the current group root to a single member (or all when address is nil), then
    /// surface the result in an alert. Admin-only (guarded again in the service).
    private func resendInvites(to address: String?) {
        Task {
            do {
                if let address { try await groupChatService.resendInvite(to: address, groupId: group.id) }
                else { try await groupChatService.resendInvites(group.id) }
                await MainActor.run { resendMessage = address == nil ? "Invites resent to all members." : "Invite resent." }
            } catch {
                await MainActor.run { resendMessage = error.localizedDescription }
            }
        }
    }

    /// Remove one member (admin), rotating the group key so they can't decrypt future messages.
    private func removeMember(_ member: GroupMember) {
        Task {
            do { try await groupChatService.removeMember(member, from: group.id) }
            catch { await MainActor.run { resendMessage = error.localizedDescription } }
        }
    }

    private var myAddress: String? { walletManager.currentWallet?.publicAddress }

    /// Other members (excludes self) — the fan-out count for admin control sends.
    private var otherMemberCount: Int { group.members.filter { $0.address != myAddress }.count }

    /// A short " Estimated network fee ≈ X KAS across N transactions." line for a confirm dialog.
    private func groupFeeSuffix(controlTx: Int, photoTx: Int = 0) -> String {
        let n = controlTx + photoTx
        let plural = n == 1 ? "" : "s"
        guard let kas = groupChatService.estimateGroupActionFeeKas(groupId: group.id, controlTx: controlTx, photoTx: photoTx) else {
            return "\n\n(\(n) network transaction\(plural).)"
        }
        return "\n\nEstimated network fee ≈ \(kas) KAS across \(n) transaction\(plural)."
    }

    /// Fee suffix for setting a NEW photo (estimated from its own size, not the stored one).
    private func groupPhotoFeeSuffix(hexLength: Int) -> String {
        let n = otherMemberCount
        let plural = n == 1 ? "" : "s"
        guard n > 0, let kas = groupChatService.estimateGroupPhotoFeeKas(hexLength: hexLength, txCount: n) else {
            return "\n\n(\(n) network transaction\(plural).)"
        }
        return "\n\nEstimated network fee ≈ \(kas) KAS across \(n) transaction\(plural)."
    }

    /// Same resolution 1:1/broadcast/the message list use (contact alias, then KNS domain, then
    /// a generated fallback) - not `member.displayName`, which is only a one-time snapshot from
    /// when the roster was built/received and never updated afterward (see `GroupChatDetailView.
    /// displayName(for:)`'s identical doc comment). Applied uniformly to every member, including
    /// the current user's own row, rather than special-casing "You" here the way message bubbles
    /// do - this screen is about who someone *is*, not who sent a given message.
    private func displayName(for address: String) -> String {
        if let assigned = contactsManager.getContact(byAddress: address)?.assignedName {
            return assigned
        }
        if let knsName = knsService.profileCache[address]?.domainName, !knsName.isEmpty {
            return knsName
        }
        return Contact.generateDefaultAlias(from: address)
    }

    private var hiddenMemberAddresses: [String] {
        Array(groupChatService.hiddenMemberAddresses(for: group.id))
    }

    /// Header section: avatar (tappable PhotosPicker for admins), name, member count, remove-photo.
    /// Extracted from `body` so the Form's big expression stays type-checkable.
    private var groupHeaderSection: some View {
        Section {
            VStack(spacing: 8) {
                if group.isAdmin {
                    PhotosPicker(selection: $groupPhotoPickerItem, matching: .images) { groupHeaderAvatar }
                        .buttonStyle(.plain)
                } else {
                    groupHeaderAvatar
                }
                Text(group.name)
                    .font(.title3).fontWeight(.semibold)
                Text("\(group.members.count) members")
                    .font(.caption).foregroundColor(.secondary)
                if group.isAdmin && groupPhotoImage != nil {
                    Button("Remove photo", role: .destructive) {
                        showRemovePhotoConfirm = true
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    /// Explicitly typed bindings keep the inline `Binding(get:set:)` closures out of the
    /// modifier chain, which is what was pushing the type-checker past its budget.
    private var isRemoveMemberPresented: Binding<Bool> {
        Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } })
    }

    private var isGroupPhotoErrorPresented: Binding<Bool> {
        Binding(get: { groupPhotoError != nil }, set: { if !$0 { groupPhotoError = nil } })
    }

    /// Admin picked a new group photo: shrink to a ~10 KB JPEG and broadcast it via gctl_photo.
    private func handleGroupPhotoSelection(_ newItem: PhotosPickerItem?) {
        guard let newItem else { return }
        Task {
            do {
                guard let data = try await newItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                let jpeg = try ImagePrep.prepareJPEGForChatMessage(image, targetBytes: 10_000)
                // Stash the compressed photo and confirm (with the estimated fee) before sending.
                await MainActor.run { pendingPhotoHex = jpeg.hexString }
            } catch {
                await MainActor.run { groupPhotoError = error.localizedDescription }
            }
            await MainActor.run { groupPhotoPickerItem = nil }
        }
    }

    // The info screen is assembled in layers, each a separately type-checked expression:
    // form -> sheets -> member alerts -> admin alerts -> navigation chrome. Keeping the whole
    // Form + ~10 presentation modifiers in one `body` expression pushed Swift's type-checker
    // past its budget ("unable to type-check this expression in reasonable time").
    var body: some View {
        NavigationStack {
            infoFormWithAdminAlerts
                .navigationTitle("Group Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    // MARK: Layer 1 - the Form

    private var infoForm: some View {
        Form {
            // Group header: avatar + name at the very top, showing what the group currently is.
            groupHeaderSection

            Section {
                DisclosureGroup(isExpanded: $membersExpanded) {
                    ForEach(group.members) { member in
                        memberRow(member)
                    }
                } label: {
                    Text("Members (\(group.members.count))")
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
                Button {
                    Task { await groupChatService.forceRefresh(groupId: group.id) }
                } label: {
                    Label("Refresh Messages", systemImage: "arrow.clockwise")
                }
                .disabled(groupChatService.refreshingGroupIds.contains(group.id))

                Toggle("Silent Group Chat", isOn: silentBinding)
                Toggle("Only Notify if I'm Mentioned", isOn: mentionsOnlyBinding)
                    // Silent already means "never", so the finer rule underneath it is moot.
                    .disabled(groupChatService.silentNotifications(for: group.id))
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
                    Button {
                        showResendAllConfirm = true
                    } label: {
                        Label("Resend invites to all", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showAddMembers = true
                    } label: {
                        Label("Add Members", systemImage: "person.badge.plus")
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
    }

    /// One member row: avatar, name, Admin tag, and (for admins) resend/remove buttons.
    private func memberRow(_ member: GroupMember) -> some View {
        let memberLabel = displayName(for: member.address)
        return HStack(spacing: 12) {
            KNSAvatarView(
                avatarURLString: knsService.profileCache[member.address]?.avatarURL,
                fallbackText: memberLabel,
                size: 32,
                contactAddress: member.address
            )
            Text(memberLabel)
                .foregroundColor(.primary)
            Spacer()
            if member.isAdmin {
                Text("Admin")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // Admin-only per-member actions (visible buttons, each confirmed first),
            // matching Android/desktop. .borderless so each taps independently of the row.
            if group.isAdmin && member.address != myAddress {
                Button { memberToResend = member } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .tint(.accentColor)
                Button { memberToRemove = member } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .tint(.red)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            profileContact = contactsManager.getContact(byAddress: member.address)
                ?? contactsManager.getOrCreateContact(address: member.address)
        }
        .task {
            guard knsService.profileCache[member.address] == nil else { return }
            _ = await knsService.fetchProfile(for: member.address)
        }
    }

    // MARK: Layer 2 - sheets

    private var infoFormWithSheets: some View {
        infoForm
            .sheet(isPresented: isProfilePresented) {
                if let contact = profileContact {
                    NavigationStack {
                        ChatInfoView(
                            contact: profileContactBinding(fallback: contact),
                            title: "User Info",
                            showsNotificationSettings: false
                        )
                    }
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { groupChatService.refreshProgress?.groupId == group.id },
                set: { if !$0 { groupChatService.clearRefreshProgress() } }
            )) {
                GroupRefreshProgressModal(groupId: group.id)
            }
            .sheet(isPresented: $showHiddenMembers) {
                NavigationStack {
                    HiddenGroupMembersView(group: group)
                }
            }
            .sheet(isPresented: $showAddMembers) {
                NavigationStack {
                    AddGroupMembersView(group: group)
                }
            }
    }

    // MARK: Layer 3 - member alerts

    private var infoFormWithMemberAlerts: some View {
        infoFormWithSheets
            .alert("Resend Invites", isPresented: isResendMessagePresented) {
                Button("OK", role: .cancel) { resendMessage = nil }
            } message: {
                Text(resendMessage ?? "")
            }
            .alert("Resend invite", isPresented: isResendMemberPresented) {
                Button("Send") { if let m = memberToResend { resendInvites(to: m.address) }; memberToResend = nil }
                Button("Cancel", role: .cancel) { memberToResend = nil }
            } message: {
                Text("Resend the group invite to \(memberName(memberToResend))?\(groupFeeSuffix(controlTx: 1))")
            }
            .alert("Remove member", isPresented: isRemoveMemberPresented) {
                Button("Yes", role: .destructive) { if let m = memberToRemove { removeMember(m) }; memberToRemove = nil }
                Button("Cancel", role: .cancel) { memberToRemove = nil }
            } message: {
                let afterN = max(0, otherMemberCount - 1)
                let hasPhoto = groupChatService.groupPhotos[group.id] != nil
                Text("Remove \(memberName(memberToRemove)) from the group chat? A fresh group key is issued to everyone who stays.\(groupFeeSuffix(controlTx: 2 * afterN + 1, photoTx: hasPhoto ? afterN : 0))")
            }
            .alert("Resend invites to all", isPresented: $showResendAllConfirm) {
                Button("Send") { resendInvites(to: nil) }
                Button("Cancel", role: .cancel) {}
            } message: {
                let hasPhoto = groupChatService.groupPhotos[group.id] != nil
                Text("Resend the group invite to every member? Use this if someone didn't receive the group.\(groupFeeSuffix(controlTx: otherMemberCount + 1, photoTx: hasPhoto ? otherMemberCount : 0))")
            }
    }

    // MARK: Layer 4 - admin alerts (photo, rename, delete)

    private var infoFormWithAdminAlerts: some View {
        infoFormWithMemberAlerts
            .alert("Group photo", isPresented: isGroupPhotoErrorPresented) {
                Button("OK", role: .cancel) { groupPhotoError = nil }
            } message: {
                Text(groupPhotoError ?? "")
            }
            .onChange(of: groupPhotoPickerItem) { newItem in
                handleGroupPhotoSelection(newItem)
            }
            .alert("Rename Group", isPresented: $showRename) {
                TextField("Group name", text: $renameText)
                Button("Save") { saveRename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every member will see the new name.\(groupFeeSuffix(controlTx: otherMemberCount + 1))")
            }
            .alert("Set group photo", isPresented: Binding(get: { pendingPhotoHex != nil }, set: { if !$0 { pendingPhotoHex = nil } })) {
                Button("Send") {
                    if let hex = pendingPhotoHex { Task { try? await groupChatService.setGroupPhoto(group.id, photoHex: hex) } }
                    pendingPhotoHex = nil
                }
                Button("Cancel", role: .cancel) { pendingPhotoHex = nil }
            } message: {
                Text("Set this as the group photo for everyone?\(groupPhotoFeeSuffix(hexLength: pendingPhotoHex?.count ?? 0))")
            }
            .alert("Remove group photo", isPresented: $showRemovePhotoConfirm) {
                Button("Remove", role: .destructive) {
                    Task { try? await groupChatService.setGroupPhoto(group.id, photoHex: "") }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove the group photo for everyone?\(groupFeeSuffix(controlTx: otherMemberCount))")
            }
            .alert("Couldn't Rename Group", isPresented: isRenameErrorPresented) {
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

    // MARK: Typed bindings + small helpers (kept out of the view expressions on purpose)

    private var silentBinding: Binding<Bool> {
        Binding(
            get: { groupChatService.silentNotifications(for: group.id) },
            set: { groupChatService.setSilentNotifications($0, for: group.id) }
        )
    }

    private var mentionsOnlyBinding: Binding<Bool> {
        Binding(
            get: { groupChatService.mentionsOnlyNotifications(for: group.id) },
            set: { groupChatService.setMentionsOnlyNotifications($0, for: group.id) }
        )
    }

    private var isProfilePresented: Binding<Bool> {
        Binding(get: { profileContact != nil }, set: { if !$0 { profileContact = nil } })
    }

    private func profileContactBinding(fallback contact: Contact) -> Binding<Contact> {
        Binding(get: { profileContact ?? contact }, set: { profileContact = $0 })
    }

    private var isResendMessagePresented: Binding<Bool> {
        Binding(get: { resendMessage != nil }, set: { if !$0 { resendMessage = nil } })
    }

    private var isResendMemberPresented: Binding<Bool> {
        Binding(get: { memberToResend != nil }, set: { if !$0 { memberToResend = nil } })
    }

    private var isRenameErrorPresented: Binding<Bool> {
        Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })
    }

    private func memberName(_ member: GroupMember?) -> String {
        member.map { displayName(for: $0.address) } ?? "this member"
    }

    private func saveRename() {
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
        if let assigned = contactsManager.getContact(byAddress: address)?.assignedName {
            return assigned
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
                            KNSAvatarView(
                                avatarURLString: knsService.profileCache[address]?.avatarURL,
                                fallbackText: displayName(for: address),
                                size: 32,
                                contactAddress: address
                            )
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

/// Admin-only "Add Members" sheet: pick contacts who aren't already in the group and add them.
/// Each add rotates the group epoch and redistributes the new root to the whole roster (see
/// `GroupChatService.addMember`), so new members only see messages from when they join onward.
private struct AddGroupMembersView: View {
    let group: GroupChat
    @EnvironmentObject var groupChatService: GroupChatService
    @EnvironmentObject var contactsManager: ContactsManager
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedAddresses: Set<String> = []
    @State private var isAdding = false
    @State private var resultMessage: String?
    @State private var showAddConfirm = false
    /// Address a typed KNS domain resolved to, so `.kas` names work here like they do everywhere
    /// else an address is accepted.
    @State private var resolvedDomainAddress: String?
    @State private var isResolvingDomain = false

    /// A group invite is encrypted to the invitee's public key, which is decoded from their
    /// address - no handshake, no prior chat, nothing but the address. Restricting this sheet to
    /// saved contacts made it look like a handshake was required to invite someone, when the only
    /// thing actually missing was somewhere to type the address.
    private var typedAddress: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let candidate = ContactsManager.shared.isValidKaspaAddress(query) ? query : resolvedDomainAddress
        guard let candidate, ContactsManager.shared.isValidKaspaAddress(candidate) else { return nil }
        guard candidate != WalletManager.shared.currentWallet?.publicAddress else { return nil }
        guard !group.members.contains(where: { $0.address == candidate }) else { return nil }
        // Already listed below as a contact, so offering it twice would just be confusing.
        guard !candidates.contains(where: { $0.address == candidate }) else { return nil }
        return candidate
    }

    /// Resolves `name` / `name.kas` in the background. Anything that is already an address, or
    /// too short to be a domain, is left alone.
    private func resolveTypedDomain() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        resolvedDomainAddress = nil
        guard !query.isEmpty,
              !ContactsManager.shared.isValidKaspaAddress(query),
              !query.contains(":"),
              query.count >= 2 else {
            isResolvingDomain = false
            return
        }
        isResolvingDomain = true
        Task {
            let resolved = await KNSService.shared.resolveDomain(query)
            await MainActor.run {
                // The field may have moved on while the lookup was in flight.
                guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == query else { return }
                resolvedDomainAddress = resolved?.ownerAddress
                isResolvingDomain = false
            }
        }
    }

    /// Estimated total fee for adding the selected members (each add rotates the group key).
    private func addFeeSuffix() -> String {
        let k = selectedAddresses.count
        let myAddr = WalletManager.shared.currentWallet?.publicAddress
        let finalOthers = group.members.filter { $0.address != myAddr }.count + k
        let hasPhoto = groupChatService.groupPhotos[group.id] != nil
        let controlTx = k * (2 * finalOthers + 1)
        let photoTx = hasPhoto ? k * finalOthers : 0
        let n = controlTx + photoTx
        guard let kas = groupChatService.estimateGroupActionFeeKas(groupId: group.id, controlTx: controlTx, photoTx: photoTx) else {
            return "\n\n(\(n) network transaction\(n == 1 ? "" : "s").)"
        }
        return "\n\nEstimated network fee ≈ \(kas) KAS across \(n) transaction\(n == 1 ? "" : "s")."
    }

    /// Contacts not already in the group, filtered by the search box (name or address).
    private var candidates: [Contact] {
        let existing = Set(group.members.map { $0.address })
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = contactsManager.activeContacts
            .filter { !existing.contains($0.address) }
            .sorted { contactsManager.displayName(for: $0).localizedCaseInsensitiveCompare(contactsManager.displayName(for: $1)) == .orderedAscending }
        guard !query.isEmpty else { return all }
        return all.filter { contactsManager.displayName(for: $0).lowercased().contains(query) || $0.address.lowercased().contains(query) }
    }

    private func addSelected() {
        let addresses = Array(selectedAddresses)
        guard !addresses.isEmpty else { return }
        isAdding = true
        Task {
            var failures = 0
            for address in addresses {
                let contact = contactsManager.getContact(byAddress: address)
                    ?? contactsManager.getOrCreateContact(address: address)
                do { try await groupChatService.addMember(contact, to: group.id) }
                catch { failures += 1 }
            }
            await MainActor.run {
                isAdding = false
                if failures == 0 { dismiss() }
                else { resultMessage = "\(failures) member(s) could not be added. Please try again." }
            }
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Search contacts, or paste an address", text: $searchText)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _ in resolveTypedDomain() }
                if isResolvingDomain {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking up domain...").font(.caption).foregroundColor(.secondary)
                    }
                }
                if let typedAddress {
                    Button {
                        if selectedAddresses.contains(typedAddress) { selectedAddresses.remove(typedAddress) }
                        else { selectedAddresses.insert(typedAddress) }
                    } label: {
                        HStack(spacing: 12) {
                            KNSAvatarView(avatarURLString: nil, fallbackText: Contact.generateDefaultAlias(from: typedAddress), size: 32, contactAddress: typedAddress)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add this address").foregroundColor(.primary).lineLimit(1)
                                Text(Contact.generateDefaultAlias(from: typedAddress))
                                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: selectedAddresses.contains(typedAddress) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedAddresses.contains(typedAddress) ? .accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                if contactsManager.activeContacts.isEmpty {
                    Text("You have no contacts yet. Paste an address or a .kas domain above to invite someone.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if candidates.isEmpty {
                    Text(searchText.isEmpty ? "Everyone in your contacts is already in this group." : "No contacts match your search. Paste an address or a .kas domain to invite someone new.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(candidates, id: \.address) { contact in
                        Button {
                            if selectedAddresses.contains(contact.address) { selectedAddresses.remove(contact.address) }
                            else { selectedAddresses.insert(contact.address) }
                        } label: {
                            HStack(spacing: 12) {
                                KNSAvatarView(avatarURLString: nil, fallbackText: contactsManager.displayName(for: contact), size: 32, contactAddress: contact.address)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contactsManager.displayName(for: contact)).foregroundColor(.primary).lineLimit(1)
                                    Text(Contact.generateDefaultAlias(from: contact.address))
                                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: selectedAddresses.contains(contact.address) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedAddresses.contains(contact.address) ? .accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } footer: {
                Text("New members can read messages from the moment they're added, not earlier history.")
            }
        }
        .navigationTitle("Add Members")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isAdding {
                    ProgressView()
                } else {
                    Button(selectedAddresses.isEmpty ? "Add" : "Add (\(selectedAddresses.count))") {
                        showAddConfirm = true
                    }
                    .disabled(selectedAddresses.isEmpty)
                }
            }
        }
        .alert("Add members", isPresented: $showAddConfirm) {
            Button("Add") { addSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add \(selectedAddresses.count) member\(selectedAddresses.count == 1 ? "" : "s") to the group?\(addFeeSuffix())")
        }
        .alert("Add Members", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK", role: .cancel) { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
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


// MARK: - Group refresh progress

/// Blocking progress for "Refresh Messages", mirroring the chat-history restore modal.
///
/// The repair walks the invite stream, then every epoch key, then each member's message stream
/// from the very beginning - which takes real time on a long-lived group. A bare spinner in a
/// settings row gave no sign any of that was happening, which is why the button read as doing
/// nothing even when it worked.
private struct GroupRefreshProgressModal: View {
    let groupId: String
    @EnvironmentObject var groupChatService: GroupChatService

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                if case .finished(let recovered, let rejections) = groupChatService.refreshProgress?.phase {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundColor(.green)
                    Text("Refresh complete")
                        .font(.headline)
                    Text(recovered > 0
                         ? "Recovered \(recovered) message\(recovered == 1 ? "" : "s") this device had not been able to read."
                         : "No new messages were recovered.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    // Says WHICH wall the repair hit, so "nothing recovered" is diagnosable
                    // rather than just disappointing.
                    if !rejections.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            if rejections.noRootForEpoch > 0 {
                                Text("\(rejections.noRootForEpoch) message\(rejections.noRootForEpoch == 1 ? "" : "s") from an epoch this device holds no key for")
                            }
                            if rejections.senderNotInRoster > 0 {
                                Text("\(rejections.senderNotInRoster) from someone no longer in the group")
                            }
                            if rejections.decryptFailed > 0 {
                                Text("\(rejections.decryptFailed) that failed to decrypt")
                            }
                            if rejections.epochRootsArchived > 0 {
                                Text("Recovered \(rejections.epochRootsArchived) older epoch key\(rejections.epochRootsArchived == 1 ? "" : "s")")
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    }
                    Button("Done") { groupChatService.clearRefreshProgress() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text("Rebuilding this group")
                        .font(.headline)
                    Text(groupChatService.refreshProgress?.phase.label ?? "Starting")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Re-reading the whole group from the chain, the same way importing your seed phrase does. Leaving now would stop it partway.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(groupRefreshGlassBackground(cornerRadius: 24))
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
    }
}

private func groupRefreshGlassBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
}
