import CoreGraphics
import Foundation

@main
struct MessageReplySwipePolicyTest {
    static func main() {
        expect(
            MessageReplySwipePolicy.shouldTriggerReply(
                translation: CGSize(width: -72, height: 8),
                predictedEndTranslation: CGSize(width: -74, height: 8)
            ),
            "left horizontal drag at the trigger distance should reply"
        )
        expect(
            MessageReplySwipePolicy.shouldTriggerReply(
                translation: CGSize(width: -30, height: 4),
                predictedEndTranslation: CGSize(width: -104, height: 4)
            ),
            "fast left flick with enough predicted travel should reply"
        )
        expect(
            MessageReplySwipePolicy.shouldTriggerReply(
                translation: CGSize(width: -84, height: 88),
                predictedEndTranslation: CGSize(width: -100, height: 108)
            ) == false,
            "mostly vertical drags should stay available for scrolling"
        )
        expect(
            MessageReplySwipePolicy.shouldTriggerReply(
                translation: CGSize(width: -44, height: 2),
                predictedEndTranslation: CGSize(width: -52, height: 2)
            ) == false,
            "short left drags should not reply"
        )
        expect(
            MessageReplySwipePolicy.visualOffset(for: CGSize(width: -120, height: 4)) == -64,
            "visual offset should clamp at the maximum pull distance"
        )
        expect(
            MessageReplySwipePolicy.visualOffset(for: CGSize(width: 40, height: 2)) == 0,
            "right drags should not move the row for left-swipe reply"
        )

        print("PASS: MessageReplySwipePolicy")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
