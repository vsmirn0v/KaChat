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
    /// Blocking progress while the post-onboarding sync runs.
    @State private var showInitialSyncProgress = false
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

    /// The Kaspa mark, pre-rendered at tab-bar size.
    ///
    /// UIKit's tab bar takes the tabItem's image and draws it at the image's OWN size - SwiftUI
    /// frame modifiers on it are ignored, which is why `.resizable().frame(22)` changed nothing
    /// and the mark still towered over the SF Symbols beside it. The only thing the bar honours
    /// is the image it is given, so the resize happens here, once, before it ever gets there.
    ///
    /// Drawn as a template so the tab bar's own selected/unselected tint applies, exactly as it
    /// does to the symbols, and aspect-fitted rather than squashed into the square.
    private static let dockKaspaLogo: Image? = {
        guard let source = UIImage(named: "KaspaLogo") else { return nil }
        let side: CGFloat = 24
        let scale = min(side / max(source.size.width, 1), side / max(source.size.height, 1))
        let fitted = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let origin = CGPoint(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2)
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            source.draw(in: CGRect(origin: origin, size: fitted))
        }
        return Image(uiImage: rendered.withRenderingMode(.alwaysTemplate))
    }()

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
                            if tab.usesKaspaLogo, let logo = Self.dockKaspaLogo {
                                logo
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
            // A hold with no guide to release it would strand the account: the branches below
            // that DON'T present a guide lift it explicitly, and this covers every other path in.
            if chatService.onboardingSyncHeld && !showWelcomeGuide && !walletManager.justCreatedNewWallet {
                chatService.releaseSyncForOnboarding()
            }
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
            } else {
                // No setup guide is coming, so nothing is waiting on it - lift any hold rather
                // than leaving the account permanently unsynced.
                chatService.releaseSyncForOnboarding()
            }
        }
        .sheet(isPresented: $showGiftSheet) {
            GiftClaimView()
        }
        .fullScreenCover(isPresented: $showInitialSyncProgress) {
            InitialSyncProgressModal(onDismiss: { showInitialSyncProgress = false })
        }
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(
                onFinished: {
                    showWelcomeGuide = false
                    resumeGuideAtUserType = false
                    // Everything the account owns starts syncing now, behind a sheet - a
                    // half-synced chat list invites taps on chats whose history has not landed.
                    if chatService.onboardingSyncHeld {
                        chatService.releaseSyncForOnboarding()
                        showInitialSyncProgress = true
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



// MARK: - Initial sync progress

/// Blocking progress shown once the setup wizard finishes, while the account's first full sync
/// runs. Nothing syncs during the wizard (see `ChatService.holdSyncForOnboarding`), so this is
/// where all of that work actually happens - and a half-populated chat list invites taps on
/// chats whose history has not arrived yet.
///
/// It is deliberately escapable. A sync can stall on a slow indexer or a bad network, and a
/// modal with no way out would be worse than an incomplete chat list, so "Continue anyway"
/// appears once it has been running a while.
private struct InitialSyncProgressModal: View {
    let onDismiss: () -> Void
    @EnvironmentObject var chatService: ChatService
    @State private var canSkip = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                if chatService.initialSyncPhase == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundColor(.green)
                    Text("You're all set")
                        .font(.headline)
                    Text("Your chats and history are up to date.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                } else {
                    ProgressView().controlSize(.large)
                    Text("Setting up your account")
                        .font(.headline)
                    Text(chatService.initialSyncPhase?.label ?? "Starting")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Downloading everything this account has on chain. It only takes this long once.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    if canSkip {
                        Button("Continue anyway", action: onDismiss)
                            .font(.subheadline)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .padding(.horizontal, 24)
        }
        .interactiveDismissDisabled(true)
        .task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            canSkip = true
        }
    }
}
