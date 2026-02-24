import SwiftUI
import UIKit

struct KNSAvatarView: View {
    let avatarURLString: String?
    let fallbackText: String
    var size: CGFloat = 44

    private var avatarURL: URL? {
        KNSProfileLinkBuilder.websiteURL(from: avatarURLString)
    }

    private var initials: String {
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }

        let words = trimmed.split(separator: " ").prefix(2)
        if words.count >= 2 {
            let chars = words.compactMap { $0.first }.map { String($0).uppercased() }.joined()
            if !chars.isEmpty { return chars }
        }
        return String(trimmed.prefix(2)).uppercased()
    }

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL, transaction: Transaction(animation: .easeInOut(duration: 0.15))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        fallbackAvatar
                            .overlay {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                    case .failure:
                        fallbackAvatar
                    @unknown default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var fallbackAvatar: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.2))
            .overlay(
                Text(initials)
                    .font(.system(size: max(12, size * 0.34), weight: .semibold))
                    .foregroundColor(.accentColor)
            )
    }
}

struct KNSAvatarFullscreenView: View {
    let avatarURLString: String?
    let fallbackText: String
    var title: String = "Avatar"

    @Environment(\.dismiss) private var dismiss
    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var showShareSheet = false
    @State private var lastLoadedURL: String?

    private var avatarURL: URL? {
        KNSProfileLinkBuilder.websiteURL(from: avatarURLString)
    }

    private var canShare: Bool {
        loadedImage != nil || avatarURL != nil
    }

    private var shareItems: [Any] {
        if let loadedImage {
            return [loadedImage]
        }
        if let avatarURL {
            return [avatarURL]
        }
        return []
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let loadedImage {
                    Image(uiImage: loadedImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    KNSAvatarView(
                        avatarURLString: avatarURLString,
                        fallbackText: fallbackText,
                        size: 220
                    )
                }
            }
            .padding(20)

            if isLoading && loadedImage == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.1)
            }
        }
        .overlay(alignment: .top) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Circle())
                }

                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Circle())
                }
                .disabled(!canShare)
                .opacity(canShare ? 1 : 0.45)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .task(id: avatarURL?.absoluteString) {
            await loadRemoteAvatarIfNeeded()
        }
        .sheet(isPresented: $showShareSheet) {
            if shareItems.isEmpty {
                EmptyView()
            } else {
                KNSAvatarShareSheet(activityItems: shareItems)
            }
        }
    }

    @MainActor
    private func loadRemoteAvatarIfNeeded() async {
        guard let avatarURL else {
            loadedImage = nil
            lastLoadedURL = nil
            isLoading = false
            return
        }

        let absolute = avatarURL.absoluteString
        if lastLoadedURL == absolute, loadedImage != nil {
            return
        }

        if lastLoadedURL != absolute {
            loadedImage = nil
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: avatarURL)
            guard !Task.isCancelled else { return }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return
            }
            guard let image = UIImage(data: data) else { return }

            loadedImage = image
            lastLoadedURL = absolute
        } catch {
            // Ignore load failures and keep fallback avatar.
        }
    }
}

private struct KNSAvatarShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum KNSProfileLinkBuilder {
    static func websiteURL(from raw: String?) -> URL? {
        guard let value = normalizedValue(raw) else { return nil }
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(value)")
    }

    static func xURL(from raw: String?) -> URL? {
        handleURL(
            from: raw,
            canonicalHost: "x.com",
            acceptedHosts: ["x.com", "www.x.com", "twitter.com", "www.twitter.com"]
        )
    }

    static func telegramURL(from raw: String?) -> URL? {
        handleURL(
            from: raw,
            canonicalHost: "t.me",
            acceptedHosts: ["t.me", "www.t.me", "telegram.me", "www.telegram.me"]
        )
    }

    static func githubURL(from raw: String?) -> URL? {
        handleURL(
            from: raw,
            canonicalHost: "github.com",
            acceptedHosts: ["github.com", "www.github.com"]
        )
    }

    static func emailURL(from raw: String?) -> URL? {
        guard var value = normalizedValue(raw) else { return nil }
        if value.lowercased().hasPrefix("mailto:") {
            value = String(value.dropFirst("mailto:".count))
        }
        guard !value.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = value
        return components.url
    }

    /// Discord profile links only support numeric user IDs (snowflakes).
    static func discordURL(from raw: String?) -> URL? {
        let acceptedHosts = ["discord.com", "www.discord.com", "discordapp.com", "www.discordapp.com"]
        guard var value = normalizedValue(raw) else { return nil }

        if let directURL = URL(string: value), let scheme = directURL.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                guard let host = directURL.host?.lowercased() else { return nil }
                guard acceptedHosts.contains(host) else { return nil }
                let parts = directURL.pathComponents.filter { $0 != "/" }
                guard parts.count >= 2, parts[0].lowercased() == "users" else { return nil }
                value = parts[1]
            } else {
                return nil
            }
        } else {
            value = stripURLDecoration(value)
            if let extracted = stripKnownHostPrefix(value, hosts: acceptedHosts) {
                value = extracted
            }
            if value.lowercased().hasPrefix("users/") {
                value = String(value.dropFirst("users/".count))
            }
        }

        value = trimmedHandle(value)
        guard isDiscordUserID(value) else { return nil }
        return URL(string: "https://discord.com/users/\(value)")
    }

    private static func handleURL(from raw: String?, canonicalHost: String, acceptedHosts: [String]) -> URL? {
        guard var value = normalizedValue(raw) else { return nil }

        if let directURL = URL(string: value), let scheme = directURL.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                if let host = directURL.host?.lowercased(), acceptedHosts.contains(host) {
                    guard let firstPathComponent = directURL.pathComponents.first(where: { $0 != "/" }) else {
                        return nil
                    }
                    value = firstPathComponent
                } else {
                    return directURL
                }
            } else {
                return directURL
            }
        } else {
            value = stripURLDecoration(value)
            if let extracted = stripKnownHostPrefix(value, hosts: acceptedHosts) {
                value = extracted
            }
        }

        value = trimmedHandle(value)
        guard !value.isEmpty else { return nil }

        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://\(canonicalHost)/\(encoded)")
    }

    private static func normalizedValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripURLDecoration(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("https://") {
            return String(value.dropFirst("https://".count))
        }
        if lower.hasPrefix("http://") {
            return String(value.dropFirst("http://".count))
        }
        return value
    }

    private static func stripKnownHostPrefix(_ value: String, hosts: [String]) -> String? {
        let lower = value.lowercased()
        for host in hosts {
            if lower == host {
                return ""
            }
            if lower.hasPrefix("\(host)/") {
                return String(value.dropFirst(host.count + 1))
            }
        }
        return nil
    }

    private static func trimmedHandle(_ value: String) -> String {
        var output = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("@") {
            output.removeFirst()
        }
        if let slash = output.firstIndex(of: "/") {
            output = String(output[..<slash])
        }
        if let query = output.firstIndex(of: "?") {
            output = String(output[..<query])
        }
        if let hash = output.firstIndex(of: "#") {
            output = String(output[..<hash])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDiscordUserID(_ value: String) -> Bool {
        guard (15...22).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
}
