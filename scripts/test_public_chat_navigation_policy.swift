import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PublicChatNavigationPolicyTest {
    static func main() {
        expect(
            PublicChatNavigationPolicy.channelPresentationMode(isMacCatalyst: true) == .inlineReplacement,
            "Mac Catalyst public chat rooms should render inline to avoid nested NavigationSplitView updates"
        )
        expect(
            PublicChatNavigationPolicy.channelPresentationMode(isMacCatalyst: false) == .navigationDestination,
            "iOS public chat rooms should keep the native push destination"
        )

        expect(
            PublicChatNavigationPolicy.listPresentationMode(usesSplitLayout: true) == .splitDetail,
            "split-layout public chat list should render in the detail column instead of pushing inside the sidebar"
        )
        expect(
            PublicChatNavigationPolicy.listPresentationMode(usesSplitLayout: false) == .navigationDestination,
            "compact public chat list should keep the native push destination"
        )
    }
}
