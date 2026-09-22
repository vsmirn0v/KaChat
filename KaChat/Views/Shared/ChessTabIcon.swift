import SwiftUI
import UIKit

/// The Chess section's icon: a rook and a knight, side by side. SF Symbols has no chess
/// pieces, so the two glyphs are rendered once into a template image, at the size each place
/// wants, and tinted like any symbol - the tab bar honours only the image's own size (see
/// `MainTabView.dockKaspaLogo`), which is why this renders rather than styling text.
enum ChessTabIcon {
    private static var cache: [Int: UIImage] = [:]

    /// A template image `side` points tall, the rook and knight filling the width.
    static func image(side: CGFloat) -> UIImage {
        let key = Int(side.rounded())
        if let cached = cache[key] { return cached }
        let width = side * 1.55
        let font = UIFont.systemFont(ofSize: side * 1.08, weight: .regular)
        let text = NSAttributedString(string: "♜♞", attributes: [.font: font, .foregroundColor: UIColor.black])
        let measured = text.size()
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: side)).image { _ in
            text.draw(at: CGPoint(x: (width - measured.width) / 2, y: (side - measured.height) / 2))
        }
        let template = rendered.withRenderingMode(.alwaysTemplate)
        cache[key] = template
        return template
    }

    static func view(side: CGFloat) -> some View {
        Image(uiImage: image(side: side))
            .renderingMode(.template)
            .foregroundStyle(Color.accentColor)
    }
}
