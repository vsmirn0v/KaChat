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

extension String {
    /// App-standard toast text for copying an address: "Address kaspa:qz3x...m2aj...8f2k copied".
    /// Every address-copy confirmation across the app must use this so the wording and the
    /// shortened form cannot drift between screens.
    var addressCopiedToastText: String {
        "Address \(addressToastShortened) copied"
    }

    /// Standard shortened form used inside the copy toast: the "kaspa:"/"kaspatest:" prefix,
    /// then the first 4 payload characters, 4 characters from the exact middle of the payload,
    /// and the last 4, joined with "..." - three visible segments so a lookalike-address swap
    /// is harder to miss. Short or abnormal strings fall back to the plain value.
    private var addressToastShortened: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        let payload: String
        if let colon = trimmed.firstIndex(of: ":") {
            prefix = String(trimmed[...colon])
            payload = String(trimmed[trimmed.index(after: colon)...])
        } else {
            prefix = ""
            payload = trimmed
        }
        // Only shorten when the three 4-char segments plus separators actually save space
        // and the segments cannot overlap; otherwise show the value as-is.
        guard payload.count >= 24 else { return trimmed }
        let chars = Array(payload)
        let first = String(chars[0..<4])
        let midStart = chars.count / 2 - 2
        let middle = String(chars[midStart..<(midStart + 4)])
        let last = String(chars[(chars.count - 4)...])
        return "\(prefix)\(first)...\(middle)...\(last)"
    }
}
