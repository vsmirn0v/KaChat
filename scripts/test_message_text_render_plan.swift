import Foundation

@main
struct MessageTextRenderPlanTest {
    static func main() {
        expect(
            MessageTextRenderPlan.requiresLinkTextView("Plain chat text without a URL") == false,
            "plain messages should use the lightweight text renderer"
        )
        expect(
            MessageTextRenderPlan.requiresLinkTextView("Visit https://kaspa.org for details"),
            "https links should use the link-capable renderer"
        )
        expect(
            MessageTextRenderPlan.requiresLinkTextView("Open http://example.com now"),
            "http links should use the link-capable renderer"
        )
        expect(
            MessageTextRenderPlan.requiresLinkTextView("ftp://example.com is not tappable here") == false,
            "non-http links should stay on the lightweight renderer"
        )

        print("PASS: MessageTextRenderPlan")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
