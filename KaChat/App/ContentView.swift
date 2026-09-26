import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        Group {
            switch LaunchRouter.route(
                isWalletMetadataLoading: walletManager.isLoading,
                hasCurrentWallet: walletManager.currentWallet != nil,
                isPendingSeedPhraseConfirmation: walletManager.isAwaitingSeedPhraseConfirmation,
                needsKeyRecovery: walletManager.walletNeedingKeyRecovery != nil
            ) {
            case .loading:
                LoadingView()
            case .mainApp:
                MainTabView()
            case .onboarding:
                OnboardingView()
            case .recovery:
                if let wallet = walletManager.walletNeedingKeyRecovery {
                    WalletRecoveryView(wallet: wallet)
                } else {
                    OnboardingView()
                }
            }
        }
        .animation(
            .easeInOut,
            value: walletManager.currentWallet != nil && !walletManager.isAwaitingSeedPhraseConfirmation
        )
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WalletManager.shared)
        .environmentObject(ContactsManager.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(SettingsViewModel())
}
