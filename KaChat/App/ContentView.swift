import SwiftUI

struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager

    var body: some View {
        Group {
            if walletManager.isLoading {
                LoadingView()
            } else if walletManager.currentWallet != nil {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .animation(.easeInOut, value: walletManager.currentWallet != nil)
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
