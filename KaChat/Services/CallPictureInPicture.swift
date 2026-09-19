import Foundation
import AVKit
import UIKit
import WebRTC

/// The floating window of the other person during a video call - the system's own
/// Picture in Picture, the one FaceTime uses - so a call keeps its face while the user moves
/// around KaChat or into another app.
///
/// Fed by the remote tile of `CallView` (`RTCVideoView` registers the on-screen view and the
/// track); starts when the call screen is minimised (`CallService.minimize`) and, through
/// `canStartPictureInPictureAutomaticallyFromInline`, when the app is sent to the background
/// with the call screen up. Its restore button brings the call screen back.
@MainActor
final class CallPictureInPicture: NSObject, ObservableObject {
    static let shared = CallPictureInPicture()

    private var controller: AVPictureInPictureController?
    // Built on first use, not at launch: MainTabView observes this object from the app's first
    // frame, and a Metal-backed video view plus a PiP view controller are not free to create.
    private lazy var contentController: AVPictureInPictureVideoCallViewController = {
        let controller = AVPictureInPictureVideoCallViewController()
        controller.preferredContentSize = CGSize(width: 720, height: 1280)
        videoView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        return controller
    }()
    private lazy var videoView: RTCMTLVideoView = {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = .black
        return view
    }()
    private weak var track: RTCVideoTrack?
    /// Observed by MainTabView: the green return bar shows only while the window is NOT up.
    @Published private(set) var isActive = false

    private override init() {
        super.init()
    }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// The remote tile came on screen: this is where the floating window animates from, and
    /// the track it shows.
    func register(sourceView: UIView, track: RTCVideoTrack) {
        guard isSupported else { return }
        if self.track !== track {
            self.track?.remove(videoView)
            track.add(videoView)
            self.track = track
        }
        if controller == nil || controller?.contentSource?.activeVideoCallSourceView !== sourceView {
            let source = AVPictureInPictureController.ContentSource(
                activeVideoCallSourceView: sourceView,
                contentViewController: contentController
            )
            let controller = AVPictureInPictureController(contentSource: source)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.delegate = self
            self.controller = controller
        }
    }

    /// Floats the other person now (the user minimised the call screen). False when there is
    /// nothing to float - no remote video yet, or PiP unavailable.
    @discardableResult
    func start() -> Bool {
        guard let controller, track != nil, controller.isPictureInPicturePossible else { return false }
        guard !controller.isPictureInPictureActive else { return true }
        controller.startPictureInPicture()
        return true
    }

    func stop() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    /// The call is over: drop the window, the track and the source.
    func tearDown() {
        stop()
        if let track { track.remove(videoView) }
        track = nil
        controller = nil
        isActive = false
    }
}

extension CallPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        AppLog.log("[Call] Picture in Picture failed: %@", error.localizedDescription)
        Task { @MainActor in self.isActive = false }
    }

    /// The window's "back to the app" button: put the call screen up again.
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            CallService.shared.restore()
            // Let the call screen present before the window folds into it.
            try? await Task.sleep(nanoseconds: 300_000_000)
            completionHandler(true)
        }
    }
}
