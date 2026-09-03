import CryptoKit
import SwiftUI
import UIKit

// MARK: - Endless scroll: per-surface paging state + footer

/// Paging bookkeeping for ONE list surface (a feed tab, a profile tab, a thread's replies, the
/// notifications list, ...). Every surface owns its own instance - loads never bleed across
/// surfaces, and exactly one request per surface is ever in flight (`isLoading`).
struct KaPostsPageState {
    /// Server cursor for the NEXT page (`pagination.nextCursor`); nil = start / exhausted.
    var cursor: String?
    /// False once the server reports no further pages - the surface stops trying.
    var hasMore = true
    var isLoading = false
    /// Set when a load-more fails. The already-loaded rows stay on screen; the footer offers
    /// a retry instead of wiping the list.
    var errorMessage: String?
    /// A whole request budget produced zero new visible rows (heavily filtered stretch of
    /// history). The footer switches from auto-loading to an explicit "Load more" so one
    /// scroll can't turn into an endless request loop.
    var stalled = false
    /// Bumped by refresh / tab switch / wallet change. In-flight loads capture it and drop
    /// their results if it moved on - that's how stale responses are ignored.
    var epoch = 0

    /// Back to page one: what pull-to-refresh, a tab switch or an account change does.
    mutating func reset() {
        cursor = nil
        hasMore = true
        isLoading = false
        errorMessage = nil
        stalled = false
        epoch += 1
    }

    /// Clears the two states that stop AUTOMATIC loading (a failed page, a request budget spent
    /// on nothing visible). Call this from an explicit user tap - "Load more" / "Tap to retry" -
    /// so the surface can move again while scroll-driven triggers stay blocked.
    mutating func prepareManualRetry() {
        stalled = false
        errorMessage = nil
    }

    /// Folds a completed batch's paging result back in.
    mutating func apply<Item>(_ batch: KaPostsPaginator.Batch<Item>) {
        cursor = batch.cursor
        hasMore = batch.hasMore
        stalled = batch.stalled
        errorMessage = nil
        isLoading = false
    }
}

/// Bottom-of-list affordance shared by every paginated KaPosts surface: a spinner while a page
/// is loading, a tappable retry when one failed, an invisible sentinel that auto-loads the next
/// page when it scrolls into view, or nothing once the end is reached.
struct KaPostsLoadMoreFooter: View {
    let state: KaPostsPageState
    let onLoadMore: () -> Void

    var body: some View {
        Group {
            if state.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading more...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else if let error = state.errorMessage {
                Button(action: onLoadMore) {
                    VStack(spacing: 4) {
                        Text("Couldn't load more")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Text("Tap to retry")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.accentColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if state.hasMore {
                if state.stalled {
                    // A full request budget yielded nothing visible - hand control back to
                    // the user rather than looping on the indexer.
                    Button(action: onLoadMore) {
                        Text("Load more")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    // Invisible sentinel: entering the render window pulls the next page.
                    Color.clear
                        .frame(height: 1)
                        .onAppear(perform: onLoadMore)
                }
            }
        }
    }
}

/// Prefetch trigger id: the row ~5 from the end, so loading starts BEFORE the user hits bottom.
/// Returns nil for lists too short to have a distinct trigger row (their footer sentinel
/// handles it).
func kaPostsPrefetchTriggerId<T: Identifiable>(_ items: [T]) -> T.ID? {
    guard items.count > 5 else { return items.last?.id }
    return items[items.count - 5].id
}

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
        /// True for a thread root WE posted this session (scheduleThread) - shows the feed's
        /// "View thread" affordance immediately, before any probe could discover it remotely.
        var isLocalThreadRoot = false
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
    /// Posts read off the chain because the indexer could not answer for them (see `chainPost`).
    ///
    /// They belong to no feed and are never rendered as one - they live here only so the thread
    /// opened onto them can FIND them. `openDetail` hands the sheet an id, not a post, and the
    /// sheet resolves it against these collections; a post that was in none of them presented as
    /// a blank sheet.
    @State private var chainResolvedPosts: [DraftPost] = []
    /// Endless-scroll state for the feed currently on screen (see `feedSource`).
    @State private var feedPage = KaPostsPageState()
    /// Which endpoint `remotePosts` was filled from. Feed and Popular share the global feed, so
    /// switching between them keeps every page already loaded (Popular just re-sorts it);
    /// switching to/from Following swaps the source and starts over.
    @State private var loadedFeedSource: FeedSource?
    @State private var feedError: String?
    /// True while the Popular tab is pulling its deep ranking window (see `deepenPopularRanking`).
    @State private var isDeepeningPopular = false
    /// Posts that arrived since the feed was last loaded, held back rather than inserted.
    ///
    /// Splicing new rows in under a reader moves everything they were looking at. X's answer -
    /// hold them and offer them - is better: nothing shifts until the reader asks for it, and the
    /// count tells them whether it is worth asking.
    @State private var pendingNewPosts: [DraftPost] = []
    /// Guards the check so a slow poll and a manual one cannot run together.
    @State private var isCheckingForNewPosts = false
    /// Set when the pill is tapped; the feed's ScrollViewReader consumes it to jump to the top.
    @State private var pendingScrollToFeedTop = false
    @State private var showComposer = false
    /// Poster being tipped via the quick-tip sheet (amount + direct send).
    @State private var tipTarget: TipTarget?
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
    /// Comment thread opened from WITHIN the poster-profile sheet. Separate from `detailTarget`
    /// because the profile is itself a sheet: the thread must present from inside the profile's
    /// own NavigationStack (a view can only present one sheet at a time), not the top-level presenter.
    @State private var profileDetailTarget: PostDetailTarget?
    /// "Post Activity" tapped from a feed/profile/bookmark cell: engagement screen first
    /// (likes/dislikes/reposts/quotes).
    @State private var engagementTarget: DraftPost?
    /// "Post Activity" tapped from INSIDE an open thread. Separate from `engagementTarget`
    /// because the thread is itself a sheet: the top-level `$engagementTarget` sheet hangs off
    /// `feedLayer`, which cannot present a second sheet while the thread is up - the screen
    /// only appeared after the thread was closed. This one presents from the thread's own
    /// hierarchy instead.
    @State private var threadEngagementTarget: DraftPost?
    /// Set when a reply notification opens the PARENT post's thread: once the thread's
    /// comment list contains this reply txid, the list scrolls it into view.
    @State private var pendingThreadScrollRemoteId: String?
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
    /// Paging state for the four profile feeds (own Posts/Replies, poster Posts/Replies) and
    /// for every open reply thread (keyed by the thread root's local id - the detail sheet's
    /// comment list and each inline "View N replies" chain each get their own).
    @State private var myPostsPage = KaPostsPageState()
    @State private var myRepliesPage = KaPostsPageState()
    @State private var posterPostsPage = KaPostsPageState()
    @State private var posterRepliesPage = KaPostsPageState()
    @State private var threadPages: [UUID: KaPostsPageState] = [:]

    /// The two feed backends behind the three tabs.
    /// Equatable stated rather than relied on: `.task(id: loadedFeedSource)` drives the new-post
    /// poll, and that constraint should be visible at the declaration.
    enum FeedSource: Equatable {
        case global
        case following
    }
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
    /// K pubkey of the profile currently open, so its feeds can page without the sheet's target.
    @State private var posterProfilePubkey: String?
    @State private var posterProfileFollowers: Int?
    @State private var posterProfileFollowing: Int?
    /// Followers/Following list opened from the OPEN poster profile's counts.
    @State private var posterProfileFollowListKind: KaPostsFollowListView.Kind?
    @State private var isLoadingPosterProfile = false
    /// Repost tapped on an on-chain post: choose plain repost vs quote.
    @State private var repostDialogTarget: DraftPost?
    @State private var quoteComposerTarget: DraftPost?
    /// Quote tapped from INSIDE the poster-profile sheet, and from INSIDE an open thread.
    /// A view can only present one sheet at a time, so `feedLayer`'s `$quoteComposerTarget`
    /// sheet is stuck behind whichever sheet is already up: the composer only appeared after
    /// the profile/thread was closed. These present from those sheets' own hierarchies.
    /// Same rule (and same fix) as `profileDetailTarget` and `threadEngagementTarget`.
    @State private var profileQuoteComposerTarget: DraftPost?
    @State private var threadQuoteComposerTarget: DraftPost?
    /// Quote tapped inside the side-menu sheet (Bookmarks / my Profile), which is presented by
    /// `body`'s ZStack - a level above `feedLayer`, so it needs its own composer too.
    @State private var menuQuoteComposerTarget: DraftPost?
    @State private var replyText = ""
    /// Caret / highlighted range in the thread's reply bar, in character offsets - what its
    /// formatting toolbar acts on.
    @State private var replySelection: ClosedRange<Int> = 0...0
    @State private var isReplyFocused = false

    /// Which presentation level a quote action came from - i.e. which view has to own the
    /// composer sheet so it can actually appear over what the user is looking at.
    private enum QuoteComposerLevel {
        case feed
        case profile
        case thread
        case menu
    }

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
        }
        .sheet(item: $menuSheet) { item in
            Group {
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
            // Quote from a Bookmarks / my-Profile cell: presented from INSIDE this sheet,
            // since the presenter of this sheet is already busy presenting it.
            .sheet(item: $menuQuoteComposerTarget) { target in
                quoteComposerSheet(for: target)
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
            KaPostComposerView(
                onPost: { text in
                    schedulePost(text: text)
                },
                onPostThread: { segments in
                    scheduleThread(segments)
                }
            )
            // Large only. The composer auto-focuses, and at the medium detent the keyboard
            // takes practically all of the sheet - the editor was left with a sliver and the
            // caret slid behind the keyboard as the post grew.
            .presentationDetents([.large])
        }
        .sheet(item: $tipTarget) { target in
            KaPostTipSheet(address: target.address, displayName: posterDisplayName(target.address))
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
                    // Held for 5s with an always-visible undo TOAST (plus the icon countdown).
                    let key = "repost:\(target.id)"
                    showUndoToast(key: key, postId: target.id, label: "Reposting")
                    scheduler.schedule(key: key) {
                        clearUndoToast(key: key)
                        performRepost(target: target, text: nil, localQuoteId: nil)
                    }
                }
            } else {
                Button("Remove Repost", role: .destructive) {
                    // Same 5s undo window; the fork's `unquote` counter-action nets the
                    // repost out on the indexer (the chain keeps both transactions).
                    let key = "repost:\(target.id)"
                    showUndoToast(key: key, postId: target.id, label: "Removing repost")
                    scheduler.schedule(key: key) {
                        clearUndoToast(key: key)
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
            quoteComposerSheet(for: target)
        }
        // Tapping an @mention anywhere in KaPosts (feed, thread detail, profiles - sheets
        // inherit this environment) resolves the KNS domain and opens that user's profile.
        // Every other link keeps the system behavior.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "kachat-mention" else { return .systemAction }
            let domain = url.host ?? url.absoluteString
                .replacingOccurrences(of: "kachat-mention://", with: "")
            openMentionProfile(domain: domain)
            return .handled
        })
        .task {
            if let myAddress = WalletManager.shared.currentWallet?.publicAddress {
                followStore.removeIfPresent(myAddress)
            }
            // Restore the local follow set from the on-chain graph (survives reinstalls).
            followStore.syncFromChain()
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
        .onChange(of: selectedFeed) { tab in
            // Feed <-> Popular share the global feed: keep every page already scrolled in
            // (Popular is just a re-sort of the same set). Only a real source change - to or
            // from Following - starts a new paginated feed.
            guard feedSource(for: tab) != loadedFeedSource || remotePosts.isEmpty else {
                // Already have the feed; Popular still needs its window deepened before its
                // order is meaningful.
                if tab == .popular { Task { await deepenPopularRanking() } }
                return
            }
            Task {
                await loadFeed()
                if tab == .popular { await deepenPopularRanking() }
            }
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            // Account switch: every surface's cursor belongs to the old identity (K responses
            // are decorated per requesterPubkey), so drop the lot and start over. The epoch
            // bumps make any in-flight page drop its result instead of appending.
            PostTranslationService.shared.reset()
            pendingNewPosts = []
            chainResolvedPosts = []
            feedPage.reset()
            myPostsPage.reset()
            myRepliesPage.reset()
            posterPostsPage.reset()
            posterRepliesPage.reset()
            threadPages.removeAll()
            remotePosts = []
            myProfileRemotePosts = []
            myProfileRemoteReplies = []
            posterProfilePosts = []
            posterProfileReplies = []
            loadedFeedSource = nil
            Task { await loadFeed() }
        }
    }

    // MARK: - Feed tabs (mirrors ChatListView.chatsTopTabBar)


    private var feedTabBar: some View {
        VStack(spacing: 0) {
            sideMenuIconRow
            HStack(spacing: 0) {
                ForEach(FeedTab.allCases, id: \.title) { tab in
                    feedTabButton(tab)
                }
            }
            Divider()
        }
    }

    /// Profile / Notifications / Bookmarks / Muted / Blocked, as the icons themselves rather than
    /// behind a hamburger.
    ///
    /// They sit on their own row above the feed tabs, left-aligned where the hamburger used to
    /// be. Five icons and three tabs do not fit one row on a phone - they would collide on the
    /// narrow ones - and the point of the change is that every destination is one tap, which a
    /// cramped row would undo. Having the row to themselves is also what lets the icons be this
    /// size; sharing it with the tabs would have forced them small.
    private var sideMenuIconRow: some View {
        HStack(spacing: 2) {
            ForEach(SideMenuItem.allCases) { item in
                Button {
                    Haptics.impact(.light)
                    menuSheet = item
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(width: 46, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.rawValue))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
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
                // Everything fetched so far was filtered away (all muted, or - on Following -
                // none of it from accounts you follow locally) while the server still has
                // older pages. No auto-sentinel here: with nothing on screen it would walk the
                // whole history unattended, so this stays an explicit tap.
                if !feedPage.isLoading, feedPage.hasMore, feedPage.cursor != nil {
                    Button {
                        feedPage.prepareManualRetry()
                        Task { await loadFeedPage(reset: false) }
                    } label: {
                        Text("Load older posts")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if feedPage.isLoading {
                    ProgressView()
                        .padding(.vertical, 12)
                }
            }
            .refreshable { await loadFeed() }
        } else {
            let triggerId = kaPostsPrefetchTriggerId(visiblePosts)
            ScrollViewReader { feedProxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Anchor for the "show new posts" jump - the pill's whole point is landing
                    // the reader on what just arrived.
                    Color.clear
                        .frame(height: 0)
                        .id(Self.feedTopAnchor)
                    ForEach(visiblePosts) { post in
                        KaPostCellView(
                            post: post,
                            displayName: posterDisplayName(post.posterAddress),
                            avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                            isFollowing: followStore.isFollowing(post.posterAddress),
                            commentCount: commentCount(of: post),
                            truncatesLongText: true,
                            quotedDisplayName: post.quoted.map { posterDisplayName($0.posterAddress) },
                            quotedAvatarURLString: quotedAvatarURL(post),
                            onComment: { openDetail(post) },
                            onMute: { moderationStore.mute(post.posterAddress) },
                            onBlock: { moderationStore.block(post.posterAddress) },
                            onBookmark: { toggleBookmark(post) },
                            onRetry: { retryPost(post) },
                            onViewEngagement: { engagementTarget = post },
                            onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
                            onOpenProfile: { profileTarget = PosterProfileTarget(address: post.posterAddress, pubkey: post.posterPubkey) },
                            onTip: { tip(post.posterAddress) },
                            onLike: { toggleLike(post) },
                            onDislike: { toggleDislike(post) },
                            onRepost: { handleRepostTap(post) },
                            onRepostAction: { handleRepostAction(post, $0) },
                            onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
                        )
                        .equatable()
                        .task(id: post.posterAddress) {
                            guard knsService.profileCache[post.posterAddress] == nil,
                                  !post.posterAddress.isEmpty else { return }
                            _ = await knsService.fetchProfile(for: post.posterAddress)
                        }
                        // Thread-root probe: once per commented post, so the "View thread"
                        // affordance below can appear for other people's threads too.
                        .task(id: post.remoteId ?? "") {
                            await probeThreadRoot(post)
                        }
                        // Endless scroll: the row ~5 from the end pulls the next pages in,
                        // well before the user reaches the bottom.
                        .onAppear {
                            guard post.id == triggerId else { return }
                            Task { await loadFeedPage(reset: false) }
                        }
                        // X-style "View thread" under a thread root - opens the detail, where
                        // the full continuation renders as a connected Thread section.
                        if isThreadRoot(post) {
                            Button {
                                openDetail(post)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "text.append")
                                        .font(.caption2.weight(.semibold))
                                    Text("View thread")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundColor(.accentColor)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 68)
                            .padding(.top, 2)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Divider()
                            .padding(.leading, 68)
                    }
                    KaPostsLoadMoreFooter(state: feedPage) {
                        feedPage.prepareManualRetry()
                        Task { await loadFeedPage(reset: false) }
                    }
                }
            }
            .refreshable { await loadFeed() }
            .overlay(alignment: .top) { newPostsPill }
            .onChange(of: pendingScrollToFeedTop) { shouldScroll in
                guard shouldScroll else { return }
                pendingScrollToFeedTop = false
                withAnimation(.easeOut(duration: 0.25)) {
                    feedProxy.scrollTo(Self.feedTopAnchor, anchor: .top)
                }
            }
            // Only while this feed is actually on screen: the task is torn down on a tab switch,
            // so nothing polls in the background.
            .task(id: loadedFeedSource) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Self.newPostsCheckInterval * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await checkForNewPosts()
                }
            }
            }
        }
    }

    private static let feedTopAnchor = "kaPostsFeedTop"

    // MARK: - New posts

    /// How often the visible feed asks whether anything newer exists.
    ///
    /// One page, and only while the feed is actually on screen and the app is in the foreground -
    /// this is the same cadence as the app's fallback message poll, chosen so a social feed still
    /// feels current without becoming a background data drain on cellular.
    private static let newPostsCheckInterval: TimeInterval = 60

    /// The floating "Show N new posts" pill, X-style.
    ///
    /// Floating rather than a row in the list: a row only exists where it was inserted, so a
    /// reader who has scrolled past it never learns there is anything new. This stays put.
    @ViewBuilder
    private var newPostsPill: some View {
        if !pendingNewPosts.isEmpty {
            Button {
                Haptics.impact(.light)
                showPendingNewPosts()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up")
                        .font(.caption.weight(.bold))
                    Text(pendingNewPosts.count == 1
                         ? "Show 1 new post"
                         : "Show \(pendingNewPosts.count) new posts")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.accentColor))
                .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Asks whether anything newer than the top of the loaded feed exists, without touching what
    /// is on screen.
    ///
    /// Deliberately page ONE only: this answers "is there anything new", not "fetch everything I
    /// missed". Pulling the gap in full would be a lot of requests for a question with a yes/no
    /// answer, and tapping the pill refreshes properly anyway.
    private func checkForNewPosts() async {
        guard !isCheckingForNewPosts, !feedPage.isLoading, !remotePosts.isEmpty else { return }
        isCheckingForNewPosts = true
        defer { isCheckingForNewPosts = false }

        let source = feedSource(for: selectedFeed)
        guard source == loadedFeedSource else { return }
        let known = Set(remotePosts.compactMap(\.remoteId))
        guard !known.isEmpty else { return }

        do {
            let page: (posts: [KaPostsAPIClient.KPost], pagination: KaPostsAPIClient.KPagination?)
            switch source {
            case .following:
                page = try await KaPostsAPIClient.shared.fetchFollowingFeed(limit: KaPostsPaginator.pageSize, before: nil)
            case .global:
                page = try await KaPostsAPIClient.shared.fetchGlobalFeed(limit: KaPostsPaginator.pageSize, before: nil)
            }
            // The feed may have been refreshed or switched while this was in flight.
            guard source == loadedFeedSource, !feedPage.isLoading else { return }
            let fresh = page.posts
                .filter { !known.contains($0.id) }
                .compactMap { Self.mapRemotePost($0) }
                .filter { !moderationStore.isHidden($0.posterAddress) }
            guard !fresh.isEmpty else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                pendingNewPosts = fresh
            }
        } catch {
            // A failed check is silent: it is a background question, and the feed on screen is
            // still perfectly usable.
            AppLog.log("%@", "[KaPosts] New-post check failed: \(error.localizedDescription)")
        }
    }

    /// Splices the held posts in at the top, on request.
    private func showPendingNewPosts() {
        guard !pendingNewPosts.isEmpty else { return }
        let known = Set(remotePosts.compactMap(\.remoteId))
        let additions = pendingNewPosts.filter { post in
            guard let id = post.remoteId else { return true }
            return !known.contains(id)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            remotePosts = additions + remotePosts
            pendingNewPosts = []
        }
        resolveIdentities(for: additions)
        pendingScrollToFeedTop = true
    }

    /// How many ranked posts Popular wants under it before its top row means anything.
    ///
    /// The indexer has no popularity endpoint - every feed comes back reverse-chronological - so
    /// Popular can only rank what the client has actually pulled. Ranking one 50-row page made
    /// "most popular" mean "the most-liked of the last few dozen posts", and a genuinely big post
    /// from last week never appeared. Popular therefore sweeps this far back before it trusts its
    /// own order.
    private static let popularRankingDepth = 300
    /// Request budget for one sweep pass. `KaPostsPaginator` follows the server's cursors, so
    /// each pass is up to this many round-trips; the loop below runs passes until it reaches
    /// `popularRankingDepth`, the feed is exhausted, or the user leaves the tab.
    private static let popularSweepRequestsPerPass = 6
    /// Hard ceiling on passes. Heavily-filtered stretches of history (a run of non-KaChat posts,
    /// a muted author) can return two visible rows for a whole pass, so depth alone is not a
    /// bound - without this, one tab tap could spend dozens of requests on cellular.
    private static let popularSweepMaxPasses = 4

    /// A post's popularity score. Every interaction counts - a post people argue with is popular
    /// in the same sense a post people like is - including comments, which the feed cell already
    /// shows but the old ordering ignored entirely.
    private func popularityScore(of post: DraftPost) -> Int {
        post.likes + post.reposts + post.dislikes + commentCount(of: post)
    }

    /// Pulls the global feed until Popular has `popularRankingDepth` posts to rank, so its top
    /// row is the most popular post in a real window of history rather than the most popular of
    /// whatever page one happened to contain. Runs only while Popular is on screen: switching
    /// tabs or accounts bumps the page epoch, which this checks between passes.
    private func deepenPopularRanking() async {
        guard selectedFeed == .popular, !isDeepeningPopular else { return }
        isDeepeningPopular = true
        defer { isDeepeningPopular = false }
        var passes = 0
        while remotePosts.count < Self.popularRankingDepth, passes < Self.popularSweepMaxPasses {
            passes += 1
            let epoch = feedPage.epoch
            guard selectedFeed == .popular,
                  feedPage.hasMore,
                  !feedPage.stalled,
                  feedPage.errorMessage == nil else { return }
            let before = remotePosts.count
            await loadFeedPage(reset: false, maxRequests: Self.popularSweepRequestsPerPass)
            // Tab switch, refresh or account change landed mid-pass - that load's result was
            // already discarded, and continuing would page a feed the user has left.
            guard feedPage.epoch == epoch else { return }
            // A pass that added nothing (all filtered out, or an error) would loop forever.
            guard remotePosts.count > before else { return }
        }
    }

    /// Your own session posts show in Feed and Following; Popular ranks by engagement across the
    /// whole swept window (see `deepenPopularRanking`), newest first among equal scores.
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
            // Ties broken by recency so equal-scoring posts (very common at 0-1 interactions,
            // deep in the window) keep a stable, sensible order instead of the sort's whim.
            return visible.sorted {
                let (a, b) = (popularityScore(of: $0), popularityScore(of: $1))
                return a == b ? $0.timestamp > $1.timestamp : a > b
            }
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
        await loadFeedPage(reset: true)
    }

    private func feedSource(for tab: FeedTab) -> FeedSource {
        tab == .following ? .following : .global
    }

    /// One page-load for the visible feed. `reset: true` is a refresh (pull-to-refresh, tab
    /// source change, account change): back to the first page with the end-reached state
    /// cleared. `reset: false` is the endless-scroll append.
    ///
    /// Because the client filters hard (KaChat marker, muted/blocked, dedup), one trigger may
    /// need several server pages - `KaPostsPaginator.collect` follows the server's cursor until
    /// it has enough VISIBLE rows, or the feed is exhausted, or it hits its request cap.
    private func loadFeedPage(reset: Bool, maxRequests: Int = KaPostsPaginator.maxRequestsPerTrigger) async {
        guard !feedPage.isLoading else { return }
        guard reset || (feedPage.hasMore && feedPage.errorMessage == nil && !feedPage.stalled) else { return }
        let source = feedSource(for: selectedFeed)
        if reset {
            feedPage.reset()
            loadedFeedSource = source
            feedError = nil
        }
        let epoch = feedPage.epoch
        let startCursor = reset ? nil : feedPage.cursor
        feedPage.isLoading = true
        feedPage.errorMessage = nil
        do {
            // Dedup set seeded with what's already on screen - the indexer can repeat items
            // across pages, and a refresh must not double up either.
            var seen: Set<String> = reset ? [] : Set(remotePosts.compactMap(\.remoteId))
            let batch = try await KaPostsPaginator.collect(
                from: startCursor,
                maxRequests: maxRequests,
                fetch: { (before: String?, limit: Int) -> (items: [KaPostsAPIClient.KPost], pagination: KaPostsAPIClient.KPagination?) in
                    switch source {
                    case .following:
                        let page = try await KaPostsAPIClient.shared.fetchFollowingFeed(limit: limit, before: before)
                        return (page.posts, page.pagination)
                    case .global:
                        let page = try await KaPostsAPIClient.shared.fetchGlobalFeed(limit: limit, before: before)
                        return (page.posts, page.pagination)
                    }
                },
                keep: { (posts: [KaPostsAPIClient.KPost]) -> [DraftPost] in
                    posts.compactMap { post in
                        guard !seen.contains(post.id),
                              let mapped = Self.mapRemotePost(post),
                              !moderationStore.isHidden(mapped.posterAddress) else { return nil }
                        seen.insert(post.id)
                        return mapped
                    }
                }
            )
            // Stale response (tab switched, refreshed, or the wallet changed under us): drop it
            // rather than appending to a list the user has moved on from.
            guard feedPage.epoch == epoch else { return }
            if reset {
                remotePosts = batch.items
                // A refresh just delivered whatever the pill was offering; leaving it up would
                // promise posts that are already on screen.
                pendingNewPosts = []
            } else {
                remotePosts.append(contentsOf: batch.items)
            }
            feedPage.apply(batch)
            resolveIdentities(for: batch.items)
        } catch {
            guard feedPage.epoch == epoch else { return }
            feedPage.isLoading = false
            feedPage.errorMessage = error.localizedDescription
            // A failed APPEND keeps everything already loaded on screen (the footer offers a
            // retry); only a failed refresh surfaces as the feed-level error.
            if reset {
                feedError = error.localizedDescription
            }
            AppLog.log("[KaPosts] Feed fetch failed: %@", error.localizedDescription)
        }
    }

    /// Batch-refresh poster identities through KNSService's debounced/backed-off path (bounded
    /// concurrency, per-address debounce) for a freshly appended page. Besides warming
    /// names/avatars ahead of row mounts, this refreshes stale cached entries - including old
    /// permanently cached failed lookups - which per-row tasks never retouch because they only
    /// fetch when the cache has no entry at all. Every appended page goes through here, so
    /// endless scroll never degrades into one KNS request per row.
    private func resolveIdentities(for newPosts: [DraftPost]) {
        let addresses = Array(Set(newPosts.map(\.posterAddress).filter { !$0.isEmpty }))
        guard !addresses.isEmpty else { return }
        Task { await knsService.refreshProfilesIfNeeded(for: addresses) }
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

    // MARK: - Profile feed paging (own + tapped poster, Posts and Replies tabs)

    /// Fetch/filter core shared by the four profile feeds. Follows the server cursor until it
    /// has enough rows that survive filtering (see `KaPostsPaginator`); the caller owns the
    /// @State it lands in.
    private func fetchProfileBatch(
        pubkey: String,
        replies: Bool,
        cursor: String?,
        knownIds: Set<String>
    ) async throws -> KaPostsPaginator.Batch<DraftPost> {
        var seen = knownIds
        return try await KaPostsPaginator.collect(
            from: cursor,
            fetch: { (before: String?, limit: Int) -> (items: [KaPostsAPIClient.KPost], pagination: KaPostsAPIClient.KPagination?) in
                if replies {
                    let page = try await KaPostsAPIClient.shared.fetchUserReplies(pubkey: pubkey, limit: limit, before: before)
                    return (page.posts, page.pagination)
                }
                let page = try await KaPostsAPIClient.shared.fetchUserPosts(pubkey: pubkey, limit: limit, before: before)
                return (page.posts, page.pagination)
            },
            keep: { (posts: [KaPostsAPIClient.KPost]) -> [DraftPost] in
                posts.compactMap { post in
                    guard !seen.contains(post.id), let mapped = Self.mapRemotePost(post) else { return nil }
                    // The Posts tab is top-level content only - replies have their own tab.
                    if !replies, mapped.parentRemoteId != nil { return nil }
                    seen.insert(post.id)
                    return mapped
                }
            }
        )
    }

    /// Your own profile > Posts.
    private func loadMyProfilePosts(pubkey: String, reset: Bool) async {
        guard !myPostsPage.isLoading else { return }
        guard reset || (myPostsPage.hasMore && myPostsPage.errorMessage == nil && !myPostsPage.stalled) else { return }
        if reset { myPostsPage.reset() }
        let epoch = myPostsPage.epoch
        let cursor = reset ? nil : myPostsPage.cursor
        let known = Set(reset ? [] : myProfileRemotePosts.compactMap(\.remoteId))
        myPostsPage.isLoading = true
        myPostsPage.errorMessage = nil
        do {
            let batch = try await fetchProfileBatch(pubkey: pubkey, replies: false, cursor: cursor, knownIds: known)
            guard myPostsPage.epoch == epoch else { return }
            if reset {
                myProfileRemotePosts = batch.items
            } else {
                myProfileRemotePosts.append(contentsOf: batch.items)
            }
            myPostsPage.apply(batch)
            resolveIdentities(for: batch.items)
        } catch {
            guard myPostsPage.epoch == epoch else { return }
            myPostsPage.isLoading = false
            myPostsPage.errorMessage = error.localizedDescription
            AppLog.log("[KaPosts] Profile posts page failed: %@", error.localizedDescription)
        }
    }

    /// Your own profile > Replies.
    private func loadMyProfileReplies(pubkey: String, reset: Bool) async {
        guard !myRepliesPage.isLoading else { return }
        guard reset || (myRepliesPage.hasMore && myRepliesPage.errorMessage == nil && !myRepliesPage.stalled) else { return }
        if reset { myRepliesPage.reset() }
        let epoch = myRepliesPage.epoch
        let cursor = reset ? nil : myRepliesPage.cursor
        let known = Set(reset ? [] : myProfileRemoteReplies.compactMap(\.remoteId))
        myRepliesPage.isLoading = true
        myRepliesPage.errorMessage = nil
        do {
            let batch = try await fetchProfileBatch(pubkey: pubkey, replies: true, cursor: cursor, knownIds: known)
            guard myRepliesPage.epoch == epoch else { return }
            if reset {
                myProfileRemoteReplies = batch.items
            } else {
                myProfileRemoteReplies.append(contentsOf: batch.items)
            }
            myRepliesPage.apply(batch)
            resolveIdentities(for: batch.items)
        } catch {
            guard myRepliesPage.epoch == epoch else { return }
            myRepliesPage.isLoading = false
            myRepliesPage.errorMessage = error.localizedDescription
            AppLog.log("[KaPosts] Profile replies page failed: %@", error.localizedDescription)
        }
    }

    /// A tapped poster's profile > Posts.
    private func loadPosterProfilePosts(pubkey: String, reset: Bool) async {
        guard !posterPostsPage.isLoading else { return }
        guard reset || (posterPostsPage.hasMore && posterPostsPage.errorMessage == nil && !posterPostsPage.stalled) else { return }
        if reset { posterPostsPage.reset() }
        let epoch = posterPostsPage.epoch
        let cursor = reset ? nil : posterPostsPage.cursor
        let known = Set(reset ? [] : posterProfilePosts.compactMap(\.remoteId))
        posterPostsPage.isLoading = true
        posterPostsPage.errorMessage = nil
        do {
            let batch = try await fetchProfileBatch(pubkey: pubkey, replies: false, cursor: cursor, knownIds: known)
            guard posterPostsPage.epoch == epoch else { return }
            if reset {
                posterProfilePosts = batch.items
            } else {
                posterProfilePosts.append(contentsOf: batch.items)
            }
            posterPostsPage.apply(batch)
            resolveIdentities(for: batch.items)
        } catch {
            guard posterPostsPage.epoch == epoch else { return }
            posterPostsPage.isLoading = false
            posterPostsPage.errorMessage = error.localizedDescription
            AppLog.log("[KaPosts] Poster posts page failed: %@", error.localizedDescription)
        }
    }

    /// A tapped poster's profile > Replies.
    private func loadPosterProfileReplies(pubkey: String, reset: Bool) async {
        guard !posterRepliesPage.isLoading else { return }
        guard reset || (posterRepliesPage.hasMore && posterRepliesPage.errorMessage == nil && !posterRepliesPage.stalled) else { return }
        if reset { posterRepliesPage.reset() }
        let epoch = posterRepliesPage.epoch
        let cursor = reset ? nil : posterRepliesPage.cursor
        let known = Set(reset ? [] : posterProfileReplies.compactMap(\.remoteId))
        posterRepliesPage.isLoading = true
        posterRepliesPage.errorMessage = nil
        do {
            let batch = try await fetchProfileBatch(pubkey: pubkey, replies: true, cursor: cursor, knownIds: known)
            guard posterRepliesPage.epoch == epoch else { return }
            if reset {
                posterProfileReplies = batch.items
            } else {
                posterProfileReplies.append(contentsOf: batch.items)
            }
            posterRepliesPage.apply(batch)
            resolveIdentities(for: batch.items)
        } catch {
            guard posterRepliesPage.epoch == epoch else { return }
            posterRepliesPage.isLoading = false
            posterRepliesPage.errorMessage = error.localizedDescription
            AppLog.log("[KaPosts] Poster replies page failed: %@", error.localizedDescription)
        }
    }

    /// Scroll trigger for your own profile. Tab-explicit (not "whichever tab is selected"):
    /// with the profile pager both tabs' lists stay alive, so each page asks for ITS OWN
    /// next batch regardless of which page is fronted.
    private func loadMoreMyProfile(_ tab: ProfileFeedTab) {
        guard let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() else { return }
        Task {
            if tab == .posts {
                await loadMyProfilePosts(pubkey: pubkey, reset: false)
            } else {
                await loadMyProfileReplies(pubkey: pubkey, reset: false)
            }
        }
    }

    /// Same for the tapped poster's profile (its pubkey is remembered when the sheet loads).
    private func loadMorePosterProfile(_ tab: ProfileFeedTab) {
        guard let pubkey = posterProfilePubkey else { return }
        Task {
            if tab == .posts {
                await loadPosterProfilePosts(pubkey: pubkey, reset: false)
            } else {
                await loadPosterProfileReplies(pubkey: pubkey, reset: false)
            }
        }
    }

    // MARK: - Thread reply paging (detail sheet + inline "View N replies" chains)

    /// Loads (or appends) a post's replies. Every thread - the detail sheet's root thread and
    /// each inline reply chain - has its own paging state keyed by the parent's local id, so
    /// two open threads never share a cursor or an in-flight request.
    private func loadThreadReplies(for post: DraftPost, reset: Bool) async {
        guard let remoteId = post.remoteId else { return }
        let key = post.id
        var page = threadPages[key] ?? KaPostsPageState()
        guard !page.isLoading else { return }
        guard reset || (page.hasMore && page.errorMessage == nil && !page.stalled) else { return }
        if reset { page.reset() }
        let epoch = page.epoch
        let cursor = reset ? nil : page.cursor
        page.isLoading = true
        page.errorMessage = nil
        threadPages[key] = page
        // Replies already on screen - the server can repeat rows across pages.
        let known: Set<String> = reset ? [] : Set(findPost(id: key)?.comments.compactMap(\.remoteId) ?? [])
        do {
            var seen = known
            let batch = try await KaPostsPaginator.collect(
                from: cursor,
                fetch: { (before: String?, limit: Int) -> (items: [KaPostsAPIClient.KPost], pagination: KaPostsAPIClient.KPagination?) in
                    let result = try await KaPostsAPIClient.shared.fetchReplies(postId: remoteId, limit: limit, before: before)
                    return (result.posts, result.pagination)
                },
                keep: { (posts: [KaPostsAPIClient.KPost]) -> [DraftPost] in
                    posts.compactMap { reply in
                        guard !seen.contains(reply.id),
                              let mapped = Self.mapRemotePost(reply),
                              !moderationStore.isHidden(mapped.posterAddress) else { return nil }
                        seen.insert(reply.id)
                        return mapped
                    }
                }
            )
            guard threadPages[key]?.epoch == epoch else { return }
            mutatePost(id: key) { target in
                // Local (session) replies always stay layered at the end of the thread.
                let localOnly = target.comments.filter { $0.remoteId == nil }
                let fetched = reset ? [] : target.comments.filter { $0.remoteId != nil }
                target.comments = fetched + batch.items + localOnly
            }
            var updated = threadPages[key] ?? KaPostsPageState()
            updated.apply(batch)
            threadPages[key] = updated
            resolveIdentities(for: batch.items)
        } catch {
            guard threadPages[key]?.epoch == epoch else { return }
            threadPages[key]?.isLoading = false
            threadPages[key]?.errorMessage = error.localizedDescription
            AppLog.log("[KaPosts] Replies page failed: %@", error.localizedDescription)
        }
    }

    /// Poster name resolution, in priority order: the alias YOU set for a saved contact wins,
    /// else the poster's KNS primary domain, else a shortened Kaspa address.
    private func posterDisplayName(_ address: String) -> String {
        guard !address.isEmpty else { return "Unknown" }
        // .kas is stripped from EVERY source, not just raw KNS lookups - contact aliases are
        // frequently auto-set to the KNS primary ("name.kas") and leaked the suffix through the
        // alias-wins branch.
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return Self.strippingKasSuffix(assigned)
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
    /// Mutates EVERY node with this id, in every tree and at any depth. Remote posts carry a
    /// DETERMINISTIC id (stableId from the txid), so the same post routinely exists as several
    /// nodes at once - e.g. a reply is both a top-level feed card in `remotePosts` AND a
    /// comment node inside its parent's thread. The old first-match-and-return version updated
    /// only whichever twin the search order hit first (usually the newer feed card, which
    /// sits BEFORE its parent in the newest-first feed), so a like/dislike/repost/bookmark
    /// made inside an open thread landed on the twin and the thread kept rendering the
    /// untouched node until it was closed and reopened.
    private func mutatePost(id: UUID, _ transform: (inout DraftPost) -> Void) {
        func mutate(_ list: inout [DraftPost]) {
            for index in list.indices {
                if list[index].id == id {
                    transform(&list[index])
                }
                mutate(&list[index].comments)
            }
        }
        mutate(&posts)
        mutate(&remotePosts)
        mutate(&posterProfilePosts)
        mutate(&posterProfileReplies)
        mutate(&myProfileRemotePosts)
        mutate(&myProfileRemoteReplies)
        mutate(&chainResolvedPosts)
        // The open thread's "Thread" section renders from threadChains COPIES (and segments
        // beyond the first exist ONLY there), so keep them in step too - otherwise an action
        // on a chain segment never renders while the thread stays open.
        for (rootId, chain) in threadChains {
            guard chain.contains(where: { $0.id == id }) else { continue }
            var updated = chain
            for index in updated.indices where updated[index].id == id {
                transform(&updated[index])
            }
            threadChains[rootId] = updated
        }
    }

    /// Recursive lookup mirroring mutatePost's coverage (mutatePost updates every twin, so any
    /// match renders the same state). Thread-chain copies are searched LAST: segments beyond
    /// the first live only in `threadChains`, and without that fallback opening one of them
    /// as its own thread came up empty.
    private func findPost(id: UUID) -> DraftPost? {
        func search(_ list: [DraftPost]) -> DraftPost? {
            for post in list {
                if post.id == id { return post }
                if let hit = search(post.comments) { return hit }
            }
            return nil
        }
        if let hit = search(posts) ?? search(remotePosts) ?? search(posterProfilePosts)
            ?? search(posterProfileReplies) ?? search(myProfileRemotePosts) ?? search(myProfileRemoteReplies)
            ?? search(chainResolvedPosts) {
            return hit
        }
        for chain in threadChains.values {
            if let hit = search(chain) { return hit }
        }
        return nil
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
        if let hit = search(posts) ?? search(remotePosts) ?? search(posterProfilePosts)
            ?? search(posterProfileReplies) ?? search(myProfileRemotePosts) ?? search(myProfileRemoteReplies)
            ?? search(chainResolvedPosts) {
            return hit
        }
        for chain in threadChains.values {
            if let hit = search(chain) { return hit }
        }
        return nil
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
    // @mention candidates: your 1:1 contacts that have a KNS domain AND a derivable pubkey. Only
    // these are mentionable (matches desktop getMentionCandidates).
    private func mentionCandidates() -> [(domain: String, pubkey: String)] {
        var out: [(domain: String, pubkey: String)] = []
        var seen = Set<String>()
        for contact in ContactsManager.shared.activeContacts {
            guard let raw = KNSService.shared.domainCache[contact.address]?.primaryDomain else { continue }
            let bare = KaPostsView.strippingKasSuffix(raw).lowercased()
            guard !bare.isEmpty, !seen.contains(bare),
                  let pubkey = KaPostsAPIClient.kapostPubkey(fromAddress: contact.address) else { continue }
            seen.insert(bare)
            out.append((bare, pubkey))
        }
        return out
    }

    /// Resolve the @domain tokens in a post to the pubkeys the indexer needs in mentioned_pubkeys.
    /// Tapped @mention: resolve the KNS domain to its owner and open that user's profile.
    /// Works for ANY KNS domain, contact or not (the pubkey derives from the owner address).
    /// Any sheet currently up (thread detail, etc.) is dismissed first - only one sheet can
    /// present at a time, so the profile waits for the dismissal animation.
    private func openMentionProfile(domain: String) {
        Task {
            guard let resolution = await KNSService.shared.resolveDomain(domain) else { return }
            let pubkey = KaPostsAPIClient.kapostPubkey(fromAddress: resolution.ownerAddress)
            let hadSheetUp = detailTarget != nil || quoteComposerTarget != nil
                || threadQuoteComposerTarget != nil || profileQuoteComposerTarget != nil
                || menuQuoteComposerTarget != nil || showComposer
            detailTarget = nil
            quoteComposerTarget = nil
            threadQuoteComposerTarget = nil
            profileQuoteComposerTarget = nil
            menuQuoteComposerTarget = nil
            showComposer = false
            DispatchQueue.main.asyncAfter(deadline: .now() + (hadSheetUp ? 0.4 : 0)) {
                profileTarget = PosterProfileTarget(address: resolution.ownerAddress, pubkey: pubkey)
            }
        }
    }

    /// The bare @domain tokens in `text`, in order, deduped.
    static func mentionDomains(in text: String) -> [String] {
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(
            pattern: "(^|[\\s(\\[{<\"'])@([a-z0-9-]+(?:\\.[a-z0-9-]+)*)",
            options: [.caseInsensitive]
        ) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            var domain = ns.substring(with: match.range(at: 2)).lowercased()
            if domain.hasSuffix(".kas") { domain = String(domain.dropLast(4)) }
            if !domain.isEmpty, seen.insert(domain).inserted { out.append(domain) }
        }
        return out
    }

    /// Resolves every @domain in `text` to a compressed pubkey for mentioned_pubkeys. Chatted
    /// contacts resolve from the local KNS cache; ANYONE else with a KNS domain resolves live
    /// through resolveDomain (owner address -> pubkey). Unresolvable tokens stay plain text.
    private func mentionedPubkeys(in text: String) async -> [String] {
        // Scanned on the RENDERED text, not the source. The @ token has to start a word, so
        // "**@alice.kas**" hides the mention behind the bold markers: the reader would see a
        // highlighted, tappable mention (the cell renders the same rendered text) while the
        // signed mentions array went out empty and @alice was never notified.
        let domains = Self.mentionDomains(in: KaPostsMarkdown.render(text).text)
        guard !domains.isEmpty else { return [] }
        var byDomain: [String: String] = [:]
        for candidate in mentionCandidates() { byDomain[candidate.domain] = candidate.pubkey }
        var found = Set<String>()
        var out: [String] = []
        for domain in domains {
            if let pubkey = byDomain[domain] {
                if found.insert(pubkey).inserted { out.append(pubkey) }
                continue
            }
            if let resolution = await KNSService.shared.resolveDomain(domain),
               let pubkey = KaPostsAPIClient.kapostPubkey(fromAddress: resolution.ownerAddress),
               found.insert(pubkey).inserted {
                out.append(pubkey)
            }
        }
        return out
    }

    /// Unposted work for an in-flight or failed thread, keyed by the root post's LOCAL id.
    /// `rootText` is non-nil until the root actually posts; `parentTxId` is the txid the next
    /// segment must chain to. Kept until every segment lands, so Retry RESUMES the chain from
    /// exactly where it failed instead of reposting only the root.
    struct ThreadRemainder {
        var rootText: String?
        var segments: [String]
        var parentTxId: String?
    }
    @State private var threadRemainders: [UUID: ThreadRemainder] = [:]

    /// X-style thread: the first segment becomes a top-level post, each following segment a
    /// reply to the PREVIOUS one. Threads submit sequentially right away (each segment needs
    /// the previous txid) - no 5s undo window; the optimistic root post carries the pending/
    /// sent/failed state for the whole chain.
    private func scheduleThread(_ segments: [String]) {
        guard let first = segments.first else { return }
        guard segments.count > 1 else {
            schedulePost(text: first)
            return
        }
        let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
        var rootPost = DraftPost(text: first, timestamp: Date(), posterAddress: myAddress)
        rootPost.posterPubkey = try? KaPostsAPIClient.shared.requesterPubkey()
        rootPost.deliveryStatus = .pending
        rootPost.isLocalThreadRoot = true
        let localId = rootPost.id
        posts.insert(rootPost, at: 0)
        threadRemainders[localId] = ThreadRemainder(rootText: first, segments: Array(segments.dropFirst()), parentTxId: nil)
        continueThread(localId: localId)
    }

    /// Sequential, RESUMABLE chain submitter. Consecutive payload txs spend each other's change
    /// before the node has indexed it, so every segment gets a settle delay plus a retry loop -
    /// and progress persists to `threadRemainders` after every landed segment, so a mid-chain
    /// failure retried later continues from the next unposted segment.
    private func continueThread(localId: UUID) {
        guard threadRemainders[localId] != nil else { return }
        mutatePost(id: localId) { $0.deliveryStatus = .pending }
        Task {
            do {
                let myPubkey = try? KaPostsAPIClient.shared.requesterPubkey()
                if let rootText = threadRemainders[localId]?.rootText {
                    let rootTxId = try await submitWithUtxoRetry {
                        try await KaPostsAPIClient.shared.submitPost(
                            text: rootText, mentionedPubkeys: await mentionedPubkeys(in: rootText)
                        )
                    }
                    mutatePost(id: localId) { $0.remoteId = rootTxId }
                    threadRemainders[localId]?.rootText = nil
                    threadRemainders[localId]?.parentTxId = rootTxId
                }
                while let remainder = threadRemainders[localId],
                      let segment = remainder.segments.first,
                      let parentTxId = remainder.parentTxId {
                    // Let the previous tx's change land in the node's UTXO index (~1s blocks).
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    let segmentMentions = await mentionedPubkeys(in: segment)
                    let txId = try await submitWithUtxoRetry {
                        try await KaPostsAPIClient.shared.submitReply(
                            text: segment, postId: parentTxId, parentAuthorPubkey: myPubkey,
                            mentionedPubkeys: segmentMentions
                        )
                    }
                    threadRemainders[localId]?.segments.removeFirst()
                    threadRemainders[localId]?.parentTxId = txId
                }
                threadRemainders[localId] = nil
                mutatePost(id: localId) { $0.deliveryStatus = .sent }
            } catch {
                mutatePost(id: localId) { $0.deliveryStatus = .failed }
                AppLog.log("[KaPosts] Thread submit failed (resumable): %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Thread reading (X-style "View thread")

    /// The author's own continuation chain for an opened root post, keyed by the root's local
    /// id: [segment2, segment3, ...]. Loaded by walking self-authored replies link by link.
    @State private var threadChains: [UUID: [DraftPost]] = [:]
    /// Probe bookkeeping that must NOT touch SwiftUI state: claims and negative results live in
    /// a plain reference box, so the write every NEW ROW makes as it scrolls in is invisible to
    /// the render loop. Keeping these in @State invalidated the entire feed twice per revealed
    /// post (once for the claim, once for the - usually negative - result), which is exactly the
    /// scroll jank the Android port hit with its observable probe-claim maps. Only a POSITIVE
    /// "this is a thread root" changes pixels, so only that lands in @State below.
    private final class ThreadProbeClaims {
        var claimed: Set<String> = []
    }
    /// @State holding a reference type: the box's identity is stable for the view's lifetime and
    /// mutating its contents never triggers a body pass.
    @State private var threadProbeClaims = ThreadProbeClaims()
    /// Confirmed thread roots (post txids) - the only probe outcome the UI shows.
    @State private var threadRootIds: Set<String> = []

    private func isThreadRoot(_ post: DraftPost) -> Bool {
        if post.isLocalThreadRoot { return true }
        guard let remoteId = post.remoteId else { return false }
        return threadRootIds.contains(remoteId)
    }

    /// Cheap feed probe, run once per commented post as its cell appears: fetch the first reply
    /// page and check for a self-authored reply (X's own "Show this thread" heuristic).
    private func probeThreadRoot(_ post: DraftPost) async {
        guard let remoteId = post.remoteId,
              !post.isLocalThreadRoot,
              commentCount(of: post) > 0,
              !threadProbeClaims.claimed.contains(remoteId) else { return }
        threadProbeClaims.claimed.insert(remoteId) // claim, so one post never probes twice
        guard let page = try? await KaPostsAPIClient.shared.fetchReplies(postId: remoteId, limit: 10, before: nil) else { return }
        if page.posts.contains(where: { reply in
            KaPostsAPIClient.kaspaAddress(fromPubkey: reply.userPublicKey) == post.posterAddress
        }) {
            threadRootIds.insert(remoteId)
        }
    }

    /// Walks the author's self-reply chain from an opened root: segment 2 comes from the
    /// already-loaded direct replies, each further segment from fetching the previous one's
    /// replies (a thread is root <- seg2 <- seg3 ... by the same author). Capped defensively.
    private func loadSelfThreadChain(rootId: UUID) async {
        guard let root = findPost(id: rootId), root.remoteId != nil else { return }
        var chain: [DraftPost] = []
        var current = root.comments
            .filter { $0.posterAddress == root.posterAddress && $0.remoteId != nil }
            .sorted { $0.timestamp < $1.timestamp }
            .first
        var hops = 0
        while let segment = current, hops < 25 {
            chain.append(segment)
            hops += 1
            guard let segmentRemoteId = segment.remoteId,
                  let page = try? await KaPostsAPIClient.shared.fetchReplies(postId: segmentRemoteId, limit: 25, before: nil) else { break }
            current = page.posts
                .compactMap { Self.mapRemotePost($0) }
                .filter { $0.posterAddress == root.posterAddress }
                .sorted { $0.timestamp < $1.timestamp }
                .first
        }
        threadChains[rootId] = chain
        if let remoteId = root.remoteId, !chain.isEmpty {
            threadProbeClaims.claimed.insert(remoteId)
            threadRootIds.insert(remoteId)
        }
    }

    /// The root's comments with thread segments removed - a thread's segment 2 IS a direct
    /// reply, but it belongs to the Thread section, not the Comments list.
    private func commentsExcludingThread(of post: DraftPost) -> [DraftPost] {
        let chainRemoteIds = Set((threadChains[post.id] ?? []).compactMap(\.remoteId))
        return visibleComments(of: post).filter { comment in
            guard let remoteId = comment.remoteId else { return true }
            return !chainRemoteIds.contains(remoteId)
        }
    }

    /// Retries an action tx a few times with settle delays - rapid sequential sends routinely
    /// hit "UTXO already spent / none spendable" until the node indexes the previous change.
    private func submitWithUtxoRetry(_ op: () async throws -> String) async throws -> String {
        var attempt = 0
        while true {
            do {
                return try await op()
            } catch {
                attempt += 1
                guard attempt <= 4 else { throw error }
                AppLog.log("[KaPosts] Thread segment retry %d: %@", attempt, error.localizedDescription)
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

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
                    let txId = try await KaPostsAPIClient.shared.submitPost(text: text, mentionedPubkeys: await mentionedPubkeys(in: text))
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
            // Only compose-style actions have an optimistic CARD to remove; a cancelled
            // like/dislike/repost simply never happens (their mutation fires post-countdown),
            // and a cancelled comment removes its optimistic reply from the thread.
            if toast.key.hasPrefix("post:") {
                posts.removeAll { $0.id == toast.postId }
            } else if toast.key.hasPrefix("comment:") {
                removeReply(withId: toast.postId)
            }
            undoToast = nil
        }
    }

    /// Removes an optimistic comment from whichever post's comment tree holds it —
    /// the same collections mutatePost() searches.
    /// The thread reply bar's formatting buttons. Same rules as the post composer's - see
    /// `KaPostComposerView.applyFormatting`.
    private func applyReplyFormatting(_ action: KaPostsMarkdown.ToolbarAction) {
        let edit = KaPostsMarkdown.apply(
            action,
            to: replyText,
            selectionStart: replySelection.lowerBound,
            selectionEnd: replySelection.upperBound
        )
        guard edit.text.count <= KaPostsView.postCharacterLimit else { return }
        replyText = edit.text
        // Deferred one runloop turn: the text has to reach the text view before a selection into
        // it means anything, otherwise this lands on the pre-edit string and is clamped away.
        DispatchQueue.main.async {
            replySelection = edit.selectionStart...edit.selectionEnd
        }
    }

    private func removeReply(withId id: UUID) {
        func strip(_ list: inout [DraftPost]) -> Bool {
            for index in list.indices {
                let before = list[index].comments.count
                list[index].comments.removeAll { $0.id == id }
                if list[index].comments.count != before { return true }
                if strip(&list[index].comments) { return true }
            }
            return false
        }
        if strip(&posts) { return }
        if strip(&remotePosts) { return }
        if strip(&posterProfilePosts) { return }
        if strip(&posterProfileReplies) { return }
        if strip(&myProfileRemotePosts) { return }
        _ = strip(&myProfileRemoteReplies)
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
        // Every interaction gets an always-visible undo TOAST (the in-icon countdown
        // alone could scroll out of view).
        let key = "like:\(post.id)"
        showUndoToast(key: key, postId: post.id, label: post.likedByMe ? "Removing like" : "Liking")
        scheduler.schedule(key: key) {
            clearUndoToast(key: key)
            performLike(post)
        }
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
        let key = "dislike:\(post.id)"
        showUndoToast(key: key, postId: post.id, label: post.dislikedByMe ? "Removing dislike" : "Disliking")
        scheduler.schedule(key: key) {
            clearUndoToast(key: key)
            performDislike(post)
        }
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

    /// X-style anchored repost menu actions (the cell shows the popover; this runs the choice).
    /// Same 5s undo toast + scheduler behavior as the old confirmation dialog.
    /// `level` says which hierarchy must own the quote composer sheet - see QuoteComposerLevel.
    private func handleRepostAction(_ post: DraftPost, _ action: KaPostRepostAction, level: QuoteComposerLevel = .feed) {
        switch action {
        case .repost:
            let key = "repost:\(post.id)"
            showUndoToast(key: key, postId: post.id, label: "Reposting")
            scheduler.schedule(key: key) {
                clearUndoToast(key: key)
                performRepost(target: post, text: nil, localQuoteId: nil)
            }
        case .removeRepost:
            let key = "repost:\(post.id)"
            showUndoToast(key: key, postId: post.id, label: "Removing repost")
            scheduler.schedule(key: key) {
                clearUndoToast(key: key)
                performUnrepost(post)
            }
        case .quote:
            switch level {
            case .feed: quoteComposerTarget = post
            case .profile: profileQuoteComposerTarget = post
            case .thread: threadQuoteComposerTarget = post
            case .menu: menuQuoteComposerTarget = post
            }
        }
    }

    /// The one quote composer, built once and hung off whichever hierarchy is on screen.
    private func quoteComposerSheet(for target: DraftPost) -> some View {
        KaPostComposerView(
            quotedPost: target,
            quotedDisplayName: posterDisplayName(target.posterAddress),
            quotedAvatarURL: knsService.profileCache[target.posterAddress]?.avatarURL
        ) { text in
            scheduleQuote(target: target, text: text)
        }
        // Single large detent: the composer auto-focuses, and on a medium sheet the keyboard
        // leaves no usable room for the editor (see the composer's own layout notes).
        .presentationDetents([.large])
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
        // A failed THREAD resumes its remaining chain (root included if it never posted)
        // instead of re-posting just the root text.
        if threadRemainders[post.id] != nil {
            continueThread(localId: post.id)
            return
        }
        mutatePost(id: post.id) { $0.deliveryStatus = .pending }
        Task {
            do {
                let txId: String
                if let parent = findParent(ofCommentId: post.id) {
                    guard let parentRemoteId = parent.remoteId else {
                        throw KaPostsAPIClient.KaPostsAPIError.badResponse
                    }
                    txId = try await KaPostsAPIClient.shared.submitReply(
                        text: post.text, postId: parentRemoteId, parentAuthorPubkey: parent.posterPubkey,
                        mentionedPubkeys: await mentionedPubkeys(in: post.text)
                    )
                } else {
                    txId = try await KaPostsAPIClient.shared.submitPost(text: post.text, mentionedPubkeys: await mentionedPubkeys(in: post.text))
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
            await openResolvedPost(post)
            return
        }
        await loadFeed()
        if let post = findPost(byRemoteId: txId) {
            await openResolvedPost(post)
            return
        }
        // Notification/deep-link targets are usually YOUR OWN content, which lives outside
        // the feed window - pull own posts+replies from the indexer and look again. (A true
        // get-post endpoint on the fork would make this exact; flagged in the handoff doc.)
        // Replies come from get-replies?user= - the indexer's get-posts never returns them.
        if let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() {
            await loadMyProfilePosts(pubkey: pubkey, reset: true)
            await loadMyProfileReplies(pubkey: pubkey, reset: true)
        }
        if let post = findPost(byRemoteId: txId) {
            await openResolvedPost(post)
            return
        }
        // Still unresolved: the txid is usually a notification's ACTING content — someone
        // ELSE's reply/quote/mentioning post, which neither the feed window nor the own-
        // content fetch above ever returns. The notification stream knows who wrote it,
        // so pull THAT author's posts+replies and look once more (falling back to the
        // parent conversation when the acting content itself still can't be loaded).
        if let n = try? await KaPostsAPIClient.shared.fetchNotifications(limit: 100).notifications
            .first(where: { $0.id == txId }) {
            await loadPosterProfilePosts(pubkey: n.userPublicKey, reset: true)
            await loadPosterProfileReplies(pubkey: n.userPublicKey, reset: true)
            if let post = findPost(byRemoteId: txId) {
                // For a reply notification the stream's contentId IS the parent - pass it
                // through in case the fetched mapping lost parentPostId.
                await openResolvedPost(post, parentRemoteIdHint: n.contentType == "reply" ? n.contentId : nil)
                return
            }
            if let parentId = n.contentId, !parentId.isEmpty, let parent = findPost(byRemoteId: parentId) {
                openDetail(parent)
                return
            }
        }
        // Last resort, and the one that always works: read the post off the transaction it was
        // published as. Everything above searches the indexer, which has no single-post lookup
        // (`get-post?id=` is still a NEEDED item in KAPOSTS_INDEXER.md), so a post outside the
        // feed window and outside the fetched profiles simply could not be found - that is what
        // "Post not found" always was. The chain has every post that ever existed.
        if let post = await chainPost(txId: txId) {
            await openResolvedPost(post)
            return
        }
        showActionToast("Post not found - it may be older than the current feed", txId: txId)
    }

    /// Builds a post from its own transaction, for the cases the indexer cannot answer.
    ///
    /// The payload carries the text, the author and (for a reply or a quote) what it points at;
    /// the transaction carries the time. Engagement counts are then filled from
    /// `get-post-engagement`, which works for ANY post id, so a post opened this way still shows
    /// real like/dislike/repost numbers and your own vote state rather than a row of zeros.
    private func chainPost(txId: String) async -> DraftPost? {
        guard let record = await KaPostChainReader.fetch(txId: txId),
              let address = KaPostsAPIClient.kaspaAddress(fromPubkey: record.authorPubkey) else { return nil }
        var post = DraftPost(
            text: record.message,
            timestamp: record.blockTimeMillis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? Date(),
            posterAddress: address
        )
        post.id = Self.stableId(forTxId: txId)
        post.remoteId = txId
        post.posterPubkey = record.authorPubkey
        // A quote's referenced id is the post it quotes, NOT a parent - only a reply has one.
        post.parentRemoteId = record.action == "reply" ? record.referencedId : nil
        if record.action == "quote", let quotedId = record.referencedId {
            // The quoted post's own text is a second chain read, and the thread view shows it
            // under this one; a quoted card with no text is worse than resolving it properly.
            if let quoted = await KaPostChainReader.fetch(txId: quotedId),
               let quotedAddress = KaPostsAPIClient.kaspaAddress(fromPubkey: quoted.authorPubkey) {
                post.quoted = DraftPost.QuotedRef(
                    remoteId: quotedId,
                    text: quoted.message,
                    posterAddress: quotedAddress,
                    timestamp: quoted.blockTimeMillis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                )
            }
        }
        // Returned rather than written through an `inout` across the `await`, which is exactly
        // the shape Swift's exclusivity rules refuse.
        if let engagement = await chainEngagement(txId: txId) {
            post.likes = engagement.likes
            post.dislikes = engagement.dislikes
            post.reposts = engagement.reposts
            post.likedByMe = engagement.likedByMe
            post.dislikedByMe = engagement.dislikedByMe
            post.repostedByMe = engagement.repostedByMe
        }
        // Held so the thread sheet can resolve the id it is about to be handed - see
        // `chainResolvedPosts`. Replacing an existing copy keeps the stable id pointing at one
        // node, so a like made in the thread does not land on a stale twin.
        chainResolvedPosts.removeAll { $0.remoteId == txId }
        chainResolvedPosts.append(post)
        return post
    }

    private struct ChainEngagement {
        var likes = 0
        var dislikes = 0
        var reposts = 0
        var likedByMe = false
        var dislikedByMe = false
        var repostedByMe = false
    }

    /// Counts the actor rows `get-post-engagement` returns, and spots our own among them. That
    /// endpoint works for any post id, unlike the notification stream (own content only), so a
    /// post opened off the chain still shows real numbers instead of a row of zeros.
    private func chainEngagement(txId: String) async -> ChainEngagement? {
        guard let entries = try? await KaPostsAPIClient.shared.fetchPostEngagement(postId: txId).entries else { return nil }
        let me = (try? KaPostsAPIClient.shared.requesterPubkey())?.lowercased()
        // A quote counts as a repost, matching how the feed's own counts are built.
        func isRepost(_ entry: KaPostsAPIClient.KEngagementEntry) -> Bool {
            entry.kind == "repost" || entry.kind == "quote"
        }
        var result = ChainEngagement()
        result.likes = entries.filter { $0.kind == "upvote" }.count
        result.dislikes = entries.filter { $0.kind == "downvote" }.count
        result.reposts = entries.filter(isRepost).count
        if let me {
            result.likedByMe = entries.contains { $0.kind == "upvote" && $0.actorPubkey.lowercased() == me }
            result.dislikedByMe = entries.contains { $0.kind == "downvote" && $0.actorPubkey.lowercased() == me }
            result.repostedByMe = entries.contains { isRepost($0) && $0.actorPubkey.lowercased() == me }
        }
        return result
    }

    /// A resolved deep-link/notification target that is itself a REPLY opens its PARENT's
    /// thread - the post that was replied to on top, the reply visible in the comments below
    /// and scrolled into view - instead of presenting the bare reply as a context-free thread
    /// root. The parent resolves from what's already loaded, then from own posts+replies (a
    /// reply notification always targets YOUR content); when it still can't be found, the
    /// reply's own thread opens as before.
    private func openResolvedPost(_ post: DraftPost, parentRemoteIdHint: String? = nil) async {
        guard let parentId = post.parentRemoteId ?? parentRemoteIdHint,
              !parentId.isEmpty, parentId != post.remoteId else {
            openDetail(post)
            return
        }
        if let parent = findPost(byRemoteId: parentId) {
            openDetail(parent, scrollToCommentRemoteId: post.remoteId)
            return
        }
        if let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() {
            await loadMyProfilePosts(pubkey: pubkey, reset: true)
            await loadMyProfileReplies(pubkey: pubkey, reset: true)
        }
        if let parent = findPost(byRemoteId: parentId) {
            openDetail(parent, scrollToCommentRemoteId: post.remoteId)
            return
        }
        // The parent is as unfindable through the indexer as the reply was - read it off its own
        // transaction rather than presenting the reply as a context-free thread root.
        if let parent = await chainPost(txId: parentId) {
            openDetail(parent, scrollToCommentRemoteId: post.remoteId)
            return
        }
        openDetail(post)
    }

    /// One place for the thread view's cells (root, comments, inline replies) - identical
    /// wiring everywhere; non-root cells navigate deeper on tap.
    private func threadCell(_ item: DraftPost, isRoot: Bool = false) -> some View {
        KaPostCellView(
            post: item,
            displayName: posterDisplayName(item.posterAddress),
            avatarURLString: knsService.profileCache[item.posterAddress]?.avatarURL,
            isFollowing: followStore.isFollowing(item.posterAddress),
            commentCount: commentCount(of: item),
            quotedDisplayName: item.quoted.map { posterDisplayName($0.posterAddress) },
            quotedAvatarURLString: quotedAvatarURL(item),
            onComment: isRoot ? nil : { openDetail(item) },
            onMute: { moderationStore.mute(item.posterAddress) },
            onBlock: { moderationStore.block(item.posterAddress) },
            onBookmark: { toggleBookmark(item) },
            onRetry: { retryPost(item) },
            // Presented from the thread sheet's OWN hierarchy - the top-level
            // $engagementTarget sheet can't present while the thread sheet is up.
            onViewEngagement: { threadEngagementTarget = item },
            onFollowToggle: { toggleFollowSubmitting(address: item.posterAddress, pubkey: item.posterPubkey) },
            onOpenProfile: { profileTarget = PosterProfileTarget(address: item.posterAddress, pubkey: item.posterPubkey) },
            onTip: { tip(item.posterAddress) },
            onLike: { toggleLike(item) },
            onDislike: { toggleDislike(item) },
            onRepost: { handleRepostTap(item) },
            // Quoting a post or one of its comments from in here presents from the thread
            // sheet's own hierarchy - the top-level $quoteComposerTarget sheet can't present
            // while the thread sheet is up, so the composer only showed after closing the post.
            onRepostAction: { handleRepostAction(item, $0, level: .thread) },
            onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
        )
        .equatable()
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
                        let replies = visibleComments(of: comment)
                        if replies.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Loading replies...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.leading, 16)
                        } else {
                            let triggerId = kaPostsPrefetchTriggerId(replies)
                            ForEach(replies) { reply in
                                threadCell(reply)
                                    .onAppear {
                                        guard reply.id == triggerId else { return }
                                        Task { await loadThreadReplies(for: comment, reset: false) }
                                    }
                            }
                            // Inline chains page endlessly too (long comment threads).
                            KaPostsLoadMoreFooter(state: threadPages[comment.id] ?? KaPostsPageState()) {
                                threadPages[comment.id, default: KaPostsPageState()].prepareManualRetry()
                                Task { await loadThreadReplies(for: comment, reset: false) }
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

    /// Expands a comment's reply chain inline, fetching its first page of replies from the
    /// indexer (the chain then pages endlessly like any other list).
    private func expandReplies(for comment: DraftPost) {
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = expandedCommentIds.insert(comment.id)
        }
        Task { await loadThreadReplies(for: comment, reset: true) }
    }

    private func openDetail(_ post: DraftPost, scrollToCommentRemoteId: String? = nil) {
        replyText = ""
        // nil on every normal open, so a stale pending scroll target from an earlier
        // notification landing can never yank a later thread around.
        pendingThreadScrollRemoteId = scrollToCommentRemoteId
        detailTarget = PostDetailTarget(id: post.id)
        // Remote post: pull its real reply thread from the indexer into the comments array,
        // then walk the author's own continuation so the Thread section can render.
        Task {
            await loadThreadReplies(for: post, reset: true)
            await loadSelfThreadChain(rootId: post.id)
        }
    }

    /// Same as `openDetail`, but opens the thread from inside the poster-profile sheet (drives
    /// `profileDetailTarget`, presented by the profile's own NavigationStack). Lets you comment on
    /// a person's posts/replies straight from their profile.
    private func openProfileDetail(_ post: DraftPost) {
        replyText = ""
        pendingThreadScrollRemoteId = nil
        profileDetailTarget = PostDetailTarget(id: post.id)
        Task {
            await loadThreadReplies(for: post, reset: true)
            await loadSelfThreadChain(rootId: post.id)
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
            // Fixed chrome (banner, avatar, name, counts, tab bar) with ONLY the feed paging
            // underneath - see the pager comment below.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // Banner (KNS profile banner when set, subtle gradient fallback).
                    ZStack(alignment: .bottomLeading) {
                        // Overlay, not a child: see the note on `KNSBannerImageView`. A
                        // fill-scaled banner reports a width far past the screen, and a vertical
                        // ScrollView takes its content's width rather than clamping it, so the
                        // whole profile stretched and looked zoomed in.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                            .overlay {
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
                        // Same as another user's profile, which has always shown this - your own
                        // was the one place your bio did not appear.
                        if let bio = myInfo?.profile?.bio,
                           !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(bio)
                                .font(.subheadline)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                    profileFeedTabBar(selection: $myProfileFeedTab)
                }

                // Finger-tracking pager between Posts and Replies - the same page-style
                // TabView machinery as the main feed tabs. Both pages stay alive, so the
                // swipe tracks the finger, each tab keeps its own scroll position, and a
                // switch never rebuilds the other tab's cells (the old end-of-drag
                // crossfade rebuilt both lists on every flip).
                TabView(selection: $myProfileFeedTab) {
                    profileFeedPage(
                        items: myPosts,
                        isLoading: isLoadingMyProfilePosts,
                        emptyIcon: "square.and.pencil",
                        emptyTitle: "No posts yet",
                        emptyBody: "Your posts will show up here.",
                        pageState: myPostsPage,
                        onLoadMore: { loadMoreMyProfile(.posts) },
                        onRetryLoadMore: {
                            myPostsPage.prepareManualRetry()
                            loadMoreMyProfile(.posts)
                        },
                        onRefresh: {
                            guard let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() else { return }
                            await loadMyProfilePosts(pubkey: pubkey, reset: true)
                        },
                        cell: { post in myProfileCell(post) }
                    )
                    .tag(ProfileFeedTab.posts)
                    profileFeedPage(
                        items: myProfileRemoteReplies,
                        isLoading: isLoadingMyProfilePosts,
                        emptyIcon: "bubble.left",
                        emptyTitle: "No replies yet",
                        emptyBody: "Replies you post will show up here.",
                        pageState: myRepliesPage,
                        onLoadMore: { loadMoreMyProfile(.replies) },
                        onRetryLoadMore: {
                            myRepliesPage.prepareManualRetry()
                            loadMoreMyProfile(.replies)
                        },
                        onRefresh: {
                            guard let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() else { return }
                            await loadMyProfileReplies(pubkey: pubkey, reset: true)
                        },
                        cell: { post in myProfileCell(post) }
                    )
                    .tag(ProfileFeedTab.replies)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .ignoresSafeArea(edges: .top)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { menuSheet = nil }
                }
            }
            // Comment thread for a post tapped here - presented from this profile's OWN
            // NavigationStack so it stacks above the profile sheet, exactly as the poster
            // profile does it (the top-level $detailTarget cannot present from inside a sheet).
            .sheet(item: $profileDetailTarget) { target in
                postDetailSheet(postId: target.id)
            }
            .sheet(item: $profileQuoteComposerTarget) { target in
                quoteComposerSheet(for: target)
            }
            .task(id: myAddress) {
                guard knsService.profileCache[myAddress] == nil, !myAddress.isEmpty else { return }
                _ = await knsService.fetchProfile(for: myAddress)
            }
            .task {
                guard let pubkey = try? KaPostsAPIClient.shared.requesterPubkey() else { return }
                isLoadingMyProfilePosts = myProfileRemotePosts.isEmpty
                async let detailsFetch = try? KaPostsAPIClient.shared.fetchUserDetails(pubkey: pubkey)
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
                // First page of each tab; both then page endlessly on scroll.
                await loadMyProfilePosts(pubkey: pubkey, reset: true)
                await loadMyProfileReplies(pubkey: pubkey, reset: true)
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
    /// Chat, live follower/following counts, bio, then their on-chain feed. Mirrors
    /// myProfileSheet; engagement runs through the same handlers (mutatePost covers this feed).
    private func posterProfileSheet(for target: PosterProfileTarget) -> some View {
        let address = target.address
        let info = knsService.profileCache[address]
        return NavigationStack {
            // Fixed chrome + finger-tracking Posts/Replies pager, mirroring myProfileSheet.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        // Overlay, not a child - see the matching note on the own-profile banner.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                            .overlay {
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
                        // Name with the actions in a single tidy row: name - Follow - Chat.
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
                                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.accentColor)
                        }
                        HStack(spacing: 16) {
                            Button {
                                posterProfileFollowListKind = .following
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(posterProfileFollowing ?? 0)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundColor(.primary)
                                    Text("Following")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                posterProfileFollowListKind = .followers
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(posterProfileFollowers ?? 0)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundColor(.primary)
                                    Text("Followers")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
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
                }

                // Finger-tracking Posts/Replies pager - see myProfileSheet's pager comment.
                TabView(selection: $posterProfileFeedTab) {
                    profileFeedPage(
                        items: posterProfilePosts,
                        isLoading: isLoadingPosterProfile,
                        emptyIcon: "square.and.pencil",
                        emptyTitle: "No posts yet",
                        emptyBody: nil,
                        pageState: posterPostsPage,
                        onLoadMore: { loadMorePosterProfile(.posts) },
                        onRetryLoadMore: {
                            posterPostsPage.prepareManualRetry()
                            loadMorePosterProfile(.posts)
                        },
                        onRefresh: {
                            guard let pubkey = posterProfilePubkey else { return }
                            await loadPosterProfilePosts(pubkey: pubkey, reset: true)
                        },
                        cell: { post in posterProfileCell(post) }
                    )
                    .tag(ProfileFeedTab.posts)
                    profileFeedPage(
                        items: posterProfileReplies,
                        isLoading: isLoadingPosterProfile,
                        emptyIcon: "bubble.left",
                        emptyTitle: "No replies yet",
                        emptyBody: nil,
                        pageState: posterRepliesPage,
                        onLoadMore: { loadMorePosterProfile(.replies) },
                        onRetryLoadMore: {
                            posterRepliesPage.prepareManualRetry()
                            loadMorePosterProfile(.replies)
                        },
                        onRefresh: {
                            guard let pubkey = posterProfilePubkey else { return }
                            await loadPosterProfileReplies(pubkey: pubkey, reset: true)
                        },
                        cell: { post in posterProfileCell(post) }
                    )
                    .tag(ProfileFeedTab.replies)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .ignoresSafeArea(edges: .top)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { profileTarget = nil }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { posterProfileFollowListKind != nil },
                set: { if !$0 { posterProfileFollowListKind = nil } }
            )) {
                if let kind = posterProfileFollowListKind {
                    KaPostsFollowListView(
                        kind: kind,
                        localFollowing: followStore.following,
                        targetPubkey: target.pubkey,
                        onToggleFollow: { address, pubkey in
                            toggleFollowSubmitting(address: address, pubkey: pubkey)
                        }
                    )
                }
            }
            // Comment thread for a post tapped on this profile — presented from the profile's OWN
            // NavigationStack so it stacks above the profile sheet (top-level $detailTarget can't).
            .sheet(item: $profileDetailTarget) { target in
                postDetailSheet(postId: target.id)
            }
            // Quote tapped on a post in this profile - presented from the profile's OWN
            // NavigationStack for the same reason as the thread sheet above it.
            .sheet(item: $profileQuoteComposerTarget) { target in
                quoteComposerSheet(for: target)
            }
            .task(id: target.id) {
                posterProfilePosts = []
                posterProfileReplies = []
                posterProfileFeedTab = .posts
                posterProfileFollowers = nil
                posterProfileFollowing = nil
                // A different profile means different cursors: bumping the epochs makes any
                // page still in flight for the previous poster discard its result.
                posterPostsPage.reset()
                posterRepliesPage.reset()
                posterProfilePubkey = target.pubkey
                if knsService.profileCache[address] == nil {
                    _ = await knsService.fetchProfile(for: address)
                }
                guard let pubkey = target.pubkey else { return }
                isLoadingPosterProfile = true
                async let detailsFetch = try? KaPostsAPIClient.shared.fetchUserDetails(pubkey: pubkey)
                if let details = await detailsFetch {
                    posterProfileFollowers = details.followersCount
                    posterProfileFollowing = details.followingCount
                }
                await loadPosterProfilePosts(pubkey: pubkey, reset: true)
                await loadPosterProfileReplies(pubkey: pubkey, reset: true)
                isLoadingPosterProfile = false
            }
        }
    }

    /// Jumps into (or creates) the 1:1 chat with this poster: ensures a contact exists
    /// (silently auto-added if new), ensures the conversation exists, then routes through the
    /// standard .openChat navigation. Slight delay so the profile sheet finishes dismissing.
    private func startChat(with address: String, paymentMode: Bool = false) {
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
                userInfo: ["contactAddress": contact.address, "paymentMode": paymentMode]
            )
        }
    }

    struct TipTarget: Identifiable {
        let address: String
        var id: String { address }
    }

    /// KaPosts "Tip" button: quick amount dialog, then a DIRECT send through
    /// ChatService.sendPayment - destination and funding follow the same Chats Payment
    /// Privacy rules as an in-chat payment (privacy pool address when available, else the
    /// poster's chatting address), and the payment bubble lands in the 1:1 chat.
    private func tip(_ address: String) {
        guard address != WalletManager.shared.currentWallet?.publicAddress else { return }
        tipTarget = TipTarget(address: address)
    }

    /// Underline tab bar for profile feeds (Posts | Replies), matching the app's other tab
    /// bars; a tap animates the pager across, and the pager's swipe moves the underline.
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

    /// One page of a profile pager (Posts or Replies): its own ScrollView + LazyVStack with the
    /// standard trigger-row prefetch and load-more footer. The pager keeps both pages alive, so
    /// each tab's scroll position survives swiping between them.
    private func profileFeedPage<Cell: View>(
        items: [DraftPost],
        isLoading: Bool,
        emptyIcon: String,
        emptyTitle: String,
        emptyBody: String?,
        pageState: KaPostsPageState,
        onLoadMore: @escaping () -> Void,
        onRetryLoadMore: @escaping () -> Void,
        onRefresh: @escaping () async -> Void,
        @ViewBuilder cell: @escaping (DraftPost) -> Cell
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty, isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: emptyIcon)
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(emptyTitle)
                            .font(.headline)
                        if let emptyBody {
                            Text(emptyBody)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    let triggerId = kaPostsPrefetchTriggerId(items)
                    ForEach(items) { post in
                        cell(post)
                            .onAppear {
                                guard post.id == triggerId else { return }
                                onLoadMore()
                            }
                        Divider()
                            .padding(.leading, 68)
                    }
                    KaPostsLoadMoreFooter(state: pageState, onLoadMore: onRetryLoadMore)
                }
            }
        }
        .refreshable { await onRefresh() }
    }

    /// The resolved KNS avatar for a post's QUOTED author, passed into the cell so the cell
    /// never has to observe KNSService itself (see KaPostCellView's observation notes).
    private func quotedAvatarURL(_ post: DraftPost) -> String? {
        guard let quoted = post.quoted, !quoted.posterAddress.isEmpty else { return nil }
        return knsService.profileCache[quoted.posterAddress]?.avatarURL
    }

    /// Cell wiring shared by both of MY profile's pager pages.
    private func myProfileCell(_ post: DraftPost) -> some View {
        KaPostCellView(
            post: post,
            displayName: posterDisplayName(post.posterAddress),
            avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
            isFollowing: followStore.isFollowing(post.posterAddress),
            commentCount: commentCount(of: post),
            quotedDisplayName: post.quoted.map { posterDisplayName($0.posterAddress) },
            quotedAvatarURLString: quotedAvatarURL(post),
            // Was nil, which made every post and reply on your OWN profile the one place you
            // could not open its thread - tapping did nothing while the same card is fully
            // interactive on the feed and on other people's profiles.
            onComment: { openProfileDetail(post) },
            onMute: { moderationStore.mute(post.posterAddress) },
            onBlock: { moderationStore.block(post.posterAddress) },
            onBookmark: { toggleBookmark(post) },
            onRetry: { retryPost(post) },
            onViewEngagement: { engagementTarget = post },
            onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
            onOpenProfile: {},
            onTip: { tip(post.posterAddress) },
            onLike: { toggleLike(post) },
            onDislike: { toggleDislike(post) },
            onRepost: { handleRepostTap(post) },
            // My-profile cell: this profile lives inside the side-menu sheet (a level
            // ABOVE feedLayer), so the composer has to present from that sheet.
            onRepostAction: { handleRepostAction(post, $0, level: .menu) },
            onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
        )
        .equatable()
    }

    /// Cell wiring shared by both of a tapped POSTER profile's pager pages.
    private func posterProfileCell(_ post: DraftPost) -> some View {
        KaPostCellView(
            post: post,
            displayName: posterDisplayName(post.posterAddress),
            avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
            isFollowing: followStore.isFollowing(post.posterAddress),
            commentCount: commentCount(of: post),
            quotedDisplayName: post.quoted.map { posterDisplayName($0.posterAddress) },
            quotedAvatarURLString: quotedAvatarURL(post),
            onComment: { openProfileDetail(post) },
            onMute: { moderationStore.mute(post.posterAddress) },
            onBlock: { moderationStore.block(post.posterAddress) },
            onBookmark: { toggleBookmark(post) },
            onRetry: nil,
            onViewEngagement: { engagementTarget = post },
            onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
            onOpenProfile: {},
            onTip: { tip(post.posterAddress) },
            onLike: { toggleLike(post) },
            onDislike: { toggleDislike(post) },
            onRepost: { handleRepostTap(post) },
            // Poster profile is itself a sheet presented by feedLayer, so feedLayer cannot
            // put the composer up on top of it - it presents from the profile instead.
            onRepostAction: { handleRepostAction(post, $0, level: .profile) },
            onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
        )
        .equatable()
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
                                    quotedDisplayName: post.quoted.map { posterDisplayName($0.posterAddress) },
                                    quotedAvatarURLString: quotedAvatarURL(post),
                                    onComment: nil,
                                    onMute: { moderationStore.mute(post.posterAddress) },
                                    onBlock: { moderationStore.block(post.posterAddress) },
                                    onBookmark: { toggleBookmark(post) },
                                    onRetry: { retryPost(post) },
                                    onViewEngagement: { engagementTarget = post },
                                    onFollowToggle: { toggleFollowSubmitting(address: post.posterAddress, pubkey: post.posterPubkey) },
                                    onOpenProfile: {},
                                    onTip: { tip(post.posterAddress) },
                            onLike: { toggleLike(post) },
                                    onDislike: { toggleDislike(post) },
                                    onRepost: { handleRepostTap(post) },
                                    // Bookmarks lives inside the side-menu sheet - same rule.
                                    onRepostAction: { handleRepostAction(post, $0, level: .menu) },
                                    onOpenQuoted: { txId in Task { await openSharedPost(txId: txId) } }
                                )
                                .equatable()
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
                    ScrollViewReader { scrollProxy in
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

                            // X-style thread reading: the author's own continuation renders as
                            // a connected, ordered section right under the root - separate from
                            // other people's comments below.
                            if let chain = threadChains[post.id], !chain.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "text.append")
                                        .font(.caption.weight(.semibold))
                                    Text("Thread · \(chain.count + 1) posts")
                                        .font(.subheadline.weight(.bold))
                                    Spacer()
                                }
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)

                                ForEach(chain) { segment in
                                    HStack(alignment: .top, spacing: 0) {
                                        // Connector rail, X-style: visually chains the segments.
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(Color.accentColor.opacity(0.35))
                                            .frame(width: 2)
                                            .padding(.leading, 16)
                                            .padding(.vertical, 2)
                                        threadCell(segment)
                                    }
                                }
                                Divider()
                            }

                            let comments = commentsExcludingThread(of: post)
                            HStack {
                                Text(comments.isEmpty ? "Comments" : "Comments (\(comments.count))")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)

                            if comments.isEmpty {
                                Text("No comments yet - be the first to reply.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 20)
                            } else {
                                let triggerId = kaPostsPrefetchTriggerId(comments)
                                ForEach(comments) { comment in
                                    threadCell(comment)
                                        // Scroll anchor for the reply-notification landing.
                                        .id(comment.remoteId ?? comment.id.uuidString)
                                        .onAppear {
                                            guard comment.id == triggerId else { return }
                                            Task { await loadThreadReplies(for: post, reset: false) }
                                        }
                                    threadRepliesSection(for: comment)
                                    Divider()
                                        .padding(.leading, 68)
                                }
                            }
                            // Endless scroll for the thread's own comment list.
                            KaPostsLoadMoreFooter(state: threadPages[postId] ?? KaPostsPageState()) {
                                threadPages[postId, default: KaPostsPageState()].prepareManualRetry()
                                Task { await loadThreadReplies(for: post, reset: false) }
                            }
                        }
                    }
                    // Reply-notification landing: this thread is the PARENT of the reply that
                    // was tapped - once the comment list actually contains that reply, bring
                    // it into view (openDetail's reset fetch changes the id list, firing this).
                    .onChange(of: commentsExcludingThread(of: post).map { $0.remoteId ?? "" }) { ids in
                        guard let target = pendingThreadScrollRemoteId, ids.contains(target) else { return }
                        pendingThreadScrollRemoteId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                scrollProxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    // Same landing when the reply was already loaded before the sheet opened
                    // (so the reset fetch changes nothing and onChange never fires).
                    .onAppear {
                        guard let target = pendingThreadScrollRemoteId,
                              commentsExcludingThread(of: post).contains(where: { $0.remoteId == target }) else { return }
                        pendingThreadScrollRemoteId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                scrollProxy.scrollTo(target, anchor: .center)
                            }
                        }
                    }
                    }
                    Divider()
                    // @mention autocomplete for COMMENTS - the same suggestion list as the post
                    // composer, rendered above the input so the keyboard can never hide it.
                    KaPostMentionSuggestionBar(text: $replyText, selection: $replySelection)
                    // Replies are posts, so they get the same formatting bar - only while the
                    // reply bar has focus, since with the keyboard down it would be a row of
                    // icons with nothing to act on.
                    if isReplyFocused {
                        MarkdownFormattingToolbar(onAction: applyReplyFormatting)
                        Divider().opacity(0.4)
                    }
                    // X's "Post your reply" bar - text only, same rule as posts.
                    HStack(spacing: 10) {
                        MarkdownComposerField(
                            text: $replyText,
                            selection: $replySelection,
                            isFocused: $isReplyFocused,
                            placeholder: "Post your reply",
                            // Roughly four lines, matching the lineLimit(1...4) this replaced: past
                            // that the field scrolls instead of pushing the thread off screen.
                            maxHeight: 92
                        )
                            .onChange(of: replyText) { newValue in
                                if newValue.count > KaPostsView.postCharacterLimit {
                                    replyText = String(newValue.prefix(KaPostsView.postCharacterLimit))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            // Fixed-radius rectangle, NOT a Capsule: a capsule's corner radius is
                            // half its height, so on a grown multi-line field the end-caps curve
                            // into the text area and the outer lines escape the bubble.
                            .background(RoundedRectangle(cornerRadius: 18).fill(Color.secondary.opacity(0.12)))
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
                            // On-chain reply when the parent post lives on K — behind the same
                            // 5s undo TOAST as every other interaction: the optimistic comment
                            // shows immediately, the submit fires when the countdown ends, and
                            // Undo removes it before anything hits the network.
                            if let parentRemoteId = post.remoteId {
                                let parentAuthor = post.posterPubkey
                                let key = "comment:\(localReplyId)"
                                showUndoToast(key: key, postId: localReplyId, label: "Posting comment")
                                scheduler.schedule(key: key) {
                                    clearUndoToast(key: key)
                                    Task {
                                        do {
                                            // @mentions work in comments exactly like in posts:
                                            // resolved client-side to pubkeys.
                                            let txId = try await KaPostsAPIClient.shared.submitReply(
                                                text: trimmed, postId: parentRemoteId, parentAuthorPubkey: parentAuthor,
                                                mentionedPubkeys: await mentionedPubkeys(in: trimmed)
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
                // The main view's toast layer sits BEHIND this sheet — without a copy in here,
                // a like/repost/reply made from an open thread showed no undo toast and no
                // network confirmation, reading as dead buttons for the whole 5s undo window.
                .overlay(alignment: .bottom) {
                    toastOverlay
                        .padding(.bottom, 70)
                }
                .sheet(isPresented: $showReplyFundingSheet) {
                    // Nested sheet on the thread sheet's own content - MainTabView's gift
                    // listener can't present while this detail sheet is up, so the funding
                    // card (and its Claim Gift flow) presents from in here instead.
                    ZeroBalanceFundingSheetView()
                }
                .sheet(item: $threadEngagementTarget) { target in
                    // Post Activity from INSIDE the open thread - same nested-sheet rule as
                    // the funding card above: feedLayer's $engagementTarget sheet can't
                    // present while this thread sheet is up, so it presents from in here.
                    KaPostEngagementView(post: target)
                }
                .sheet(item: $threadQuoteComposerTarget) { target in
                    // Quote on the open post OR on one of its comments. Exactly the same
                    // nested-sheet rule: feedLayer's $quoteComposerTarget sheet cannot come
                    // up while this thread sheet is, which is why the composer used to appear
                    // only after the post was dismissed.
                    quoteComposerSheet(for: target)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // Clear whichever target presented this thread (feed = detailTarget,
                        // profile = profileDetailTarget); nil-ing the other is a harmless no-op.
                        Button("Done") { detailTarget = nil; profileDetailTarget = nil }
                    }
                }
            } else {
                // An id this view cannot resolve used to render an empty NavigationStack - a
                // blank sheet with no way to tell whether it was loading, broken, or closed
                // wrong. It should not be reachable (every opener registers its post first), so
                // this says something rather than nothing if one ever slips through.
                VStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("This post could not be loaded")
                        .font(.headline)
                    Text("It may have been removed, or the network may be unreachable.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { detailTarget = nil; profileDetailTarget = nil }
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
    /// Resolved display bits for the QUOTED post's author, passed in by the parent (which
    /// observes KNSService) instead of observed here - see the observation note on `body`.
    var quotedDisplayName: String? = nil
    var quotedAvatarURLString: String? = nil
    /// nil hides the comment affordance entirely (comment cells - no nested threads).
    let onComment: (() -> Void)?
    let onMute: () -> Void
    let onBlock: () -> Void
    let onBookmark: () -> Void
    var onRetry: (() -> Void)? = nil
    var onViewEngagement: (() -> Void)? = nil
    let onFollowToggle: () -> Void
    let onOpenProfile: () -> Void
    /// "Tip": opens the 1:1 chat with the poster in KAS-send mode. nil (or your own post) hides it.
    var onTip: (() -> Void)? = nil
    let onLike: () -> Void
    let onDislike: () -> Void
    let onRepost: () -> Void
    /// X-style repost menu: when set (and the post is on-chain), tapping repost opens a small
    /// anchored popover with Repost/Quote rows instead of the old confirmation dialog.
    var onRepostAction: ((KaPostRepostAction) -> Void)? = nil
    /// Tapping the quoted-post embed opens that post's own thread (comments and all).
    var onOpenQuoted: ((String) -> Void)? = nil

    private var translationKey: String {
        PostTranslationService.translationKey(for: post.remoteId, localId: post.id)
    }

    /// The post text as it should render: the translation once one exists, the original until
    /// then and whenever the reader asks for it back.
    private var displayedText: String {
        translation.displayText(for: translationKey, original: post.text)
    }

    /// Long enough that the feed should fold it behind "Show more" (X-style ~280-char threshold,
    /// or a wall of newlines). Measured on what is actually rendered, so a translation that runs
    /// longer than its original still folds.
    private var isLongPost: Bool {
        displayedText.count > 280 || displayedText.filter { $0 == "\n" }.count >= 8
    }

    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.openURL) private var openURL
    /// Observed for the 5s undo countdown pills. Deadlines only change when the user arms or
    /// cancels an action - never while scrolling - so this subscription is cheap.
    ///
    /// KNSService is deliberately NOT observed here (it used to be): its whole profileCache
    /// dictionary is one @Published property, so every avatar/profile arriving anywhere
    /// re-rendered EVERY visible cell. The parent observes it once and passes the resolved
    /// name/avatar strings in; combined with the Equatable conformance below, a cache update
    /// re-renders only the cells whose own inputs actually changed.
    @ObservedObject private var scheduler = KaPostsActionScheduler.shared
    /// Observed for the Translate affordance. Like `scheduler`, this only changes when the user
    /// acts (taps Translate, or flips back to the original) - never while scrolling.
    @ObservedObject private var translation = PostTranslationService.shared

    /// Your own post: no follow affordance (you can't follow yourself).
    private var isOwnPost: Bool {
        post.posterAddress == WalletManager.shared.currentWallet?.publicAddress
    }

    /// The sent-checkmark auto-hides 60s after the post's timestamp (mirrors the reaction
    /// checkmark's timed window); pending/failed always show.
    @State private var sentCheckExpired = false

    /// URL tapped in the post text - drives the Copy / Open option menu.
    @State private var tappedLinkURL: URL?
    /// X-style anchored Repost/Quote menu over the repost button.
    @State private var showRepostMenu = false
    /// The PARENT's openURL handler, captured from the environment ABOVE this cell's own
    /// override - @mention taps forward straight to it (profile open), never the URL dialog.
    @Environment(\.openURL) private var parentOpenURL

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
                                Label("Post Activity", systemImage: "globe")
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
                Text(Self.linkified(displayedText))
                    .font(.body)
                    .foregroundColor(.primary)
                    .tint(.accentColor)
                    .environment(\.openURL, OpenURLAction { url in
                        // @mention taps open the profile directly - the Copy/Open dialog
                        // (showing a raw kachat-mention:// string) is only for real URLs.
                        if url.scheme == "kachat-mention" {
                            parentOpenURL(url)
                            return .handled
                        }
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
                translateAffordance

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
                    if scheduler.deadlines["dislike:\(post.id)"] != nil {
                        countdownButton(key: "dislike:\(post.id)")
                    } else {
                        engagementButton(
                            icon: post.dislikedByMe ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                            count: post.dislikes,
                            tint: post.dislikedByMe ? .orange : .secondary,
                            action: onDislike
                        )
                    }
                    if scheduler.deadlines["repost:\(post.id)"] != nil {
                        countdownButton(key: "repost:\(post.id)")
                    } else {
                        engagementButton(
                            icon: "arrow.2.squarepath",
                            count: post.reposts,
                            tint: post.repostedByMe ? .accentColor : .secondary,
                            action: {
                                // X-style: a compact anchored menu over the tapped button.
                                if onRepostAction != nil, post.remoteId != nil, post.posterPubkey != nil {
                                    showRepostMenu = true
                                } else {
                                    onRepost()
                                }
                            }
                        )
                        .popover(isPresented: $showRepostMenu, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    showRepostMenu = false
                                    onRepostAction?(post.repostedByMe ? .removeRepost : .repost)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.2.squarepath")
                                        Text(post.repostedByMe ? "Remove Repost" : "Repost")
                                            .fontWeight(.semibold)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(post.repostedByMe ? .red : .primary)
                                Divider()
                                Button {
                                    showRepostMenu = false
                                    onRepostAction?(.quote)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "pencil.line")
                                        Text("Quote")
                                            .fontWeight(.semibold)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(width: 190)
                            // A REAL anchored popover bubble on iPhone (not a bottom sheet).
                            .modifier(CompactPopoverAdaptation())
                        }
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
                    // Tip: opens the 1:1 chat with the poster already in KAS-send mode. Hidden on
                    // your own posts (you can't tip yourself).
                    if let onTip, !isOwnPost {
                        Button {
                            Haptics.impact(.light)
                            onTip()
                        } label: {
                            HStack(spacing: 3) {
                                Image("KaspaLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 16, height: 16)
                                Text("Tip")
                                    .lineLimit(1)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.accentColor)
                            // Never let the row squeeze "Tip" into vertical letters - the label
                            // keeps its intrinsic width and wins the compression fight.
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .layoutPriority(1)
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
        if scheduler.deadlines["like:\(post.id)"] != nil {
            return AnyView(countdownButton(key: "like:\(post.id)"))
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

    /// Compiled ONCE - this used to be built inline in the linkify pass, i.e. a fresh
    /// NSRegularExpression compile per cell per render.
    private static let mentionRegex = try? NSRegularExpression(
        pattern: "(^|[\\s(\\[{<\"'])@([a-z0-9-]+(?:\\.[a-z0-9-]+)*)",
        options: [.caseInsensitive]
    )

    /// AttributedString is a value type, so cache entries ride in a class box for NSCache.
    private final class LinkifiedBox {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    /// Linkified output cached by post text: data detection + mention matching over up to 25k
    /// characters is far too expensive to redo on every body pass while scrolling. Keyed by
    /// content, so edits/refreshes that keep the text hit the cache.
    private static let linkifiedCache: NSCache<NSString, LinkifiedBox> = {
        let cache = NSCache<NSString, LinkifiedBox>()
        cache.countLimit = 400
        return cache
    }()

    /// Post text ready to render: KaChat markdown applied (see `KaPostsMarkdown`), detected URLs
    /// and @mentions made tappable. Cached by SOURCE content - see `linkifiedCache`.
    static func linkified(_ text: String) -> AttributedString {
        let key = text as NSString
        if let cached = linkifiedCache.object(forKey: key) { return cached.value }
        // Markdown first: it decides what the text actually READS as (markers gone, bullets and
        // numbers materialised), and the linkifier's offsets have to be into that string, not the
        // source. Its spans are then layered on top.
        let rendered = KaPostsMarkdown.render(text)
        var built = buildLinkified(rendered.text)
        applyMarkdownSpans(
            rendered.spans,
            to: &built,
            protecting: Self.mentionCharacterRanges(in: rendered.text)
        )
        linkifiedCache.setObject(LinkifiedBox(built), forKey: key)
        return built
    }

    /// Character ranges of the @mention tokens in already-rendered text.
    ///
    /// A mention is an identity, not prose: it always looks the same so it stays recognisable at a
    /// glance, and formatting never applies to it. `**@alice.kas** ships it` bolds "ships it" and
    /// leaves the mention alone.
    static func mentionCharacterRanges(in text: String) -> [Range<Int>] {
        guard let mentionRegex else { return [] }
        let ns = text as NSString
        var out: [Range<Int>] = []
        for match in mentionRegex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let domainRange = match.range(at: 2)
            let tokenStart = domainRange.location - 1 // include the '@'
            guard tokenStart >= 0,
                  let stringRange = Range(
                      NSRange(location: tokenStart, length: domainRange.length + 1),
                      in: text
                  ) else { continue }
            let start = text.distance(from: text.startIndex, to: stringRange.lowerBound)
            let end = text.distance(from: text.startIndex, to: stringRange.upperBound)
            out.append(start..<end)
        }
        return out
    }

    /// A quoted post's text for a preview card: markdown styling applied, but nothing tappable.
    ///
    /// Without this the card showed the raw `**markers**` the author typed. Links are deliberately
    /// left inert - the card is itself a button through to the quoted post, and a tappable link
    /// inside it would compete with that.
    static func markdownPreview(_ text: String) -> AttributedString {
        let rendered = KaPostsMarkdown.render(text)
        var attributed = AttributedString(rendered.text)
        guard rendered.hasFormatting else { return attributed }
        applyMarkdownSpans(
            rendered.spans,
            to: &attributed,
            includeLinks: false,
            protecting: Self.mentionCharacterRanges(in: rendered.text)
        )
        return attributed
    }

    /// Layers markdown styling over the already-linkified string.
    ///
    /// An explicit `[label](url)` link wins over whatever the URL detector made of the same
    /// characters, since the author named that target deliberately.
    private static func applyMarkdownSpans(
        _ spans: [KaPostsMarkdown.Span],
        to attributed: inout AttributedString,
        includeLinks: Bool = true,
        protecting protectedRanges: [Range<Int>] = []
    ) {
        let total = attributed.characters.count
        for span in spans {
            guard span.start < span.end, span.end <= total else { continue }
            // A span crossing a mention is applied to the pieces either side of it, never over it.
            for piece in Self.subtract(protectedRanges, from: span.start..<span.end) {
                applyStyle(span.style, over: piece, to: &attributed, includeLinks: includeLinks)
            }
        }
    }

    /// `range` minus every protected range, in order. Returns `[range]` when nothing overlaps,
    /// which is the case for the overwhelming majority of posts.
    private static func subtract(_ protectedRanges: [Range<Int>], from range: Range<Int>) -> [Range<Int>] {
        let overlapping = protectedRanges
            .filter { $0.lowerBound < range.upperBound && $0.upperBound > range.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !overlapping.isEmpty else { return [range] }
        var out: [Range<Int>] = []
        var cursor = range.lowerBound
        for blocked in overlapping {
            if blocked.lowerBound > cursor {
                out.append(cursor..<blocked.lowerBound)
            }
            cursor = max(cursor, blocked.upperBound)
        }
        if cursor < range.upperBound {
            out.append(cursor..<range.upperBound)
        }
        return out
    }

    private static func applyStyle(
        _ style: KaPostsMarkdown.Style,
        over range: Range<Int>,
        to attributed: inout AttributedString,
        includeLinks: Bool
    ) {
        let total = attributed.characters.count
        guard range.lowerBound < range.upperBound, range.upperBound <= total else { return }
        let start = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
        let end = attributed.index(start, offsetByCharacters: range.count)

        var font: Font = style.subtext ? .footnote : .body
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        attributed[start..<end].font = font

        if style.subtext {
            attributed[start..<end].foregroundColor = .secondary
        }
        if style.underline {
            attributed[start..<end].underlineStyle = .single
        }
        if style.strikethrough {
            attributed[start..<end].strikethroughStyle = .single
        }
        if let link = style.link {
            if includeLinks { attributed[start..<end].link = link }
            attributed[start..<end].foregroundColor = .accentColor
            attributed[start..<end].underlineStyle = .single
        }
    }

    private static func buildLinkified(_ text: String) -> AttributedString {
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
        // Highlight @mentions (accent-coloured) and make them TAPPABLE: each carries a
        // kachat-mention:// link that KaPostsView's OpenURLAction resolves to the mentioned
        // user's profile (any KNS domain, contact or not).
        if let mentionRegex {
            for match in mentionRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
                let domainRange = match.range(at: 2)
                let tokenStart = domainRange.location - 1 // include the '@'
                let tokenLength = domainRange.length + 1
                guard tokenStart >= 0,
                      let stringRange = Range(NSRange(location: tokenStart, length: tokenLength), in: text) else { continue }
                var domain = nsText.substring(with: domainRange).lowercased()
                if domain.hasSuffix(".kas") { domain = String(domain.dropLast(4)) }
                let startOffset = text.distance(from: text.startIndex, to: stringRange.lowerBound)
                let length = text.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
                let start = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
                let end = attributed.index(start, offsetByCharacters: length)
                attributed[start..<end].foregroundColor = .accentColor
                if let url = URL(string: "kachat-mention://\(domain)") {
                    attributed[start..<end].link = url
                }
            }
        }
        return attributed
    }

    /// Prefers the parent-resolved name; the fallback reads shared services WITHOUT observing
    /// them (plain singleton reads create no subscription).
    private func resolvedQuotedName(_ address: String) -> String {
        if let quotedDisplayName { return quotedDisplayName }
        guard !address.isEmpty else { return "Unknown" }
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.strippingKasSuffix(assigned)
        }
        if let domain = KNSService.shared.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    private func quotedEmbedCard(_ quoted: KaPostsView.DraftPost.QuotedRef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KNSAvatarView(
                    avatarURLString: quotedAvatarURLString,
                    fallbackText: resolvedQuotedName(quoted.posterAddress),
                    size: 20,
                    contactAddress: quoted.posterAddress
                )
                Text(resolvedQuotedName(quoted.posterAddress))
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                if let timestamp = quoted.timestamp {
                    Text(relativeTime(timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(KaPostCellView.markdownPreview(quoted.text))
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
                  KNSService.shared.profileCache[quoted.posterAddress] == nil else { return }
            _ = await KNSService.shared.fetchProfile(for: quoted.posterAddress)
        }
    }

    /// Takes the icon's place while the action is held: it hasn't gone to the network yet, so
    /// tapping cancels it.
    ///
    /// Deliberately NO seconds here. The ticking number belongs in the undo toast, which is the
    /// one place it can be read without hunting for the row it came from; on the icon it turned
    /// a static engagement row into several digits counting down at once, and re-rendered the
    /// cell four times a second while it did. The row just says "you can still take this back".
    private func countdownButton(key: String) -> some View {
        Button {
            Haptics.impact(.light)
            KaPostsActionScheduler.shared.cancel(key: key)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.caption2.weight(.bold))
                .foregroundColor(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 1))
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

    /// X-style translate link under the post text. Absent unless the post is confidently in
    /// another language (and the OS can translate at all), so ordinary same-language feeds look
    /// exactly as they did.
    @ViewBuilder
    private var translateAffordance: some View {
        switch translation.state(for: translationKey) {
        case .none:
            if PostTranslationService.canOfferTranslation(for: post.text) {
                translateLink("Translate post") {
                    translation.translate(key: translationKey, text: post.text, postId: post.remoteId)
                }
            }
        case .translating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Translating...")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 2)
        case .translated(_, let sourceName):
            if translation.isShowingOriginal(translationKey) {
                translateLink("Show translation") {
                    translation.showTranslation(key: translationKey)
                }
            } else {
                HStack(spacing: 4) {
                    Text("Translated from \(sourceName)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("-")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        translation.showOriginal(key: translationKey)
                    } label: {
                        Text("Show original")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        case .failed:
            // Almost always a dropped connection, so this stays a live button rather than dead
            // text: tapping again once there is a network is the fix.
            translateLink("Translation unavailable - try again") {
                translation.translate(key: translationKey, text: post.text, postId: post.remoteId)
            }
        }
    }

    private func translateLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
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

/// Content-based render skipping (used via `.equatable()` at the list call sites): the cell's
/// ~15 closure parameters defeat SwiftUI's automatic field comparison, so without this every
/// parent body pass re-ran every visible cell's body. Compare the fields that actually change
/// pixels; for the optional affordances only PRESENCE matters (nil hides the control).
extension KaPostCellView: Equatable {
    static func == (lhs: KaPostCellView, rhs: KaPostCellView) -> Bool {
        lhs.post == rhs.post &&
        lhs.displayName == rhs.displayName &&
        lhs.avatarURLString == rhs.avatarURLString &&
        lhs.isFollowing == rhs.isFollowing &&
        lhs.commentCount == rhs.commentCount &&
        lhs.truncatesLongText == rhs.truncatesLongText &&
        lhs.quotedDisplayName == rhs.quotedDisplayName &&
        lhs.quotedAvatarURLString == rhs.quotedAvatarURLString &&
        (lhs.onComment == nil) == (rhs.onComment == nil) &&
        (lhs.onRetry == nil) == (rhs.onRetry == nil) &&
        (lhs.onViewEngagement == nil) == (rhs.onViewEngagement == nil) &&
        (lhs.onTip == nil) == (rhs.onTip == nil) &&
        (lhs.onRepostAction == nil) == (rhs.onRepostAction == nil) &&
        (lhs.onOpenQuoted == nil) == (rhs.onOpenQuoted == nil)
    }
}

// MARK: - Quick tip

/// Quick tip sheet, styled to match the app's Send Kaspa UI (WithdrawKaspaView's Form
/// language: fixed recipient row, KaspaLogo/fiat amount toggle with conversion + Max, an
/// Available footer, and a Network Fee row). The send itself goes through
/// `ChatService.sendPayment`, so the destination and funding follow the exact same Chats
/// Payment Privacy rules as an in-chat payment (privacy on + pool data -> a fresh private pool
/// address; otherwise the poster's public chatting address), and the payment bubble still lands
/// in the 1:1 conversation with them. No fee tiers or coin control - chat payments have neither.
private struct KaPostTipSheet: View {
    let address: String
    let displayName: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var portfolioViewModel = PortfolioViewModel.shared
    @StateObject private var fiatAmountState = KaspaFiatAmountState()

    @State private var contact: Contact?
    @State private var paysViaPool = false
    /// True when the funding source is the primary spending address (privacy ON), false when
    /// it's the chatting address (privacy OFF) - drives the Available footer label.
    @State private var fundingIsSpending = false
    @State private var amountInput = ""
    @State private var availableSompi: UInt64?
    @State private var normalFeeSompi: UInt64?
    @State private var isEstimatingFee = false
    @State private var isEstimatingMax = false
    @State private var isSending = false
    @State private var errorMessage: String?

    // Fee tiers, mirroring WithdrawKaspaView: Normal/Fast/Priority multiply the estimated base
    // fee; tapping the fee amount sets a custom total instead (values under the network minimum
    // are clamped up to it at commit).
    @State private var feeTier: WithdrawFeeTier = .normal
    @State private var customExtraFeeSompi: UInt64?
    @State private var isEditingFee = false
    @State private var customFeeText = ""

    private var amountSompi: UInt64? {
        guard let kas = Double(amountInput), kas > 0 else { return nil }
        return UInt64((kas * 100_000_000).rounded())
    }

    private var canSend: Bool {
        amountSompi != nil && !isSending
    }

    /// Extra priority tip on top of the base (Normal-tier) fee - custom overrides the tier.
    private var extraFeeSompi: UInt64 {
        guard let normalFeeSompi else { return 0 }
        if let customExtraFeeSompi { return customExtraFeeSompi }
        return normalFeeSompi * (feeTier.multiplier - 1)
    }

    private var totalFeeSompi: UInt64? {
        guard let normalFeeSompi else { return nil }
        return normalFeeSompi + extraFeeSompi
    }

    private func trimmedKas(_ sompi: UInt64) -> String {
        var text = String(format: "%.8f", Double(sompi) / 100_000_000.0)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(displayName)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(address)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150)
                    }
                    // Which of the privacy scenarios this tip will actually hit (same signal as
                    // the chat composer's fresh-address indicator).
                    HStack(spacing: 6) {
                        Image(systemName: paysViaPool ? "lock.fill" : "globe")
                            .font(.caption)
                            .foregroundColor(paysViaPool ? .green : .secondary)
                        Text(paysViaPool
                             ? "Goes to a fresh private address they shared"
                             : "Goes to their public chatting address")
                            .font(.caption)
                            .foregroundColor(paysViaPool ? .green : .secondary)
                    }
                } header: {
                    Text("Tipping")
                } footer: {
                    Text("Your Chats Payment Privacy setting decides the destination and funding, exactly like a payment inside their chat.")
                }

                Section {
                    HStack {
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
                            "0.00",
                            text: Binding(
                                get: { fiatAmountState.displayText },
                                set: { amountInput = fiatAmountState.onDisplayTextChange($0, priceInCurrency: portfolioViewModel.currentPriceUsd) }
                            )
                        )
                        .keyboardType(.decimalPad)
                        .numericKeyboardDoneButton()

                        if let conversionLabel = fiatAmountState.conversionLabelText(
                            priceInCurrency: portfolioViewModel.currentPriceUsd,
                            currency: portfolioViewModel.currentCurrency
                        ) {
                            Text(conversionLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .onTapGesture {
                                    fiatAmountState.toggleMode(priceInCurrency: portfolioViewModel.currentPriceUsd)
                                }
                        }

                        if isEstimatingMax {
                            ProgressView().scaleEffect(0.75)
                        } else {
                            Button("Max") { setMaxAmount() }
                                .font(.caption)
                                .fontWeight(.semibold)
                                .buttonStyle(.borderless)
                        }
                        Text(fiatAmountState.isFiatMode ? portfolioViewModel.currentCurrency.code : "KAS")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Amount")
                } footer: {
                    if let availableSompi {
                        Text("Available: \(trimmedKas(availableSompi)) KAS from your \(fundingIsSpending ? "primary spending address" : "chatting address")")
                    }
                }

                Section {
                    Picker("Fee", selection: $feeTier) {
                        ForEach(WithdrawFeeTier.allCases) { tier in
                            Text(tier.rawValue).tag(tier)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: feeTier) { _ in
                        customExtraFeeSompi = nil
                        isEditingFee = false
                    }

                    HStack {
                        Text("Network Fee")
                        Spacer()
                        if isEditingFee {
                            TextField("0.00", text: $customFeeText)
                                .keyboardType(.decimalPad)
                                .numericKeyboardDoneButton()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                                .onSubmit { commitCustomFee() }
                            Button {
                                commitCustomFee()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        } else if isEstimatingFee {
                            ProgressView().scaleEffect(0.75)
                        } else if let totalFeeSompi {
                            Button {
                                startEditingFee()
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(trimmedKas(totalFeeSompi)) KAS")
                                        .underline()
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                }
                                .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("—")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Fee")
                } footer: {
                    Text("If the network is busy, Fast or Priority pays a higher fee to help your tip confirm sooner. Tap the fee amount to set a custom fee.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Tip \(displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send") { send() }
                            .disabled(!canSend)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                // Deliberately does NOT create a contact here: opening the tip sheet and
                // cancelling must leave no trace in the Chats list. The contact (and its
                // conversation) is created in send(), only once a tip is actually sent.
                contact = ContactsManager.shared.getContact(byAddress: address)
                paysViaPool = ChatService.shared.willPayViaFreshPoolAddress(contactAddress: address)
                // Available = the FUNDING SOURCE's spendable balance, exactly what the send will
                // see: the primary spending address when Payment Privacy is on, the chatting
                // address when it's off (paymentFundingSourceAddress is the single authority).
                if let source = try? ChatService.shared.paymentFundingSourceAddress() {
                    fundingIsSpending = source != WalletManager.shared.currentWallet?.publicAddress
                    let utxos = (try? await ChatService.shared.fetchUtxosWithFallback(for: source)) ?? []
                    availableSompi = utxos.filter { !$0.isCoinbase }.reduce(0) { $0 + $1.amount }
                }
            }
            .task(id: amountSompi ?? 0) {
                guard let amountSompi else {
                    normalFeeSompi = nil
                    return
                }
                isEstimatingFee = true
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                normalFeeSompi = try? await ChatService.shared.estimatePaymentFee(to: estimationContact, amountSompi: amountSompi)
                isEstimatingFee = false
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    /// Estimation-only stand-in when the poster isn't a contact yet: fee/max sizing needs a
    /// Contact value but must NOT persist one - the real contact is only created on send().
    private var estimationContact: Contact {
        contact ?? Contact(address: address, isAutoAdded: true)
    }

    private func setMaxAmount() {
        isEstimatingMax = true
        Task {
            let max = try? await ChatService.shared.estimateMaxPaymentAmount(to: estimationContact)
            await MainActor.run {
                isEstimatingMax = false
                guard let max, max > 0 else { return }
                // Max = balance minus the send-all fee; Available keeps showing the source's
                // full spendable balance, matching the Send Kaspa screen's semantics.
                amountInput = fiatAmountState.setMaxKas(
                    Double(max) / 100_000_000.0,
                    priceInCurrency: portfolioViewModel.currentPriceUsd
                )
            }
        }
    }

    private func startEditingFee() {
        guard let totalFeeSompi else { return }
        customFeeText = trimmedKas(totalFeeSompi)
        isEditingFee = true
    }

    /// Commits the manually-typed total fee. Values below the network-computed minimum are
    /// clamped up to that minimum, matching WithdrawKaspaView.
    private func commitCustomFee() {
        defer { isEditingFee = false }
        guard let normalFeeSompi, let kas = Double(customFeeText), kas >= 0 else { return }
        let totalSompi = UInt64((kas * 100_000_000).rounded())
        customExtraFeeSompi = totalSompi > normalFeeSompi ? totalSompi - normalFeeSompi : 0
    }

    private func send() {
        guard let amountSompi else { return }
        // The chat with the poster is created HERE, on an actual send - not when the
        // sheet opened - so a cancelled tip never leaves an orphan conversation.
        let recipient: Contact
        if let existing = contact ?? ContactsManager.shared.getContact(byAddress: address) {
            recipient = existing
        } else if let created = try? ContactsManager.shared.addContact(address: address, alias: "", isAutoAdded: true) {
            recipient = created
        } else {
            errorMessage = "Couldn't prepare the recipient."
            return
        }
        contact = recipient
        _ = ChatService.shared.getOrCreateConversation(for: recipient)
        isSending = true
        errorMessage = nil
        let tipExtraFee = extraFeeSompi
        Task {
            do {
                try await ChatService.shared.sendPayment(to: recipient, amountSompi: amountSompi, extraFeeSompi: tipExtraFee)
                await MainActor.run {
                    Haptics.success()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Composer

/// Text-only post composer. Deliberately NO attachment affordances (no photo picker, no link
/// tools) - a KaPost is plain text, full stop.
/// The X-style anchored repost menu's choices (see KaPostCellView's popover).
enum KaPostRepostAction {
    case repost, removeRepost, quote
}

/// `.presentationCompactAdaptation(.popover)` is iOS 16.4+ — it makes the repost menu a real
/// anchored bubble on iPhone. On 16.0-16.3 the popover falls back to a sheet, still functional.
private struct CompactPopoverAdaptation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationCompactAdaptation(.popover)
        } else {
            content
        }
    }
}

/// Reusable @mention autocomplete for the comment/reply bar - the exact same suggestion
/// source as KaPostComposerView (chatted contacts' KNS domains + a live-resolved any-KNS
/// match). Rendered above the input so the keyboard can never hide it; tapping a row
/// completes the @token in the bound text.
private struct KaPostMentionSuggestionBar: View {
    @Binding var text: String
    /// The bound field's caret. Completing a mention rewrites the text from OUTSIDE the field, so
    /// without this the caret keeps its old offset and lands mid-sentence; the completion always
    /// happens at the end, so that is where the caret belongs.
    var selection: Binding<ClosedRange<Int>>? = nil
    @ObservedObject private var knsService = KNSService.shared
    @State private var resolvedAnyDomain: String? = nil

    private var mentionQuery: String? {
        guard let range = text.range(
            of: "(^|[\\s(\\[{<\"'])@([a-z0-9-]*)$",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let token = text[range]
        guard let atIndex = token.firstIndex(of: "@") else { return nil }
        return String(token[token.index(after: atIndex)...]).lowercased()
    }

    private var suggestions: [String] {
        guard let query = mentionQuery else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for contact in ContactsManager.shared.activeContacts {
            guard let raw = knsService.domainCache[contact.address]?.primaryDomain else { continue }
            let bare = KaPostsView.strippingKasSuffix(raw).lowercased()
            guard !bare.isEmpty, !seen.contains(bare),
                  query.isEmpty || bare.hasPrefix(query) else { continue }
            seen.insert(bare)
            out.append(bare)
        }
        out.sort()
        if let extra = resolvedAnyDomain, !seen.contains(extra),
           query.isEmpty || extra.hasPrefix(query) {
            out.append(extra)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty {
                let rows = VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { domain in
                        Button {
                            if let range = text.range(of: "@[a-z0-9-]*$", options: [.regularExpression, .caseInsensitive]) {
                                text.replaceSubrange(range, with: "@\(domain) ")
                                let end = text.count
                                DispatchQueue.main.async { selection?.wrappedValue = end...end }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("@")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(.accentColor)
                                Text(domain)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if domain != suggestions.last {
                            Divider()
                        }
                    }
                }
                Group {
                    if suggestions.count > 4 {
                        ScrollView { rows }.frame(height: 168)
                    } else {
                        rows
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Warm the contact KNS cache so @ has a populated list immediately.
        .task { await ContactsManager.shared.fetchKNSDomainsForAllContacts() }
        // Anyone-with-a-KNS-domain mentions: debounce-resolve the typed @query live.
        .task(id: mentionQuery ?? "") {
            resolvedAnyDomain = nil
            guard let query = mentionQuery, query.count >= 2 else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let resolution = await KNSService.shared.resolveDomain(query) else { return }
            guard !Task.isCancelled, mentionQuery == query else { return }
            var bare = resolution.domain.lowercased()
            if bare.hasSuffix(".kas") { bare = String(bare.dropLast(4)) }
            resolvedAnyDomain = bare
        }
    }
}

private struct KaPostComposerView: View {
    // When quoting: the post being quoted renders X-style below the editor - you write above it.
    var quotedPost: KaPostsView.DraftPost? = nil
    var quotedDisplayName: String = ""
    var quotedAvatarURL: String? = nil
    let onPost: (String) -> Void
    /// Thread posting (X-style): when set (and not quoting), a + button appears once you start
    /// typing - each tap stacks the current text as a thread segment. "Post All" hands every
    /// segment here; single posts still go through `onPost`.
    var onPostThread: (([String]) -> Void)? = nil

    @EnvironmentObject private var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    // Observed so the @mention list live-updates as KNS lookups land after the on-appear
    // prefetch (an unobserved singleton read would stay empty until an unrelated re-render).
    @ObservedObject private var knsService = KNSService.shared
    @State private var text = ""
    @State private var threadSegments: [String] = []
    /// A live KNS resolution of the CURRENT @query - lets you mention anyone with a KNS
    /// domain, not just chatted contacts (those come from the local cache).
    @State private var resolvedAnyDomain: String?
    /// A plain Bool, not @FocusState: the editor is a UIViewRepresentable now (see
    /// `MarkdownComposerField`) and SwiftUI's focus system cannot drive one.
    @State private var isFocused = false
    /// Caret / highlighted range in the editor, in character offsets - what the formatting
    /// toolbar acts on.
    @State private var selection: ClosedRange<Int> = 0...0

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var threadingEnabled: Bool {
        onPostThread != nil && quotedPost == nil
    }

    /// Everything that would be posted right now: stacked segments plus the in-progress text.
    private var allSegments: [String] {
        trimmed.isEmpty ? threadSegments : threadSegments + [trimmed]
    }

    private var canPost: Bool {
        !allSegments.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header card row, matching the desktop composer: X in a rounded square, bold
            // title, and a teal capsule Post button.
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.primary)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                Text(quotedPost == nil
                     ? (threadSegments.isEmpty ? "New Post" : "New Thread")
                     : "Quote Post")
                    .font(.title3.weight(.bold))
                Spacer()
                characterMeter
                Button {
                    postAll()
                } label: {
                    Text(allSegments.count > 1 ? "Post All (\(allSegments.count))" : "Post")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(canPost ? Color.black : Color.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(canPost ? Color.accentColor : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(!canPost)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // @mention autocomplete stays PINNED between the header and the scroll view, so
            // scrolling the post text can never carry the suggestion list out of sight.
            mentionSuggestionBar

            // Everything that can grow lives in ONE scroll view, which respects the keyboard's
            // safe area. This used to be a plain VStack: with the keyboard up, the header plus
            // the editor's 120pt floor plus the quote card and fee row exceeded what was left of
            // the sheet, the VStack overflowed its container, and the bottom of the editor -
            // where the caret is - sat behind the keyboard with no way to bring it back.
            // ScrollViewReader so the editor can be kept in view as it grows. A ScrollView
            // alone is not enough: it makes room for the keyboard, but nothing scrolls the
            // growing field back up, so a long post walks its own last line off the bottom.
            // Anchoring on the EDITOR rather than the content bottom keeps the line being typed
            // against the keyboard, instead of scrolling past it to show the fee row.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        threadSegmentsList
                        composerEditor
                            .id(Self.composerEditorAnchor)
                        if let quotedPost {
                            quotedPostCard(quotedPost)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                        }
                        feeEstimateRow
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: text) { _ in
                    keepEditorVisible(proxy)
                }
                // The keyboard arriving shrinks the scroll viewport without the text changing,
                // so re-reveal on focus too.
                .onChange(of: isFocused) { focused in
                    guard focused else { return }
                    keepEditorVisible(proxy)
                }
            }
            // Pinned below the scroll view so it rides directly on top of the keyboard, where a
            // formatting bar belongs. Only while the editor has focus - with the keyboard down it
            // would just be a row of icons with nothing to act on.
            if isFocused {
                Divider().opacity(0.4)
                MarkdownFormattingToolbar(onAction: applyFormatting)
                    .padding(.bottom, 2)
            }
        }
        .onAppear { isFocused = true }
        // Warm the KNS domain cache for every 1:1 contact so typing @ has a populated list -
        // without this the mention list stayed empty until something else happened to fetch.
        .task {
            await ContactsManager.shared.fetchKNSDomainsForAllContacts()
        }
        // Anyone-with-a-KNS-domain mentions: debounce-resolve the typed @query live; a hit
        // appends its row to the list even when they're not a contact.
        .task(id: mentionQuery ?? "") {
            resolvedAnyDomain = nil
            guard let query = mentionQuery, query.count >= 2 else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let resolution = await KNSService.shared.resolveDomain(query) else { return }
            guard !Task.isCancelled, mentionQuery == query else { return }
            var bare = resolution.domain.lowercased()
            if bare.hasSuffix(".kas") { bare = String(bare.dropLast(4)) }
            resolvedAnyDomain = bare
        }
        .onChange(of: text) { newValue in
            // Hard cap at the limit, X-style.
            if newValue.count > KaPostsView.postCharacterLimit {
                text = String(newValue.prefix(KaPostsView.postCharacterLimit))
            }
        }
    }

    /// Already-stacked thread segments, numbered, each removable. No longer its own ScrollView:
    /// it now rides inside the composer's single outer scroll view, and a vertical scroll view
    /// nested in another one fights it for the drag.
    @ViewBuilder
    private var threadSegmentsList: some View {
        if !threadSegments.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(threadSegments.enumerated()), id: \.offset) { index, segment in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.accentColor)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        Text(segment)
                            .font(.subheadline)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            threadSegments.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    /// @mention autocomplete: a SCROLLABLE vertical list of the KNS domains of everyone you've
    /// chatted with 1:1 (plus a live-resolved non-contact match), shown the moment an @token is
    /// being typed. Pinned ABOVE the editor - below it the keyboard pushed the list off-screen,
    /// which read as "no list at all".
    @ViewBuilder
    private var mentionSuggestionBar: some View {
        if !mentionSuggestions.isEmpty {
            let rows = VStack(alignment: .leading, spacing: 0) {
                ForEach(mentionSuggestions, id: \.self) { domain in
                    Button {
                        insertMention(domain)
                    } label: {
                        HStack(spacing: 8) {
                            Text("@")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(.accentColor)
                            Text(domain)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if domain != mentionSuggestions.last {
                        Divider()
                    }
                }
            }
            Group {
                // Short lists hug their content; longer ones get an EXACT-height ScrollView
                // (~4.5 rows so it visibly reads as scrollable) - group chat's pattern.
                if mentionSuggestions.count > 4 {
                    ScrollView {
                        rows
                    }
                    .frame(height: 168)
                } else {
                    rows
                }
            }
            .frame(maxWidth: 280, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The bordered editor card. A growing multi-line TextField, deliberately NOT a TextEditor:
    /// TextEditor is greedy in both axes and has no intrinsic content height, so inside a scroll
    /// view it cannot size itself and the scroll view has no caret rectangle to bring above the
    /// keyboard. An axis-based TextField grows line by line with a real intrinsic height (the
    /// same control the post thread's reply bar uses), so as the post gets longer the caret rides
    /// down with the text and SwiftUI's keyboard avoidance scrolls it back into view. The empty
    /// card keeps its 120pt look via the minHeight floor.
    /// Scroll anchor for the editor, so the line being typed can be pinned above the keyboard.
    private static let composerEditorAnchor = "kaPostComposerEditor"

    /// Keeps the editor's bottom edge, where the caret sits while composing, against the bottom
    /// of the visible area. Deferred a runloop turn so the field has already grown to its new
    /// height by the time we scroll, otherwise this lands one line short on every keystroke.
    private func keepEditorVisible(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.12)) {
                proxy.scrollTo(Self.composerEditorAnchor, anchor: .bottom)
            }
        }
    }

    /// Applies a toolbar button to whatever is selected. The markers written here are exactly the
    /// ones a person could type by hand, so both routes produce identical post text.
    private func applyFormatting(_ action: KaPostsMarkdown.ToolbarAction) {
        let edit = KaPostsMarkdown.apply(
            action,
            to: text,
            selectionStart: selection.lowerBound,
            selectionEnd: selection.upperBound
        )
        text = edit.text
        // Deferred one runloop turn: the text has to reach the text view before a selection into
        // it means anything, otherwise this lands on the pre-edit string and is clamped away.
        DispatchQueue.main.async {
            selection = edit.selectionStart...edit.selectionEnd
        }
    }

    private var composerEditor: some View {
        MarkdownComposerField(
            text: $text,
            selection: $selection,
            isFocused: $isFocused,
            placeholder: quotedPost == nil
                ? (threadSegments.isEmpty ? "What's happening on Kaspa?" : "Add another post")
                : "Add a comment"
        )
        .padding(12)
        .frame(minHeight: 120, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.35), lineWidth: 1)
        )
        // X-style +: appears once you start typing; stacks this text as a segment and
        // clears the editor for the next post in the thread.
        .overlay(alignment: .bottomTrailing) {
            if threadingEnabled, !trimmed.isEmpty {
                Button {
                    threadSegments.append(trimmed)
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
        .padding(.horizontal, 16)
    }

    /// Live network-fee estimate while typing (Settings > Show Fee Estimate), matching the chat
    /// composer's behavior.
    private var feeEstimateRow: some View {
        HStack {
            Spacer()
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

    private func postAll() {
        let segments = allSegments
        guard !segments.isEmpty else { return }
        if segments.count > 1, let onPostThread {
            onPostThread(segments)
        } else {
            onPost(segments[0])
        }
        dismiss()
    }

    private var characterMeter: some View {
        KaPostCharacterMeter(count: text.count)
    }

    /// The @token currently being typed at the END of the text ("" right after "@"), or nil.
    /// Must start the text or follow whitespace/opening punctuation so emails don't trigger it.
    private var mentionQuery: String? {
        guard let range = text.range(
            of: "(^|[\\s(\\[{<\"'])@([a-z0-9-]*)$",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let token = text[range]
        guard let atIndex = token.firstIndex(of: "@") else { return nil }
        return String(token[token.index(after: atIndex)...]).lowercased()
    }

    /// Mentionable = your 1:1 contacts that have a KNS domain, filtered by the live @query.
    private var mentionSuggestions: [String] {
        guard let query = mentionQuery else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for contact in ContactsManager.shared.activeContacts {
            // Read through the OBSERVED service so rows appear live as lookups land.
            guard let raw = knsService.domainCache[contact.address]?.primaryDomain else { continue }
            let bare = KaPostsView.strippingKasSuffix(raw).lowercased()
            guard !bare.isEmpty, !seen.contains(bare),
                  query.isEmpty || bare.hasPrefix(query) else { continue }
            seen.insert(bare)
            out.append(bare)
        }
        out.sort()
        // Live-resolved non-contact domain matching the current query rides along at the end.
        if let extra = resolvedAnyDomain, !seen.contains(extra),
           query.isEmpty || extra.hasPrefix(query) {
            out.append(extra)
        }
        return out
    }

    private func insertMention(_ domain: String) {
        guard let range = text.range(of: "@[a-z0-9-]*$", options: [.regularExpression, .caseInsensitive]) else { return }
        text.replaceSubrange(range, with: "@\(domain) ")
        // The editor's caret has to be moved with it: this rewrites the text from OUTSIDE the
        // field, so the old offset would leave the caret mid-sentence. The completion always
        // happens at the end, so that is where the caret belongs.
        let end = text.count
        DispatchQueue.main.async { selection = end...end }
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
            Text(KaPostCellView.markdownPreview(quoted.text))
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

    /// One-shot per session: rebuild this LOCAL set from the on-chain follow graph. Every
    /// Follow button and the Following feed filter read the local set, and it lives only in
    /// UserDefaults — so a reinstall/upgrade that cleared app data left users "following 0"
    /// with Follow buttons beside people they already follow on-chain. Chain entries are only
    /// ever ADDED (never removed), so a just-tapped local unfollow the indexer hasn't caught
    /// up on can't be resurrected mid-session.
    private var chainSyncStarted = false
    func syncFromChain() {
        guard !chainSyncStarted else { return }
        chainSyncStarted = true
        Task { @MainActor in
            do {
                let pubkey = try KaPostsAPIClient.shared.requesterPubkey()
                var chain: Set<String> = []
                var cursor: String? = nil
                var pagesLeft = 10 // far beyond any real follow list
                while pagesLeft > 0 {
                    pagesLeft -= 1
                    let result = try await KaPostsAPIClient.shared.fetchFollowList(
                        ofPubkey: pubkey, followers: false, limit: 100, before: cursor
                    )
                    for user in result.users {
                        if let address = KaPostsAPIClient.kaspaAddress(fromPubkey: user.userPublicKey) {
                            chain.insert(address)
                        }
                    }
                    guard result.pagination?.hasMore == true,
                          let next = result.pagination?.nextCursor else { break }
                    cursor = next
                }
                let myAddress = WalletManager.shared.currentWallet?.publicAddress
                let merged = following.union(chain).subtracting([myAddress ?? ""])
                if merged != following {
                    following = merged
                    UserDefaults.standard.set(Array(following), forKey: defaultsKey)
                }
            } catch {
                chainSyncStarted = false // network miss — retry on the next KaPosts open
            }
        }
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

/// Intermediate screen behind "Post Activity": four tabs of actors (Likes, Dislikes,
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
    /// One cursor for the whole actor stream (`type=all`), which the view fans out into the
    /// four tabs - so "load more" from any tab advances the same underlying pagination.
    @State private var page = KaPostsPageState()
    /// Action txids already shown, across all four tabs (the server can repeat across pages).
    @State private var seenActionIds: Set<String> = []

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
                        let triggerId = kaPostsPrefetchTriggerId(rows)
                        List {
                            ForEach(rows) { entry in
                                entryRow(entry)
                                    .onAppear {
                                        guard entry.id == triggerId else { return }
                                        Task { await loadMore() }
                                    }
                            }
                            KaPostsLoadMoreFooter(state: page) {
                                page.prepareManualRetry()
                                Task { await loadMore() }
                            }
                            .listRowSeparator(.hidden)
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
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.strippingKasSuffix(assigned)
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
        await loadPage(reset: true)
    }

    private func loadMore() async {
        await loadPage(reset: false)
    }

    private func loadPage(reset: Bool) async {
        guard let postId = post.remoteId else { return }
        guard !page.isLoading else { return }
        guard reset || (page.hasMore && page.errorMessage == nil && !page.stalled) else { return }
        if reset {
            page.reset()
            seenActionIds = []
        }
        let epoch = page.epoch
        let cursor = reset ? nil : page.cursor
        page.isLoading = true
        page.errorMessage = nil
        if reset { isLoading = true }
        defer { if reset { isLoading = false } }
        do {
            var seen = seenActionIds
            let batch = try await KaPostsPaginator.collect(
                from: cursor,
                fetch: { (before: String?, limit: Int) -> (items: [KaPostsAPIClient.KEngagementEntry], pagination: KaPostsAPIClient.KPagination?) in
                    let result = try await KaPostsAPIClient.shared.fetchPostEngagement(
                        postId: postId, limit: limit, before: before
                    )
                    return (result.entries, result.pagination)
                },
                keep: { (rows: [KaPostsAPIClient.KEngagementEntry]) -> [KaPostsAPIClient.KEngagementEntry] in
                    rows.filter { row in
                        guard !seen.contains(row.actionTxId) else { return false }
                        seen.insert(row.actionTxId)
                        return true
                    }
                }
            )
            guard page.epoch == epoch else { return }
            seenActionIds = seen
            var likes: [EngagementEntry] = reset ? [] : (entries[.likes] ?? [])
            var dislikes: [EngagementEntry] = reset ? [] : (entries[.dislikes] ?? [])
            var reposts: [EngagementEntry] = reset ? [] : (entries[.reposts] ?? [])
            var quotes: [EngagementEntry] = reset ? [] : (entries[.quotes] ?? [])
            for row in batch.items {
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
            page.apply(batch)
            // Batched KNS resolution for the appended actors.
            let addresses = Array(Set(batch.items.compactMap { KaPostsAPIClient.kaspaAddress(fromPubkey: $0.actorPubkey) }))
            if !addresses.isEmpty {
                Task { await knsService.refreshProfilesIfNeeded(for: addresses) }
            }
        } catch {
            guard page.epoch == epoch else { return }
            page.isLoading = false
            // Keep whatever is already listed; only a failed FIRST page falls back.
            guard reset else {
                page.errorMessage = error.localizedDescription
                AppLog.log("[KaPosts] Engagement page failed: %@", error.localizedDescription)
                return
            }
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
    /// Deliberately single-page: filtering a whole notification stream down to one post's
    /// actions is so sparse that paging it would burn requests for nothing - so this fallback
    /// marks the surface exhausted and shows no load-more affordance.
    private func loadFromNotifications(postId: String) async {
        page.hasMore = false
        do {
            let notifications = try await KaPostsAPIClient.shared.fetchNotifications(limit: 100).notifications
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
    /// The profile whose follow list this is. nil = the signed-in user's own list (loaded via
    /// requesterPubkey, with locally-stored follows merged in); non-nil = another user's list.
    let targetPubkey: String?
    /// Routes through KaPostsView.toggleFollowSubmitting - local store toggle + the on-chain
    /// follow/unfollow tx (and its toast) when the pubkey is known.
    let onToggleFollow: (String, String?) -> Void

    /// Own list when no target pubkey is supplied; only then do we merge local-only follows.
    private var isOwnList: Bool { targetPubkey == nil }

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
    /// Endless-scroll state for the server-side follow list (the locally-merged rows are a
    /// fixed tail, see `load`).
    @State private var page = KaPostsPageState()

    init(kind: Kind, localFollowing: Set<String>, targetPubkey: String? = nil, onToggleFollow: @escaping (String, String?) -> Void) {
        self.kind = kind
        self.localFollowing = localFollowing
        self.targetPubkey = targetPubkey
        self.onToggleFollow = onToggleFollow
    }

    var body: some View {
        Group {
            if isLoading, entries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                emptyState
            } else {
                let triggerId = kaPostsPrefetchTriggerId(entries)
                List {
                    ForEach(entries) { entry in
                        entryRow(entry)
                            .onAppear {
                                guard entry.id == triggerId else { return }
                                Task { await loadPage(reset: false) }
                            }
                    }
                    KaPostsLoadMoreFooter(state: page) {
                        page.prepareManualRetry()
                        Task { await loadPage(reset: false) }
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .refreshable { await load() }
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
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.strippingKasSuffix(assigned)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    private func load() async {
        await loadPage(reset: true)
    }

    /// Pages the server list (newest-first, cursor-driven). Locally-stored follows the indexer
    /// hasn't caught up on are merged in as a fixed tail AFTER the server rows, and stay there
    /// as further pages arrive - they have no cursor position of their own.
    private func loadPage(reset: Bool) async {
        guard !page.isLoading else { return }
        guard reset || (page.hasMore && page.errorMessage == nil && !page.stalled) else { return }
        if reset { page.reset() }
        let epoch = page.epoch
        let cursor = reset ? nil : page.cursor
        page.isLoading = true
        page.errorMessage = nil
        if reset { isLoading = true }
        guard let pubkey = targetPubkey ?? (try? KaPostsAPIClient.shared.requesterPubkey()) else {
            page.isLoading = false
            page.hasMore = false
            isLoading = false
            if reset { entries = localOnlyEntries(excluding: []) }
            return
        }
        // Only hide the signed-in user from their OWN list (you never follow yourself). On another
        // user's list you legitimately may appear, and should - the row hides just the Follow button.
        let myAddress = isOwnList ? WalletManager.shared.currentWallet?.publicAddress : nil
        do {
            var seen: Set<String> = reset ? [] : Set(entries.map(\.address))
            let batch = try await KaPostsPaginator.collect(
                from: cursor,
                fetch: { (before: String?, limit: Int) -> (items: [KaPostsAPIClient.KFollowUser], pagination: KaPostsAPIClient.KPagination?) in
                    let result = try await KaPostsAPIClient.shared.fetchFollowList(
                        ofPubkey: pubkey, followers: kind == .followers, limit: limit, before: before
                    )
                    return (result.users, result.pagination)
                },
                keep: { (users: [KaPostsAPIClient.KFollowUser]) -> [Entry] in
                    users.compactMap { user in
                        guard let address = KaPostsAPIClient.kaspaAddress(fromPubkey: user.userPublicKey),
                              address != myAddress,
                              !seen.contains(address) else { return nil }
                        seen.insert(address)
                        let date = user.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
                        return Entry(address: address, pubkey: user.userPublicKey, timestamp: date)
                    }
                }
            )
            guard page.epoch == epoch else { return }
            // Server rows keep their (descending) order; the local-only tail is recomputed so
            // an entry that just arrived from the indexer stops being duplicated locally.
            var serverRows = reset ? [] : entries.filter { $0.pubkey != nil }
            serverRows.append(contentsOf: batch.items)
            entries = serverRows + localOnlyEntries(excluding: Set(serverRows.map(\.address)))
            page.apply(batch)
            isLoading = false
            let addresses = Array(Set(batch.items.map(\.address).filter { !$0.isEmpty }))
            if !addresses.isEmpty {
                Task { await knsService.refreshProfilesIfNeeded(for: addresses) }
            }
        } catch {
            guard page.epoch == epoch else { return }
            page.isLoading = false
            page.errorMessage = error.localizedDescription
            isLoading = false
            if reset {
                // First page failed: still show the local follows rather than an empty screen.
                entries = localOnlyEntries(excluding: [])
            }
            AppLog.log("[KaPosts] Follow list load failed: %@", error.localizedDescription)
        }
    }

    /// Locally-stored follows the indexer hasn't reported (own Following list only).
    private func localOnlyEntries(excluding known: Set<String>) -> [Entry] {
        guard isOwnList, kind == .following else { return [] }
        return localFollowing
            .filter { !known.contains($0) && $0 != WalletManager.shared.currentWallet?.publicAddress }
            .sorted()
            .map { Entry(address: $0, pubkey: nil, timestamp: nil) }
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
            case like, dislike, reply, quote, repost, follow, mention, other

            var icon: String {
                switch self {
                case .like: return "heart.fill"
                case .dislike: return "hand.thumbsdown.fill"
                case .reply: return "bubble.left.fill"
                case .quote, .repost: return "arrow.2.squarepath"
                case .follow: return "person.fill.badge.plus"
                case .mention: return "at"
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
                case .mention: return .accentColor
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
                case .mention: return "mentioned you in a post"
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
    /// Endless-scroll state for the notification stream (cursor-paginated by the indexer).
    @State private var page = KaPostsPageState()

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
                    let triggerId = kaPostsPrefetchTriggerId(items)
                    List {
                        ForEach(items) { item in
                            itemRow(item)
                                .onAppear {
                                    guard item.id == triggerId else { return }
                                    Task { await loadMore() }
                                }
                        }
                        KaPostsLoadMoreFooter(state: page) {
                            page.prepareManualRetry()
                            Task { await loadMore() }
                        }
                        .listRowSeparator(.hidden)
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
            // The open-conversation rule for KaPosts: while this stream is on screen,
            // AppDelegate.willPresent suppresses kaposts banners (local and push alike).
            .onAppear { KaPostsNotificationService.shared.isNotificationsScreenVisible = true }
            .onDisappear { KaPostsNotificationService.shared.isNotificationsScreenVisible = false }
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
        if let assigned = ContactsManager.shared.getContact(byAddress: address)?.assignedName {
            return KaPostsView.strippingKasSuffix(assigned)
        }
        if let domain = knsService.profileCache[address]?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    /// Pull-to-refresh / first load: back to page one with the end-reached state cleared.
    private func load() async {
        await loadPage(reset: true)
    }

    private func loadMore() async {
        await loadPage(reset: false)
    }

    private func loadPage(reset: Bool) async {
        guard !page.isLoading else { return }
        guard reset || (page.hasMore && page.errorMessage == nil && !page.stalled) else { return }
        if reset { page.reset() }
        let epoch = page.epoch
        let cursor = reset ? nil : page.cursor
        page.isLoading = true
        page.errorMessage = nil
        if reset { isLoading = true; loadFailed = false }
        do {
            let myAddress = WalletManager.shared.currentWallet?.publicAddress
            // Muted/blocked actors and your own actions are dropped client-side, so a server
            // page can shrink a lot - the paginator keeps pulling until enough rows survive.
            var seen: Set<String> = reset ? [] : Set(items.map(\.id))
            var newestSeenTimestamp: Int64 = 0
            let batch = try await KaPostsPaginator.collect(
                from: cursor,
                fetch: { (before: String?, limit: Int) -> (items: [KaPostsAPIClient.KNotification], pagination: KaPostsAPIClient.KPagination?) in
                    let result = try await KaPostsAPIClient.shared.fetchNotifications(limit: limit, before: before)
                    return (result.notifications, result.pagination)
                },
                keep: { (notifications: [KaPostsAPIClient.KNotification]) -> [Item] in
                    notifications.compactMap { notification in
                        newestSeenTimestamp = max(newestSeenTimestamp, notification.timestamp)
                        guard !seen.contains(notification.id),
                              let address = KaPostsAPIClient.kaspaAddress(fromPubkey: notification.userPublicKey),
                              address != myAddress,
                              !moderationStore.isHidden(address) else { return nil }
                        seen.insert(notification.id)
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
                        case "mention":
                            kind = .mention
                            // A mention's acting content IS the post/comment mentioning you, so
                            // when the indexer leaves contentId empty fall back to the
                            // notification's own txid — otherwise mention rows have no target.
                            targetTxId = (notification.contentId?.isEmpty == false) ? notification.contentId : notification.id
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
                }
            )
            guard page.epoch == epoch else { return }
            if reset {
                items = batch.items
                // Everything now on screen counts as seen - the local-notification poller
                // won't ping for it later. Only the first (newest) page can advance this.
                if newestSeenTimestamp > 0 {
                    KaPostsNotificationService.shared.markSeen(upTo: newestSeenTimestamp)
                }
            } else {
                items.append(contentsOf: batch.items)
            }
            page.apply(batch)
            isLoading = false
            // Batched KNS resolution for the appended actors (the per-row task only covers
            // cache misses; this also refreshes stale entries).
            let addresses = Array(Set(batch.items.map(\.actorAddress).filter { !$0.isEmpty }))
            if !addresses.isEmpty {
                Task { await knsService.refreshProfilesIfNeeded(for: addresses) }
            }
        } catch {
            guard page.epoch == epoch else { return }
            page.isLoading = false
            page.errorMessage = error.localizedDescription
            isLoading = false
            // A failed page-append leaves the loaded notifications on screen; only a failed
            // first load counts as an outright failure.
            if reset { loadFailed = true }
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
