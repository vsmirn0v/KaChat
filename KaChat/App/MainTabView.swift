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
    /// KaPosts is enabled but didn't fit the 5-item dock: re-tapping the Chats tab toggles the
    /// Chats slot between the chat list and KaPosts (see handleChatsTabReselection).
    @State private var showKaPostsViaChats = false
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var giftService: GiftService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    /// Chats slot is currently flipped to KaPosts (full-dock re-tap mode) AND the mode is still
    /// available - the single source of truth for the slot content, the dock label, and hit-testing.
    private var kaPostsViaChatsActive: Bool {
        showKaPostsViaChats && AppTab.kaPostsAccessibleViaChatsTab(from: settingsViewModel.settings)
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
                            tab == .chats && kaPostsViaChatsActive ? AppTab.kaposts.label : tab.label,
                            systemImage: tab == .chats && kaPostsViaChatsActive ? AppTab.kaposts.icon : tab.icon
                        )
                    }
                    .tag(tab.tag)
            }
        }
        .tint(.accentColor)
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
            if showKaPostsViaChats { showKaPostsViaChats = false }
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBroadcast)) { _ in
            // Switch to Chats tab when a broadcast-room notification is tapped
            if showKaPostsViaChats { showKaPostsViaChats = false }
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGroup)) { _ in
            if showKaPostsViaChats { showKaPostsViaChats = false }
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
            // When the re-tap mode is unavailable (most users), this is BYTE-IDENTICAL to 3.0:
            // bare ChatListView, no ZStack, no opacity. Wrapping the app's main screen in a
            // permanent .opacity() compositing group cost per-frame GPU work for everyone - the
            // 4.0 "lag everywhere" regression. The ZStack shape exists only while the mode is on,
            // and the KaPosts overlay (a .regularMaterial blur) is mounted only while ACTIVE -
            // parking a blur layer at opacity 0 behind a scrolling list is real compositing cost.
            // (KaPosts stays bare - no NavigationStack - since ChatListView already hosts one;
            // nesting two wrapped navigation controllers in a slot is a UIKit crash.)
            if AppTab.kaPostsAccessibleViaChatsTab(from: settingsViewModel.settings) {
                ZStack {
                    ChatListView()
                        .opacity(kaPostsViaChatsActive ? 0 : 1)
                        .allowsHitTesting(!kaPostsViaChatsActive)
                    if kaPostsViaChatsActive {
                        KaPostsView()
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
            NavigationStack {
                KaPostsView()
                    .navigationTitle("KaPosts")
                    .navigationBarTitleDisplayMode(.inline)
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
        if previousValue == 1, newValue != 1, showKaPostsViaChats {
            // Leaving the Chats slot always lands back on the chat list next time. Guarded so an
            // ordinary tab switch doesn't write @State (and re-render) when nothing changes.
            showKaPostsViaChats = false
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
        // Re-tapping Chats always toggles the slot between Chats and KaPosts (the old
        // return-to-last-chat gesture was removed in favor of a predictable flip).
        if AppTab.kaPostsAccessibleViaChatsTab(from: settingsViewModel.settings) {
            showKaPostsViaChats.toggle()
        }
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
