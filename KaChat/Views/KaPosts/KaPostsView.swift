import CryptoKit
import SwiftUI
import UIKit

/// KaPosts main screen - UI ONLY for now (nothing is wired to K/K-indexer yet; posts live in
/// memory for this session purely so the composer flow is demoable). Three feeds along the top
/// (Following | Feed | Popular - Popular will rank by likes, reposts and dislikes once wired),
/// and a floating create-post button mirroring the chat list's create-chat button.
///
/// Deliberately has NO NavigationStack of its own - same reason as the old coming-soon page:
/// when shown in the Chats slot (full-dock re-tap mode) it overlays ChatListView, which already
/// hosts one; nesting two wrapped navigation controllers in a tab slot is a UIKit crash. The
/// standalone dock-tab case wraps it at the call site (MainTabView.tabContent).
struct KaPostsView: View {
    private enum FeedTab: CaseIterable {
        case following
        case feed
        case popular

        var title: String {
            switch self {
            case .following: return "Following"
            case .feed: return "Feed"
            case .popular: return "Popular"
            }
        }
    }

    /// In-memory only - a post is PLAIN TEXT, nothing else. No links (rendered inert), no photos.
    /// X-matching post/reply length cap.
    static let postCharacterLimit = 25_000

    struct DraftPost: Identifiable, Equatable {
        /// Local session posts get a random id; indexer-fetched posts get a STABLE id derived
        /// from their txid (see mapRemotePost) - refreshing a feed must not hand every row a
        /// new identity, or LazyVStack rebuilds the whole feed (scroll jumps + a beefy hang,
        /// seen on resume when an in-flight load completed).
        var id = UUID()
        let text: String
        let timestamp: Date
        /// Kaspa address of the author - drives KNS avatar/name resolution and follow state.
        let posterAddress: String
        /// K transaction id when this post came from the indexer (nil = local session post that
        /// hasn't been wired on-chain yet). Used to fetch replies and (Phase B) target votes.
        var remoteId: String? = nil
        /// Author's K pubkey (needed for Phase B write targeting); nil for local session posts.
        var posterPubkey: String? = nil
        var likes: Int = 0
        var dislikes: Int = 0
        var reposts: Int = 0
        var likedByMe = false
        var dislikedByMe = false
        var repostedByMe = false
        /// In-memory only, like the posts themselves - bookmark persistence lands with post
        /// wiring (a bookmark id is meaningless across launches while posts are session-only).
        var bookmarkedByMe = false
        /// On-chain delivery state, mirroring chat messages: pending while the K transaction is
        /// submitting, sent once it's on the network, failed -> Retry. Remote-fetched posts are
        /// sent by definition.
        enum Delivery: Equatable { case pending, sent, failed }
        var deliveryStatus: Delivery = .sent
        /// The indexer's reply count for this post - feed cells show it before any replies
        /// have actually been fetched (they load lazily on opening the thread).
        var remoteReplyCount: Int = 0
        /// Replies, X-style. Comments are themselves DraftPosts so the cell (avatar/KNS
        /// name/follow/engagement) is reused wholesale - and they nest: a comment carries its
        /// own comments, opened as its own thread.
        var comments: [DraftPost] = []
        /// X-style quote embed: set when this post quotes another (locally at compose time, or
        /// from the indexer's embedded quote reference). Renders as a bordered mini card under
        /// the post text.
        struct QuotedRef: Equatable {
            let remoteId: String?
            let text: String
            let posterAddress: String
            let timestamp: Date?
        }
        var quoted: QuotedRef? = nil
        /// Set for replies fetched from the indexer - splits profile feeds into Posts/Replies.
        var parentRemoteId: String? = nil
    }

    @State private var selectedFeed: FeedTab = .feed
    /// Local session posts (composer output) - overlaid on top of remote posts until on-chain
    /// posting lands (Phase B), at which point composing will submit a real K transaction.
    @State private var posts: [DraftPost] = []
    /// Posts fetched from the K indexer (already KaChat-marker-filtered by the client).
    @State private var remotePosts: [DraftPost] = []
    @State private var isLoadingFeed = false
    @State private var feedError: String?
    @State private var showComposer = false
    /// Zero-balance interception for the new-post entry point: with a CONFIRMED 0 KAS chatting
    /// balance (never on unknown/still-loading - see
    /// `WalletManager.hasConfirmedZeroChattingBalance`) the pencil button presents the shared
    /// funding card instead of the composer.
    @State private var showComposeFundingSheet = false
    /// Same interception for the thread view's reply bar - separate flag because that bar
    /// lives inside the `detailTarget` sheet, so its funding card must present as a nested
    /// sheet from in there (a single shared flag bound to two `.sheet` modifiers at different
    /// presentation levels would fight over who presents).
    @State private var showReplyFundingSheet = false
    @State private var profileTarget: PosterProfileTarget?
    /// Post whose comment thread is open - the sheet looks the post up live by id, so new
    /// comments/likes appear immediately.
    @State private var detailTarget: PostDetailTarget?
    /// "View Post in Explorer" tapped: engagement screen first (likes/dislikes/reposts/quotes).
    @State private var engagementTarget: DraftPost?
    @State private var profileFollowListKind: KaPostsFollowListView.Kind?
    @State private var myFollowersCount: Int?
    /// Your on-chain posts fetched from the indexer for the profile feed - local session posts
    /// alone would make the profile forget everything on relaunch.
    @State private var myProfileRemotePosts: [DraftPost] = []
    @State private var isLoadingMyProfilePosts = false
    @State private var myProfileRemoteReplies: [DraftPost] = []
    @State private var myProfileFeedTab: ProfileFeedTab = .posts
    @State private var posterProfileReplies: [DraftPost] = []
    @State private var posterProfileFeedTab: ProfileFeedTab = .posts
    /// Comments whose reply chains are expanded inline in the thread view (X-style).
    @State private var expandedCommentIds: Set<UUID> = []

    enum ProfileFeedTab: String, CaseIterable {
        case posts = "Posts"
        case replies = "Replies"
    }
    /// One self-unfollow scrub per session at most (indexer lag would otherwise resubmit).
    @State private var selfUnfollowScrubbed = false
    /// The tapped poster's on-chain posts + counts for the full-profile sheet.
    @State private var posterProfilePosts: [DraftPost] = []
    @State private var posterProfileFollowers: Int?
    @State private var posterProfileFollowing: Int?
    @State private var isLoadingPosterProfile = false
    /// Repost tapped on an on-chain post: choose plain repost vs quote.
    @State private var repostDialogTarget: DraftPost?
    @State private var quoteComposerTarget: DraftPost?
    @State private var replyText = ""

    struct PostDetailTarget: Identifiable {
        let id: UUID
    }

    /// Left slide-out menu entries - all coming-soon placeholders for now.
    enum SideMenuItem: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case notifications = "Notifications"
        case bookmarks = "Bookmarks"
        case muted = "Muted"
        case blocked = "Blocked"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .profile: return "person.crop.circle"
            case .notifications: return "bell"
            case .bookmarks: return "bookmark"
            case .muted: return "speaker.slash"
            case .blocked: return "hand.raised"
            }
        }
    }

    @State private var showSideMenu = false
    @State private var menuSheet: SideMenuItem?
    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var followStore = KaPostsFollowStore.shared
    @ObservedObject private var moderationStore = KaPostsModerationStore.shared
    @EnvironmentObject private var walletManager: WalletManager
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL

    /// Transient confirmation that an on-chain action landed, with a link to the tx.
    struct ActionToast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let txId: String
    }
    @State private var actionToast: ActionToast?

    /// 5-second undo window for a just-composed post/quote: the optimistic card is already in
    /// the feed, but the on-chain submit is held until the countdown expires. Undo pulls the
    /// card and nothing ever touches the network.
    struct UndoPostToast: Identifiable, Equatable {
        let id = UUID()
        let key: String
        let postId: UUID
        let deadline: Date
        let label: String
    }
    @State private var undoToast: UndoPostToast?
    @ObservedObject private var scheduler = KaPostsActionScheduler.shared

    struct PosterProfileTarget: Identifiable {
        let id = UUID()
        let address: String
        var pubkey: String? = nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            feedLayer
            sideMenuOverlay
        }
        .sheet(item: $menuSheet) { item in
            switch item {
            case .bookmarks:
                bookmarksSheet
            case .muted:
                moderationSheet(kind: .muted)
            case .blocked:
                moderationSheet(kind: .blocked)
            case .profile:
                myProfileSheet
            case .notifications:
                KaPostsNotificationsView()
            }
        }
    }

    private var feedLayer: some View {
        VStack(spacing: 0) {
            feedTabBar
            // Horizontal paging between the three feeds, synced both ways with the top tab bar
            // (tap animates the page across; swipe moves the underline). Page-style TabView is
            // safe here - unlike the chat list, post cells have no row-level horizontal swipe
            // gestures to fight with.
            TabView(selection: $selectedFeed) {
                ForEach(FeedTab.allCases, id: \.self) { tab in
                    feedContent(for: tab)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .overlay(alignment: .bottomTrailing) {
            createPostButton
        }
        .overlay(alignment: .bottom) {
            toastOverlay
        }
        .sheet(isPresented: $showComposer) {
            KaPostComposerView { text in
                schedulePost(text: text)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showComposeFundingSheet) {
            // Zero-balance gate: presented INSTEAD of the post composer (see
            // `createPostButton`) - auto-dismisses once the chatting balance turns positive.
            ZeroBalanceFundingSheetView()
        }
        .sheet(item: $profileTarget) { target in
            posterProfileSheet(for: target)
                .presentationDetents([.large])
        }
        .sheet(item: $detailTarget) { target in
            postDetailSheet(postId: target.id)
        }
        .confirmationDialog(
            "Repost",
            isPresented: Binding(
                get: { repostDialogTarget != nil },
                set: { if !$0 { repostDialogTarget = nil } }
            ),
            presenting: repostDialogTarget
        ) { target in
            if !target.repostedByMe {
                Button("Repost") {
                    // Held for 5s behind the icon countdown - tap it to cancel before submit.
                    scheduler.schedule(key: "repost:\(target.id)") {
                        performRepost(target: target, text: nil, localQuoteId: nil)
                    }
                }
            } else {
                Button("Remove Repost", role: .destructive) {
                    // Same 5s countdown window; the fork's `unquote` counter-action nets the
                    // repost out on the indexer (the chain keeps both transactions).
                    scheduler.schedule(key: "repost:\(target.id)") {
                        performUnrepost(target)
                    }
                }
            }
            Button("Quote Post") {
                quoteComposerTarget = target
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(target.repostedByMe
                 ? "You've reposted this. Remove your repost, or quote it with your own thoughts."
                 : "Share this post as-is, or add your own thoughts.")
        }
        .sheet(item: $engagementTarget) { target in
            KaPostEngagementView(post: target)
        }
        .sheet(item: $quoteComposerTarget) { target in
            KaPostComposerView(
                quotedPost: target,
                quotedDisplayName: posterDisplayName(target.posterAddress),
                quotedAvatarURL: knsService.profileCache[target.posterAddress]?.avatarURL
            ) { text in
                scheduleQuote(target: target, text: text)
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            if let myAddress = WalletManager.shared.currentWallet?.publicAddress {
                followStore.removeIfPresent(myAddress)
            }
            await loadFeed()
            // Cold-start shared-post link: consume whatever arrived before this view existed.
            if let pending = KaPostsDeepLink.pendingPostTxId {
                KaPostsDeepLink.pendingPostTxId = nil
                await openSharedPost(txId: pending)
            }
            if KaPostsDeepLink.pendingOpenNotifications {
                KaPostsDeepLink.pendingOpenNotifications = false
                menuSheet = .notifications
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openKaPost)) { notification in
            if let txId = notification.userInfo?["txId"] as? String {
                KaPostsDeepLink.pendingPostTxId = nil
                Task { await openSharedPost(txId: txId) }
                return
            }
            // Push-tap variants: a pending post id or the Notifications screen.
            if let pending = KaPostsDeepLink.pendingPostTxId {
                KaPostsDeepLink.pendingPostTxId = nil
                Task { await openSharedPost(txId: pending) }
            } else if KaPostsDeepLink.pendingOpenNotifications {
                KaPostsDeepLink.pendingOpenNotifications = false
                menuSheet = .notifications
            }
        }
        .onChange(of: selectedFeed) { _ in
            Task { await loadFeed() }
        }
    }

    // MARK: - Feed tabs (mirrors ChatListView.chatsTopTabBar)


    private var feedTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    Haptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSideMenu = true
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(FeedTab.allCases, id: \.title) { tab in
                    feedTabButton(tab)
                }
            }
            Divider()
        }
    }

    // MARK: - Side menu (left slide-out card)

    @ViewBuilder
    private var sideMenuOverlay: some View {
        if showSideMenu {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSideMenu = false
                    }
                }
                .transition(.opacity)
            sideMenuCard
                .transition(.move(edge: .leading))
                .zIndex(1)
        }
    }

    private var sideMenuCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No card title - the page's bold KaPosts header is still visible behind the
            // drawer, so repeating it here just doubled up.
            ForEach(SideMenuItem.allCases) { item in
                Button {
                    Haptics.impact(.light)
                    // The drawer deliberately stays open behind the sheet - coming back from
                    // Profile/Bookmarks/etc. lands you back on the open menu. Only an explicit
                    // dismissal (tapping the dimmed scrim) closes it.
                    menuSheet = item
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18))
                            .frame(width: 26)
                        Text(item.rawValue)
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        // Liquid Glass on iOS 26+ (the system's real glass material), falling back to the app's
        // established glass-card look (material + hairline + shadow) on older iOS. The glass
        // wraps ONLY the options (background applied before the positioning frame), so the card
        // hugs its content instead of stretching to the bottom.
        .background(drawerGlassBackground)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.leading, 10)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var drawerGlassBackground: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.22), radius: 16, x: 4, y: 0)
        }
    }

    private func feedTabButton(_ tab: FeedTab) -> some View {
        let isSelected = selectedFeed == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedFeed = tab
            }
        } label: {
            VStack(spacing: 8) {
                Text(tab.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(isSelected ? .accentColor : .accentColor.opacity(0.5))
                    .frame(maxWidth: .infinity)
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .padding(.top, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feed content

    @ViewBuilder
    private func feedContent(for tab: FeedTab) -> some View {
        let visiblePosts = posts(for: tab)
        if visiblePosts.isEmpty {
            // Wrapped in a ScrollView purely so pull-to-refresh works on an empty tab too -
            // the common bootstrap case while feeds are sparse.
            ScrollView {
                emptyState(for: tab)
                    .frame(maxWidth: .infinity, minHeight: 460)
            }
            .refreshable { await loadFeed() }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visiblePosts) { post in
                        KaPostCellView(
                            post: post,
                            displayName: posterDisplayName(post.posterAddress),
                            avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                            isFollowing: followStore.isFollowing(post.posterAddress),
                            commentCount: commentCount(of: post),
                            truncatesLongText: true,
                            onComment: { openDetail(post) },
                            onMute: { moderationStore.mute(post.posterAddress) },
                            onBlock: { moderationStore.block(post.posterAddress) },
                            onBookmark: { toggleBookmark(post) },
                            onRetry: { retryPost(post) },
                            onViewEngagement: { engagementTarget = post },
                            onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
                            onOpenProfile: { profileTarget = PosterProfileTarget(address: post.posterAddress, pubkey: post.posterPubkey) },
                            onLike: { toggleLike(post) },
                            onDislike: { toggleDislike(post) },
                            onRepost: { handleRepostTap(post) },
                            onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
                        )
                        .task(id: post.posterAddress) {
                            guard knsService.profileCache[post.posterAddress] == nil,
                                  !post.posterAddress.isEmpty else { return }
                            _ = await knsService.fetchProfile(for: post.posterAddress)
                        }
                        Divider()
                            .padding(.leading, 68)
                    }
                }
            }
            .refreshable { await loadFeed() }
        }
    }

    /// UI-only placeholder logic: your own session posts show in Feed and Following; Popular
    /// sorts them by engagement (likes + reposts + dislikes - all interactions count toward
    /// popularity, matching the intended ranking once wired).
    private func posts(for tab: FeedTab) -> [DraftPost] {
        // Session posts first (newest local compose on top), then remote feed - deduped by
        // remote id once Phase B starts round-tripping our own posts.
        let combined = posts + remotePosts.filter { remote in
            !posts.contains { $0.remoteId != nil && $0.remoteId == remote.remoteId }
        }
        // Muted and blocked authors' content is hidden EVERYWHERE (the difference between the
        // two is interaction rights, which only matters once real wiring lands).
        let visible = combined.filter { !moderationStore.isHidden($0.posterAddress) }
        switch tab {
        case .following:
            // Only posts from accounts you follow - the Follow toggle drives this live.
            return visible.filter { followStore.isFollowing($0.posterAddress) }
        case .feed:
            return visible
        case .popular:
            return visible.sorted { ($0.likes + $0.reposts + $0.dislikes) > ($1.likes + $1.reposts + $1.dislikes) }
        }
    }

    /// A post's comments minus muted/blocked authors - used for both display and counts.
    private func visibleComments(of post: DraftPost) -> [DraftPost] {
        post.comments.filter { !moderationStore.isHidden($0.posterAddress) }
    }

    /// Comment count for a cell: the indexer's reply count until the thread has been opened
    /// and replies actually loaded (locally-added comments can exceed the stale remote count).
    private func commentCount(of post: DraftPost) -> Int {
        max(post.remoteReplyCount, visibleComments(of: post).count)
    }

    private func emptyState(for tab: FeedTab) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: emptyStateIcon(for: tab))
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text(emptyStateTitle(for: tab))
                .font(.headline)
                .foregroundColor(.primary)
            Text(emptyStateBody(for: tab))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyStateIcon(for tab: FeedTab) -> String {
        switch tab {
        case .following: return "person.2"
        case .feed: return "square.and.pencil"
        case .popular: return "flame"
        }
    }

    private func emptyStateTitle(for tab: FeedTab) -> String {
        switch tab {
        case .following: return "Nothing from people you follow"
        case .feed: return "No posts yet"
        case .popular: return "Nothing trending yet"
        }
    }

    private func emptyStateBody(for tab: FeedTab) -> String {
        switch tab {
        case .following: return "Posts from accounts you follow will show up here."
        case .feed: return "Be the first - tap the pencil to write a post."
        case .popular: return "The most liked, reposted and talked-about posts will show up here."
        }
    }

    // MARK: - Create post (mirrors ChatListView.createChatButton)

    private var createPostButton: some View {
        Button {
            Haptics.impact(.light)
            // Zero-balance gate: a confirmed 0 KAS chatting balance can't fund a post
            // transaction, so offer the funding card instead of a composer that would
            // dead-end at submit. Unknown/still-loading balances open the composer normally.
            if walletManager.hasConfirmedZeroChattingBalance {
                showComposeFundingSheet = true
            } else {
                showComposer = true
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 56, height: 56)
                .background(
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                )
        }
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }

    /// Fetches the selected feed from the K indexer and maps it into the UI model. Identity
    /// stays KNS-side: only the pubkey->address bridge is taken from K, names/avatars resolve
    /// through the app's normal chain. Errors surface inline; the local session posts always
    /// remain visible regardless.
    private func loadFeed() async {
        guard !isLoadingFeed else { return }
        isLoadingFeed = true
        feedError = nil
        defer { isLoadingFeed = false }
        do {
            let result: [KaPostsAPIClient.KPost]
            switch selectedFeed {
            case .following:
                result = try await KaPostsAPIClient.shared.fetchFollowingFeed().posts
            case .feed, .popular:
                result = try await KaPostsAPIClient.shared.fetchGlobalFeed().posts
            }
            remotePosts = result.compactMap { Self.mapRemotePost($0) }
            // Batch-refresh poster identities through KNSService's debounced/backed-off path
            // (bounded concurrency, per-address debounce). Besides warming names/avatars ahead
            // of row mounts, this refreshes stale cached entries - including old permanently
            // cached failed lookups - which per-row tasks never retouch because they only fetch
            // when the cache has no entry at all.
            let posterAddresses = Array(Set(remotePosts.map(\.posterAddress).filter { !$0.isEmpty }))
            if !posterAddresses.isEmpty {
                Task { await knsService.refreshProfilesIfNeeded(for: posterAddresses) }
            }
        } catch {
            feedError = error.localizedDescription
            AppLog.log("[KaPosts] Feed fetch failed: %@", error.localizedDescription)
        }
    }

    /// K wire post -> UI model. Content arrives base64-decoded with the KaChat marker stripped;
    /// counts map 1:1 (K "reposts" are quotes - quotesCount is the live counter).
    /// Deterministic UUID from a txid so re-fetches keep row identity stable.
    static func stableId(forTxId txId: String) -> UUID {
        let digest = SHA256.hash(data: Data(txId.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func mapRemotePost(_ post: KaPostsAPIClient.KPost) -> DraftPost? {
        guard let content = post.decodedContent,
              let address = KaPostsAPIClient.kaspaAddress(fromPubkey: post.userPublicKey) else { return nil }
        var mapped = DraftPost(
            text: KaPostsAPIClient.stripMarker(content),
            timestamp: Date(timeIntervalSince1970: TimeInterval(post.timestamp) / 1000),
            posterAddress: address
        )
        mapped.id = Self.stableId(forTxId: post.id)
        mapped.parentRemoteId = post.parentPostId
        mapped.remoteId = post.id
        mapped.posterPubkey = post.userPublicKey
        mapped.likes = post.upVotesCount ?? 0
        mapped.remoteReplyCount = post.repliesCount ?? 0
        mapped.dislikes = post.downVotesCount ?? 0
        mapped.reposts = post.quotesCount ?? 0
        mapped.likedByMe = post.isUpvoted ?? false
        mapped.dislikedByMe = post.isDownvoted ?? false
        if let quote = post.quote,
           let quotedText = quote.decodedMessage,
           let quotedPubkey = quote.referencedSenderPubkey,
           let quotedAddress = KaPostsAPIClient.kaspaAddress(fromPubkey: quotedPubkey) {
            mapped.quoted = DraftPost.QuotedRef(
                remoteId: quote.referencedContentId,
                text: KaPostsAPIClient.stripMarker(quotedText),
                posterAddress: quotedAddress,
                timestamp: nil
            )
        }
        return mapped
    }

    /// Poster name resolution, in priority order: the alias YOU set for a saved contact wins,
    /// else the poster's KNS primary domain, else a shortened Kaspa address.
    private func posterDisplayName(_ address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        // .kas is stripped from EVERY source, not just raw KNS lookups - contact aliases are
        // frequently auto-set to the KNS primary ("name.kas") and leaked the suffix through the
        // alias-wins branch.
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.strippingKasSuffix(alias)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    /// "alice.kas" reads better as just "alice" - the .kas is implied everywhere inside KaPosts.
    static func strippingKasSuffix(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasSuffix(".kas") ? String(trimmed.dropLast(4)) : trimmed
    }

    // MARK: - Local-only engagement toggles (pure UI state, no wiring)

    /// Applies a mutation to a post OR any of its comments, found by id - one code path for
    /// engagement on both levels of the thread.
    /// Mutates a post ANYWHERE in the trees - top level or nested comments at any depth
    /// (comment threads can nest now).
    private func mutatePost(id: UUID, _ transform: (inout DraftPost) -> Void) {
        func mutate(_ list: inout [DraftPost]) -> Bool {
            for index in list.indices {
                if list[index].id == id {
                    transform(&list[index])
                    return true
                }
                if mutate(&list[index].comments) {
                    return true
                }
            }
            return false
        }
        if mutate(&posts) { return }
        if mutate(&remotePosts) { return }
        if mutate(&posterProfilePosts) { return }
        if mutate(&posterProfileReplies) { return }
        if mutate(&myProfileRemotePosts) { return }
        _ = mutate(&myProfileRemoteReplies)
    }

    /// Recursive lookup mirroring mutatePost's search order.
    private func findPost(id: UUID) -> DraftPost? {
        func search(_ list: [DraftPost]) -> DraftPost? {
            for post in list {
                if post.id == id { return post }
                if let hit = search(post.comments) { return hit }
            }
            return nil
        }
        return search(posts) ?? search(remotePosts) ?? search(posterProfilePosts)
            ?? search(posterProfileReplies) ?? search(myProfileRemotePosts) ?? search(myProfileRemoteReplies)
    }

    /// findPost by the on-chain txid instead of the local UUID, same recursive coverage.
    private func findPost(byRemoteId remoteId: String) -> DraftPost? {
        func search(_ list: [DraftPost]) -> DraftPost? {
            for post in list {
                if post.remoteId == remoteId { return post }
                if let hit = search(post.comments) { return hit }
            }
            return nil
        }
        return search(posts) ?? search(remotePosts) ?? search(posterProfilePosts)
            ?? search(posterProfileReplies) ?? search(myProfileRemotePosts) ?? search(myProfileRemoteReplies)
    }

    /// Bottom toast stack: the post-undo countdown (while a submit is being held) above the
    /// on-chain confirmation capsule.
    private var toastOverlay: some View {
        VStack(spacing: 8) {
            if let undo = undoToast {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let remaining = max(0, Int(ceil(undo.deadline.timeIntervalSince(context.date))))
                        Text("\(undo.label) in \(remaining)s")
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                    }
                    Button {
                        Haptics.impact(.light)
                        undoPendingPost(undo)
                    } label: {
                        Text("Undo")
                            .font(.footnote.weight(.bold))
                            .foregroundColor(.orange)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(toastCapsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let toast = actionToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(toast.message)
                        .font(.footnote.weight(.semibold))
                    Button {
                        if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: toast.txId) {
                            openURL(url)
                        }
                    } label: {
                        Text("View")
                            .font(.footnote.weight(.bold))
                            .foregroundColor(.accentColor)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(toastCapsule)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 84)
    }

    private var toastCapsule: some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
    }

    /// Inserts the optimistic post immediately, then holds the on-chain submit behind the 5s
    /// Undo toast - Undo pulls the card before anything touches the network.
    private func schedulePost(text: String) {
        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        var newPost = DraftPost(text: text, timestamp: Date(), posterAddress: myAddress)
        newPost.posterPubkey = try? KaPostsAPIClient.shared.requesterPubkey()
        newPost.deliveryStatus = .pending
        let localId = newPost.id
        posts.insert(newPost, at: 0)
        let key = "post:\(localId)"
        showUndoToast(key: key, postId: localId, label: "Posting")
        scheduler.schedule(key: key) {
            clearUndoToast(key: key)
            // On-chain publish (Phase B): submit the K post tx; stamp the optimistic local
            // post with the returned txid so it dedupes against the feed once indexed.
            Task {
                do {
                    let txId = try await KaPostsAPIClient.shared.submitPost(text: text)
                    mutatePost(id: localId) {
                        $0.remoteId = txId
                        $0.deliveryStatus = .sent
                    }
                } catch {
                    mutatePost(id: localId) { $0.deliveryStatus = .failed }
                    AppLog.log("[KaPosts] Post submit failed: %@", error.localizedDescription)
                }
            }
        }
    }

    /// Same 5s undo window for quotes: the optimistic quote card is in the feed but the quote
    /// tx (and the target's repost bump) wait for the countdown.
    private func scheduleQuote(target: DraftPost, text: String) {
        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        var quotePost = DraftPost(text: text, timestamp: Date(), posterAddress: myAddress)
        quotePost.posterPubkey = try? KaPostsAPIClient.shared.requesterPubkey()
        quotePost.deliveryStatus = .pending
        quotePost.quoted = DraftPost.QuotedRef(
            remoteId: target.remoteId,
            text: target.text,
            posterAddress: target.posterAddress,
            timestamp: target.timestamp
        )
        let localId = quotePost.id
        posts.insert(quotePost, at: 0)
        let key = "post:\(localId)"
        showUndoToast(key: key, postId: localId, label: "Posting quote")
        scheduler.schedule(key: key) {
            clearUndoToast(key: key)
            performRepost(target: target, text: text, localQuoteId: localId)
        }
    }

    private func showUndoToast(key: String, postId: UUID, label: String) {
        withAnimation(.easeOut(duration: 0.25)) {
            undoToast = UndoPostToast(
                key: key, postId: postId,
                deadline: Date().addingTimeInterval(KaPostsActionScheduler.undoDelay),
                label: label
            )
        }
    }

    private func clearUndoToast(key: String) {
        if undoToast?.key == key {
            withAnimation(.easeIn(duration: 0.25)) { undoToast = nil }
        }
    }

    private func undoPendingPost(_ toast: UndoPostToast) {
        scheduler.cancel(key: toast.key)
        withAnimation(.easeIn(duration: 0.25)) {
            posts.removeAll { $0.id == toast.postId }
            undoToast = nil
        }
    }

    /// Shows the on-chain confirmation toast for ~4s with a tappable explorer link.
    private func showActionToast(_ message: String, txId: String) {
        let toast = ActionToast(message: message, txId: txId)
        withAnimation(.easeOut(duration: 0.25)) { actionToast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if actionToast?.id == toast.id {
                withAnimation(.easeIn(duration: 0.25)) { actionToast = nil }
            }
        }
    }

    /// Both directions are held for 5s behind the in-icon countdown (tap it to cancel):
    /// liking submits an upvote, un-liking submits the fork's `unvote` counter-action.
    private func toggleLike(_ post: DraftPost) {
        if post.likedByMe, post.remoteId == nil {
            performLike(post)   // local-only unlike, instant
            return
        }
        scheduler.schedule(key: "like:\(post.id)") { performLike(post) }
    }

    private func performLike(_ post: DraftPost) {
        if !post.likedByMe, let remoteId = post.remoteId, let author = post.posterPubkey {
            Task {
                do {
                    let txId = try await KaPostsAPIClient.shared.submitVote(postId: remoteId, upvote: true, authorPubkey: author)
                    showActionToast("Like posted to the network", txId: txId)
                } catch { AppLog.log("[KaPosts] Upvote submit failed: %@", error.localizedDescription) }
            }
        } else if post.likedByMe, let remoteId = post.remoteId, let author = post.posterPubkey {
            Task {
                do {
                    let txId = try await KaPostsAPIClient.shared.submitUnvote(postId: remoteId, authorPubkey: author)
                    showActionToast("Like removed on the network", txId: txId)
                } catch { AppLog.log("[KaPosts] Unvote submit failed: %@", error.localizedDescription) }
            }
        }
        mutatePost(id: post.id) { target in
            if target.likedByMe {
                target.likedByMe = false
                target.likes -= 1
            } else {
                target.likedByMe = true
                target.likes += 1
                if target.dislikedByMe {
                    target.dislikedByMe = false
                    target.dislikes -= 1
                }
            }
        }
    }

    /// Same 5s countdown-then-submit as toggleLike, un-dislike included.
    private func toggleDislike(_ post: DraftPost) {
        if post.dislikedByMe, post.remoteId == nil {
            performDislike(post)
            return
        }
        scheduler.schedule(key: "dislike:\(post.id)") { performDislike(post) }
    }

    private func performDislike(_ post: DraftPost) {
        if !post.dislikedByMe, let remoteId = post.remoteId, let author = post.posterPubkey {
            Task {
                do {
                    let txId = try await KaPostsAPIClient.shared.submitVote(postId: remoteId, upvote: false, authorPubkey: author)
                    showActionToast("Dislike posted to the network", txId: txId)
                } catch { AppLog.log("[KaPosts] Downvote submit failed: %@", error.localizedDescription) }
            }
        } else if post.dislikedByMe, let remoteId = post.remoteId, let author = post.posterPubkey {
            Task {
                do {
                    let txId = try await KaPostsAPIClient.shared.submitUnvote(postId: remoteId, authorPubkey: author)
                    showActionToast("Dislike removed on the network", txId: txId)
                } catch { AppLog.log("[KaPosts] Unvote submit failed: %@", error.localizedDescription) }
            }
        }
        mutatePost(id: post.id) { target in
            if target.dislikedByMe {
                target.dislikedByMe = false
                target.dislikes -= 1
            } else {
                target.dislikedByMe = true
                target.dislikes += 1
                if target.likedByMe {
                    target.likedByMe = false
                    target.likes -= 1
                }
            }
        }
    }

    /// Repost tap: on-chain posts offer the Repost/Quote chooser; local unpublished posts keep
    /// the demo-era local toggle.
    private func handleRepostTap(_ post: DraftPost) {
        if post.remoteId != nil, post.posterPubkey != nil {
            repostDialogTarget = post
        } else {
            toggleRepost(post)
        }
    }

    /// K's repost mechanism is the quote action: nil text = plain repost (marker-only message),
    /// text = quote with commentary. Runs AFTER the 5s undo window - the optimistic quote card
    /// (if any) was already inserted by scheduleQuote and is stamped here by id.
    private func performRepost(target: DraftPost, text: String?, localQuoteId: UUID?) {
        guard let contentId = target.remoteId, let author = target.posterPubkey else { return }
        mutatePost(id: target.id) { post in
            if !post.repostedByMe {
                post.repostedByMe = true
                post.reposts += 1
            }
        }
        Task {
            do {
                let txId = try await KaPostsAPIClient.shared.submitQuote(text: text, contentId: contentId, quotedAuthorPubkey: author)
                showActionToast(text?.isEmpty == false ? "Quote posted to the network" : "Repost posted to the network", txId: txId)
                if let localQuoteId {
                    mutatePost(id: localQuoteId) {
                        $0.remoteId = txId
                        $0.deliveryStatus = .sent
                    }
                }
            } catch {
                if let localQuoteId {
                    mutatePost(id: localQuoteId) { $0.deliveryStatus = .failed }
                }
                AppLog.log("[KaPosts] Quote/repost submit failed: %@", error.localizedDescription)
            }
        }
    }

    /// Withdraws our repost of `target` via the fork's unquote counter-action.
    private func performUnrepost(_ target: DraftPost) {
        guard let contentId = target.remoteId else { return }
        mutatePost(id: target.id) { post in
            if post.repostedByMe {
                post.repostedByMe = false
                post.reposts = max(0, post.reposts - 1)
            }
        }
        Task {
            do {
                let txId = try await KaPostsAPIClient.shared.submitUnquote(contentId: contentId)
                showActionToast("Repost removed on the network", txId: txId)
            } catch {
                AppLog.log("[KaPosts] Unquote submit failed: %@", error.localizedDescription)
            }
        }
    }

    private func toggleRepost(_ post: DraftPost) {
        mutatePost(id: post.id) { target in
            target.repostedByMe.toggle()
            target.reposts += target.repostedByMe ? 1 : -1
        }
    }

    /// Recursive parent lookup for retry: who owns this comment, at any nesting depth.
    private func findParent(ofCommentId id: UUID) -> DraftPost? {
        func search(_ list: [DraftPost]) -> DraftPost? {
            for post in list {
                if post.comments.contains(where: { $0.id == id }) { return post }
                if let hit = search(post.comments) { return hit }
            }
            return nil
        }
        return search(posts) ?? search(remotePosts) ?? search(posterProfilePosts)
            ?? search(posterProfileReplies) ?? search(myProfileRemotePosts) ?? search(myProfileRemoteReplies)
    }

    /// Re-submits a failed post or reply (found by id; replies resolve their parent for the
    /// reply payload). Pending while in flight, back to failed on another miss.
    private func retryPost(_ post: DraftPost) {
        mutatePost(id: post.id) { $0.deliveryStatus = .pending }
        Task {
            do {
                let txId: String
                if let parent = findParent(ofCommentId: post.id) {
                    guard let parentRemoteId = parent.remoteId else {
                        throw KaPostsAPIClient.KaPostsAPIError.badResponse
                    }
                    txId = try await KaPostsAPIClient.shared.submitReply(
                        text: post.text, postId: parentRemoteId, parentAuthorPubkey: parent.posterPubkey
                    )
                } else {
                    txId = try await KaPostsAPIClient.shared.submitPost(text: post.text)
                }
                mutatePost(id: post.id) {
                    $0.remoteId = txId
                    $0.deliveryStatus = .sent
                }
            } catch {
                mutatePost(id: post.id) { $0.deliveryStatus = .failed }
                AppLog.log("[KaPosts] Retry failed: %@", error.localizedDescription)
            }
        }
    }

    /// Local follow toggle + on-chain K follow/unfollow when the target's compressed pubkey is
    /// known (it comes from post data; profile-sheet follows without one stay local-only).
    private func toggleFollowSubmitting(address: String, pubkey: String?) {
        guard address != WalletManager.shared.currentWallet?.publicAddress else { return }
        let willFollow = !followStore.isFollowing(address)
        followStore.toggle(address)
        guard let pubkey else { return }
        Task {
            do {
                let txId = try await KaPostsAPIClient.shared.submitFollow(willFollow, followedPubkey: pubkey)
                showActionToast(willFollow ? "Follow posted to the network" : "Unfollow posted to the network", txId: txId)
            }
            catch { AppLog.log("[KaPosts] Follow submit failed: %@", error.localizedDescription) }
        }
    }

    private func toggleBookmark(_ post: DraftPost) {
        mutatePost(id: post.id) { target in
            target.bookmarkedByMe.toggle()
        }
    }

    /// Everything bookmarked, posts and comments alike, newest first - feeds the side menu's
    /// Bookmarks screen.
    private var bookmarkedPosts: [DraftPost] {
        let all = posts + posts.flatMap { $0.comments }
            + remotePosts + remotePosts.flatMap { $0.comments }
        return all.filter { $0.bookmarkedByMe && !moderationStore.isHidden($0.posterAddress) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Shared-link landing: resolve the txid to a loaded post (refreshing the feed once if
    /// needed) and open its comment thread.
    private func openSharedPost(txId: String) async {
        if let post = findPost(byRemoteId: txId) {
            openDetail(post)
            return
        }
        await loadFeed()
        if let post = findPost(byRemoteId: txId) {
            openDetail(post)
            return
        }
        // Notification/deep-link targets are usually YOUR OWN content, which lives outside
        // the feed window - pull own posts+replies from the indexer and look again. (A true
        // get-post endpoint on the fork would make this exact; flagged in the handoff doc.)
        // Replies come from get-replies?user= - the indexer's get-posts never returns them.
        if let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() {
            async let postsFetch = try? KaPostsAPIClient.shared.fetchUserPosts(pubkey: pubkey)
            async let repliesFetch = try? KaPostsAPIClient.shared.fetchUserReplies(pubkey: pubkey)
            if let fetched = await postsFetch {
                myProfileRemotePosts = fetched.posts.compactMap(Self.mapRemotePost)
                    .filter { $0.parentRemoteId == nil }
            }
            if let fetchedReplies = await repliesFetch {
                myProfileRemoteReplies = fetchedReplies.posts.compactMap(Self.mapRemotePost)
            }
        }
        if let post = findPost(byRemoteId: txId) {
            openDetail(post)
        } else {
            showActionToast("Post not found - it may be older than the current feed", txId: txId)
        }
    }

    /// One place for the thread view's cells (root, comments, inline replies) - identical
    /// wiring everywhere; non-root cells navigate deeper on tap.
    private func threadCell(_ item: DraftPost, isRoot: Bool = false) -> KaPostCellView {
        KaPostCellView(
            post: item,
            displayName: posterDisplayName(item.posterAddress),
            avatarURLString: knsService.profileCache[item.posterAddress]?.avatarURL,
            isFollowing: followStore.isFollowing(item.posterAddress),
            commentCount: commentCount(of: item),
            onComment: isRoot ? nil : { openDetail(item) },
            onMute: { moderationStore.mute(item.posterAddress) },
            onBlock: { moderationStore.block(item.posterAddress) },
            onBookmark: { toggleBookmark(item) },
            onRetry: { retryPost(item) },
            onViewEngagement: { engagementTarget = item },
            onFollowToggle: { toggleFollowSubmitting(address: item.posterAddress, pubkey: item.posterPubkey) },
            onOpenProfile: { profileTarget = PosterProfileTarget(address: item.posterAddress, pubkey: item.posterPubkey) },
            onLike: { toggleLike(item) },
            onDislike: { toggleDislike(item) },
            onRepost: { handleRepostTap(item) },
            onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
        )
    }

    /// X-style inline reply chain under a comment: "View N replies" expands the chain in
    /// place with a connector line; tapping a reply dives into its own thread.
    @ViewBuilder
    private func threadRepliesSection(for comment: DraftPost) -> some View {
        let replyCount = commentCount(of: comment)
        if replyCount > 0 {
            if expandedCommentIds.contains(comment.id) {
                HStack(alignment: .top, spacing: 0) {
                    // Connector dropping from the comment's avatar column.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 2)
                        .padding(.leading, 35)
                    VStack(alignment: .leading, spacing: 0) {
                        if visibleComments(of: comment).isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Loading replies...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.leading, 16)
                        } else {
                            ForEach(visibleComments(of: comment)) { reply in
                                threadCell(reply)
                            }
                        }
                    }
                }
                threadToggleButton("Hide replies") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = expandedCommentIds.remove(comment.id)
                    }
                }
            } else {
                threadToggleButton("View \(replyCount) \(replyCount == 1 ? "reply" : "replies")") {
                    expandReplies(for: comment)
                }
            }
        }
    }

    private func threadToggleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 18, height: 2)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            .padding(.leading, 36)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Expands a comment's reply chain inline, fetching its replies from the indexer.
    private func expandReplies(for comment: DraftPost) {
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = expandedCommentIds.insert(comment.id)
        }
        guard let remoteId = comment.remoteId else { return }
        Task {
            guard let replies = try? await KaPostsAPIClient.shared.fetchReplies(postId: remoteId).posts else { return }
            let mapped = replies.compactMap { Self.mapRemotePost($0) }
            mutatePost(id: comment.id) { target in
                let localOnly = target.comments.filter { $0.remoteId == nil }
                target.comments = mapped + localOnly
            }
        }
    }

    private func openDetail(_ post: DraftPost) {
        replyText = ""
        detailTarget = PostDetailTarget(id: post.id)
        // Remote post: pull its real reply thread from the indexer into the comments array.
        if let remoteId = post.remoteId {
            Task {
                guard let replies = try? await KaPostsAPIClient.shared.fetchReplies(postId: remoteId).posts else { return }
                let mapped = replies.compactMap { Self.mapRemotePost($0) }
                mutatePost(id: post.id) { target in
                    // Keep any local (session) replies layered after the fetched thread.
                    let localOnly = target.comments.filter { $0.remoteId == nil }
                    target.comments = mapped + localOnly
                }
            }
        }
    }

    // MARK: - My profile (side menu, X-style)

    /// X-style profile: KNS banner across the top, avatar overlapping it, name, following/followers
    /// counts, then the feed of your own posts. Followers is a placeholder 0 until follows are
    /// wired on-chain; Following is the live local follow count.
    private var myProfileSheet: some View {
        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        let myInfo = knsService.profileCache[myAddress]
        // Indexer-fetched history first, then local session posts that haven't been indexed
        // yet (unstamped or too fresh), newest first.
        let remoteIds = Set(myProfileRemotePosts.compactMap(\.remoteId))
        let localOnly = posts.filter { post in
            post.posterAddress == myAddress
                && (post.remoteId == nil || !remoteIds.contains(post.remoteId!))
        }
        let myPosts = (myProfileRemotePosts + localOnly).sorted { $0.timestamp > $1.timestamp }
        return NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Banner (KNS profile banner when set, subtle gradient fallback).
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let bannerURL = myInfo?.profile?.bannerUrl,
                               let url = URL(string: bannerURL) {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        bannerFallback
                                    }
                                }
                            } else {
                                bannerFallback
                            }
                        }
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }

                    // Avatar overlapping the banner, X-style.
                    KNSAvatarView(
                        avatarURLString: myInfo?.avatarURL,
                        fallbackText: posterDisplayName(myAddress),
                        size: 76
                    )
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
                    .padding(.leading, 16)
                    .padding(.top, -38)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(posterDisplayName(myAddress))
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                        HStack(spacing: 16) {
                            Button {
                                profileFollowListKind = .following
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(followStore.following.count)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundColor(.primary)
                                    Text("Following")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                profileFollowListKind = .followers
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(myFollowersCount ?? 0)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundColor(.primary)
                                    Text("Followers")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                    profileFeedTabBar(selection: $myProfileFeedTab)

                    let myFeedItems = myProfileFeedTab == .posts ? myPosts : myProfileRemoteReplies
                    if myFeedItems.isEmpty, isLoadingMyProfilePosts {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if myFeedItems.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: myProfileFeedTab == .posts ? "square.and.pencil" : "bubble.left")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text(myProfileFeedTab == .posts ? "No posts yet" : "No replies yet")
                                .font(.headline)
                            Text(myProfileFeedTab == .posts
                                 ? "Your posts will show up here."
                                 : "Replies you post will show up here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(myFeedItems) { post in
                            KaPostCellView(
                                post: post,
                                displayName: posterDisplayName(post.posterAddress),
                                avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                                isFollowing: followStore.isFollowing(post.posterAddress),
                                commentCount: commentCount(of: post),
                                onComment: nil,
                                onMute: { moderationStore.mute(post.posterAddress) },
                                onBlock: { moderationStore.block(post.posterAddress) },
                                onBookmark: { toggleBookmark(post) },
                                onRetry: { retryPost(post) },
                                onViewEngagement: { engagementTarget = post },
                                onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
                                onOpenProfile: {},
                                onLike: { toggleLike(post) },
                                onDislike: { toggleDislike(post) },
                                onRepost: { handleRepostTap(post) },
                                onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
                            )
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            .simultaneousGesture(profileFeedSwipe(selection: $myProfileFeedTab))
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { menuSheet = nil }
                }
            }
            .task(id: myAddress) {
                guard knsService.profileCache[myAddress] == nil, !myAddress.isEmpty else { return }
                _ = await knsService.fetchProfile(for: myAddress)
            }
            .task {
                guard let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() else { return }
                isLoadingMyProfilePosts = myProfileRemotePosts.isEmpty
                async let detailsFetch = try? KaPostsAPIClient.shared.fetchUserDetails(pubkey: pubkey)
                async let postsFetch = try? KaPostsAPIClient.shared.fetchUserPosts(pubkey: pubkey)
                async let repliesFetch = try? KaPostsAPIClient.shared.fetchUserReplies(pubkey: pubkey)
                if let details = await detailsFetch {
                    // Never count yourself as your own follower. followedUser here means
                    // "requester follows user" - with both being us, true = a stale on-chain
                    // self-follow from before the no-self-follow rule. Display without it and
                    // submit a one-time unfollow to scrub it from the indexer.
                    if details.followedUser == true {
                        myFollowersCount = max(0, (details.followersCount ?? 0) - 1)
                        if !selfUnfollowScrubbed {
                            selfUnfollowScrubbed = true
                            Task {
                                _ = try? await KaPostsAPIClient.shared.submitFollow(false, followedPubkey: pubkey)
                                AppLog.log("[KaPosts] Submitted self-unfollow scrub")
                            }
                        }
                    } else {
                        myFollowersCount = details.followersCount
                    }
                }
                if let fetched = await postsFetch {
                    myProfileRemotePosts = fetched.posts.compactMap(Self.mapRemotePost)
                        .filter { $0.parentRemoteId == nil }
                }
                if let fetchedReplies = await repliesFetch {
                    myProfileRemoteReplies = fetchedReplies.posts.compactMap(Self.mapRemotePost)
                }
                isLoadingMyProfilePosts = false
            }
            .navigationDestination(isPresented: Binding(
                get: { profileFollowListKind != nil },
                set: { if !$0 { profileFollowListKind = nil } }
            )) {
                if let kind = profileFollowListKind {
                    KaPostsFollowListView(
                        kind: kind,
                        localFollowing: followStore.following,
                        onToggleFollow: { address, pubkey in
                            toggleFollowSubmitting(address: address, pubkey: pubkey)
                        }
                    )
                }
            }
        }
    }

    /// Full X-style profile for a tapped poster - banner, avatar, name, Follow +
    /// Send A Chat, live follower/following counts, bio, then their on-chain feed. Mirrors
    /// myProfileSheet; engagement runs through the same handlers (mutatePost covers this feed).
    private func posterProfileSheet(for target: PosterProfileTarget) -> some View {
        let address = target.address
        let info = knsService.profileCache[address]
        return NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        Group {
                            if let bannerURL = info?.profile?.bannerUrl,
                               let url = URL(string: bannerURL) {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        bannerFallback
                                    }
                                }
                            } else {
                                bannerFallback
                            }
                        }
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }

                    KNSAvatarView(
                        avatarURLString: info?.avatarURL,
                        fallbackText: posterDisplayName(address),
                        size: 76,
                        contactAddress: address
                    )
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
                    .padding(.leading, 16)
                    .padding(.top, -38)

                    VStack(alignment: .leading, spacing: 6) {
                        // Name with the actions in a single tidy row: name - Follow - Send A Chat.
                        HStack(spacing: 8) {
                            Text(posterDisplayName(address))
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                                .layoutPriority(1)
                            Spacer(minLength: 8)
                            if address != WalletManager.shared.currentWallet?.publicAddress {
                                Button {
                                    Haptics.impact(.light)
                                    toggleFollowSubmitting(address: address, pubkey: target.pubkey)
                                } label: {
                                    Text(followStore.isFollowing(address) ? "Following" : "Follow")
                                        .font(.caption.weight(.bold))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(followStore.isFollowing(address) ? Color.secondary.opacity(0.35) : Color.accentColor)
                            }
                            Button {
                                Haptics.impact(.light)
                                startChat(with: address)
                            } label: {
                                Label("Send A Chat", systemImage: "bubble.left.and.bubble.right")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.accentColor)
                        }
                        HStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Text("\(posterProfileFollowing ?? 0)")
                                    .font(.subheadline.weight(.bold))
                                Text("Following")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("\(posterProfileFollowers ?? 0)")
                                    .font(.subheadline.weight(.bold))
                                Text("Followers")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        if let bio = info?.profile?.bio,
                           !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(bio)
                                .font(.subheadline)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                    Divider()

                    profileFeedTabBar(selection: $posterProfileFeedTab)

                    let posterFeedItems = posterProfileFeedTab == .posts ? posterProfilePosts : posterProfileReplies
                    if posterFeedItems.isEmpty, isLoadingPosterProfile {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if posterFeedItems.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: posterProfileFeedTab == .posts ? "square.and.pencil" : "bubble.left")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text(posterProfileFeedTab == .posts ? "No posts yet" : "No replies yet")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(posterFeedItems) { post in
                            KaPostCellView(
                                post: post,
                                displayName: posterDisplayName(post.posterAddress),
                                avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                                isFollowing: followStore.isFollowing(post.posterAddress),
                                commentCount: commentCount(of: post),
                                onComment: nil,
                                onMute: { moderationStore.mute(post.posterAddress) },
                                onBlock: { moderationStore.block(post.posterAddress) },
                                onBookmark: { toggleBookmark(post) },
                                onRetry: nil,
                                onViewEngagement: { engagementTarget = post },
                                onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
                                onOpenProfile: {},
                                onLike: { toggleLike(post) },
                                onDislike: { toggleDislike(post) },
                                onRepost: { handleRepostTap(post) },
                                onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
                            )
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
            .simultaneousGesture(profileFeedSwipe(selection: $posterProfileFeedTab))
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { profileTarget = nil }
                }
            }
            .task(id: target.id) {
                posterProfilePosts = []
                posterProfileReplies = []
                posterProfileFeedTab = .posts
                posterProfileFollowers = nil
                posterProfileFollowing = nil
                if knsService.profileCache[address] == nil {
                    _ = await knsService.fetchProfile(for: address)
                }
                guard let pubkey = target.pubkey else { return }
                isLoadingPosterProfile = true
                async let detailsFetch = try? KaPostsAPIClient.shared.fetchUserDetails(pubkey: pubkey)
                async let postsFetch = try? KaPostsAPIClient.shared.fetchUserPosts(pubkey: pubkey)
                async let repliesFetch = try? KaPostsAPIClient.shared.fetchUserReplies(pubkey: pubkey)
                if let details = await detailsFetch {
                    posterProfileFollowers = details.followersCount
                    posterProfileFollowing = details.followingCount
                }
                if let fetched = await postsFetch {
                    posterProfilePosts = fetched.posts.compactMap(Self.mapRemotePost)
                        .filter { $0.parentRemoteId == nil }
                }
                if let fetchedReplies = await repliesFetch {
                    posterProfileReplies = fetchedReplies.posts.compactMap(Self.mapRemotePost)
                }
                isLoadingPosterProfile = false
            }
        }
    }

    /// Jumps into (or creates) the 1:1 chat with this poster: ensures a contact exists
    /// (silently auto-added if new), ensures the conversation exists, then routes through the
    /// standard .openChat navigation. Slight delay so the profile sheet finishes dismissing.
    private func startChat(with address: String) {
        let contact: Contact?
        if let existing = ContactsManager.shared.getContact(byAddress: address) {
            contact = existing
        } else {
            contact = try? ContactsManager.shared.addContact(address: address, alias: "", isAutoAdded: true)
        }
        guard let contact else { return }
        _ = ChatService.shared.getOrCreateConversation(for: contact)
        profileTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(
                name: .openChat,
                object: nil,
                userInfo: ["contactAddress": contact.address]
            )
        }
    }

    /// Underline tab bar for profile feeds (Posts | Replies), matching the app's other tab
    /// bars; swiping the sheet content switches too (profileFeedSwipe).
    private func profileFeedTabBar(selection: Binding<ProfileFeedTab>) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ProfileFeedTab.allCases, id: \.self) { tab in
                    Button {
                        Haptics.impact(.light)
                        withAnimation(.easeInOut(duration: 0.2)) { selection.wrappedValue = tab }
                    } label: {
                        VStack(spacing: 8) {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(selection.wrappedValue == tab ? .accentColor : .accentColor.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 10)
                            Rectangle()
                                .fill(selection.wrappedValue == tab ? Color.accentColor : Color.clear)
                                .frame(height: 2.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
        }
    }

    private func profileFeedSwipe(selection: Binding<ProfileFeedTab>) -> some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > 50, abs(dx) > abs(value.translation.height) * 1.5 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    if dx < 0, selection.wrappedValue == .posts {
                        selection.wrappedValue = .replies
                    } else if dx > 0, selection.wrappedValue == .replies {
                        selection.wrappedValue = .posts
                    }
                }
            }
    }

    private var bannerFallback: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.15)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Muted / Blocked (side menu)

    enum ModerationKind {
        case muted
        case blocked

        var title: String { self == .muted ? "Muted" : "Blocked" }
        var emptyIcon: String { self == .muted ? "speaker.slash" : "hand.raised" }
        var emptyText: String {
            self == .muted
                ? "Accounts you mute disappear from your feeds but can still interact with you."
                : "Blocked accounts are removed everywhere and can't interact with you."
        }
        var actionLabel: String { self == .muted ? "Unmute" : "Unblock" }
    }

    private func moderationSheet(kind: ModerationKind) -> some View {
        let addresses = (kind == .muted ? moderationStore.muted : moderationStore.blocked).sorted()
        return NavigationStack {
            Group {
                if addresses.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: kind.emptyIcon)
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No \(kind.title.lowercased()) accounts")
                            .font(.headline)
                        Text(kind.emptyText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(addresses, id: \.self) { address in
                            HStack(spacing: 12) {
                                KNSAvatarView(
                                    avatarURLString: knsService.profileCache[address]?.avatarURL,
                                    fallbackText: posterDisplayName(address),
                                    size: 40,
                                    contactAddress: address
                                )
                                Text(posterDisplayName(address))
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Button(kind.actionLabel) {
                                    Haptics.impact(.light)
                                    if kind == .muted {
                                        moderationStore.unmute(address)
                                    } else {
                                        moderationStore.unblock(address)
                                    }
                                }
                                .font(.caption.weight(.bold))
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { menuSheet = nil }
                }
            }
        }
    }

    // MARK: - Bookmarks (side menu)

    private var bookmarksSheet: some View {
        NavigationStack {
            Group {
                if bookmarkedPosts.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "bookmark")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No bookmarks yet")
                            .font(.headline)
                        Text("Tap the bookmark on any post to save it here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(bookmarkedPosts) { post in
                                KaPostCellView(
                                    post: post,
                                    displayName: posterDisplayName(post.posterAddress),
                                    avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                                    isFollowing: followStore.isFollowing(post.posterAddress),
                                    commentCount: commentCount(of: post),
                                    onComment: nil,
                                    onMute: { moderationStore.mute(post.posterAddress) },
                                    onBlock: { moderationStore.block(post.posterAddress) },
                                    onBookmark: { toggleBookmark(post) },
                                    onRetry: { retryPost(post) },
                                    onViewEngagement: { engagementTarget = post },
                                    onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
                                    onOpenProfile: {},
                                    onLike: { toggleLike(post) },
                                    onDislike: { toggleDislike(post) },
                                    onRepost: { handleRepostTap(post) },
                                    onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
                                )
                                Divider()
                                    .padding(.leading, 68)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { menuSheet = nil }
                }
            }
        }
    }

    // MARK: - Post detail (X-style thread: post on top, comments below, reply bar at bottom)

    @ViewBuilder
    private func postDetailSheet(postId: UUID) -> some View {
        NavigationStack {
            if let post = findPost(id: postId) {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // X-style upward context: when this thread's root is itself a
                            // reply, link back to what it replies to.
                            if let parent = findParent(ofCommentId: post.id) {
                                Button {
                                    openDetail(parent)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.turn.up.left")
                                            .font(.caption2.weight(.semibold))
                                        Text("Replying to \(posterDisplayName(parent.posterAddress))")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            threadCell(post, isRoot: true)
                            Divider()

                            HStack {
                                Text(visibleComments(of: post).isEmpty ? "Comments" : "Comments (\(visibleComments(of: post).count))")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                            if visibleComments(of: post).isEmpty {
                                Text("No comments yet - be the first to reply.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 20)
                            } else {
                                ForEach(visibleComments(of: post)) { comment in
                                    threadCell(comment)
                                    threadRepliesSection(for: comment)
                                    Divider()
                                        .padding(.leading, 68)
                                }
                            }
                        }
                    }
                    Divider()
                    // X's "Post your reply" bar - text only, same rule as posts.
                    HStack(spacing: 10) {
                        TextField("Post your reply", text: $replyText, axis: .vertical)
                            .onChange(of: replyText) { newValue in
                                if newValue.count > KaPostsView.postCharacterLimit {
                                    replyText = String(newValue.prefix(KaPostsView.postCharacterLimit))
                                }
                            }
                            .lineLimit(1...4)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        KaPostCharacterMeter(count: replyText.count)
                        Button {
                            let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            Haptics.impact(.light)
                            let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
                            var reply = DraftPost(text: trimmed, timestamp: Date(), posterAddress: myAddress)
                            reply.posterPubkey = try? KaPostsAPIClient.shared.requesterPubkey()
                            let isRemoteParent = post.remoteId != nil
                            reply.deliveryStatus = isRemoteParent ? .pending : .sent
                            let localReplyId = reply.id
                            mutatePost(id: postId) { target in
                                target.comments.append(reply)
                            }
                            replyText = ""
                            // On-chain reply when the parent post lives on K.
                            if let parentRemoteId = post.remoteId {
                                let parentAuthor = post.posterPubkey
                                Task {
                                    do {
                                        let txId = try await KaPostsAPIClient.shared.submitReply(
                                            text: trimmed, postId: parentRemoteId, parentAuthorPubkey: parentAuthor
                                        )
                                        mutatePost(id: localReplyId) {
                                            $0.remoteId = txId
                                            $0.deliveryStatus = .sent
                                        }
                                    } catch {
                                        mutatePost(id: localReplyId) { $0.deliveryStatus = .failed }
                                        AppLog.log("[KaPosts] Reply submit failed: %@", error.localizedDescription)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Zero-balance gate: with a confirmed 0 KAS chatting balance the reply
                    // bar dims and any tap on it presents the shared funding card instead of
                    // focusing the composer (reading the thread stays fully usable). The
                    // overlay swallows the tap before the TextField/send button can react.
                    .grayscale(walletManager.hasConfirmedZeroChattingBalance ? 1 : 0)
                    .opacity(walletManager.hasConfirmedZeroChattingBalance ? 0.45 : 1)
                    .overlay {
                        if walletManager.hasConfirmedZeroChattingBalance {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    Haptics.impact(.light)
                                    showReplyFundingSheet = true
                                }
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: walletManager.hasConfirmedZeroChattingBalance)
                }
                .navigationTitle("Post")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showReplyFundingSheet) {
                    // Nested sheet on the thread sheet's own content - MainTabView's gift
                    // listener can't present while this detail sheet is up, so the funding
                    // card (and its Claim Gift flow) presents from in here instead.
                    ZeroBalanceFundingSheetView()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { detailTarget = nil }
                    }
                }
            }
        }
    }
}

// MARK: - Post cell

private struct KaPostCellView: View {
    let post: KaPostsView.DraftPost
    let displayName: String
    let avatarURLString: String?
    let isFollowing: Bool
    let commentCount: Int
    /// Feed cells truncate very long posts behind "Show more" (which opens the full thread view);
    /// detail/comment/bookmark cells show everything.
    var truncatesLongText: Bool = false
    /// nil hides the comment affordance entirely (comment cells - no nested threads).
    let onComment: (() -> Void)?
    let onMute: () -> Void
    let onBlock: () -> Void
    let onBookmark: () -> Void
    var onRetry: (() -> Void)? = nil
    var onViewEngagement: (() -> Void)? = nil
    let onFollowToggle: () -> Void
    let onOpenProfile: () -> Void
    let onLike: () -> Void
    let onDislike: () -> Void
    let onRepost: () -> Void
    /// Tapping the quoted-post embed opens that post's own thread (comments and all).
    var onOpenQuoted: ((String) -> Void)? = nil

    /// Long enough that the feed should fold it behind "Show more" (X-style ~280-char threshold,
    /// or a wall of newlines).
    private var isLongPost: Bool {
        post.text.count > 280 || post.text.filter { $0 == "\n" }.count >= 8
    }

    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL
    @ObservedObject private var scheduler = KaPostsActionScheduler.shared
    @ObservedObject private var knsService = KNSService.shared

    /// Your own post: no follow affordance (you can't follow yourself).
    private var isOwnPost: Bool {
        post.posterAddress == WalletManager.shared.currentWallet?.publicAddress
    }

    /// The sent-checkmark auto-hides 60s after the post's timestamp (mirrors the reaction
    /// checkmark's timed window); pending/failed always show.
    @State private var sentCheckExpired = false

    /// URL tapped in the post text - drives the Copy / Open option menu.
    @State private var tappedLinkURL: URL?

    // Kaspa-logo like burst: appears over the heart, spins, then dissolves into the liked state.
    @State private var burstVisible = false
    @State private var burstScale: CGFloat = 0.2
    @State private var burstRotation: Double = 0
    @State private var burstOpacity: Double = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // KNS avatar (falls back to initials) - tapping it opens the poster's profile.
            Button(action: onOpenProfile) {
                KNSAvatarView(
                    avatarURLString: avatarURLString,
                    fallbackText: displayName,
                    size: 40,
                    contactAddress: post.posterAddress
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    Text(relativeTime(post.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // Inline follow toggle: Follow -> Following -> Follow. Hidden on your own
                    // posts - you can't follow yourself.
                    if !isOwnPost {
                        Button {
                            Haptics.impact(.light)
                            onFollowToggle()
                        } label: {
                            Text(isFollowing ? "Following" : "Follow")
                                .font(.caption.weight(.bold))
                                .foregroundColor(isFollowing ? .secondary : .accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    // X-style overflow menu. Mute: their content disappears everywhere but they
                    // can still interact with you. Block: content gone AND they can't interact
                    // (the interaction half becomes real once wiring lands).
                    Menu {
                        // Post Activity works for EVERYONE's posts now (the KaChat indexer
                        // fork serves get-post-engagement); the post's own explorer link lives
                        // inside that screen.
                        if post.remoteId != nil, let onViewEngagement {
                            Button {
                                onViewEngagement()
                            } label: {
                                Label("View Post in Explorer", systemImage: "globe")
                            }
                        }
                        if !isOwnPost {
                            Button {
                                onMute()
                            } label: {
                                Label("Mute \(displayName)", systemImage: "speaker.slash")
                            }
                            Button(role: .destructive) {
                                onBlock()
                            } label: {
                                Label("Block \(displayName)", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 30, height: 24)
                            .contentShape(Rectangle())
                    }
                }

                // Text-only posts, but URLs are TAPPABLE: tapping a link opens a Copy/Open
                // option menu (never auto-opens - OpenURLAction intercepts). No previews, no
                // photos, no markdown - just detected links styled accent+underline.
                Text(Self.linkified(post.text))
                    .font(.body)
                    .foregroundColor(.primary)
                    .tint(.accentColor)
                    .environment(\.openURL, OpenURLAction { url in
                        tappedLinkURL = url
                        return .handled
                    })
                    .lineLimit(truncatesLongText && isLongPost ? 8 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .confirmationDialog(
                        tappedLinkURL?.absoluteString ?? "",
                        isPresented: Binding(
                            get: { tappedLinkURL != nil },
                            set: { if !$0 { tappedLinkURL = nil } }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button("Open Link") {
                            if let url = tappedLinkURL {
                                openURL(url)
                            }
                        }
                        Button("Copy Link") {
                            if let url = tappedLinkURL {
                                UIPasteboard.general.string = url.absoluteString
                                Haptics.success()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                if truncatesLongText && isLongPost {
                    Button {
                        onComment?()
                    } label: {
                        Text("Show more")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                // X-style quote embed: the quoted post in a bordered mini card under the
                // text - tappable through to the quoted post's own thread.
                if let quoted = post.quoted {
                    if let onOpenQuoted, let quotedId = quoted.remoteId {
                        Button {
                            onOpenQuoted(quotedId)
                        } label: {
                            quotedEmbedCard(quoted)
                        }
                        .buttonStyle(.plain)
                    } else {
                        quotedEmbedCard(quoted)
                    }
                }

                HStack(spacing: 18) {
                    if let onComment {
                        engagementButton(
                            icon: "bubble.left",
                            count: commentCount,
                            tint: .secondary,
                            action: onComment
                        )
                    }
                    likeButton
                    if let deadline = scheduler.deadlines["dislike:\(post.id)"] {
                        countdownButton(key: "dislike:\(post.id)", deadline: deadline)
                    } else {
                        engagementButton(
                            icon: post.dislikedByMe ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                            count: post.dislikes,
                            tint: post.dislikedByMe ? .orange : .secondary,
                            action: onDislike
                        )
                    }
                    if let deadline = scheduler.deadlines["repost:\(post.id)"] {
                        countdownButton(key: "repost:\(post.id)", deadline: deadline)
                    } else {
                        engagementButton(
                            icon: "arrow.2.squarepath",
                            count: post.reposts,
                            tint: post.repostedByMe ? .accentColor : .secondary,
                            action: onRepost
                        )
                    }
                    // Bookmark sits with the other actions (no inline count - saved posts live in
                    // the side menu's Bookmarks screen).
                    engagementButton(
                        icon: post.bookmarkedByMe ? "bookmark.fill" : "bookmark",
                        count: 0,
                        tint: post.bookmarkedByMe ? .accentColor : .secondary,
                        action: onBookmark
                    )
                    // Share: a kachat:// link that drops other KaChat users straight into this
                    // post's comment thread, plus an explorer link for everyone else. Only for
                    // posts that exist on the network.
                    if let remoteId = post.remoteId {
                        ShareLink(item: shareText(remoteId: remoteId)) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    // Bottom-right: on-chain delivery state, mirroring chat bubbles - green check
                    // once the K transaction is on the network, spinner while submitting, red
                    // Retry when it didn't go through.
                    switch post.deliveryStatus {
                    case .sent:
                        if post.remoteId != nil, !sentCheckExpired,
                           Date().timeIntervalSince(post.timestamp) < 60 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                                .task(id: post.id) {
                                    let remaining = 60 - Date().timeIntervalSince(post.timestamp)
                                    if remaining > 0 {
                                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                                    }
                                    withAnimation(.easeOut(duration: 0.3)) { sentCheckExpired = true }
                                }
                        }
                    case .pending:
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.secondary)
                    case .failed:
                        Button {
                            Haptics.impact(.light)
                            onRetry?()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                Text("Retry")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // Tap anywhere on the card (outside a button) to open the post's comment thread.
        .onTapGesture {
            onComment?()
        }
        // The Kaspa-logo burst plays when the like actually lands - i.e. after the 5s
        // countdown fires, not on the tap that armed it.
        .onChange(of: post.likedByMe) { liked in
            if liked { runLikeBurst() }
        }
    }

    private var likeButton: some View {
        if let deadline = scheduler.deadlines["like:\(post.id)"] {
            return AnyView(countdownButton(key: "like:\(post.id)", deadline: deadline))
        }
        return AnyView(Button {
            Haptics.impact(.light)
            onLike()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: post.likedByMe ? "heart.fill" : "heart")
                    .font(.subheadline)
                    // The heart ducks out while the logo spins, then pops back in liked.
                    .opacity(burstVisible ? 0 : 1)
                    .overlay {
                        if burstVisible {
                            Image("KaspaLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)
                                .scaleEffect(burstScale)
                                .rotationEffect(.degrees(burstRotation))
                                .opacity(burstOpacity)
                                .allowsHitTesting(false)
                        }
                    }
                if post.likes > 0 {
                    Text("\(post.likes)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .fixedSize()
            .foregroundColor(post.likedByMe ? .red : .secondary)
        }
        .buttonStyle(.plain))
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Post text with detected URLs carrying tappable link attributes (accent + underline);
    /// everything else stays plain.
    static func linkified(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = linkDetector else { return attributed }
        let nsText = text as NSString
        for match in detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text) else { continue }
            // Offset-mapped (not range(of:)) so repeated identical URLs each get linked.
            let startOffset = text.distance(from: text.startIndex, to: stringRange.lowerBound)
            let length = text.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
            let start = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
            let end = attributed.index(start, offsetByCharacters: length)
            attributed[start..<end].link = url
            attributed[start..<end].underlineStyle = .single
        }
        return attributed
    }

    private func quotedDisplayName(_ address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(alias)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    private func quotedEmbedCard(_ quoted: KaPostsView.DraftPost.QuotedRef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KNSAvatarView(
                    avatarURLString: knsService.profileCache[quoted.posterAddress]?.avatarURL,
                    fallbackText: quotedDisplayName(quoted.posterAddress),
                    size: 20,
                    contactAddress: quoted.posterAddress
                )
                Text(quotedDisplayName(quoted.posterAddress))
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                if let timestamp = quoted.timestamp {
                    Text(relativeTime(timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(verbatim: quoted.text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .padding(.top, 2)
        .task(id: quoted.posterAddress) {
            guard !quoted.posterAddress.isEmpty,
                  knsService.profileCache[quoted.posterAddress] == nil else { return }
            _ = await knsService.fetchProfile(for: quoted.posterAddress)
        }
    }

    /// The in-icon 5s countdown: the action hasn't gone to the network yet - tap to cancel it.
    private func countdownButton(key: String, deadline: Date) -> some View {
        Button {
            Haptics.impact(.light)
            KaPostsActionScheduler.shared.cancel(key: key)
        } label: {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let remaining = max(1, Int(ceil(deadline.timeIntervalSince(context.date))))
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption2.weight(.bold))
                    Text("\(remaining)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
    }

    /// Manual keyframes (iOS 16-safe): pop in with a spring, one full spin, then dissolve back
    /// down to the (now red) heart.
    private func runLikeBurst() {
        burstVisible = true
        burstScale = 0.2
        burstRotation = 0
        burstOpacity = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            burstScale = 1.5
            burstOpacity = 1
        }
        withAnimation(.easeInOut(duration: 0.55)) {
            burstRotation = 360
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeIn(duration: 0.18)) {
                burstOpacity = 0
                burstScale = 0.5
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            burstVisible = false
        }
    }

    private func shareText(remoteId: String) -> String {
        let snippet = String(post.text.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        let ellipsis = post.text.count > 60 ? "..." : ""
        return "\"\(snippet)\(ellipsis)\"\n\nOpen in KaChat: kachat://kapost/\(remoteId)"
    }

    private func engagementButton(icon: String, count: Int, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.subheadline)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .fixedSize()
            .foregroundColor(tint)
        }
        .buttonStyle(.plain)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Composer

/// Text-only post composer. Deliberately NO attachment affordances (no photo picker, no link
/// tools) - a KaPost is plain text, full stop.
private struct KaPostComposerView: View {
    // When quoting: the post being quoted renders X-style below the editor - you write above it.
    var quotedPost: KaPostsView.DraftPost? = nil
    var quotedDisplayName: String = ""
    var quotedAvatarURL: String? = nil
    let onPost: (String) -> Void

    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .focused($isFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(quotedPost == nil ? "What's happening on Kaspa?" : "Add a comment")
                                .font(.body)
                                .foregroundColor(.secondary.opacity(0.6))
                                .padding(.horizontal, 17)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
                if let quotedPost {
                    quotedPostCard(quotedPost)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
                Divider()
                HStack {
                    characterMeter
                    Spacer()
                    // Live network-fee estimate while typing (Settings > Show Fee Estimate),
                    // matching the chat composer's behavior.
                    if settingsViewModel.settings.showFeeEstimate, !trimmed.isEmpty,
                       let fee = KaPostsAPIClient.estimatePostFee(text: trimmed) {
                        Text("Est. fee: \(String(format: "%.8f", Double(fee) / 100_000_000.0)) KAS")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle(quotedPost == nil ? "New Post" : "Quote Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        onPost(trimmed)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { isFocused = true }
            .onChange(of: text) { newValue in
                // Hard cap at the limit, X-style.
                if newValue.count > KaPostsView.postCharacterLimit {
                    text = String(newValue.prefix(KaPostsView.postCharacterLimit))
                }
            }
        }
    }

    private var characterMeter: some View {
        KaPostCharacterMeter(count: text.count)
    }

    /// X-style embedded preview of the post being quoted.
    private func quotedPostCard(_ quoted: KaPostsView.DraftPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KNSAvatarView(
                    avatarURLString: quotedAvatarURL,
                    fallbackText: quotedDisplayName,
                    size: 22,
                    contactAddress: quoted.posterAddress
                )
                Text(quotedDisplayName)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text(quoted.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            Text(verbatim: quoted.text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}


// MARK: - Action scheduler (5s undo window)

/// Holds each on-chain action (like/dislike/repost/post) for a short countdown before it
/// actually submits. Keyed "kind:postId"; the UI shows a countdown in the icon's place (or an
/// Undo toast for posts) and cancelling the key drops the action entirely - nothing has touched
/// the network yet. Singleton so countdowns survive cell recycling and screen switches.
@MainActor
final class KaPostsActionScheduler: ObservableObject {
    static let shared = KaPostsActionScheduler()
    static let undoDelay: TimeInterval = 5

    /// Fire deadline per pending key - cells read this to render the countdown.
    @Published private(set) var deadlines: [String: Date] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func schedule(key: String, action: @escaping @MainActor () -> Void) {
        cancel(key: key)
        deadlines[key] = Date().addingTimeInterval(Self.undoDelay)
        tasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.undoDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.deadlines[key] = nil
            self?.tasks[key] = nil
            action()
        }
    }

    func cancel(key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
        deadlines[key] = nil
    }
}

// MARK: - Follow store (local-only persistence; on-chain follow wiring comes later)

/// Followed poster addresses, persisted locally in UserDefaults. This is deliberately NOT wired
/// to anything on-chain yet - it exists so Follow/Following state survives relaunch and the
/// Following feed has something real to filter on once posts are wired.
@MainActor
final class KaPostsFollowStore: ObservableObject {
    static let shared = KaPostsFollowStore()

    @Published private(set) var following: Set<String> = []

    private let defaultsKey = "kachat_kaposts_following"

    private init() {
        if let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) {
            following = Set(stored)
        }
    }

    func isFollowing(_ address: String) -> Bool {
        following.contains(address)
    }

    func toggle(_ address: String) {
        guard !address.isEmpty,
              address != WalletManager.shared.currentWallet?.publicAddress else { return }
        if following.contains(address) {
            following.remove(address)
        } else {
            following.insert(address)
        }
        UserDefaults.standard.set(Array(following), forKey: defaultsKey)
    }

    /// Scrubs a stale entry (used to drop any old self-follow left from before the
    /// no-self-follow rule).
    func removeIfPresent(_ address: String) {
        guard !address.isEmpty, following.contains(address) else { return }
        following.remove(address)
        UserDefaults.standard.set(Array(following), forKey: defaultsKey)
    }
}

// MARK: - Moderation store (local-only; interaction enforcement lands with wiring)

/// Muted + blocked poster addresses, persisted locally. Both hide the author's content
/// everywhere in KaPosts; the distinction - a muted user can still interact with you, a blocked
/// user cannot - takes effect when real feeds/interactions are wired.
final class KaPostsModerationStore: ObservableObject {
    static let shared = KaPostsModerationStore()

    @Published private(set) var muted: Set<String> = []
    @Published private(set) var blocked: Set<String> = []

    private let mutedKey = "kachat_kaposts_muted"
    private let blockedKey = "kachat_kaposts_blocked"

    private init() {
        muted = Set(UserDefaults.standard.stringArray(forKey: mutedKey) ?? [])
        blocked = Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? [])
    }

    func isHidden(_ address: String) -> Bool {
        muted.contains(address) || blocked.contains(address)
    }

    func mute(_ address: String) {
        guard !address.isEmpty else { return }
        muted.insert(address)
        persist()
    }

    func unmute(_ address: String) {
        muted.remove(address)
        persist()
    }

    func block(_ address: String) {
        guard !address.isEmpty else { return }
        blocked.insert(address)
        // Block supersedes mute - no need to track both.
        muted.remove(address)
        persist()
    }

    func unblock(_ address: String) {
        blocked.remove(address)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(muted), forKey: mutedKey)
        UserDefaults.standard.set(Array(blocked), forKey: blockedKey)
    }
}


// MARK: - Post engagement screen (who liked/disliked/reposted/quoted, each row -> explorer)

/// Intermediate screen behind "View Post in Explorer": four tabs of actors (Likes, Dislikes,
/// Reposts, Quotes), each row linking to THAT action's transaction on the explorer, plus a link
/// to the post's own transaction. Actor identity resolves through contacts/KNS as everywhere.
///
/// Data reality: the K API exposes no per-post voter/quoter list - the only actor-level source is
/// the requester's own notification stream, so actor lists populate for YOUR posts; other
/// authors' posts show counts with an explanatory empty state until K grows list endpoints.
struct KaPostEngagementView: View {
    let post: KaPostsView.DraftPost

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var knsService = KNSService.shared

    enum EngagementTab: String, CaseIterable {
        case likes = "Likes"
        case dislikes = "Dislikes"
        case reposts = "Reposts"
        case quotes = "Quotes"
    }

    struct EngagementEntry: Identifiable {
        let id: String        // the ACTION's txid (notification id)
        let actorPubkey: String
        let timestamp: Date
    }

    @State private var selectedTab: EngagementTab = .likes
    @State private var entries: [EngagementTab: [EngagementEntry]] = [:]
    @State private var isLoading = false
    @State private var loadFailed = false

    private var isOwnPost: Bool {
        post.posterAddress == WalletManager.shared.currentWallet?.publicAddress
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(EngagementTab.allCases, id: \.self) { tab in
                        Text(tabTitle(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    let rows = entries[selectedTab] ?? []
                    if rows.isEmpty {
                        emptyState
                    } else {
                        List(rows) { entry in
                            entryRow(entry)
                        }
                        .listStyle(.plain)
                    }
                }

                Divider()
                Button {
                    if let txId = post.remoteId,
                       let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                        openURL(url)
                    }
                } label: {
                    Label("View Post Transaction in Explorer", systemImage: "globe")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
            }
            .navigationTitle("Post Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func tabTitle(_ tab: EngagementTab) -> String {
        let count: Int
        switch tab {
        case .likes: count = max(post.likes, entries[.likes]?.count ?? 0)
        case .dislikes: count = max(post.dislikes, entries[.dislikes]?.count ?? 0)
        case .reposts: count = entries[.reposts]?.count ?? 0
        case .quotes: count = entries[.quotes]?.count ?? 0
        }
        return count > 0 ? "\(tab.rawValue) (\(count))" : tab.rawValue
    }

    private func entryRow(_ entry: EngagementEntry) -> some View {
        let address = KaPostsAPIClient.kaspaAddress(fromPubkey: entry.actorPubkey) ?? ""
        return HStack(spacing: 12) {
            KNSAvatarView(
                avatarURLString: knsService.profileCache[address]?.avatarURL,
                fallbackText: displayName(for: address),
                size: 38,
                contactAddress: address
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: address))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(entry.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: entry.id) {
                    openURL(url)
                }
            } label: {
                Text("View")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.accentColor)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .task(id: address) {
            guard !address.isEmpty, knsService.profileCache[address] == nil else { return }
            _ = await knsService.fetchProfile(for: address)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Nothing here yet")
                .font(.headline)
            Text("When someone engages with this post, they'll show up here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func displayName(for address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(alias)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    /// Actor lists come from the KaChat indexer fork's get-post-engagement - works for ANY
    /// post. Falls back to the notification-stream derivation (own posts only) if the endpoint
    /// isn't available (older indexer deployment).
    private func load() async {
        guard let postId = post.remoteId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await KaPostsAPIClient.shared.fetchPostEngagement(postId: postId)
            var likes: [EngagementEntry] = []
            var dislikes: [EngagementEntry] = []
            var reposts: [EngagementEntry] = []
            var quotes: [EngagementEntry] = []
            for row in rows {
                let entry = EngagementEntry(
                    id: row.actionTxId,
                    actorPubkey: row.actorPubkey,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row.timestamp) / 1000)
                )
                switch row.kind {
                case "upvote": likes.append(entry)
                case "downvote": dislikes.append(entry)
                case "repost": reposts.append(entry)
                case "quote": quotes.append(entry)
                default: break
                }
            }
            entries = [.likes: likes, .dislikes: dislikes, .reposts: reposts, .quotes: quotes]
        } catch {
            AppLog.log("[KaPosts] Engagement endpoint failed, falling back: %@", error.localizedDescription)
            if isOwnPost {
                await loadFromNotifications(postId: postId)
            } else {
                loadFailed = true
            }
        }
    }

    /// Legacy path: derive the lists from the requester's notification stream, filtered to this
    /// post. Reposts vs Quotes split on whether the quote carried text beyond the KaChat marker.
    private func loadFromNotifications(postId: String) async {
        do {
            let notifications = try await KaPostsAPIClient.shared.fetchNotifications(limit: 100)
            var likes: [EngagementEntry] = []
            var dislikes: [EngagementEntry] = []
            var reposts: [EngagementEntry] = []
            var quotes: [EngagementEntry] = []
            for notification in notifications where notification.contentId == postId {
                let entry = EngagementEntry(
                    id: notification.id,
                    actorPubkey: notification.userPublicKey,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(notification.timestamp) / 1000)
                )
                switch notification.contentType {
                case "vote":
                    if notification.voteType == "upvote" { likes.append(entry) }
                    else if notification.voteType == "downvote" { dislikes.append(entry) }
                case "quote":
                    let text = KaPostsAPIClient.stripMarker(notification.decodedContent ?? "")
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reposts.append(entry)
                    } else {
                        quotes.append(entry)
                    }
                default:
                    break
                }
            }
            entries = [.likes: likes, .dislikes: dislikes, .reposts: reposts, .quotes: quotes]
        } catch {
            loadFailed = true
            AppLog.log("[KaPosts] Engagement load failed: %@", error.localizedDescription)
        }
    }
}

// MARK: - Follow lists (profile > Following / Followers)

/// Full list of accounts you follow or that follow you, reached by tapping the counts on the
/// KaPosts profile. Server (K indexer) is the source for followers; Following merges the
/// server list with the local follow store so pre-wiring follows still show.
struct KaPostsFollowListView: View {
    enum Kind {
        case following
        case followers

        var title: String { self == .following ? "Following" : "Followers" }
    }

    let kind: Kind
    let localFollowing: Set<String>
    /// Routes through KaPostsView.toggleFollowSubmitting - local store toggle + the on-chain
    /// follow/unfollow tx (and its toast) when the pubkey is known.
    let onToggleFollow: (String, String?) -> Void

    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var followStore = KaPostsFollowStore.shared

    struct Entry: Identifiable {
        let address: String
        let pubkey: String?
        let timestamp: Date?
        var id: String { address }
    }

    @State private var entries: [Entry] = []
    @State private var isLoading = true

    init(kind: Kind, localFollowing: Set<String>, onToggleFollow: @escaping (String, String?) -> Void) {
        self.kind = kind
        self.localFollowing = localFollowing
        self.onToggleFollow = onToggleFollow
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                emptyState
            } else {
                List(entries) { entry in
                    entryRow(entry)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func entryRow(_ entry: Entry) -> some View {
        HStack(spacing: 12) {
            KNSAvatarView(
                avatarURLString: knsService.profileCache[entry.address]?.avatarURL,
                fallbackText: displayName(for: entry.address),
                size: 38,
                contactAddress: entry.address
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: entry.address))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let timestamp = entry.timestamp {
                    Text(timestamp.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            // Quick follow controls: Unfollow in the Following list; Follow Back (or Unfollow)
            // in the Followers list. Rows stay in place after a toggle so it's reversible.
            if entry.address != WalletManager.shared.currentWallet?.publicAddress {
                let isFollowing = followStore.isFollowing(entry.address)
                Button {
                    Haptics.impact(.light)
                    onToggleFollow(entry.address, entry.pubkey)
                } label: {
                    Text(isFollowing ? "Unfollow" : (kind == .followers ? "Follow Back" : "Follow"))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(isFollowing ? Color.secondary.opacity(0.35) : Color.accentColor)
            }
        }
        .task(id: entry.address) {
            guard !entry.address.isEmpty, knsService.profileCache[entry.address] == nil else { return }
            _ = await knsService.fetchProfile(for: entry.address)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: kind == .following ? "person.badge.plus" : "person.2")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(kind == .following ? "Not following anyone yet" : "No followers yet")
                .font(.headline)
            Text(kind == .following
                 ? "Accounts you follow will show up here."
                 : "When someone follows you, they'll show up here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func displayName(for address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(alias)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    private func load() async {
        defer { isLoading = false }
        var remote: [Entry] = []
        if let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() {
            let users = (try? await KaPostsAPIClient.shared.fetchFollowList(
                ofPubkey: pubkey, followers: kind == .followers
            )) ?? []
            let myAddress = WalletManager.shared.currentWallet?.publicAddress
            remote = users.compactMap { user in
                guard let address = KaPostsAPIClient.kaspaAddress(fromPubkey: user.userPublicKey),
                      address != myAddress else { return nil }
                let date = user.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                return Entry(address: address, pubkey: user.userPublicKey, timestamp: date)
            }
        }
        if kind == .following {
            // Merge in locally-stored follows the indexer may not have caught up on yet.
            var seen = Set(remote.map(\.address))
            let localOnly = localFollowing
                .filter { !seen.contains($0) && $0 != WalletManager.shared.currentWallet?.publicAddress }
                .sorted()
                .map { Entry(address: $0, pubkey: nil, timestamp: nil) }
            seen.formUnion(localOnly.map(\.address))
            remote.append(contentsOf: localOnly)
        }
        entries = remote.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
    }
}


// MARK: - Notifications (side menu)

/// Who did what to YOUR content, from the indexer's notification stream - likes, dislikes,
/// replies, quotes/reposts, X-style. Identity is KNS-resolved from the actor's pubkey like
/// everywhere else; muted/blocked actors are filtered out.
struct KaPostsNotificationsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var moderationStore = KaPostsModerationStore.shared

    struct Item: Identifiable {
        enum Kind {
            case like, dislike, reply, quote, repost, follow, other

            var icon: String {
                switch self {
                case .like: return "heart.fill"
                case .dislike: return "hand.thumbsdown.fill"
                case .reply: return "bubble.left.fill"
                case .quote, .repost: return "arrow.2.squarepath"
                case .follow: return "person.fill.badge.plus"
                case .other: return "bell.fill"
                }
            }

            var tint: Color {
                switch self {
                case .like: return .red
                case .dislike: return .orange
                case .reply: return .accentColor
                case .quote, .repost: return .green
                case .follow: return .accentColor
                case .other: return .secondary
                }
            }

            var actionText: String {
                switch self {
                case .like: return "liked your post"
                case .dislike: return "disliked your post"
                case .reply: return "replied to your post"
                case .quote: return "quoted your post"
                case .repost: return "reposted your post"
                case .follow: return "followed you"
                case .other: return "interacted with your post"
                }
            }
        }

        let id: String        // the ACTION's txid
        let actorAddress: String
        let kind: Kind
        let snippet: String?  // reply/quote text, marker-stripped
        let timestamp: Date
        /// Post to open in-app when the row is tapped: the reply/quote itself (it's a post,
        /// shown with its "Replying to"/embed context), or YOUR post for votes/reposts.
        /// Nil for follows (nothing to open).
        let targetTxId: String?
    }

    @State private var items: [Item] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading, items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    ScrollView {
                        emptyState
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    }
                    .refreshable { await load() }
                } else {
                    List(items) { item in
                        itemRow(item)
                    }
                    .listStyle(.plain)
                    .refreshable { await load() }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func itemRow(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            KNSAvatarView(
                avatarURLString: knsService.profileCache[item.actorAddress]?.avatarURL,
                fallbackText: displayName(for: item.actorAddress),
                size: 38,
                contactAddress: item.actorAddress
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: item.kind.icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(item.kind.tint)
                    .padding(3)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                (Text(displayName(for: item.actorAddress)).fontWeight(.bold)
                    + Text(" \(item.kind.actionText)"))
                    .font(.subheadline)
                    .lineLimit(2)
                if let snippet = item.snippet, !snippet.isEmpty {
                    Text(verbatim: snippet)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                Text(item.timestamp.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: item.id) {
                    openURL(url)
                }
            } label: {
                Text("View")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.accentColor)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        // Tap the row -> the relevant post opens in-app (the inner explorer View button still
        // wins its own taps). Rides the shared deep-link plumbing: close this sheet, let
        // KaPostsView pick up the pending id and open the thread.
        .onTapGesture {
            guard let target = item.targetTxId else { return }
            Haptics.impact(.light)
            KaPostsDeepLink.pendingPostTxId = target
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                NotificationCenter.default.post(name: .openKaPost, object: nil, userInfo: [:])
            }
        }
        .task(id: item.actorAddress) {
            guard !item.actorAddress.isEmpty,
                  knsService.profileCache[item.actorAddress] == nil else { return }
            _ = await knsService.fetchProfile(for: item.actorAddress)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Nothing yet")
                .font(.headline)
            Text("When someone likes, replies to or shares your posts, it shows up here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func displayName(for address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(alias)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            let notifications = try await KaPostsAPIClient.shared.fetchNotifications(limit: 100)
            // Everything now on screen counts as seen - the local-notification poller won't
            // ping for it later.
            if let newest = notifications.map(\.timestamp).max() {
                KaPostsNotificationService.shared.markSeen(upTo: newest)
            }
            let myAddress = WalletManager.shared.currentWallet?.publicAddress
            items = notifications.compactMap { notification in
                guard let address = KaPostsAPIClient.kaspaAddress(fromPubkey: notification.userPublicKey),
                      address != myAddress,
                      !moderationStore.isHidden(address) else { return nil }
                let text = KaPostsAPIClient.stripMarker(notification.decodedContent ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let kind: Item.Kind
                let targetTxId: String?
                switch notification.contentType {
                case "vote":
                    kind = notification.voteType == "downvote" ? .dislike : .like
                    targetTxId = notification.contentId
                case "reply":
                    kind = .reply
                    targetTxId = notification.id
                case "quote":
                    kind = text.isEmpty ? .repost : .quote
                    targetTxId = text.isEmpty ? notification.contentId : notification.id
                case "follow":
                    kind = .follow
                    targetTxId = nil
                default:
                    kind = .other
                    targetTxId = notification.contentId
                }
                return Item(
                    id: notification.id,
                    actorAddress: address,
                    kind: kind,
                    snippet: text.isEmpty ? nil : text,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(notification.timestamp) / 1000),
                    targetTxId: targetTxId
                )
            }
        } catch {
            loadFailed = true
            AppLog.log("[KaPosts] Notifications load failed: %@", error.localizedDescription)
        }
    }
}


// MARK: - KaPosts page wrapper (shared navigation chrome)

/// KaPosts inside its navigation chrome - used by BOTH the standalone dock tab and the
/// chats-slot presentation, so the header (green connection dot leading, balance centered,
/// bold large title) is rendered by the exact same UIKit bar as Chats and Broadcasts and
/// never shifts between pages.
struct KaPostsPageView: View {
    var body: some View {
        NavigationStack {
            KaPostsView()
                .navigationTitle("KaPosts")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        ConnectionStatusIndicator()
                    }
                    ToolbarItem(placement: .principal) {
                        BalanceToolbarLabel()
                    }
                }
        }
    }
}


/// X-style ring meter shared by the post composer and the reply bar: fills toward the
/// 25,000-character limit, flips orange in the final 10% with a live remaining count, red at
/// the wall. Hidden while empty.
struct KaPostCharacterMeter: View {
    let count: Int

    var body: some View {
        let limit = KaPostsView.postCharacterLimit
        let progress = min(1, Double(count) / Double(limit))
        let remaining = limit - count
        let nearLimit = progress >= 0.9
        let ringColor: Color = remaining <= 0 ? .red : (nearLimit ? .orange : .accentColor)
        return HStack(spacing: 6) {
            if nearLimit {
                Text("\(remaining)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundColor(ringColor)
            }
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
            .animation(.easeOut(duration: 0.15), value: progress)
        }
        .opacity(count == 0 ? 0 : 1)
    }
}
