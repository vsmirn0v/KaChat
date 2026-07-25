import Foundation

@main
struct LaunchRouterTest {
    static func main() {
        expect(
            LaunchRouter.route(isWalletMetadataLoading: true, hasCurrentWallet: true) == .mainApp,
            "known wallet should route to main app while background bootstrap continues"
        )
        expect(
            LaunchRouter.route(isWalletMetadataLoading: true, hasCurrentWallet: false) == .loading,
            "unknown wallet state should keep loading screen"
        )
        expect(
            LaunchRouter.route(isWalletMetadataLoading: false, hasCurrentWallet: false) == .onboarding,
            "loaded wallet state without a wallet should route to onboarding"
        )
        expect(
            LaunchRouter.route(isWalletMetadataLoading: false, hasCurrentWallet: true, isPendingSeedPhraseConfirmation: true) == .onboarding,
            "a freshly-created wallet awaiting seed phrase confirmation should stay on onboarding, not jump to main app"
        )
        expect(
            LaunchRouter.route(isWalletMetadataLoading: false, hasCurrentWallet: true, isPendingSeedPhraseConfirmation: false) == .mainApp,
            "a wallet with no pending seed phrase confirmation should route to main app as before"
        )

        print("PASS: LaunchRouter")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
