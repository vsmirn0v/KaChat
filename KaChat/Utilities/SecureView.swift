import SwiftUI
import UIKit

/// Blurs/hides its content while the screen is actively being recorded, mirrored, or AirPlayed
/// (`UIScreen.main.isCaptured`) - the only thing iOS actually lets an app detect and react to in
/// real time. There is no API to prevent a screenshot itself (only to detect one after the fact
/// via `UIApplication.userDidTakeScreenshotNotification`), so this protects against a live feed
/// of the screen leaving the device, not a single screenshot.
///
/// Previously implemented via a `UITextField.isSecureTextEntry` trick that hosted the content
/// inside the text field's internal secure-rendering subview, found by matching undocumented
/// private view class names (`_UITextFieldCanvasView` etc.). That hierarchy isn't guaranteed
/// stable across iOS versions - when the expected subview isn't found, the content silently never
/// renders, making the seed phrase permanently invisible rather than merely unprotected. This
/// replacement never depends on Apple's private view internals, so it can't fail in that way.
struct SecureView<Content: View>: View {
    let content: Content
    @State private var isCaptured = UIScreen.main.isCaptured

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .blur(radius: isCaptured ? 20 : 0)
            .overlay {
                if isCaptured {
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .font(.title)
                        Text("Hidden while screen is being recorded or mirrored")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.secondary)
                    .padding()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isCaptured)
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                isCaptured = UIScreen.main.isCaptured
            }
    }
}
