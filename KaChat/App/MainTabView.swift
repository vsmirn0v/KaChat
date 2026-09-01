import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var selectedTab = 1
    /// Customize Dock, hosted here rather than pushed inside a tab - see the notification's note.
    @State private var showCustomizeDock = false
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

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.visible(from: settingsViewModel.settings)) { tab in
                tabContent(for: tab)
                    .tabItem {
                        // Single Label whose VALUES vary (no structural if) - conditional tabItem
                        // content churns the tab bar's identity on every render.
                        Label {
                            Text(tab.label)
                        } icon: {
                            // Values vary, structure does not - the comment above is why this is
                            // one Label with a varying image rather than two Labels behind an if.
                            if tab.usesKaspaLogo {
                                // A resizable Image has no intrinsic tab-bar size the way an SF
                                // Symbol does, so without a frame it filled the slot and towered
                                // over its neighbours. 22pt matches the rendered height of the
                                // symbols beside it.
                                Image("KaspaLogo")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                            } else {
                                Image(systemName: tab.icon)
                            }
                        }
                    }
                    // Profile hosts the notification bell - surface its unread state on the
                    // dock as a plain red dot (an empty badge renders as a dot, not a count).
                    .badge(tab == .profile && notifCenter.unreadCount > 0 ? Text(" ") : nil)
                    .tag(tab.tag)
            }
        }
        .tint(.accentColor)
        .toast(message: nextcloudService.syncStatusToast)
        .onAppear {
            chatService.startPolling()
            preloadProfileResources()
            // A notification tapped from a cold start routed before this view existed - replay
            // its tab switch now that there's something to switch.
            consumePendingNotificationRoute()
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
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBroadcast)) { _ in
            routeToBroadcasts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openKaPost)) { _ in
            routeToKaPosts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPortfolio)) { _ in
            // Widget tap and spending-address receipts: land on Portfolio (its data is what the
            // widget shows either way), or Profile when Portfolio isn't in the dock.
            PendingTabRoute.pending = nil
            routeToWalletTab(.portfolio)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openColdStorage)) { _ in
            // Cold-storage address-activity notification tapped: the Storage tab, or the next
            // best wallet surface when it's hidden.
            PendingTabRoute.pending = nil
            routeToWalletTab(.coldStorage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { _ in
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCustomizeDock)) { _ in
            showCustomizeDock = true
        }
        .sheet(isPresented: $showCustomizeDock) {
            NavigationStack {
                MenuVisibilityView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showCustomizeDock = false }
                        }
                    }
            }
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
            // Bare ChatListView, no ZStack, no wrappers - a permanent compositing wrapper on the
            // app's main screen was the 4.0 "lag everywhere" regression, and the slot machinery
            // that needed one is gone now that Ecosystem holds the masked tabs.
            ChatListView()
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
        case .ecosystem:
            EcosystemView()
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

        // Re-tapping Ecosystem while inside one of its sections steps back out to the grid -
        // the same button that got you in gets you out.
        if previousValue == AppTab.ecosystem.tag, newValue == AppTab.ecosystem.tag {
            EcosystemRouter.shared.closeSection()
            return
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
            if newValue == AppTab.chats.tag {
                await NodePoolService.shared.resumeDiscovery()
                chatService.startPolling()
            } else {
                await NodePoolService.shared.pauseDiscovery()
                chatService.stopPollingTimerOnly()
            }
        }
    }

    // MARK: - Notification routing

    /// Broadcast notification or a shared room link: its own dock tab when the user has one,
    /// otherwise Ecosystem, which always holds whatever is not in the dock. BroadcastListView
    /// picks up the pending channel itself.
    private func routeToBroadcasts() { routeToFeature(.broadcasts) }

    /// KaPosts notification or a shared-post link. KaPostsView picks up the pending txid itself.
    private func routeToKaPosts() { routeToFeature(.kaposts) }

    /// Lands on a feature wherever it currently lives.
    ///
    /// Its own dock tab if it has one; otherwise Ecosystem with that section opened, which is
    /// where every non-docked feature now lives. If the user has hidden the feature outright its
    /// notifications still arrive - they are not gated on tab visibility - so this falls back to
    /// Chats rather than leaving the tap on whatever screen happened to be open.
    private func routeToFeature(_ feature: AppTab) {
        let visible = AppTab.visible(from: settingsViewModel.settings)
        if visible.contains(feature) {
            selectedTab = feature.tag
        } else if visible.contains(.ecosystem),
                  AppTab.ecosystemSections(from: settingsViewModel.settings).contains(feature) {
            EcosystemRouter.shared.openSection(feature)
            selectedTab = AppTab.ecosystem.tag
        } else {
            selectedTab = AppTab.chats.tag
        }
    }

    /// Wallet-event notifications (address activity, widget). `preferred` is the ideal tab;
    /// when the user has hidden it, fall back to Portfolio and finally to Profile, which is
    /// never hideable and shows the wallet's addresses and balances - so one of these always
    /// lands somewhere the money is visible.
    private func routeToWalletTab(_ preferred: AppTab) {
        let visible = AppTab.visible(from: settingsViewModel.settings)
        let target = [preferred, .portfolio, .profile].first { visible.contains($0) } ?? .profile
        handleTabSelectionChange(target.tag)
    }

    /// Cold-start replay of a notification tap's tab switch: the tap's NotificationCenter post
    /// is delivered before this view exists (the app is still on the loading/onboarding route),
    /// so its tab switch is lost while the pending target survives. The destination screens
    /// consume the target itself; this only puts the user on the tab that mounts them.
    private func consumePendingNotificationRoute() {
        if let tab = PendingTabRoute.pending {
            PendingTabRoute.pending = nil
            routeToWalletTab(tab)
            return
        }
        if BroadcastService.shared.pendingBroadcastNavigation != nil {
            routeToBroadcasts()
            return
        }
        if KaPostsDeepLink.pendingPostTxId != nil || KaPostsDeepLink.pendingOpenNotifications {
            routeToKaPosts()
            return
        }
        if chatService.pendingChatNavigation != nil ||
            GroupChatService.shared.pendingGroupNavigation != nil ||
            GroupChatService.shared.pendingGroupListNavigation {
            selectedTab = AppTab.chats.tag
        }
    }

    private func preloadProfileResources() {
        guard let address = walletManager.currentWallet?.publicAddress else { return }
        ProfileView.preloadQRCode(for: address)
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
    // Bumped for 4.1: the dock changed shape, so everyone sees this again rather than only the
    // users who never dismissed the 4.0 one.
    static let dismissedKey = "kachat_dock_wizard_dismissed_41"

    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    /// Drives the page-2 icon-morph demo through the sections Ecosystem holds.
    @State private var demoIndex = 0

    private let demoIcons = [AppTab.kaposts.icon, AppTab.broadcasts.icon, AppTab.swap.icon, AppTab.apps.icon]
    private let demoLabels = [AppTab.kaposts.label, AppTab.broadcasts.label, AppTab.swap.label, AppTab.apps.label]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                wizardPage(
                    icon: "sparkles",
                    title: "Meet Kaspa Hub",
                    text: "KaPosts, Broadcasts, ChangeNOW Swap and Kaspa Websites now live together in one place - Kaspa Hub, right in your dock.",
                    demo: { dockMock(highlightIcon: AppTab.ecosystem.icon, label: AppTab.ecosystem.label) }
                )
                .tag(0)

                wizardPage(
                    icon: "square.grid.2x2",
                    title: "Everything Inside",
                    text: "Open Kaspa Hub and pick what you want. Tap the Kaspa Hub tab again to come straight back out.",
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
                    icon: "slider.horizontal.3",
                    title: "Make It Yours",
                    text: "Every tab lives either in your dock or in Kaspa Hub - move any of them, Chats and Profile included. Five fit in the dock, and Kaspa Hub always keeps one of the slots. Customize Dock is in the Hub's top corner.",
                    demo: { dockMock(highlightIcon: "slider.horizontal.3", label: "Customize") }
                )
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 10) {
                Button {
                    Haptics.impact(.light)
                    if page < 2 {
                        withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                    } else {
                        dismiss()
                    }
                } label: {
                    Text(page < 2 ? "Next" : "Got It")
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
}
