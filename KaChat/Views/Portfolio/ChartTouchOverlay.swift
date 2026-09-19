import SwiftUI
import UIKit

/// Touch tracking for the portfolio charts: one finger scrubs (its x), two fingers pick a
/// range (both x positions). Reported in the overlay's own coordinates, on every touch change;
/// nil when the fingers lift.
///
/// A plain touch-handling view rather than gesture recognizers: SwiftUI's DragGesture only
/// ever sees one finger, and a pan recognizer reports a centroid, while a range needs each
/// finger's own position - and it needs them the moment the second finger lands, before
/// anything has moved.
struct ChartTouchOverlay: UIViewRepresentable {
    var onSingle: (CGFloat?) -> Void
    var onPair: ((CGFloat, CGFloat)?) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.onSingle = onSingle
        view.onPair = onPair
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.onSingle = onSingle
        uiView.onPair = onPair
    }

    final class TouchView: UIView {
        var onSingle: ((CGFloat?) -> Void)?
        var onPair: (((CGFloat, CGFloat)?) -> Void)?
        private var pairActive = false
        /// The page under the chart, frozen while the chart is being read: two fingers on a
        /// range, or one finger moving along the line. Without this the scroll view took the
        /// touches for a vertical scroll and the page moved under the fingers. A single finger
        /// that moves mostly up or down is left to the page, so the chart still scrolls past.
        private weak var lockedScrollView: UIScrollView?
        private var singleStart: CGPoint?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if singleStart == nil, let touch = touches.first { singleStart = touch.location(in: self) }
            report(event)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { report(event) }

        private func report(_ event: UIEvent?) {
            let touches = (event?.allTouches ?? [])
                .filter { $0.view === self && $0.phase != .ended && $0.phase != .cancelled }
            let live = touches.map { $0.location(in: self).x }.sorted()
            switch live.count {
            case 0:
                pairActive = false
                singleStart = nil
                unlockPage()
                onSingle?(nil)
                onPair?(nil)
            case 1:
                if let start = singleStart, let touch = touches.first {
                    let now = touch.location(in: self)
                    let dx = abs(now.x - start.x), dy = abs(now.y - start.y)
                    if dx > 8, dx > dy { lockPage() }
                }
                // A range stays on screen once one finger lifts; lifting the last one clears it.
                if !pairActive { onSingle?(live[0]) }
            default:
                pairActive = true
                lockPage()
                onSingle?(nil)
                onPair?((live[0], live[live.count - 1]))
            }
        }

        private func lockPage() {
            guard lockedScrollView == nil else { return }
            var view: UIView? = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard let scrollView = view as? UIScrollView, scrollView.isScrollEnabled else { return }
            scrollView.isScrollEnabled = false
            lockedScrollView = scrollView
        }

        private func unlockPage() {
            lockedScrollView?.isScrollEnabled = true
            lockedScrollView = nil
        }
    }
}
