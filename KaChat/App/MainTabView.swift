import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 1
    @State private var lastActiveChatAddress: String?
    @State private var isChatReturnArmed = false
    /// Debounces the off-chat-tab discovery pause/resume so rapid tab-flipping can't thrash it.
    @State private var tabWorkTask: Task<Void, Never>?
    @State private var showGiftSheet = false
    @State private var showWelcomeGuide = false
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var giftService: GiftService
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(AppTab.visible(from: settingsViewModel.settings)) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.label, systemImage: tab.icon)
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
        .fullScreenCover(isPresented: $showWelcomeGuide) {
            WelcomeGuideView(onFinished: { showWelcomeGuide = false })
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            preloadProfileResources()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            // Switch to Chats tab when notification is tapped
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBroadcast)) { _ in
            // Switch to Chats tab when a broadcast-room notification is tapped
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGiftClaim)) { _ in
            presentGiftSheetIfEligibleForZeroBalance()
        }
        .onChange(of: chatService.activeConversationAddress) { newValue in
            guard let address = newValue else { return }
            lastActiveChatAddress = address
            isChatReturnArmed = false
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
            ChatListView()
        case .swap:
            SwapView()
        case .profile:
            ProfileView()
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
        let previousValue = selectedTab
        selectedTab = newValue

        if previousValue == 1, newValue == 1 {
            handleChatsTabReselection()
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
        if let activeAddress = chatService.activeConversationAddress {
            lastActiveChatAddress = activeAddress
            isChatReturnArmed = true
            return
        }

        guard isChatReturnArmed, let address = lastActiveChatAddress else { return }
        isChatReturnArmed = false
        NotificationCenter.default.post(
            name: .openChat,
            object: nil,
            userInfo: ["contactAddress": address]
        )
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
