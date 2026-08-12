import SwiftUI
import UIKit

/// Wraps `UIImagePickerController`'s camera source so a photo taken in-app can feed into the same
/// staging pipeline a library-picked photo already uses (`attachImageData(_:)` in
/// `ChatDetailView.swift`, the equivalent inline block in `GroupChatDetailView.swift`) - this view
/// only ever hands back raw JPEG `Data`, it has no opinion about what happens to it afterward.
/// `UIImagePickerController` handles the camera permission prompt itself off the
/// `NSCameraUsageDescription` Info.plist string, so no manual `AVCaptureDevice.requestAccess` call
/// is needed here (unlike `QRScannerView.swift`'s live-preview scanner, a different, lower-level
/// use case that reads frames directly rather than presenting a capture UI).
struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void
    /// When set, the camera UI offers its native Photo/Video mode switcher and recorded clips
    /// come back here as a temp-file URL (the caller owns deleting it). Nil keeps the picker
    /// photo-only — video has no on-chain send path, so callers enable this only when the
    /// Nextcloud media-send route can carry the file.
    var onCaptureVideo: ((URL) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if onCaptureVideo != nil {
            picker.mediaTypes = ["public.image", "public.movie"]
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel, onCaptureVideo: onCaptureVideo)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void
        private let onCaptureVideo: ((URL) -> Void)?

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void, onCaptureVideo: ((URL) -> Void)?) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            self.onCaptureVideo = onCaptureVideo
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Recorded video: the picker's media URL lives in a system temp spot that can be
            // reclaimed after dismissal — copy it into our own temp dir before handing it over.
            if let onCaptureVideo, let mediaURL = info[.mediaURL] as? URL {
                let stableURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kachat-capture-\(UUID().uuidString).\(mediaURL.pathExtension.isEmpty ? "mov" : mediaURL.pathExtension)")
                do {
                    try FileManager.default.copyItem(at: mediaURL, to: stableURL)
                    onCaptureVideo(stableURL)
                } catch {
                    onCancel()
                }
                return
            }
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            // JPEG-encoding a full-resolution camera photo (often 12MP+) is expensive enough to
            // visibly stall the dismiss animation if done synchronously on the main thread here.
            let onCapture = onCapture
            let onCancel = onCancel
            Task.detached(priority: .userInitiated) {
                guard let data = image.jpegData(compressionQuality: 0.9) else {
                    await MainActor.run { onCancel() }
                    return
                }
                await MainActor.run { onCapture(data) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
