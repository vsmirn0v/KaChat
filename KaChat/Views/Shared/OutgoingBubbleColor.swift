import SwiftUI
import UIKit

/// The one colour of every message bubble you sent - 1:1, group and public room alike.
///
/// Light mode keeps the Kaspa teal the app has always used. Dark mode is a deeper teal: the
/// light value on a dark screen read as a pale green wash under white text, with too little
/// contrast to read comfortably (white on the deep value clears WCAG AA; on the light one it
/// did not). Resolved per trait collection, so a theme switch mid-session repaints it.
enum OutgoingBubble {
    static let color = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 22 / 255, green: 115 / 255, blue: 104 / 255, alpha: 1)
            : UIColor(red: 112 / 255, green: 199 / 255, blue: 186 / 255, alpha: 1)
    })
}
