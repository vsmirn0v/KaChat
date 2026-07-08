import SwiftUI

/// Diagonal shimmer swept across a fee bubble while a fee estimate is loading - shared by 1:1
/// chat and broadcast rooms' compose bars so both fee bubbles look and animate identically.
struct FeeShimmerOverlay: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(20))
                .offset(x: phase * width * 1.5)
        }
    }
}
