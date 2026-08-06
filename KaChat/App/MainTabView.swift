import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var selectedTab = 1
    /// Debounces the off-chat-tab discovery pause/resume so rapid tab-flipping can't thrash it.
    @State private var tabWorkTask: Task<Void, Never>?
    @State private var showGiftSheet = false
    @State private var showWelcomeGuide = false
    /// "+ More" dock item tapped - opens Customize Menu directly (selection never moves there).
    @State private var showCustomizeMenuSheet = false
    @State private var isSnappingBackFromMore = false
    /// What the Chats slot currently shows: .chats, or a masked-out tab (.kaposts/.broadcasts)
    /// the user cycled to by re-tapping the Chats tab (see handleChatsTabReselection).
    @State private var chatsSlotTab: AppTab = .chats
    // Hold-the-Chats-tab slide menu (same mechanics as the chat composer's send-mode menu):
    // long-press arms a card above the dock, drag highlights, release selects.
    @State private var slotMenuVisible = false
    @State private var slotMenuHighlight: AppTab?
    @State private var slotMenuArmTask: Task<Void, Never>?
    @State private var slotDragActive = false
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var giftService: GiftService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    /// The Chats slot's effective content - the cycled-to tab, validated against what's still
    /// masked behind the slot (menu toggles can restore a tab to the dock mid-flight). Single
    /// source of truth for the slot content, the dock label, and hit-testing.
    private var chatsSlotMode: AppTab {
        AppTab.chatsSlotCycle(from: settingsViewModel.settings).contains(chatsSlotTab) ? chatsSlotTab : .chats
    }

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.visible(from: settingsViewModel.settings)) { tab in
                tabContent(for: tab)
                    .tabItem {
                        // Single Label whose VALUES vary (no structural if) - conditional tabItem
                        // content churns the tab bar's identity on every render. While the Chats
                        // slot shows KaPosts (full-dock re-tap mode), the item reads as KaPosts.
                        Label(
                            tab == .chats ? chatsSlotMode.label : tab.label,
                            systemImage: tab == .chats ? chatsSlotMode.icon : tab.icon
                        )
                    }
                    .tag(tab.tag)
            }
        }
        .tint(.accentColor)
        // Custom gesture layer over the Chats dock slot: replicates tap (switch/cycle) and adds
        // hold-then-slide selection of the masked tabs. Mounted only when something is actually
        // masked behind the slot, and only on iPhone (iPad's tab bar isn't a bottom dock).
        .overlay {
            if AppTab.chatsSlotCycle(from: settingsViewModel.settings).count > 1,
               UIDevice.current.userInterfaceIdiom == .phone {
                chatsSlotHoldOverlay
            }
        }
        .onAppear {
            chatService.startPolling()
            preloadProfileResources()
            if walletManager.justCreatedNewWallet {
                walletManager.justCreatedNewWallet = false
                showWelcomeGuide = true
            }
        }
        .sheet(isPresented: $showGiftSheet) {
            GiftClaimView()
        }
        .sheet(isPresented: $showCustomizeMenuSheet) {
            NavigationStack {
                MenuVisibilityView()
            }
        }
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(onFinished: { showWelcomeGuide = false })
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            preloadProfileResources()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            // Switch to Chats tab when notification is tapped
            if chatsSlotTab != .chats { chatsSlotTab = .chats }
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBroadcast)) { _ in
            // Broadcast-room notification tapped: land on Broadcasts wherever it lives - its
            // own dock tab when visible, else the Chats slot cycled onto it. BroadcastListView
            // consumes the pending channel itself once mounted.
            if AppTab.visible(from: settingsViewModel.settings).contains(.broadcasts) {
                selectedTab = AppTab.broadcasts.tag
            } else if AppTab.broadcastsAccessibleViaChatsTab(from: settingsViewModel.settings) {
                chatsSlotTab = .broadcasts
                selectedTab = 1
            } else {
                if chatsSlotTab != .chats { chatsSlotTab = .chats }
                selectedTab = 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { _ in
            if chatsSlotTab != .chats { chatsSlotTab = .chats }
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGiftClaim)) { _ in
            presentGiftSheetIfEligibleForZeroBalance()
        }
        .onChange(of: AppTab.visible(from: settingsViewModel.settings).map(\.tag)) { visibleTags in
            // Menu toggles can remove the currently-selected page (or hand its position to
            // another tab) mid-flight - a TabView whose selection points at a page that no longer
            // exists renders a stuck black screen. Snap home to Chats whenever that happens.
            if !visibleTags.contains(selectedTab) {
                // Through the handler (not a bare @State write) so the debounced power-save
                // machinery runs too - a bare write landed the user on Chats with node discovery
                // paused and the poll timer dead.
                handleTabSelectionChange(1)
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .portfolio:
            PortfolioView()
        case .coldStorage:
            NavigationStack {
                ColdStorageListView()
            }
        case .chats:
            // When no tab is masked behind the slot (most users), this is BYTE-IDENTICAL to
            // 3.0: bare ChatListView, no ZStack, no opacity. Wrapping the app's main screen in
            // a permanent .opacity() compositing group cost per-frame GPU work for everyone -
            // the 4.0 "lag everywhere" regression. The KaPosts overlay is mounted only while
            // ACTIVE, and stays bare (no NavigationStack - overlaying a second wrapped
            // navigation controller on ChatListView's is a UIKit crash). Broadcasts NEEDS its
            // own NavigationStack (title + toolbar + room pushes), so that mode structurally
            // swaps ChatListView out instead of overlaying - the only slot state where the
            // chat list unmounts.
            if AppTab.chatsSlotCycle(from: settingsViewModel.settings).count > 1 {
                ZStack {
                    if chatsSlotMode == .broadcasts {
                        NavigationStack {
                            BroadcastListView()
                        }
                        .transition(.opacity)
                    } else {
                        ChatListView()
                            .opacity(chatsSlotMode == .chats ? 1 : 0)
                            .allowsHitTesting(chatsSlotMode == .chats)
                        if chatsSlotMode == .kaposts {
                            KaPostsView()
                                .transition(.opacity)
                        }
                    }
                }
            } else {
                ChatListView()
            }
        case .swap:
            SwapView()
        case .profile:
            ProfileView()
        case .kaposts:
            NavigationStack {
                KaPostsView()
                    .navigationTitle("KaPosts")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .broadcasts:
            NavigationStack {
                BroadcastListView()
            }
        case .more:
            // Tapping More presents the Customize Menu sheet and the selection snaps back to the
            // previous tab (see handleTabSelectionChange). UIKit can still land here for a frame
            // before the snap-back, so this page must be opaque and harmless - a pure Color.clear
            // here rendered as a stuck BLACK screen whenever the snap-back/reselect raced a menu
            // change.
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(systemName: AppTab.more.icon)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Customize Menu")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Chats-slot hold menu

    private static let dockBarHeight: CGFloat = 49
    private static let slotMenuItemWidth: CGFloat = 86
    private static let slotMenuHeight: CGFloat = 66

    private var windowBottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.bottom ?? 0
    }

    private var chatsSlotHoldOverlay: some View {
        GeometryReader { geo in
            let tabs = AppTab.visible(from: settingsViewModel.settings)
            let cycle = AppTab.chatsSlotCycle(from: settingsViewModel.settings)
            let count = max(tabs.count, 1)
            let slotWidth = geo.size.width / CGFloat(count)
            let chatsIndex = CGFloat(tabs.firstIndex(of: .chats) ?? 0)
            let hitHeight = Self.dockBarHeight + windowBottomInset
            let menuRect = slotMenuRect(in: geo.size, tabs: tabs, cycle: cycle)

            ZStack(alignment: .topLeading) {
                if slotMenuVisible {
                    slotMenuCard(options: cycle, rect: menuRect)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                }
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: slotWidth, height: hitHeight)
                    .offset(x: chatsIndex * slotWidth, y: geo.size.height - hitHeight)
                    .gesture(slotDragGesture(menuRect: menuRect, options: cycle))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "chatsSlotOverlay")
        }
        .ignoresSafeArea()
    }

    /// Menu card frame: centered above the Chats slot, clamped to the screen edges, floating
    /// just above the dock.
    private func slotMenuRect(in size: CGSize, tabs: [AppTab], cycle: [AppTab]) -> CGRect {
        let width = CGFloat(cycle.count) * Self.slotMenuItemWidth + 16
        let count = max(tabs.count, 1)
        let slotWidth = size.width / CGFloat(count)
        let chatsMid = (CGFloat(tabs.firstIndex(of: .chats) ?? 0) + 0.5) * slotWidth
        let x = min(max(8, chatsMid - width / 2), size.width - width - 8)
        let y = size.height - windowBottomInset - Self.dockBarHeight - Self.slotMenuHeight - 12
        return CGRect(x: x, y: y, width: width, height: Self.slotMenuHeight)
    }

    private func slotMenuCard(options: [AppTab], rect: CGRect) -> some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                VStack(spacing: 5) {
                    Image(systemName: option.icon)
                        .font(.system(size: 20, weight: .semibold))
                    Text(option.label)
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundColor(slotMenuHighlight == option ? .white
                                 : (chatsSlotMode == option ? .accentColor : .primary))
                .frame(width: Self.slotMenuItemWidth, height: Self.slotMenuHeight - 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(slotMenuHighlight == option ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(width: rect.width, height: rect.height)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                .shadow(color: Color.black.opacity(0.2), radius: 14, x: 0, y: 6)
        )
        .position(x: rect.midX, y: rect.midY)
    }

    private func slotDragGesture(menuRect: CGRect, options: [AppTab]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("chatsSlotOverlay"))
            .onChanged { value in
                if !slotDragActive {
                    slotDragActive = true
                    slotMenuArmTask?.cancel()
                    slotMenuArmTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard !Task.isCancelled, slotDragActive else { return }
                        Haptics.impact(.medium)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            slotMenuVisible = true
                        }
                    }
                }
                guard slotMenuVisible else { return }
                let highlight = slotMenuOption(at: value.location, rect: menuRect, options: options)
                if highlight != slotMenuHighlight {
                    slotMenuHighlight = highlight
                    if highlight != nil { Haptics.impact(.light) }
                }
            }
            .onEnded { value in
                slotMenuArmTask?.cancel()
                let menuWasOpen = slotMenuVisible
                let highlight = slotMenuHighlight
                withAnimation(.easeOut(duration: 0.15)) { slotMenuVisible = false }
                slotMenuHighlight = nil
                slotDragActive = false
                if menuWasOpen {
                    if let highlight {
                        Haptics.impact(.light)
                        selectChatsSlot(highlight)
                    }
                } else {
                    // Quick tap: exactly what tapping the real tab item did.
                    if selectedTab != AppTab.chats.tag {
                        handleTabSelectionChange(AppTab.chats.tag)
                    } else {
                        handleChatsTabReselection()
                    }
                }
            }
    }

    /// Generous hit test: anywhere within the card's horizontal span (with a little vertical
    /// slack) maps to an item, so sliding along the dock still highlights.
    private func slotMenuOption(at point: CGPoint, rect: CGRect, options: [AppTab]) -> AppTab? {
        let expanded = rect.insetBy(dx: 0, dy: -28)
        guard expanded.contains(point) else { return nil }
        let index = Int((point.x - rect.minX - 8) / Self.slotMenuItemWidth)
        guard options.indices.contains(index) else { return nil }
        return options[index]
    }

    private func selectChatsSlot(_ tab: AppTab) {
        if selectedTab != AppTab.chats.tag {
            handleTabSelectionChange(AppTab.chats.tag)
        }
        chatsSlotTab = tab
    }

    private func preloadProfileResources() {
        guard let address = walletManager.currentWallet?.publicAddress else { return }
        ProfileView.preloadQRCode(for: address)
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                handleTabSelectionChange(newValue)
            }
        )
    }

    private func handleTabSelectionChange(_ newValue: Int) {
        // "+ More" is not a destination: open Customize Menu, then snap the selection back to the
        // tab the user was on. UIKit moves the page BEFORE this setter runs, so refusing the new
        // value outright (the previous shape) left the TabView visually stuck on the More page
        // (rendered black) while the selection state disagreed - the "black screen" bug. Accept
        // the move, then revert on the next runloop tick so the TabView actually re-renders the
        // previous page, and present the sheet after that.
        if newValue == AppTab.more.tag {
            // Coalesced + latch-proof: a rapid double-tap (or SwiftUI writing the selection back)
            // could capture previous == More and "revert" onto the More placeholder forever,
            // re-presenting the sheet in a self-sustaining cycle.
            guard !isSnappingBackFromMore else { return }
            let previous = selectedTab == AppTab.more.tag ? 1 : selectedTab
            isSnappingBackFromMore = true
            selectedTab = newValue
            DispatchQueue.main.async {
                selectedTab = previous
                showCustomizeMenuSheet = true
                isSnappingBackFromMore = false
            }
            return
        }
        let previousValue = selectedTab
        selectedTab = newValue

        if previousValue == 1, newValue == 1 {
            handleChatsTabReselection()
            return
        }
        if previousValue == 1, newValue != 1, chatsSlotTab != .chats {
            // Leaving the Chats slot always lands back on the chat list next time. Guarded so an
            // ordinary tab switch doesn't write @State (and re-render) when nothing changes.
            chatsSlotTab = .chats
        }

        // Off-chat-tab power saving, DEBOUNCED so rapidly flipping tabs can't thrash start/stop
        // (which was restarting the initial sync and freezing the UI). Only the settled tab - after
        // a short quiet period - pauses or resumes the node pool's aggressive discovery/probe loops
        // and the fallback message-poll timer. The pool + UTXO subscription stay live, so sending,
        // on-demand balance/history and push keep working; only background scanning stops.
        tabWorkTask?.cancel()
        tabWorkTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if newValue == 1 {
                await NodePoolService.shared.resumeDiscovery()
                chatService.startPolling()
            } else {
                await NodePoolService.shared.pauseDiscovery()
                chatService.stopPollingTimerOnly()
            }
        }
    }

    private func handleChatsTabReselection() {
        // Re-tapping Chats advances the slot through its cycle - Chats, then whichever of
        // KaPosts/Broadcasts are enabled but masked out of the full dock, then back to Chats.
        let cycle = AppTab.chatsSlotCycle(from: settingsViewModel.settings)
        guard cycle.count > 1 else { return }
        let currentIndex = cycle.firstIndex(of: chatsSlotMode) ?? 0
        chatsSlotTab = cycle[(currentIndex + 1) % cycle.count]
    }

    /// Only reached reactively now, via `.showGiftClaim` (posted from `ChatDetailView` when a
    /// send fails for insufficient funds) - the unprompted auto-popup this used to also fire from
    /// on every launch/balance-zero/claim-state change was removed since the Welcome Guide's
    /// funding step now offers the same claim inline for new accounts, the moment they'd actually
    /// need it.
    private func presentGiftSheetIfEligibleForZeroBalance() {
        guard walletManager.currentWallet?.balanceSompi == 0 else { return }

        switch giftService.claimState {
        case .eligible:
            if !showGiftSheet {
                showGiftSheet = true
            }
        case .checking:
            Task { @MainActor in
                await giftService.checkEligibility()
                guard walletManager.currentWallet?.balanceSompi == 0 else { return }
                guard giftService.claimState == .eligible else { return }
                if !showGiftSheet {
                    showGiftSheet = true
                }
            }
        default:
            break
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(SettingsViewModel())
        .environmentObject(GiftService.shared)
        .environmentObject(BroadcastService.shared)
}
