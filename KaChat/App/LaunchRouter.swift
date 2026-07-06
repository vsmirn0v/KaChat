import Foundation

enum LaunchRoute: Equatable {
    case loading
    case mainApp
    case onboarding
}

enum LaunchRouter {
    static func route(isWalletMetadataLoading: Bool, hasCurrentWallet: Bool) -> LaunchRoute {
        if hasCurrentWallet {
            return .mainApp
        }
        return isWalletMetadataLoading ? .loading : .onboarding
    }
}
