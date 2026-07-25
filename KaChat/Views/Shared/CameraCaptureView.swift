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

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
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
