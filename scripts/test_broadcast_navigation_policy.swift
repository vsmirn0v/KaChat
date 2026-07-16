import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct BroadcastNavigationPolicyTest {
    static func main() {
        expect(
            BroadcastNavigationPolicy.channelPresentationMode(isMacCatalyst: true) == .inlineReplacement,
            "Mac Catalyst broadcast rooms should render inline to avoid nested NavigationSplitView updates"
        )
        expect(
            BroadcastNavigationPolicy.channelPresentationMode(isMacCatalyst: false) == .navigationDestination,
            "iOS broadcast rooms should keep the native push destination"
        )

        expect(
            BroadcastNavigationPolicy.listPresentationMode(usesSplitLayout: true) == .splitDetail,
            "split-layout broadcast list should render in the detail column instead of pushing inside the sidebar"
        )
        expect(
            BroadcastNavigationPolicy.listPresentationMode(usesSplitLayout: false) == .navigationDestination,
            "compact broadcast list should keep the native push destination"
        )
    }
}
