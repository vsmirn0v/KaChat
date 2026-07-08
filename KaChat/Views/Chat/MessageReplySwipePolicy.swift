import CoreGraphics

enum MessageReplySwipePolicy {
    static let triggerDistance: CGFloat = 64
    static let maxVisualOffset: CGFloat = 64

    static func visualOffset(
        for translation: CGSize,
        maxOffset: CGFloat = maxVisualOffset
    ) -> CGFloat {
        guard isLeftHorizontal(translation) else { return 0 }
        return max(translation.width, -maxOffset)
    }

    static func shouldTriggerReply(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Bool {
        guard isLeftHorizontal(translation) || isLeftHorizontal(predictedEndTranslation) else {
            return false
        }
        return min(translation.width, predictedEndTranslation.width) <= -triggerDistance
    }

    private static func isLeftHorizontal(_ translation: CGSize) -> Bool {
        guard translation.width < 0 else { return false }
        return abs(translation.width) > abs(translation.height)
    }
}
