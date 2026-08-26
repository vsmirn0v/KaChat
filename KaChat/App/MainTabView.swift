import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var selectedTab = 1
    /// Debounces the off-chat-tab discovery pause/resume so rapid tab-flipping can't thrash it.
    @State private var tabWorkTask: Task<Void, Never>?
    @State private var showGiftSheet = false
    @State private var showWelcomeGuide = false
    /// The guide is being re-presented because a first run was interrupted (app killed) before
    /// the Adult/Child step was answered - jump straight back to that step.
    @State private var resumeGuideAtUserType = false
    /// 4.0 "what's new" wizard: shown on every entry into the app until the user taps
    /// Don't Show Again (persisted per device).
    @State private var showDockWizard = false
    /// What the Chats slot currently shows: .chats, or a masked-out tab (.kaposts/.broadcasts)
    /// the user cycled to by re-tapping the Chats tab (see handleChatsTabReselection).
    @State private var chatsSlotTab: AppTab = .chats
    // Hold-the-Chats-tab slide menu (same mechanics as the chat composer's send-mode menu):
    // long-press arms a card above the dock, drag highlights, release selects.
    @State private var slotMenuVisible = false
    @State private var slotMenuHighlight: AppTab?
    @State private var slotMenuArmTask: Task<Void, Never>?
    @State private var slotMenuFailsafeTask: Task<Void, Never>?
    @State private var slotDragActive = false
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var giftService: GiftService
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    // Red dot on the Profile tab while the bell (which lives on the Profile screen)
    // holds unread notifications.
    @ObservedObject private var notifCenter = GlobalNotificationCenter.shared
    // Surfaces the Nextcloud silent auto-restore's one-line result ("Restored N messages...")
    // as a toast over whatever tab is showing - the automatic path has no modal by design.
    @ObservedObject private var nextcloudService = NextcloudService.shared

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
                    // Profile hosts the notification bell - surface its unread state on the
                    // dock as a plain red dot (an empty badge renders as a dot, not a count).
                    .badge(tab == .profile && notifCenter.unreadCount > 0 ? Text(" ") : nil)
                    .tag(tab.tag)
            }
        }
        .tint(.accentColor)
        .toast(message: nextcloudService.syncStatusToast)
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
            // Warm the portfolio view model: its init fetches the price and publishes the
            // Home Screen widget snapshot - without this, the widget stays empty until the
            // user first visits the Portfolio tab.
            _ = PortfolioViewModel.shared
            if walletManager.justCreatedNewWallet {
                walletManager.justCreatedNewWallet = false
                // Persisted BEFORE presenting: justCreatedNewWallet is in-memory only, so an
                // app kill mid-wizard would otherwise be a permanent way past the mandatory
                // Adult/Child step - the pending markers make the next launch re-present it.
                // The onboarding-run marker covers devices where Adult/Child was already
                // answered for a prior account ("chosen" never downgrades), so an interrupted
                // IMPORT wizard re-presents exactly like an interrupted create does.
                WelcomeGuideView.markUserTypePending()
                WelcomeGuideView.markOnboardingRunPending()
                showWelcomeGuide = true
            } else if WelcomeGuideView.isUserTypePending {
                // First-run guide was interrupted before the Adult/Child choice: bring the
                // wizard back at that step, on every launch, until it's answered.
                resumeGuideAtUserType = true
                showWelcomeGuide = true
            } else if WelcomeGuideView.isOnboardingRunPending {
                // Onboarding run interrupted AFTER the Adult/Child choice was already settled
                // (e.g. an import on a device that answered it for a prior account): re-present
                // the full guide from the top, still as an unskippable onboarding run.
                showWelcomeGuide = true
            } else if !UserDefaults.standard.bool(forKey: DockWizardView.dismissedKey),
                      !settingsViewModel.settings.childModeEnabled {
                // What's-new wizard, shown ONCE (any dismissal persists). Child Mode skips it
                // entirely - it describes the Chats cycle, which Child Mode doesn't have.
                // Slightly deferred so the first render settles before a sheet animates in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if !UserDefaults.standard.bool(forKey: DockWizardView.dismissedKey),
                       !settingsViewModel.settings.childModeEnabled {
                        showDockWizard = true
                    }
                }
            }
        }
        .sheet(isPresented: $showGiftSheet) {
            GiftClaimView()
        }
        .sheet(isPresented: $showDockWizard) {
            DockWizardView()
                .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(
                onFinished: {
                    showWelcomeGuide = false
                    resumeGuideAtUserType = false
                    // Fresh installs chain straight into the 4.0 what's-new wizard once the full
                    // setup guide is done (returning users get it from onAppear instead). Child
                    // Mode skips it - the guide's Child choice removes the Chats cycle it teaches.
                    if !UserDefaults.standard.bool(forKey: DockWizardView.dismissedKey),
                       !settingsViewModel.settings.childModeEnabled {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            showDockWizard = true
                        }
                    }
                },
                startAtUserType: resumeGuideAtUserType,
                // MainTabView only ever presents the guide for account onboarding (fresh
                // create/import or a kill/relaunch re-present) - Help replays live in
                // ContactsView, which leaves this false. Onboarding runs are fully unskippable.
                isOnboardingRun: true
            )
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
        .onReceive(NotificationCenter.default.publisher(for: .openKaPost)) { _ in
            // Shared-post link: land on KaPosts - its own dock tab when visible, else the
            // Chats slot cycled onto it. KaPostsView picks up the pending txid itself.
            if AppTab.visible(from: settingsViewModel.settings).contains(.kaposts) {
                selectedTab = AppTab.kaposts.tag
            } else if AppTab.kaPostsAccessibleViaChatsTab(from: settingsViewModel.settings) {
                chatsSlotTab = .kaposts
                selectedTab = 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPortfolio)) { _ in
            // Widget tap: land on Portfolio when it's in the dock (its data is what the
            // widget shows either way).
            if AppTab.visible(from: settingsViewModel.settings).contains(.portfolio) {
                handleTabSelectionChange(AppTab.portfolio.tag)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openColdStorage)) { _ in
            // Cold-storage address-activity notification tapped: land on the Storage tab
            // when it's in the dock; otherwise the default landing screen is fine.
            if AppTab.visible(from: settingsViewModel.settings).contains(.coldStorage) {
                handleTabSelectionChange(AppTab.coldStorage.tag)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { _ in
            if chatsSlotTab != .chats { chatsSlotTab = .chats }
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGiftClaim)) { _ in
            presentGiftSheetIfEligibleForZeroBalance()
        }
        .onChange(of: scenePhase) { phase in
            // Leaving the foreground mid-hold cancels the touch without onEnded - never let
            // the hold menu survive that.
            if phase != .active { resetSlotMenu() }
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
            // 3.0: bare ChatListView, no ZStack, no wrappers (a permanent compositing wrapper
            // on the app's main screen was the 4.0 "lag everywhere" regression).
            if AppTab.chatsSlotCycle(from: settingsViewModel.settings).count > 1 {
                // Structural swap per mode: each masked tab brings its OWN NavigationStack, so
                // KaPosts/Broadcasts render the identical UIKit header bar (dot / balance /
                // large title) as Chats - nothing shifts when cycling. Only one nav stack is
                // ever mounted at a time (overlaying two in a slot is a UIKit crash).
                ZStack {
                    switch chatsSlotMode {
                    case .kaposts:
                        KaPostsPageView()
                            .transition(.opacity)
                    case .broadcasts:
                        NavigationStack {
                            BroadcastListView()
                        }
                        .transition(.opacity)
                    default:
                        ChatListView()
                            .transition(.opacity)
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
            KaPostsPageView()
        case .broadcasts:
            NavigationStack {
                BroadcastListView()
            }
        case .apps:
            NavigationStack {
                ProfileAppsView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            ConnectionStatusIndicator()
                        }
                        ToolbarItem(placement: .principal) {
                            BalanceToolbarLabel()
                        }
                    }
            }
        case .more:
            // Retired: "+ More" can never be in the dock anymore (AppTab.isEnabled hard-hides
            // it), so this page is unreachable - kept only so the switch stays exhaustive,
            // and opaque just in case.
            Color(uiColor: .systemBackground).ignoresSafeArea()
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
                        // Failsafe: a cancelled touch (no onEnded) must never strand the menu.
                        slotMenuFailsafeTask?.cancel()
                        slotMenuFailsafeTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                            guard !Task.isCancelled else { return }
                            resetSlotMenu()
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
                let menuWasOpen = slotMenuVisible
                let highlight = slotMenuHighlight
                resetSlotMenu()
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

    /// Tears the hold-menu down completely. iOS can CANCEL a touch (backgrounding, incoming
    /// call, control center) without DragGesture.onEnded ever firing - that stranded the menu
    /// on screen until the next tap. Called on any scene-phase dip and by an 8s failsafe.
    private func resetSlotMenu() {
        slotMenuArmTask?.cancel()
        slotMenuArmTask = nil
        slotMenuFailsafeTask?.cancel()
        slotMenuFailsafeTask = nil
        slotDragActive = false
        if slotMenuVisible {
            withAnimation(.easeOut(duration: 0.15)) { slotMenuVisible = false }
        }
        slotMenuHighlight = nil
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


// MARK: - 4.0 dock wizard (what's new popup)

/// Multi-page walkthrough of the 4.0 dock: KaPosts and Broadcasts riding the Chats tab
/// (tap to cycle, hold to slide-select) and where to customize it. Presented from
/// MainTabView on every app entry until "Don't Show Again".
struct DockWizardView: View {
    static let dismissedKey = "kachat_dock_wizard_dismissed_40"

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    /// Drives the page-2 icon-morph demo.
    @State private var demoIndex = 0
    /// Drives the page-3 hold-and-slide demo: 0 = pressing the dock, 1 = menu popped,
    /// 2-4 = finger on Chats/KaPosts/Broadcasts, 5 = selected (menu gone, dock icon flipped).
    @State private var holdPhase = 0

    private let demoIcons = [AppTab.chats.icon, AppTab.kaposts.icon, AppTab.broadcasts.icon]
    private let demoLabels = [AppTab.chats.label, AppTab.kaposts.label, AppTab.broadcasts.label]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                wizardPage(
                    icon: "sparkles",
                    title: "What's New in 4.0",
                    text: "KaPosts - an on-chain social feed - and Broadcasts now live right behind your Chats tab. Everything happens on the Kaspa network, KaChat style.",
                    demo: { dockMock(highlightIcon: AppTab.kaposts.icon, label: AppTab.kaposts.label) }
                )
                .tag(0)

                wizardPage(
                    icon: "hand.tap",
                    title: "Tap Chats to Cycle",
                    text: "Already on Chats? Tap the Chats tab again to flip to KaPosts, again for Broadcasts, and once more to come back. The dock icon follows along.",
                    demo: {
                        dockMock(highlightIcon: demoIcons[demoIndex], label: demoLabels[demoIndex])
                            .onAppear { demoIndex = 0 }
                            .task {
                                while !Task.isCancelled {
                                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        demoIndex = (demoIndex + 1) % demoIcons.count
                                    }
                                }
                            }
                    }
                )
                .tag(1)

                wizardPage(
                    icon: "hand.draw",
                    title: "Hold to Jump",
                    text: "In a hurry? Press and hold the Chats tab - a menu pops up above the dock. Slide your finger onto Chats, KaPosts or Broadcasts and let go.",
                    demo: { holdMenuMock }
                )
                .tag(2)

                wizardPage(
                    icon: "slider.horizontal.3",
                    title: "Make It Yours",
                    text: "Everything is on by default. Turn tabs on and off (and reorder them) in Settings > Customization > Customize Dock. If the dock is full, KaPosts and Broadcasts stay reachable through the Chats tab.",
                    demo: { dockMock(highlightIcon: "slider.horizontal.3", label: "Customize") }
                )
                .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 10) {
                Button {
                    Haptics.impact(.light)
                    if page < 3 {
                        withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page < 3 ? "Next" : "Got It")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
            .padding(.top, 6)
        }
        .background(Color(uiColor: .systemBackground))
        // Shows exactly ONCE: any way out (Got It, swipe-down) persists the dismissal.
        // Replayable on demand from Profile > Help.
        .onDisappear {
            UserDefaults.standard.set(true, forKey: Self.dismissedKey)
        }
    }

    private func wizardPage<Demo: View>(
        icon: String,
        title: String,
        text: String,
        @ViewBuilder demo: () -> Demo
    ) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            Image(systemName: icon)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(26)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                )
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            demo()
                .padding(.top, 4)
            Spacer()
        }
        .padding(.top, 8)
    }

    /// A miniature dock with the Chats slot centered - `highlightIcon` morphs to show the
    /// cycling behavior. Real Liquid Glass on iOS 26+, the app's glass-card fallback earlier.
    private func dockMock(highlightIcon: String, label: String) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { index in
                VStack(spacing: 4) {
                    Image(systemName: index == 2 ? highlightIcon : mockIcon(index))
                        .font(.system(size: 20, weight: .semibold))
                        .frame(height: 24)
                    Text(index == 2 ? label : mockLabel(index))
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(index == 2 ? .accentColor : .secondary.opacity(0.55))
                .frame(width: 62)
                .id(index == 2 ? label : mockLabel(index))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(wizardGlass(cornerRadius: 22))
    }

    private func mockIcon(_ index: Int) -> String {
        [AppTab.portfolio.icon, AppTab.coldStorage.icon, "", AppTab.profile.icon, AppTab.swap.icon][index]
    }

    private func mockLabel(_ index: Int) -> String {
        [AppTab.portfolio.label, AppTab.coldStorage.label, "", AppTab.profile.label, AppTab.swap.label][index]
    }

    /// Liquid Glass on iOS 26+ (the system's real glass material), falling back to the app's
    /// established glass-card look - same pattern as KaPostsView's side-menu drawer.
    @ViewBuilder
    private func wizardGlass(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
        }
    }

    /// Animated hold-and-slide demo: the finger presses the Chats slot, the menu pops above
    /// the dock, the finger slides across the three options with the highlight following, and
    /// Broadcasts gets "picked" - then it loops.
    private var holdMenuMock: some View {
        let menuVisible = holdPhase >= 1 && holdPhase <= 4
        let highlightIndex = (2...4).contains(holdPhase) ? holdPhase - 2 : nil
        let itemWidth: CGFloat = 76
        // Finger target: on the dock's Chats slot while pressing/selected, else on the
        // highlighted menu item.
        let fingerX: CGFloat = {
            guard let highlightIndex else { return 0 }
            return (CGFloat(highlightIndex) - 1) * itemWidth
        }()
        let fingerY: CGFloat = menuVisible && highlightIndex != nil ? 30 : 118

        return ZStack(alignment: .top) {
            // Menu card (pops in above the dock).
            HStack(spacing: 0) {
                ForEach(Array(zip(demoIcons.indices, zip(demoIcons, demoLabels))), id: \.0) { index, pair in
                    VStack(spacing: 5) {
                        Image(systemName: pair.0)
                            .font(.system(size: 19, weight: .semibold))
                        Text(pair.1)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(highlightIndex == index ? .white : .primary)
                    .frame(width: itemWidth, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(highlightIndex == index ? Color.accentColor : Color.clear)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(wizardGlass(cornerRadius: 18))
            .scaleEffect(menuVisible ? 1 : 0.75, anchor: .bottom)
            .opacity(menuVisible ? 1 : 0)

            // Mini dock below; its Chats slot flips to the picked tab at the end of the loop.
            dockMock(
                highlightIcon: holdPhase == 5 ? AppTab.broadcasts.icon : AppTab.chats.icon,
                label: holdPhase == 5 ? AppTab.broadcasts.label : AppTab.chats.label
            )
            .padding(.top, 86)

            // The finger.
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 26))
                .foregroundColor(.accentColor)
                .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                .scaleEffect(holdPhase == 0 ? 0.85 : 1)
                .offset(x: fingerX + 12, y: fingerY)
                .opacity(holdPhase == 5 ? 0 : 1)
        }
        .frame(height: 165)
        .task {
            // Phase timeline, looping: press-and-hold -> menu pops -> slide across the three
            // options -> pick Broadcasts -> reset.
            while !Task.isCancelled {
                for (phase, holdNanos) in [(0, UInt64(900)), (1, 500), (2, 800), (3, 800), (4, 800), (5, 1_300)] {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        holdPhase = phase
                    }
                    try? await Task.sleep(nanoseconds: UInt64(holdNanos) * 1_000_000)
                    if Task.isCancelled { return }
                }
            }
        }
    }
}
