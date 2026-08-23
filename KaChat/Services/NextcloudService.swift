import Foundation
import UIKit

/// A connected Nextcloud account (server + login + app password), persisted as one Keychain blob.
struct NextcloudAccount: Codable, Equatable {
    var serverURLString: String
    var username: String
    var appPassword: String
    /// Where "Send from Nextcloud" starts browsing — nil means the files root. Optional so
    /// blobs stored before this field existed still decode.
    var defaultFolder: String? = nil
    /// Where message backups upload — nil means the default "KaChat" folder at the files root.
    var backupFolder: String? = nil

    var serverURL: URL? { URL(string: serverURLString) }
    var displayName: String {
        let host = URL(string: serverURLString)?.host ?? serverURLString
        return "\(username)@\(host)"
    }
}

/// One entry from a WebDAV folder listing.
struct NextcloudFile: Identifiable, Equatable {
    /// Path relative to the user's files root, e.g. "Photos/cat.jpg".
    let path: String
    let name: String
    let isDirectory: Bool
    let contentType: String?
    let size: Int64?
    let modified: Date?

    var id: String { path }

    /// Content-Type first, file extension as fallback — servers without a mimetype mapping for
    /// HEIC/MOV and friends report `application/octet-stream`, which would otherwise hide real
    /// media from the picker entirely.
    var isImage: Bool {
        if contentType?.hasPrefix("image/") == true { return true }
        return Self.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    var isVideo: Bool {
        if contentType?.hasPrefix("video/") == true { return true }
        return Self.videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tiff"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "webm", "mkv", "avi"]
}

extension Array where Element == NextcloudFile {
    /// The one ordering every Nextcloud listing surface uses: phone-gallery order.
    ///
    /// Folders stay grouped ahead of files (so a folder never lands in the middle of the
    /// thumbnail grid), and within each group entries run newest-first by `getlastmodified`.
    /// Entries whose date the server omitted or that failed to parse sort last rather than
    /// interleaving randomly, and name is the tiebreak so equal timestamps stay deterministic.
    ///
    /// Applied once in `NextcloudService.listFolder`; views only filter, never re-sort.
    func sortedNewestFirst() -> [NextcloudFile] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch (lhs.modified, rhs.modified) {
            case let (left?, right?):
                if left != right { return left > right }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

enum NextcloudError: LocalizedError {
    case invalidServerURL
    case badCredentials
    case httpError(Int)
    case malformedResponse
    case backupNotFound

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "That doesn't look like a valid server URL."
        case .badCredentials:
            return "Nextcloud rejected the username or app password."
        case .httpError(let code):
            return "Nextcloud returned HTTP \(code)."
        case .malformedResponse:
            return "Unexpected response from the Nextcloud server."
        case .backupNotFound:
            return "No KaChat backup was found on this Nextcloud server."
        }
    }
}

/// Talks to the user's own Nextcloud server (docs: KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md,
/// "send from Nextcloud" flow): connect with an app password, browse files over WebDAV, and mint
/// public `/s/TOKEN` share links via the OCS API — so chats carry a small link the recipient's
/// link-preview feature renders, instead of pushing file bytes through the on-chain payload.
/// Credentials live in the Keychain (`KeychainService.saveNextcloudCredentials`); the server URL
/// and username aren't secrets but ride along in the same blob for simplicity.
@MainActor
final class NextcloudService: ObservableObject {
    static let shared = NextcloudService()

    @Published private(set) var account: NextcloudAccount?

    /// "Automatic Backup" toggle (Settings > Storage > Nextcloud). When on, the chat archive
    /// uploads on app-background, throttled to at most once per hour.
    @Published var autoBackupEnabled: Bool {
        didSet { UserDefaults.standard.set(autoBackupEnabled, forKey: Self.autoBackupKey) }
    }

    /// "Send Media via Nextcloud" toggle (Settings > Storage > Nextcloud). When on, photos and
    /// voice recordings sent in 1:1 chats upload to the connected server and the chat message
    /// is the public share link (the recipient's link-preview feature renders it as a native
    /// media bubble / audio card) instead of embedding the bytes in the on-chain payload.
    @Published var mediaSendEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaSendEnabled, forKey: Self.mediaSendKey) }
    }

    // `nonisolated` so these constants are usable from nonisolated contexts (e.g. the default
    // argument of autoBackupIfDue) without a main-actor hop — they're immutable Sendable values.
    private nonisolated static let autoBackupKey = "kachat_nextcloud_auto_backup"
    private nonisolated static let mediaSendKey = "kachat_nextcloud_media_send"
    private nonisolated static let lastAutoBackupKey = "kachat_nextcloud_last_auto_backup"
    nonisolated static let autoBackupMinInterval: TimeInterval = 3600
    /// Launch/foreground catch-up threshold: if the last automatic backup is older than this
    /// (e.g. the app was force-quit for days and never got a backgrounding moment), back up on
    /// becoming active instead of waiting for the next background.
    private nonisolated static let autoBackupCatchUpInterval: TimeInterval = 86_400

    private init() {
        autoBackupEnabled = UserDefaults.standard.bool(forKey: Self.autoBackupKey)
        mediaSendEnabled = UserDefaults.standard.bool(forKey: Self.mediaSendKey)
        if let data = try? KeychainService.shared.loadNextcloudCredentials() {
            account = try? JSONDecoder().decode(NextcloudAccount.self, from: data)
        }
        // Backgrounding is the natural "done chatting" moment — back up then, inside a
        // background task so iOS gives the upload time to finish.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await NextcloudService.shared.autoBackupIfDue()
            }
        }
        // Catch-up on launch/foreground: covers users who never background the app cleanly
        // (force-quit, crash, days of disuse). The day-long threshold keeps this from ever
        // competing with the normal hourly on-background cadence.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await NextcloudService.shared.autoBackupIfDue(minInterval: Self.autoBackupCatchUpInterval)
            }
        }
    }

    /// Runs the automatic backup when enabled, connected, and at least `minInterval` past the
    /// last one (hourly for on-background, daily for the launch catch-up). Failures are silent
    /// by design (the next trigger retries); success stamps the throttle clock.
    func autoBackupIfDue(minInterval: TimeInterval = NextcloudService.autoBackupMinInterval) async {
        guard autoBackupEnabled, isConnected else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastAutoBackupKey)
        guard Date().timeIntervalSince1970 - last >= minInterval else { return }

        let taskId = UIApplication.shared.beginBackgroundTask(withName: "nextcloud-auto-backup")
        defer { if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) } }

        guard let fileURL = try? await ChatService.shared.exportChatHistoryArchive(),
              let data = try? Data(contentsOf: fileURL) else { return }
        try? FileManager.default.removeItem(at: fileURL)
        if (try? await uploadBackup(data)) != nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAutoBackupKey)
        }
    }

    var isConnected: Bool { account != nil }

    /// Normalizes user input ("restohome.duckdns.org", trailing slashes, an accidental
    /// "/index.php" suffix) into a clean base URL, defaulting to https.
    nonisolated static func normalizedServerURL(from input: String) -> URL? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.lowercased().hasSuffix("/index.php") { raw.removeLast("/index.php".count) }
        guard let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }

    /// Verifies the credentials against the OCS user endpoint (the cheapest authenticated call),
    /// then persists them. Throws `badCredentials` on a 401 so the connect screen can say exactly
    /// what's wrong.
    func connect(serverInput: String, username: String, appPassword: String) async throws {
        guard let server = Self.normalizedServerURL(from: serverInput) else {
            throw NextcloudError.invalidServerURL
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !password.isEmpty else { throw NextcloudError.badCredentials }

        let candidate = NextcloudAccount(serverURLString: server.absoluteString, username: user, appPassword: password)
        guard let endpoint = URL(string: server.absoluteString + "/ocs/v2.php/cloud/user?format=json") else {
            throw NextcloudError.invalidServerURL
        }
        var request = URLRequest(url: endpoint)
        applyAuth(&request, account: candidate)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = decoded["ocs"] as? [String: Any],
              ocs["data"] is [String: Any] else {
            throw NextcloudError.malformedResponse
        }

        let encoded = try JSONEncoder().encode(candidate)
        try KeychainService.shared.saveNextcloudCredentials(encoded)
        account = candidate
    }

    func disconnect() {
        try? KeychainService.shared.deleteNextcloudCredentials()
        account = nil
    }

    /// Persists the picker's start folder (nil/"" = files root) into the credentials blob.
    func setDefaultFolder(_ path: String?) {
        guard var updated = account else { return }
        let clean = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.defaultFolder = (clean?.isEmpty ?? true) ? nil : clean
        if let encoded = try? JSONEncoder().encode(updated) {
            try? KeychainService.shared.saveNextcloudCredentials(encoded)
        }
        account = updated
    }

    /// Persists the backup destination folder (nil/"" = the default "KaChat" folder).
    func setBackupFolder(_ path: String?) {
        guard var updated = account else { return }
        let clean = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.backupFolder = (clean?.isEmpty ?? true) ? nil : clean
        if let encoded = try? JSONEncoder().encode(updated) {
            try? KeychainService.shared.saveNextcloudCredentials(encoded)
        }
        account = updated
    }

    /// The folder backups actually go to — the user's chosen folder, or "KaChat" by default.
    var backupFolderPath: String {
        account?.backupFolder ?? Self.backupFolderName
    }

    // MARK: - Thumbnails (the picker's photo grid)

    /// In-memory only — thumbnails are cheap to refetch and shouldn't outlive the session.
    private let thumbnailCache = NSCache<NSString, NSData>()

    /// Server-generated square thumbnail via Nextcloud's authenticated `core/preview` endpoint
    /// (`a=1` keeps aspect by cropping). Works for images everywhere and for videos when the
    /// server has a video preview provider; nil on any failure (the grid shows an icon).
    func thumbnailData(for path: String, size: Int = 256) async -> Data? {
        guard let account, let server = account.serverURL else { return nil }
        if let cached = thumbnailCache.object(forKey: path as NSString) { return cached as Data }
        guard var components = URLComponents(url: server.appendingPathComponent("index.php/core/preview.png"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "file", value: "/" + path),
            URLQueryItem(name: "x", value: String(size)),
            URLQueryItem(name: "y", value: String(size)),
            URLQueryItem(name: "a", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        applyAuth(&request, account: account)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        thumbnailCache.setObject(data as NSData, forKey: path as NSString)
        return data
    }

    /// Lets the picker cache a client-side generated thumbnail (HEIC decode / video frame grab)
    /// alongside the server-generated ones.
    func storeThumbnail(_ data: Data, for path: String) {
        thumbnailCache.setObject(data as NSData, forKey: path as NSString)
    }

    /// Authenticated GET request for a file's raw bytes over WebDAV — used by the thumbnail
    /// fallbacks when the server can't generate a preview (HEIC without ImageMagick, MOV
    /// without ffmpeg).
    func authenticatedFileRequest(for path: String) -> URLRequest? {
        guard let account, let server = account.serverURL else { return nil }
        var url = server
        for part in "remote.php/dav/files/\(account.username)/\(path)".split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        var request = URLRequest(url: url)
        applyAuth(&request, account: account)
        return request
    }

    /// Full file bytes over WebDAV, size-capped — the HEIC thumbnail fallback decodes these
    /// locally (iOS reads HEIC natively even when the server can't).
    func fileData(for path: String, maxBytes: Int = 25_000_000) async -> Data? {
        guard let request = authenticatedFileRequest(for: path) else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }

    // MARK: - Chat-history backup (WebDAV PUT/GET of the archive JSON)

    static let backupFolderName = "KaChat"
    static let backupFileName = "kachat-backup.json"

    /// Uploads the archive to `<backup folder>/kachat-backup.json`, creating the folder first
    /// (MKCOL answers 405 when it already exists — fine; a user-picked folder always already
    /// exists since it was chosen through the folder browser).
    func uploadBackup(_ data: Data) async throws {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        var folderURL = server.appendingPathComponent("remote.php/dav/files/\(account.username)")
        for part in backupFolderPath.split(separator: "/") {
            folderURL.appendPathComponent(String(part))
        }

        var mkcol = URLRequest(url: folderURL)
        mkcol.httpMethod = "MKCOL"
        applyAuth(&mkcol, account: account)
        let (_, mkcolResponse) = try await URLSession.shared.data(for: mkcol)
        if let http = mkcolResponse as? HTTPURLResponse {
            if http.statusCode == 401 { throw NextcloudError.badCredentials }
            guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
                throw NextcloudError.httpError(http.statusCode)
            }
        }

        var put = URLRequest(url: folderURL.appendingPathComponent(Self.backupFileName))
        put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&put, account: account)
        put.httpBody = data
        let (_, putResponse) = try await URLSession.shared.data(for: put)
        guard let http = putResponse as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }
    }

    /// The backup file's server-side metadata (nil = no backup yet). A missing folder lists
    /// as a 404, which also just means "no backup yet".
    func fetchBackupInfo() async -> NextcloudFile? {
        guard let listing = try? await listFolder(backupFolderPath) else { return nil }
        return listing.first { $0.name == Self.backupFileName && !$0.isDirectory }
    }

    /// Downloads the backup archive bytes. 404 -> `backupNotFound`.
    /// `progress` (optional) streams `(bytesReceived, totalBytesExpected)` as the body downloads;
    /// `totalBytesExpected` is nil when the server omits Content-Length. It is invoked OFF the
    /// main actor (the byte accumulation runs nonisolated so a large archive never stalls UI),
    /// so callers must hop to the main actor themselves.
    func downloadBackup(progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> Data {
        guard let request = authenticatedFileRequest(for: "\(backupFolderPath)/\(Self.backupFileName)") else {
            throw NextcloudError.badCredentials
        }
        return try await Self.performBackupDownload(request: request, progress: progress)
    }

    private nonisolated static func performBackupDownload(
        request: URLRequest,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        if http.statusCode == 404 { throw NextcloudError.backupNotFound }
        guard (200..<300).contains(http.statusCode) else {
            throw NextcloudError.httpError(http.statusCode)
        }

        let expected: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        var data = Data()
        if let expected { data.reserveCapacity(Int(expected)) }
        // Throttle progress to every 64KB so a big archive doesn't flood the main actor.
        let reportStride: Int64 = 65_536
        var lastReported: Int64 = 0
        for try await byte in bytes {
            data.append(byte)
            if let progress {
                let count = Int64(data.count)
                if count - lastReported >= reportStride {
                    lastReported = count
                    progress(count, expected)
                }
            }
        }
        guard !data.isEmpty else { throw NextcloudError.httpError(http.statusCode) }
        progress?(Int64(data.count), expected)
        return data
    }

    // MARK: - Media send (chat photos/voice notes uploaded as public share links)

    /// Fixed upload destination for chat media — intentionally independent of the user-chosen
    /// backup folder so media never lands inside a folder the user picked for archives.
    nonisolated static let mediaFolderPath = "KaChat/Media"

    /// Uploads one media file to `KaChat/Media/` and returns a public `/s/TOKEN` share link for
    /// it — the exact URL form the recipient's link-preview feature renders as a media bubble.
    /// The folder chain is created level by level (MKCOL is not recursive; 405 means "already
    /// exists", same convention as `uploadBackup`). An 8-char random prefix on the stored name
    /// keeps same-second filenames (photo_20260811-101502.jpg twice) from overwriting each other.
    func uploadMediaAndShare(data: Data, filename: String, contentType: String) async throws -> URL {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }

        var folderURL = server.appendingPathComponent("remote.php/dav/files/\(account.username)")
        for part in Self.mediaFolderPath.split(separator: "/") {
            folderURL.appendPathComponent(String(part))
            var mkcol = URLRequest(url: folderURL)
            mkcol.httpMethod = "MKCOL"
            applyAuth(&mkcol, account: account)
            let (_, mkcolResponse) = try await URLSession.shared.data(for: mkcol)
            if let http = mkcolResponse as? HTTPURLResponse {
                if http.statusCode == 401 { throw NextcloudError.badCredentials }
                guard (200..<300).contains(http.statusCode) || http.statusCode == 405 else {
                    throw NextcloudError.httpError(http.statusCode)
                }
            }
        }

        let storedName = "\(UUID().uuidString.prefix(8))_\(Self.sanitizedMediaFilename(filename))"
        var put = URLRequest(url: folderURL.appendingPathComponent(storedName))
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        applyAuth(&put, account: account)
        put.httpBody = data
        let (_, putResponse) = try await URLSession.shared.data(for: put)
        guard let http = putResponse as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard (200..<300).contains(http.statusCode) else { throw NextcloudError.httpError(http.statusCode) }

        return try await createPublicShareLink(for: "\(Self.mediaFolderPath)/\(storedName)")
    }

    /// Keeps stored filenames WebDAV/URL-safe: alphanumerics, dot, dash and underscore survive;
    /// everything else becomes "_". The extension must survive intact — Nextcloud derives the
    /// Content-Type it serves (and thus the recipient's media-kind detection) from it.
    private nonisolated static func sanitizedMediaFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "file" : cleaned
    }

    private nonisolated func applyAuth(_ request: inout URLRequest, account: NextcloudAccount) {
        let token = Data("\(account.username):\(account.appPassword)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    // MARK: - WebDAV browsing (the chat attach picker's data source)

    /// Lists one folder (non-recursive) of the connected account's files via a Depth-1 PROPFIND.
    func listFolder(_ relativePath: String = "") async throws -> [NextcloudFile] {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        let davBasePath = "/remote.php/dav/files/\(account.username)"
        // Normalized form of the listed folder, for the parser's self-entry exclusion below.
        let listedPath = relativePath.split(separator: "/").joined(separator: "/")
        var url = server
        for part in "remote.php/dav/files/\(account.username)/\(relativePath)".split(separator: "/") {
            url.appendPathComponent(String(part))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, account: account)
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/><d:getcontentlength/><d:getlastmodified/></d:prop>
        </d:propfind>
        """.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        guard http.statusCode == 207 else { throw NextcloudError.httpError(http.statusCode) }

        return DavMultistatusParser(davBasePath: davBasePath, listedPath: listedPath)
            .parse(data)
            .sortedNewestFirst()
    }

    // MARK: - Public share links (OCS files_sharing API)

    /// Creates a public link share (shareType 3) for `relativePath` and returns its `/s/TOKEN`
    /// URL — the exact form the link-preview feature renders. If the file already has a public
    /// link (creating again can fail on some configs), the existing link is reused.
    func createPublicShareLink(for relativePath: String) async throws -> URL {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        guard let endpoint = URL(string: server.absoluteString + "/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json") else {
            throw NextcloudError.invalidServerURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        applyAuth(&request, account: account)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("path=\(Self.formEncoded("/" + relativePath))&shareType=3".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NextcloudError.malformedResponse }
        if http.statusCode == 401 { throw NextcloudError.badCredentials }
        if (200..<300).contains(http.statusCode),
           let url = Self.shareURL(fromOCSObject: data) {
            return url
        }
        if let existing = try await existingPublicShareLink(for: relativePath) { return existing }
        throw NextcloudError.malformedResponse
    }

    private func existingPublicShareLink(for relativePath: String) async throws -> URL? {
        guard let account, let server = account.serverURL else { throw NextcloudError.badCredentials }
        let path = Self.formEncoded("/" + relativePath)
        guard let endpoint = URL(string: server.absoluteString + "/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json&path=\(path)") else {
            return nil
        }
        var request = URLRequest(url: endpoint)
        applyAuth(&request, account: account)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = decoded["ocs"] as? [String: Any],
              let list = ocs["data"] as? [[String: Any]] else { return nil }
        for share in list where (share["share_type"] as? Int) == 3 {
            if let urlString = share["url"] as? String, let url = URL(string: urlString) { return url }
        }
        return nil
    }

    private nonisolated static func shareURL(fromOCSObject data: Data) -> URL? {
        guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ocs = decoded["ocs"] as? [String: Any],
              let payload = ocs["data"] as? [String: Any],
              let urlString = payload["url"] as? String else { return nil }
        return URL(string: urlString)
    }

    private nonisolated static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Minimal WebDAV `multistatus` parser for folder listings — pulls each response's href,
/// display name, collection flag, content type and length. Namespace-agnostic via
/// `shouldProcessNamespaces` (servers vary between `d:` and `D:` prefixes).
private final class DavMultistatusParser: NSObject, XMLParserDelegate {
    private let davBasePath: String
    /// The folder being listed. A Depth-1 PROPFIND's multistatus includes the listed folder
    /// ITSELF as its first response — without excluding it, every folder appears to contain
    /// itself (an infinite "Photos inside Photos" loop when browsing).
    private let listedPath: String
    private var results: [NextcloudFile] = []
    private var inResponse = false
    private var currentHref = ""
    private var currentName: String?
    private var currentType: String?
    private var currentLength: Int64?
    private var currentModified: Date?
    private var isCollection = false
    private var text = ""

    /// WebDAV's getlastmodified is RFC 1123 ("Mon, 11 Aug 2026 20:14:07 GMT").
    private static let lastModifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        // The string carries its own zone ("GMT"), but pin the fallback so a server that omits it
        // is read as UTC instead of drifting with the device's local zone.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    init(davBasePath: String, listedPath: String) {
        self.davBasePath = davBasePath
        self.listedPath = listedPath
    }

    func parse(_ data: Data) -> [NextcloudFile] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response":
            inResponse = true
            currentHref = ""
            currentName = nil
            currentType = nil
            currentLength = nil
            currentModified = nil
            isCollection = false
        case "collection":
            isCollection = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href":
            if inResponse, currentHref.isEmpty { currentHref = trimmed }
        case "displayname":
            if inResponse, currentName == nil, !trimmed.isEmpty { currentName = trimmed }
        case "getcontenttype":
            if inResponse, !trimmed.isEmpty { currentType = trimmed }
        case "getcontentlength":
            if inResponse { currentLength = Int64(trimmed) }
        case "getlastmodified":
            if inResponse, !trimmed.isEmpty { currentModified = Self.lastModifiedFormatter.date(from: trimmed) }
        case "response":
            inResponse = false
            appendCurrent()
        default:
            break
        }
    }

    private func appendCurrent() {
        guard let decoded = currentHref.removingPercentEncoding,
              let range = decoded.range(of: davBasePath) else { return }
        var relative = String(decoded[range.upperBound...])
        while relative.hasPrefix("/") { relative.removeFirst() }
        while relative.hasSuffix("/") { relative.removeLast() }
        guard !relative.isEmpty, relative != listedPath else { return } // the listed folder itself
        let fallbackName = relative.split(separator: "/").last.map(String.init) ?? relative
        results.append(NextcloudFile(
            path: relative,
            name: currentName ?? fallbackName,
            isDirectory: isCollection,
            contentType: currentType,
            size: currentLength,
            modified: currentModified
        ))
    }
}

// MARK: - Backup restore coordinator (blocking progress modal)

/// Owns a chat-history restore from tap to terminal state, independent of any view's lifetime.
/// Interrupting a restore midway can leave local state partially written, so the Settings screens
/// only OBSERVE this singleton: the restore `Task` is held here, never by a view, and view
/// teardown can never cancel it. While `phase == .running` the Settings hierarchy presents a
/// full-screen modal (`ChatRestoreProgressModal` in SettingsView.swift) that cannot be dismissed;
/// the only exits are the modal's own Done / Try Again / Close buttons, which call back into
/// `dismiss()` / `retry()` here, and `dismiss()` refuses to fire while a restore is running.
@MainActor
final class BackupRestoreCoordinator: ObservableObject {
    static let shared = BackupRestoreCoordinator()
    private init() {}

    enum Phase: Equatable {
        case idle
        case running
        case success(conversations: Int, messages: Int, filledSent: Int)
        case failure(String)
    }

    enum Source {
        /// kachat-backup.json downloaded from the connected Nextcloud server.
        case nextcloud
        /// An archive the user picked with the file importer (Settings > Chat History > Import).
        case localArchive(Data)
    }

    @Published private(set) var phase: Phase = .idle
    /// 0...1, monotonic. Stage weights: download 0-30% (real bytes when the server sends
    /// Content-Length), validate/prepare 30-40%, Core Data import 40-90% (advances per
    /// conversation inside MessageStore.syncFromConversations), finalize 90-100%.
    @Published private(set) var fraction: Double = 0
    @Published private(set) var stageText: String = ""

    var isRunning: Bool { phase == .running }
    var isPresentingModal: Bool { phase != .idle }

    /// Kept so Try Again after a failure reruns the exact same restore.
    private var lastSource: Source?
    /// Held by the singleton (not a view) so navigation or sheet dismissal cannot cancel it.
    private var restoreTask: Task<Void, Never>?

    func startNextcloudRestore() { start(.nextcloud) }
    func startLocalRestore(data: Data) { start(.localArchive(data)) }

    /// Reruns the failed restore. Only valid from the failure state.
    func retry() {
        guard case .failure = phase, let lastSource else { return }
        phase = .idle
        start(lastSource)
    }

    /// Leaves the modal. Only honored from a terminal state; a running restore cannot be dismissed.
    func dismiss() {
        guard !isRunning else { return }
        phase = .idle
        fraction = 0
        stageText = ""
    }

    private func start(_ source: Source) {
        guard !isRunning else { return }
        lastSource = source
        fraction = 0
        switch source {
        case .nextcloud: stageText = "Downloading backup..."
        case .localArchive: stageText = "Reading archive..."
        }
        phase = .running
        restoreTask = Task { [weak self] in
            await self?.run(source)
        }
    }

    private func run(_ source: Source) async {
        do {
            let data: Data
            switch source {
            case .nextcloud:
                data = try await NextcloudService.shared.downloadBackup { [weak self] received, expectedTotal in
                    Task { @MainActor [weak self] in
                        guard let self, let expectedTotal, expectedTotal > 0 else { return }
                        let downloaded = min(1.0, Double(received) / Double(expectedTotal))
                        self.advance(to: 0.30 * downloaded, stage: "Downloading backup...")
                    }
                }
                advance(to: 0.30, stage: "Validating backup...")
            case .localArchive(let archiveData):
                data = archiveData
                advance(to: 0.05, stage: "Validating backup...")
            }

            let summary = try await ChatService.shared.importChatHistoryArchive(data) { [weak self] event in
                guard let self else { return }
                switch event {
                case .validating:
                    self.advance(to: 0.32, stage: "Validating backup...")
                case .preparing:
                    self.advance(to: 0.36, stage: "Preparing messages...")
                case .importing(let done, let total):
                    let f = total > 0 ? Double(done) / Double(total) : 1.0
                    self.advance(
                        to: 0.40 + 0.50 * f,
                        stage: "Restoring messages... \(done) of \(total) conversations"
                    )
                case .finalizing:
                    self.advance(to: 0.92, stage: "Finishing up...")
                }
            }
            fraction = 1.0
            stageText = "Done"
            // Retry is only offered after a failure; drop the retained archive bytes on success.
            lastSource = nil
            phase = .success(
                conversations: summary.conversationCount,
                messages: summary.messageCount,
                filledSent: summary.filledSentContentCount
            )
        } catch {
            phase = .failure(error.localizedDescription)
        }
    }

    /// Monotonic progress: overlapping async reports can never move the bar backwards.
    private func advance(to value: Double, stage: String) {
        fraction = max(fraction, min(value, 1.0))
        stageText = stage
    }
}
