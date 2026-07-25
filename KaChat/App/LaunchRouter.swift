import Foundation

enum LaunchRoute: Equatable {
    case loading
    case mainApp
    case onboarding
}

enum LaunchRouter {
    /// `isPendingSeedPhraseConfirmation` covers the window where `WalletManager.createWallet`
    /// has already generated and persisted a new wallet (so `hasCurrentWallet` is `true`) but the
    /// user hasn't yet reviewed/acknowledged its seed phrase on `CreateWalletView` - routing to
    /// `.mainApp` during that window would tear down the seed-phrase screen before it's had a
    /// chance to be read, or even shown at all. Defaults to `false` so every other caller
    /// (imports, app relaunch with an already-confirmed wallet) is unaffected.
    static func route(
        isWalletMetadataLoading: Bool,
        hasCurrentWallet: Bool,
        isPendingSeedPhraseConfirmation: Bool = false
    ) -> LaunchRoute {
        if hasCurrentWallet && !isPendingSeedPhraseConfirmation {
            return .mainApp
        }
        return isWalletMetadataLoading ? .loading : .onboarding
    }
}
