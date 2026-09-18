import SwiftUI
import AVFoundation

/// The caller's own camera while a video call is still ringing - before there is a WebRTC
/// track to show. One capture session, started when a video call is placed and stopped the
/// moment WebRTC takes the camera over (`CallService.joinAndSignal`), since iOS lets only one
/// session hold the device.
final class CallCameraPreview: @unchecked Sendable {
    static let shared = CallCameraPreview()

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "kachat.call.camera-preview")
    private var configured = false

    private init() {}

    func start() {
        queue.async { [self] in
            if !configured {
                session.beginConfiguration()
                session.sessionPreset = .medium
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                   let input = try? AVCaptureDeviceInput(device: device),
                   session.canAddInput(input) {
                    session.addInput(input)
                }
                session.commitConfiguration()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Returns only once the camera is free for the next owner (WebRTC's capturer).
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }
}

/// Shows `CallCameraPreview` as the camera sees it - not mirrored, like the live track.
struct CallCameraPreviewView: UIViewRepresentable {
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = CallCameraPreview.shared.session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if let connection = uiView.previewLayer.connection, connection.isVideoMirrored {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}
