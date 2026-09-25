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

// MARK: - Swipe-back off while a chart is up

extension View {
    /// The navigation stack's swipe-back is off while this screen is on top. A finger scrubbing
    /// along a chart from near the left edge was being taken for a swipe out of the page, and
    /// the two fought over every drag. The back button still works; the gesture returns the
    /// moment the screen goes away.
    func swipeBackDisabled() -> some View {
        background(SwipeBackDisabler())
    }
}

private struct SwipeBackDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) {}

    static func dismantleUIView(_ uiView: Probe, coordinator: ()) {
        uiView.restore()
    }

    final class Probe: UIView {
        private var disabled: [UIGestureRecognizer] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                restore()
            } else {
                // The view controller chain is complete a beat after the view lands.
                DispatchQueue.main.async { [weak self] in self?.disableSwipeBack() }
            }
        }

        private func disableSwipeBack() {
            guard window != nil, disabled.isEmpty else { return }
            var responder: UIResponder? = self
            var navigation: UINavigationController?
            while let current = responder, navigation == nil {
                if let found = current as? UINavigationController {
                    navigation = found
                } else if let controller = current as? UIViewController {
                    navigation = controller.navigationController
                }
                responder = current.next
            }
            guard let navigation else { return }
            var recognizers: [UIGestureRecognizer] = []
            if let pop = navigation.interactivePopGestureRecognizer { recognizers.append(pop) }
            // The full-width swipe back some builds add beside the edge one.
            for recognizer in navigation.view.gestureRecognizers ?? [] where recognizer !== navigation.interactivePopGestureRecognizer {
                let name = String(describing: type(of: recognizer))
                if name.contains("ParallaxTransitionPan") || name.contains("PopGesture") {
                    recognizers.append(recognizer)
                }
            }
            for recognizer in recognizers where recognizer.isEnabled {
                recognizer.isEnabled = false
                disabled.append(recognizer)
            }
        }

        func restore() {
            for recognizer in disabled { recognizer.isEnabled = true }
            disabled = []
        }
    }
}
