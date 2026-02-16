import Foundation

#if os(iOS)
import UIKit
#endif

enum Haptics {
    static func success() {
        #if os(iOS)
        #if !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        #endif
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if os(iOS)
        #if !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
        #endif
    }

    static func selection() {
        #if os(iOS)
        #if !targetEnvironment(macCatalyst)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
        #endif
    }
}
