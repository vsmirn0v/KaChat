import SwiftUI
import UIKit

/// A view wrapper that hides its content during screenshots and screen recording.
/// Uses the UITextField.isSecureTextEntry technique to leverage iOS's built-in
/// screen capture protection.
struct SecureView<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIView(context: Context) -> SecureContainerView<Content> {
        SecureContainerView(content: content)
    }

    func updateUIView(_ uiView: SecureContainerView<Content>, context: Context) {
        uiView.updateContent(content)
    }
}

final class SecureContainerView<Content: View>: UIView {
    private let secureField = UITextField()
    private var hostingController: UIHostingController<Content>?

    init(content: Content) {
        super.init(frame: .zero)
        setupSecureField()
        setupContent(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSecureField() {
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false
        addSubview(secureField)
        secureField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            secureField.topAnchor.constraint(equalTo: topAnchor),
            secureField.leadingAnchor.constraint(equalTo: leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: trailingAnchor),
            secureField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Find the secure container inside UITextField and use it as our content host
        guard let secureContainer = secureField.subviews.first(where: {
            type(of: $0).description().contains("TextLayoutCanvasView") ||
            type(of: $0).description().contains("_UITextFieldCanvasView") ||
            type(of: $0).description().contains("_UITextLayoutCanvasView")
        }) ?? secureField.subviews.first else {
            return
        }
        secureContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    private func setupContent(_ content: Content) {
        let hostVC = UIHostingController(rootView: content)
        hostVC.view.backgroundColor = .clear
        hostVC.view.translatesAutoresizingMaskIntoConstraints = false

        // Add the hosting view to the secure field's container
        let container = secureField.subviews.first ?? secureField
        container.addSubview(hostVC.view)

        NSLayoutConstraint.activate([
            hostVC.view.topAnchor.constraint(equalTo: container.topAnchor),
            hostVC.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostVC.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostVC.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        hostingController = hostVC
    }

    func updateContent(_ content: Content) {
        hostingController?.rootView = content
    }
}
