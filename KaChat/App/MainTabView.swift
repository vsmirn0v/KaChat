import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 1
    @State private var lastActiveChatAddress: String?
    @State private var isChatReturnArmed = false
    @State private var showGiftSheet = false
    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @EnvironmentObject var giftService: GiftService

    var body: some View {
        TabView(selection: tabSelection) {
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(0)

            ChatListView()
                .tabItem {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(1)

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(2)
        }
        .tint(.accentColor)
        .onAppear {
            chatService.startPolling()
            preloadProfileResources()
            // Show gift sheet only when wallet balance is zero and gift is not yet claimed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                presentGiftSheetIfEligibleForZeroBalance()
            }
        }
        .sheet(isPresented: $showGiftSheet) {
            GiftClaimView()
        }
        .onChange(of: walletManager.currentWallet?.publicAddress) { _ in
            preloadProfileResources()
        }
        .onChange(of: walletManager.currentWallet?.balanceSompi) { newValue in
            guard newValue == 0 else { return }
            presentGiftSheetIfEligibleForZeroBalance()
        }
        .onChange(of: giftService.claimState) { _ in
            presentGiftSheetIfEligibleForZeroBalance()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChat)) { _ in
            // Switch to Chats tab when notification is tapped
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
        .alert(
            "High Transaction Traffic",
            isPresented: Binding(
                get: { chatService.noisyContactWarning != nil },
                set: { if !$0 { chatService.dismissNoisyContactWarning() } }
            ),
            presenting: chatService.noisyContactWarning
        ) { warning in
            Button("Disable", role: .destructive) {
                chatService.disableRealtimeForContact(warning.contactAddress)
            }
            Button("Dismiss", role: .cancel) {
                chatService.dismissNoisyContactWarning()
            }
        } message: { warning in
            Text("\(warning.contactAlias) has produced \(warning.txCount) transactions in the last minute that are not relevant to you. This consumes battery and network resources.\n\nDisable real-time updates for this contact? Messages will still be fetched periodically.")
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

        guard previousValue == 1, newValue == 1 else { return }
        handleChatsTabReselection()
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
}
