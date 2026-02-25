import CryptoKit
import Foundation
import SwiftUI
import UIKit

struct KNSAvatarView: View {
    let avatarURLString: String?
    let fallbackText: String
    var size: CGFloat = 44

    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var lastLoadedIdentity: String?

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
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackAvatar
                    .overlay {
                        if isLoading, KNSProfileImageDescriptor.from(raw: avatarURLString) != nil {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: KNSProfileImageDescriptor.from(raw: avatarURLString)?.cacheIdentity) {
            await loadAvatarIfNeeded()
        }
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

    @MainActor
    private func loadAvatarIfNeeded() async {
        guard let descriptor = KNSProfileImageDescriptor.from(raw: avatarURLString) else {
            loadedImage = nil
            lastLoadedIdentity = nil
            isLoading = false
            return
        }

        if lastLoadedIdentity == descriptor.cacheIdentity, loadedImage != nil {
            return
        }

        if lastLoadedIdentity != descriptor.cacheIdentity {
            loadedImage = nil
        }

        isLoading = true
        let image = await KNSProfileImageCache.shared.image(for: descriptor)
        guard !Task.isCancelled else { return }

        loadedImage = image
        lastLoadedIdentity = image == nil ? nil : descriptor.cacheIdentity
        isLoading = false
    }
}

struct KNSBannerImageView: View {
    let bannerURLString: String?
    var height: CGFloat = 110
    var cornerRadius: CGFloat = 10

    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var lastLoadedIdentity: String?

    var body: some View {
        Group {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if KNSProfileImageDescriptor.from(raw: bannerURLString) != nil {
                if isLoading || !didFail {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: height)
                        .overlay {
                            ProgressView().scaleEffect(0.8)
                        }
                }
            }
        }
        .task(id: KNSProfileImageDescriptor.from(raw: bannerURLString)?.cacheIdentity) {
            await loadBannerIfNeeded()
        }
    }

    @MainActor
    private func loadBannerIfNeeded() async {
        guard let descriptor = KNSProfileImageDescriptor.from(raw: bannerURLString) else {
            loadedImage = nil
            didFail = false
            lastLoadedIdentity = nil
            isLoading = false
            return
        }

        if lastLoadedIdentity == descriptor.cacheIdentity, loadedImage != nil {
            return
        }
        if lastLoadedIdentity != descriptor.cacheIdentity {
            loadedImage = nil
            didFail = false
        }

        isLoading = true
        let image = await KNSProfileImageCache.shared.image(for: descriptor)
        guard !Task.isCancelled else { return }

        loadedImage = image
        didFail = image == nil
        lastLoadedIdentity = image == nil ? nil : descriptor.cacheIdentity
        isLoading = false
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
    @State private var lastLoadedIdentity: String?

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
        guard let descriptor = KNSProfileImageDescriptor.from(raw: avatarURLString) else {
            loadedImage = nil
            lastLoadedIdentity = nil
            isLoading = false
            return
        }

        if lastLoadedIdentity == descriptor.cacheIdentity, loadedImage != nil {
            return
        }

        if lastLoadedIdentity != descriptor.cacheIdentity {
            loadedImage = nil
        }

        isLoading = true
        let image = await KNSProfileImageCache.shared.image(for: descriptor)
        guard !Task.isCancelled else { return }

        loadedImage = image
        lastLoadedIdentity = image == nil ? nil : descriptor.cacheIdentity
        isLoading = false
    }
}

private struct KNSProfileImageDescriptor {
    let requestURL: URL
    let cacheIdentity: String
    let fileName: String

    private static let ignoredQueryKeys: Set<String> = [
        "expires",
        "expiration",
        "exp",
        "sig",
        "signature",
        "token",
        "x-amz-algorithm",
        "x-amz-credential",
        "x-amz-date",
        "x-amz-expires",
        "x-amz-security-token",
        "x-amz-signature",
        "x-amz-signedheaders"
    ]

    static func from(raw: String?) -> KNSProfileImageDescriptor? {
        guard let requestURL = KNSProfileLinkBuilder.websiteURL(from: raw) else {
            return nil
        }
        return from(url: requestURL)
    }

    static func from(url: URL) -> KNSProfileImageDescriptor? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let host = components.host?.lowercased() ?? ""
        let path = normalizedPath(from: components.percentEncodedPath)
        var identityParts = ["host=\(host)", "path=\(path)"]

        let queryPairs = (components.queryItems ?? [])
            .compactMap { item -> String? in
                let key = item.name.lowercased()
                guard !ignoredQueryKeys.contains(key),
                      let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else {
                    return nil
                }
                return "\(key)=\(value)"
            }
            .sorted()
        if !queryPairs.isEmpty {
            identityParts.append("query=\(queryPairs.joined(separator: "&"))")
        }

        let identity = identityParts.joined(separator: "|")
        let fileName = "\(sha256Hex(identity)).bin"
        return KNSProfileImageDescriptor(
            requestURL: url,
            cacheIdentity: identity,
            fileName: fileName
        )
    }

    private static func normalizedPath(from rawPath: String) -> String {
        var value = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            value = "/"
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

private actor KNSProfileImageCache {
    static let shared = KNSProfileImageCache()

    private struct ManifestEntry: Codable {
        let fileName: String
        var requestURL: String
        var eTag: String?
        var lastModified: String?
        var contentLength: Int64?
        var contentDigest: String?
        var updatedAt: Date
        var lastValidatedAt: Date
    }

    private let fileManager = FileManager.default
    private let session: URLSession
    private let imageDirectoryURL: URL
    private let manifestURL: URL
    private let memoryCache = NSCache<NSString, UIImage>()
    private let manifestEncoder = JSONEncoder()
    private let manifestDecoder = JSONDecoder()
    private let revalidationInterval: TimeInterval = 12 * 60 * 60

    private var manifestLoaded = false
    private var manifest: [String: ManifestEntry] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)

        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        imageDirectoryURL = base.appendingPathComponent("KNSProfileImages", isDirectory: true)
        manifestURL = imageDirectoryURL.appendingPathComponent("manifest_v1.json")
        memoryCache.totalCostLimit = 48 * 1024 * 1024
        memoryCache.countLimit = 256
    }

    func image(for descriptor: KNSProfileImageDescriptor) async -> UIImage? {
        let key = descriptor.cacheIdentity as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        await loadManifestIfNeeded()

        if let entry = manifest[descriptor.cacheIdentity],
           let diskImage = imageFromDisk(fileName: entry.fileName) {
            memoryCache.setObject(diskImage, forKey: key)

            if shouldRevalidate(entry: entry, descriptor: descriptor) {
                if let refreshed = await revalidate(entry: entry, descriptor: descriptor, cachedImage: diskImage) {
                    return refreshed
                }
                return diskImage
            }

            if entry.requestURL != descriptor.requestURL.absoluteString {
                var updated = entry
                updated.requestURL = descriptor.requestURL.absoluteString
                updated.lastValidatedAt = Date()
                manifest[descriptor.cacheIdentity] = updated
                persistManifest()
            }
            return diskImage
        }

        return await downloadAndStore(descriptor: descriptor, existingEntry: manifest[descriptor.cacheIdentity])
    }

    private func shouldRevalidate(entry: ManifestEntry, descriptor: KNSProfileImageDescriptor) -> Bool {
        let hasValidators = entry.eTag != nil || entry.lastModified != nil || entry.contentLength != nil
        guard hasValidators else { return false }

        if entry.requestURL != descriptor.requestURL.absoluteString {
            return true
        }
        return Date().timeIntervalSince(entry.lastValidatedAt) >= revalidationInterval
    }

    private func revalidate(
        entry: ManifestEntry,
        descriptor: KNSProfileImageDescriptor,
        cachedImage: UIImage
    ) async -> UIImage? {
        var request = URLRequest(url: descriptor.requestURL)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        if let eTag = entry.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = entry.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return cachedImage
            }

            if http.statusCode == 304 {
                var updated = entry
                updated.requestURL = descriptor.requestURL.absoluteString
                updated.lastValidatedAt = Date()
                manifest[descriptor.cacheIdentity] = updated
                persistManifest()
                return cachedImage
            }

            guard (200...299).contains(http.statusCode) else {
                return cachedImage
            }

            let responseETag = header(named: "ETag", in: http)
            let responseLastModified = header(named: "Last-Modified", in: http)
            let responseLength = contentLength(from: http)
            let validatorsMatch =
                validatorMatches(stored: entry.eTag, received: responseETag) &&
                validatorMatches(stored: entry.lastModified, received: responseLastModified) &&
                validatorMatches(stored: entry.contentLength, received: responseLength)

            if validatorsMatch {
                var updated = entry
                updated.requestURL = descriptor.requestURL.absoluteString
                updated.eTag = responseETag ?? entry.eTag
                updated.lastModified = responseLastModified ?? entry.lastModified
                updated.contentLength = responseLength ?? entry.contentLength
                updated.lastValidatedAt = Date()
                manifest[descriptor.cacheIdentity] = updated
                persistManifest()
                return cachedImage
            }
        } catch {
            return cachedImage
        }

        return await downloadAndStore(descriptor: descriptor, existingEntry: entry) ?? cachedImage
    }

    private func downloadAndStore(
        descriptor: KNSProfileImageDescriptor,
        existingEntry: ManifestEntry?
    ) async -> UIImage? {
        var request = URLRequest(url: descriptor.requestURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        if let eTag = existingEntry?.eTag {
            request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = existingEntry?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return nil
            }

            if http.statusCode == 304,
               let existingEntry,
               let cached = imageFromDisk(fileName: existingEntry.fileName) {
                var updated = existingEntry
                updated.requestURL = descriptor.requestURL.absoluteString
                updated.lastValidatedAt = Date()
                manifest[descriptor.cacheIdentity] = updated
                persistManifest()
                memoryCache.setObject(cached, forKey: descriptor.cacheIdentity as NSString)
                return cached
            }

            guard (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }

            try ensureDirectory()
            let fileURL = imageDirectoryURL.appendingPathComponent(descriptor.fileName, isDirectory: false)
            try data.write(to: fileURL, options: .atomic)

            if let existingEntry, existingEntry.fileName != descriptor.fileName {
                let oldFile = imageDirectoryURL.appendingPathComponent(existingEntry.fileName, isDirectory: false)
                try? fileManager.removeItem(at: oldFile)
            }

            let entry = ManifestEntry(
                fileName: descriptor.fileName,
                requestURL: descriptor.requestURL.absoluteString,
                eTag: header(named: "ETag", in: http),
                lastModified: header(named: "Last-Modified", in: http),
                contentLength: Int64(data.count),
                contentDigest: sha256Hex(data),
                updatedAt: Date(),
                lastValidatedAt: Date()
            )
            manifest[descriptor.cacheIdentity] = entry
            persistManifest()

            memoryCache.setObject(image, forKey: descriptor.cacheIdentity as NSString, cost: data.count)
            return image
        } catch {
            return nil
        }
    }

    private func loadManifestIfNeeded() async {
        guard !manifestLoaded else { return }
        manifestLoaded = true

        do {
            try ensureDirectory()
            let data = try Data(contentsOf: manifestURL)
            let decoded = try manifestDecoder.decode([String: ManifestEntry].self, from: data)

            var cleaned = decoded
            for (identity, entry) in decoded {
                let fileURL = imageDirectoryURL.appendingPathComponent(entry.fileName, isDirectory: false)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    cleaned.removeValue(forKey: identity)
                }
            }
            manifest = cleaned
            if cleaned.count != decoded.count {
                persistManifest()
            }
        } catch {
            manifest = [:]
        }
    }

    private func persistManifest() {
        do {
            try ensureDirectory()
            let data = try manifestEncoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            // Best-effort cache persistence.
        }
    }

    private func imageFromDisk(fileName: String) -> UIImage? {
        let fileURL = imageDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }
        return image
    }

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: imageDirectoryURL.path) {
            try fileManager.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
        }
    }

    private func header(named name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let keyString = (key as? String)?.lowercased(),
                  keyString == name.lowercased(),
                  let valueString = value as? String else {
                continue
            }
            let trimmed = valueString.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func contentLength(from response: HTTPURLResponse) -> Int64? {
        if let value = header(named: "Content-Length", in: response),
           let parsed = Int64(value),
           parsed >= 0 {
            return parsed
        }
        return nil
    }

    private func validatorMatches<T: Equatable>(stored: T?, received: T?) -> Bool {
        guard let received else {
            return true
        }
        guard let stored else {
            return false
        }
        return stored == received
    }
}

private func sha256Hex(_ text: String) -> String {
    sha256Hex(Data(text.utf8))
}

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

enum KNSProfileImagePrefetcher {
    static func preload(rawURLStrings: [String], maxConcurrent: Int = 6) async {
        let uniqueDescriptors: [KNSProfileImageDescriptor] = {
            var seen: Set<String> = []
            var descriptors: [KNSProfileImageDescriptor] = []
            for raw in rawURLStrings {
                guard let descriptor = KNSProfileImageDescriptor.from(raw: raw) else { continue }
                guard !seen.contains(descriptor.cacheIdentity) else { continue }
                seen.insert(descriptor.cacheIdentity)
                descriptors.append(descriptor)
            }
            return descriptors
        }()
        guard !uniqueDescriptors.isEmpty else { return }

        let concurrency = max(1, maxConcurrent)
        var startIndex = 0
        while startIndex < uniqueDescriptors.count {
            let endIndex = min(startIndex + concurrency, uniqueDescriptors.count)
            let batch = uniqueDescriptors[startIndex..<endIndex]
            for descriptor in batch {
                _ = await KNSProfileImageCache.shared.image(for: descriptor)
            }
            startIndex = endIndex
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
