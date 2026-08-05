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
    struct DraftPost: Identifiable, Equatable {
        let id = UUID()
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
        /// One flat level of replies, X-style. Comments are themselves DraftPosts so the cell
        /// (avatar/KNS name/follow/engagement) is reused wholesale - they just can't be
        /// commented on in turn (no nested threads yet).
        var comments: [DraftPost] = []
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
    @State private var profileTarget: PosterProfileTarget?
    /// Post whose comment thread is open - the sheet looks the post up live by id, so new
    /// comments/likes appear immediately.
    @State private var detailTarget: PostDetailTarget?
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

    struct PosterProfileTarget: Identifiable {
        let id = UUID()
        let address: String
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
                KaPostsMenuComingSoonView(item: item)
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
        .sheet(isPresented: $showComposer) {
            KaPostComposerView { text in
                let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
                posts.insert(DraftPost(text: text, timestamp: Date(), posterAddress: myAddress), at: 0)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $profileTarget) { target in
            KaPostsProfileView(address: target.address)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $detailTarget) { target in
            postDetailSheet(postId: target.id)
        }
        .task {
            await loadFeed()
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
            Text("KaPosts")
                .font(.title2.weight(.bold))
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)
            Divider()
            ForEach(SideMenuItem.allCases) { item in
                Button {
                    Haptics.impact(.light)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showSideMenu = false
                    }
                    menuSheet = item
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18))
                            .frame(width: 26)
                        Text(item.rawValue)
                            .font(.body.weight(.semibold))
                        Spacer()
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(width: min(UIScreen.main.bounds.width * 0.72, 300), alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Liquid Glass on iOS 26+ (the system's real glass material), falling back to the app's
        // established glass-card look (material + hairline + shadow) on older iOS. Either way the
        // card floats inside the content area - no ignoresSafeArea - so it stops above the dock.
        .background(drawerGlassBackground)
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
            emptyState(for: tab)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visiblePosts) { post in
                        KaPostCellView(
                            post: post,
                            displayName: posterDisplayName(post.posterAddress),
                            avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                            isFollowing: followStore.isFollowing(post.posterAddress),
                            commentCount: visibleComments(of: post).count,
                            truncatesLongText: true,
                            onComment: { openDetail(post) },
                            onMute: { moderationStore.mute(post.posterAddress) },
                            onBlock: { moderationStore.block(post.posterAddress) },
                            onBookmark: { toggleBookmark(post) },
                            onFollowToggle: { followStore.toggle(post.posterAddress) },
                            onOpenProfile: { profileTarget = PosterProfileTarget(address: post.posterAddress) },
                            onLike: { toggleLike(post) },
                            onDislike: { toggleDislike(post) },
                            onRepost: { toggleRepost(post) }
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
            showComposer = true
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
        } catch {
            feedError = error.localizedDescription
            AppLog.log("[KaPosts] Feed fetch failed: %@", error.localizedDescription)
        }
    }

    /// K wire post -> UI model. Content arrives base64-decoded with the KaChat marker stripped;
    /// counts map 1:1 (K "reposts" are quotes - quotesCount is the live counter).
    static func mapRemotePost(_ post: KaPostsAPIClient.KPost) -> DraftPost? {
        guard let content = post.decodedContent,
              let address = KaPostsAPIClient.kaspaAddress(fromPubkey: post.userPublicKey) else { return nil }
        var mapped = DraftPost(
            text: KaPostsAPIClient.stripMarker(content),
            timestamp: Date(timeIntervalSince1970: TimeInterval(post.timestamp) / 1000),
            posterAddress: address
        )
        mapped.remoteId = post.id
        mapped.posterPubkey = post.userPublicKey
        mapped.likes = post.upVotesCount ?? 0
        mapped.dislikes = post.downVotesCount ?? 0
        mapped.reposts = post.quotesCount ?? 0
        mapped.likedByMe = post.isUpvoted ?? false
        mapped.dislikedByMe = post.isDownvoted ?? false
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
    private func mutatePost(id: UUID, _ transform: (inout DraftPost) -> Void) {
        for index in posts.indices {
            if posts[index].id == id {
                transform(&posts[index])
                return
            }
            for commentIndex in posts[index].comments.indices where posts[index].comments[commentIndex].id == id {
                transform(&posts[index].comments[commentIndex])
                return
            }
        }
        for index in remotePosts.indices {
            if remotePosts[index].id == id {
                transform(&remotePosts[index])
                return
            }
            for commentIndex in remotePosts[index].comments.indices where remotePosts[index].comments[commentIndex].id == id {
                transform(&remotePosts[index].comments[commentIndex])
                return
            }
        }
    }

    private func toggleLike(_ post: DraftPost) {
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

    private func toggleDislike(_ post: DraftPost) {
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

    private func toggleRepost(_ post: DraftPost) {
        mutatePost(id: post.id) { target in
            target.repostedByMe.toggle()
            target.reposts += target.repostedByMe ? 1 : -1
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
        let myPosts = posts.filter { $0.posterAddress == myAddress }
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
                            HStack(spacing: 4) {
                                Text("\(followStore.following.count)")
                                    .font(.subheadline.weight(.bold))
                                Text("Following")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 4) {
                                // Placeholder until follower data exists on-chain.
                                Text("0")
                                    .font(.subheadline.weight(.bold))
                                Text("Followers")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                    Divider()

                    if myPosts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("No posts yet")
                                .font(.headline)
                            Text("Your posts will show up here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(myPosts) { post in
                            KaPostCellView(
                                post: post,
                                displayName: posterDisplayName(post.posterAddress),
                                avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                                isFollowing: followStore.isFollowing(post.posterAddress),
                                commentCount: visibleComments(of: post).count,
                                onComment: nil,
                                onMute: { moderationStore.mute(post.posterAddress) },
                                onBlock: { moderationStore.block(post.posterAddress) },
                                onBookmark: { toggleBookmark(post) },
                                onFollowToggle: { followStore.toggle(post.posterAddress) },
                                onOpenProfile: {},
                                onLike: { toggleLike(post) },
                                onDislike: { toggleDislike(post) },
                                onRepost: { toggleRepost(post) }
                            )
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                }
            }
            .ignoresSafeArea(edges: .top)
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
                                    size: 40
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
                                    commentCount: visibleComments(of: post).count,
                                    onComment: nil,
                                    onMute: { moderationStore.mute(post.posterAddress) },
                                    onBlock: { moderationStore.block(post.posterAddress) },
                                    onBookmark: { toggleBookmark(post) },
                                    onFollowToggle: { followStore.toggle(post.posterAddress) },
                                    onOpenProfile: {},
                                    onLike: { toggleLike(post) },
                                    onDislike: { toggleDislike(post) },
                                    onRepost: { toggleRepost(post) }
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
            if let post = (posts + remotePosts).first(where: { $0.id == postId }) {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            KaPostCellView(
                                post: post,
                                displayName: posterDisplayName(post.posterAddress),
                                avatarURLString: knsService.profileCache[post.posterAddress]?.avatarURL,
                                isFollowing: followStore.isFollowing(post.posterAddress),
                                commentCount: visibleComments(of: post).count,
                                onComment: nil,
                                onMute: { moderationStore.mute(post.posterAddress) },
                                onBlock: { moderationStore.block(post.posterAddress) },
                                onBookmark: { toggleBookmark(post) },
                                onFollowToggle: { followStore.toggle(post.posterAddress) },
                                onOpenProfile: { profileTarget = PosterProfileTarget(address: post.posterAddress) },
                                onLike: { toggleLike(post) },
                                onDislike: { toggleDislike(post) },
                                onRepost: { toggleRepost(post) }
                            )
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
                                    KaPostCellView(
                                        post: comment,
                                        displayName: posterDisplayName(comment.posterAddress),
                                        avatarURLString: knsService.profileCache[comment.posterAddress]?.avatarURL,
                                        isFollowing: followStore.isFollowing(comment.posterAddress),
                                        commentCount: 0,
                                        onComment: nil,
                                        onMute: { moderationStore.mute(comment.posterAddress) },
                                        onBlock: { moderationStore.block(comment.posterAddress) },
                                        onBookmark: { toggleBookmark(comment) },
                                        onFollowToggle: { followStore.toggle(comment.posterAddress) },
                                        onOpenProfile: { profileTarget = PosterProfileTarget(address: comment.posterAddress) },
                                        onLike: { toggleLike(comment) },
                                        onDislike: { toggleDislike(comment) },
                                        onRepost: { toggleRepost(comment) }
                                    )
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
                            .lineLimit(1...4)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        Button {
                            let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            Haptics.impact(.light)
                            let myAddress = WalletManager.shared.currentWallet?.publicAddress ?? ""
                            mutatePost(id: postId) { target in
                                target.comments.append(DraftPost(text: trimmed, timestamp: Date(), posterAddress: myAddress))
                            }
                            replyText = ""
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .navigationTitle("Post")
                .navigationBarTitleDisplayMode(.inline)
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
    let onFollowToggle: () -> Void
    let onOpenProfile: () -> Void
    let onLike: () -> Void
    let onDislike: () -> Void
    let onRepost: () -> Void

    /// Long enough that the feed should fold it behind "Show more" (X-style ~280-char threshold,
    /// or a wall of newlines).
    private var isLongPost: Bool {
        post.text.count > 280 || post.text.filter { $0 == "\n" }.count >= 8
    }

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
                    size: 40
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
                    // Inline follow toggle: Follow -> Following -> Follow.
                    // TODO(wiring): hide this for the user's OWN posts once feeds carry other
                    // authors - kept visible for now purely so the flow is demoable on session
                    // posts (which are always self-authored).
                    Button {
                        Haptics.impact(.light)
                        onFollowToggle()
                    } label: {
                        Text(isFollowing ? "Following" : "Follow")
                            .font(.caption.weight(.bold))
                            .foregroundColor(isFollowing ? .secondary : .accentColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // X-style overflow menu. Mute: their content disappears everywhere but they
                    // can still interact with you. Block: content gone AND they can't interact
                    // (the interaction half becomes real once wiring lands).
                    Menu {
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
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(width: 30, height: 24)
                            .contentShape(Rectangle())
                    }
                }

                // PLAIN TEXT by design: a KaPost is text only - no tappable links, no previews,
                // no photos. Rendering with Text (never markdown/link detection) keeps any URL
                // inert on screen.
                Text(verbatim: post.text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(truncatesLongText && isLongPost ? 8 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { onComment?() }
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

                HStack(spacing: 28) {
                    if let onComment {
                        engagementButton(
                            icon: "bubble.left",
                            count: commentCount,
                            tint: .secondary,
                            action: onComment
                        )
                    }
                    likeButton
                    engagementButton(
                        icon: post.dislikedByMe ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                        count: post.dislikes,
                        tint: post.dislikedByMe ? .orange : .secondary,
                        action: onDislike
                    )
                    engagementButton(
                        icon: "arrow.2.squarepath",
                        count: post.reposts,
                        tint: post.repostedByMe ? .accentColor : .secondary,
                        action: onRepost
                    )
                    Spacer()
                    // Trailing bookmark, X-style (no inline count - saved posts live in the
                    // side menu's Bookmarks screen).
                    engagementButton(
                        icon: post.bookmarkedByMe ? "bookmark.fill" : "bookmark",
                        count: 0,
                        tint: post.bookmarkedByMe ? .accentColor : .secondary,
                        action: onBookmark
                    )
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var likeButton: some View {
        Button {
            Haptics.impact(.light)
            let becomingLiked = !post.likedByMe
            onLike()
            if becomingLiked {
                runLikeBurst()
            }
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
                }
            }
            .foregroundColor(post.likedByMe ? .red : .secondary)
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

    private func engagementButton(icon: String, count: Int, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.subheadline)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                }
            }
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
    let onPost: (String) -> Void

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
                            Text("What's happening on Kaspa?")
                                .font(.body)
                                .foregroundColor(.secondary.opacity(0.6))
                                .padding(.horizontal, 17)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    }
                Divider()
                HStack {
                    Text("Text only - no photos or links")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("New Post")
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
        }
    }
}


// MARK: - Follow store (local-only persistence; on-chain follow wiring comes later)

/// Followed poster addresses, persisted locally in UserDefaults. This is deliberately NOT wired
/// to anything on-chain yet - it exists so Follow/Following state survives relaunch and the
/// Following feed has something real to filter on once posts are wired.
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
        guard !address.isEmpty else { return }
        if following.contains(address) {
            following.remove(address)
        } else {
            following.insert(address)
        }
        UserDefaults.standard.set(Array(following), forKey: defaultsKey)
    }
}

// MARK: - Poster profile

/// Poster profile sheet - mirrors the app's other info screens: KNS avatar/name up top, the full
/// KNS profile underneath (bio + socials when set), the raw address, and a prominent
/// Follow/Following button.
struct KaPostsProfileView: View {
    let address: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var knsService = KNSService.shared
    @ObservedObject private var followStore = KaPostsFollowStore.shared

    private var profileInfo: KNSAddressProfileInfo? {
        knsService.profileCache[address]
    }

    private var displayName: String {
        if let alias = ContactsManager.shared.getContact(byAddress: address)?.alias,
           !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(alias)
        }
        if let domain = profileInfo?.domainName,
           !domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return KaPostsView.strippingKasSuffix(domain)
        }
        return String(address.suffix(10))
    }

    /// Jumps into (or creates) the 1:1 chat with this poster: ensures a contact exists (silently
    /// auto-added if new, same as other implicit-add flows), ensures the conversation exists, then
    /// routes through the app's standard .openChat navigation - which lands on the Chats tab with
    /// the thread open. Slight delay so this sheet finishes dismissing first.
    private func startChat() {
        let contact: Contact?
        if let existing = ContactsManager.shared.getContact(byAddress: address) {
            contact = existing
        } else {
            contact = try? ContactsManager.shared.addContact(address: address, alias: "", isAutoAdded: true)
        }
        guard let contact else { return }
        _ = ChatService.shared.getOrCreateConversation(for: contact)
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(
                name: .openChat,
                object: nil,
                userInfo: ["contactAddress": contact.address]
            )
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        KNSAvatarView(
                            avatarURLString: profileInfo?.avatarURL,
                            fallbackText: displayName,
                            size: 64
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                            if let domain = profileInfo?.domainName.map(KaPostsView.strippingKasSuffix),
                               domain != displayName {
                                Text(domain)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)

                    Button {
                        Haptics.impact(.light)
                        followStore.toggle(address)
                    } label: {
                        Text(followStore.isFollowing(address) ? "Following" : "Follow")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(followStore.isFollowing(address) ? Color.secondary.opacity(0.35) : Color.accentColor)

                    Button {
                        Haptics.impact(.light)
                        startChat()
                    } label: {
                        Label("Send A Chat", systemImage: "bubble.left.and.bubble.right")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                }

                if let bio = profileInfo?.profile?.bio,
                   !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Bio") {
                        Text(bio)
                            .font(.subheadline)
                    }
                }

                let socials: [(label: String, icon: String, value: String?)] = [
                    ("X", "at", profileInfo?.profile?.x),
                    ("Website", "globe", profileInfo?.profile?.website),
                    ("Telegram", "paperplane", profileInfo?.profile?.telegram),
                    ("Discord", "bubble.left.and.bubble.right", profileInfo?.profile?.discord),
                    ("GitHub", "chevron.left.forwardslash.chevron.right", profileInfo?.profile?.github),
                    ("Email", "envelope", profileInfo?.profile?.contactEmail)
                ]
                let filledSocials = socials.compactMap { entry -> (String, String, String)? in
                    guard let value = entry.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else { return nil }
                    return (entry.label, entry.icon, value)
                }
                if !filledSocials.isEmpty {
                    Section("Links") {
                        ForEach(filledSocials, id: \.0) { label, icon, value in
                            HStack {
                                Label(label, systemImage: icon)
                                Spacer()
                                Text(value)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                Section("Address") {
                    Text(address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: address) {
                guard knsService.profileCache[address] == nil, !address.isEmpty else { return }
                _ = await knsService.fetchProfile(for: address)
            }
        }
    }
}


// MARK: - Side-menu coming-soon placeholder

/// Placeholder destination for the side menu's entries - same visual language as the original
/// KaPosts coming-soon landing, parameterized per item.
struct KaPostsMenuComingSoonView: View {
    let item: KaPostsView.SideMenuItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: item.icon)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(RoundedCornerRectangleStroke())
                    )
                Text(item.rawValue)
                    .font(.title.weight(.bold))
                Text("Coming Soon")
                    .font(.headline)
                    .foregroundColor(.accentColor)
                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(item.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Shared hairline stroke used by the coming-soon icon card.
private struct RoundedCornerRectangleStroke: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
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
