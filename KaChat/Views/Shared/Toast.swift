import SwiftUI

enum ToastStyle: String {
    case success
    case error

    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success:
            return .green
        case .error:
            return .red
        }
    }
}

struct ToastBanner: View {
    let message: String
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.iconName)
                .foregroundColor(style.iconColor)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 16)
    }
}

struct ToastPresenter: ViewModifier {
    let message: String?
    let style: ToastStyle

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                ToastBanner(message: message, style: style)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 12)
            }
        }
    }
}

extension View {
    func toast(message: String?, style: ToastStyle = .success) -> some View {
        modifier(ToastPresenter(message: message, style: style))
    }
}
