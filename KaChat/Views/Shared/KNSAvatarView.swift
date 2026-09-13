import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import Contacts
import UIKit

/// The one avatar view in the app. Resolution order, applied here so no call site ever
/// re-implements it: KNS avatar -> linked device-contact photo -> person glyph.
///
/// Pass `contactAddress` wherever the avatar stands for a person with a Kaspa address (chat
/// rows, chat header, chat info, message bubbles, group member lists, pickers, share targets,
/// KaPosts authors) and the device-contact photo layer comes for free - see
/// `SystemContactAvatarStore` for the cache and for the `preferKNSAvatar` override.
struct KNSAvatarView: View {
    let avatarURLString: String?
    let fallbackText: String
    var size: CGFloat = 44
    /// Caller-resolved image that wins over everything else (rare; the device-contact photo
    /// does NOT need this - use `contactAddress`).
    var overrideImage: UIImage? = nil
    /// Kaspa address this avatar represents; enables the device-contact photo layer.
    var contactAddress: String? = nil

    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var lastLoadedIdentity: String?
    /// Observed so an avatar re-renders when its contact's photo lands from the lazy CN fetch.
    /// The store only publishes when a photo is decoded (once per linked contact per session,
    /// disk-cached afterwards), so this costs nothing on scroll.
    @ObservedObject private var contactAvatars = SystemContactAvatarStore.shared

    /// The Contacts-app photo for `contactAddress`, if any. Asking for it is what kicks off the
    /// (off-main-thread, cached) fetch, so it's read on every body pass.
    private var deviceContactPhoto: UIImage? {
        guard overrideImage == nil, contactAddress != nil else { return nil }
        return contactAvatars.photo(forAddress: contactAddress)
    }

    /// Only when the user explicitly chose "Contacts Photo" for this contact does the device
    /// photo jump ahead of the KNS avatar.
    private var deviceContactPhotoWinsOverKNS: Bool {
        contactAvatars.prefersContactPhotoOverKNS(forAddress: contactAddress)
    }

    /// Decoded cache so a base64 backup photo is turned into a UIImage once, not on every
    /// body pass while scrolling. Keyed by CONTACT ADDRESS, not the base64 itself: the old
    /// key allocated and hashed a multi-KB NSString from the photo blob on every body pass,
    /// and the cache had no bounds. Cost-limited so hundreds of contacts can't grow it forever.
    private static let backupPhotoCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    /// The cross-platform backup photo (base64 JPEG on the Contact), decoded lazily. Only the
    /// final fallback before the glyph, so it is evaluated only for contacts with no device or
    /// KNS photo.
    private var backupPhotoImage: UIImage? {
        guard overrideImage == nil, let contactAddress,
              let base64 = ContactsManager.shared.getContact(byAddress: contactAddress)?.backupPhoto,
              !base64.isEmpty else { return nil }
        let key = contactAddress as NSString
        if let cached = Self.backupPhotoCache.object(forKey: key) { return cached }
        guard let data = Data(base64Encoded: base64), let image = UIImage(data: data) else { return nil }
        Self.backupPhotoCache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    var body: some View {
        Group {
            let devicePhoto = deviceContactPhoto
            if let resolved = overrideImage ?? (deviceContactPhotoWinsOverKNS ? devicePhoto : nil) {
                Image(uiImage: resolved)
                    .resizable()
                    .scaledToFill()
            } else if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if let devicePhoto {
                // No KNS avatar (or it hasn't loaded/failed): the device-contact photo is the
                // fallback, ahead of the glyph.
                Image(uiImage: devicePhoto)
                    .resizable()
                    .scaledToFill()
            } else if let backupPhoto = backupPhotoImage {
                // A photo carried in the cross-platform backup (e.g. set on desktop): the last
                // photo fallback before the glyph.
                Image(uiImage: backupPhoto)
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
        // Person glyph instead of initials for anyone without a photo/KNS avatar.
        Circle()
            .fill(Color.accentColor.opacity(0.2))
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: max(12, size * 0.42), weight: .medium))
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
        // Rows only ever draw this at `size` points, so ask for a thumbnail-sized decode - a
        // full-resolution avatar bitmap for a 32pt circle is where the memory went.
        let image = await KNSProfileImageCache.shared.image(
            for: descriptor,
            maxPixelSize: KNSProfileImageCache.thumbnailPixelSize(forPointSize: size)
        )
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
                // The image is an OVERLAY on a fixed-size canvas, never a laid-out child.
                //
                // `.scaledToFill()` scales the image until it covers the frame, which for a wide
                // banner means a rendered width far beyond the screen. As a child it reported that
                // width up the tree, and since the Profile screen is a vertical ScrollView - which
                // sizes its content to the content's own width rather than clamping it - the whole
                // page became as wide as the image. Every sibling using `maxWidth: .infinity` then
                // stretched to match, so the rows and the round launcher buttons grew with it and
                // the page looked zoomed in, clipped on both edges. Uploading one large banner was
                // enough to do it.
                //
                // An overlay is laid out against its base's size and can never change it, so the
                // canvas below is the only thing that decides how much room this takes.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .overlay {
                        Image(uiImage: loadedImage)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
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
    /// Linked iOS contact id: enables "add this KNS avatar as their photo in the Contacts
    /// app" from the top bar.
    var systemContactId: String? = nil
    /// Kaspa address behind this avatar, so the placeholder falls back to their device-contact
    /// photo (same order as everywhere else) while/if the KNS image isn't available.
    var contactAddress: String? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var loadedImage: UIImage?
    @State private var isLoading = false
    @State private var showShareSheet = false
    @State private var lastLoadedIdentity: String?
    @State private var contactSaveMessage: String?

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
                        size: 220,
                        contactAddress: contactAddress
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

                if systemContactId != nil {
                    Button {
                        saveAvatarToSystemContact()
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Circle())
                    }
                    .disabled(loadedImage == nil)
                    .opacity(loadedImage == nil ? 0.45 : 1)
                    .accessibilityLabel("Add as contact photo in Contacts")
                }

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
        .overlay(alignment: .bottom) {
            if let contactSaveMessage {
                Text(contactSaveMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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

    /// Writes the loaded KNS avatar into the linked contact's card in the iOS Contacts app,
    /// then refreshes the in-app cache so KaChat's own avatar reflects it immediately.
    private func saveAvatarToSystemContact() {
        guard let systemContactId,
              let image = loadedImage,
              let data = image.jpegData(compressionQuality: 0.9) else { return }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            showContactSaveMessage("Contacts access isn't granted.")
            return
        }
        Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            do {
                let keys = [CNContactImageDataKey as CNKeyDescriptor]
                let cnContact = try store.unifiedContact(withIdentifier: systemContactId, keysToFetch: keys)
                guard let mutable = cnContact.mutableCopy() as? CNMutableContact else {
                    throw CocoaError(.featureUnsupported)
                }
                mutable.imageData = data
                let saveRequest = CNSaveRequest()
                saveRequest.update(mutable)
                try store.execute(saveRequest)
                await MainActor.run {
                    SystemContactAvatarStore.shared.storeImage(image, data: data, forSystemContactId: systemContactId)
                    showContactSaveMessage("Saved as their photo in Contacts.")
                }
            } catch {
                await MainActor.run {
                    showContactSaveMessage("Couldn't update Contacts.")
                }
            }
        }
    }

    @MainActor
    private func showContactSaveMessage(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { contactSaveMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeIn(duration: 0.2)) { contactSaveMessage = nil }
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

/// The one thing outside this file needs from the image cache: a way to say "the files are gone".
///
/// A seam rather than making the actor itself internal - its methods take
/// `KNSProfileImageDescriptor`, which is private, and an internal method cannot expose a private
/// type. Widening both to satisfy one call would put the whole caching mechanism into the app's
/// API surface for no reason.
enum KNSProfileImageCacheControl {
    /// Call after deleting the image directory (Settings > Storage > Cache). Without it the
    /// in-memory cache and the manifest keep describing files that are gone, so the app shows
    /// avatars that no longer exist on disk until the next launch and never re-downloads them.
    static func resetAfterExternalPurge() async {
        await KNSProfileImageCache.shared.resetAfterExternalPurge()
    }
}

private actor KNSProfileImageCache {
    static let shared = KNSProfileImageCache()

    /// See `KNSProfileImageCacheControl.resetAfterExternalPurge`.
    func resetAfterExternalPurge() {
        memoryCache.removeAllObjects()
        manifest = [:]
        manifestLoaded = false
    }

    private struct ManifestEntry: Codable {
        let fileName: String
        var requestURL: String
        var eTag: String?
        var lastModified: String?
        var contentLength: Int64?
        var contentDigest: String?
        var updatedAt: Date
        var lastValidatedAt: Date
        /// Optional so manifests written before it existed still decode; those entries fall
        /// back to `updatedAt` for eviction ordering until they are next read.
        var lastAccessedAt: Date?
    }

    /// Row avatars (32-56pt) decode at this many pixels on the long edge; the on-disk file
    /// stays full resolution for the banner and the fullscreen viewer, which pass `nil`.
    static let rowThumbnailMaxPixelSize = 160
    static let mediumThumbnailMaxPixelSize = 320

    /// Bucketed rather than exact so a handful of memory-cache variants cover every row size
    /// in the app instead of one per distinct point size. Above the medium bucket the caller
    /// gets the full-resolution decode.
    static func thumbnailPixelSize(forPointSize size: CGFloat) -> Int? {
        if size <= 56 { return rowThumbnailMaxPixelSize }
        if size <= 112 { return mediumThumbnailMaxPixelSize }
        return nil
    }

    private let fileManager = FileManager.default
    private let session: URLSession
    private let imageDirectoryURL: URL
    private let manifestURL: URL
    private let memoryCache = NSCache<NSString, UIImage>()
    private let manifestEncoder = JSONEncoder()
    private let manifestDecoder = JSONDecoder()
    private let revalidationInterval: TimeInterval = 12 * 60 * 60

    /// Disk budget: once the files described by the manifest pass the high-water mark, the
    /// least-recently-read entries go until the total is back under the low-water mark. Two
    /// marks so one oversized download doesn't trigger a prune on every subsequent write.
    private let diskHighWaterBytes: Int64 = 64 * 1024 * 1024
    private let diskLowWaterBytes: Int64 = 48 * 1024 * 1024
    /// `lastAccessedAt` bumps are batched: rewriting the manifest on every disk read would
    /// turn a scroll through the chat list into a stream of file writes, so a read only
    /// persists when the last write is older than the interval (any other write picks up the
    /// pending bumps for free).
    private var manifestAccessPersistedAt = Date.distantPast
    private let manifestAccessPersistInterval: TimeInterval = 60
    /// The memory cache can't be enumerated, so pruning an identity from disk needs to know
    /// which size variants it may have been cached under.
    private var knownVariantSuffixes: Set<String> = [""]

    private var manifestLoaded = false
    private var manifest: [String: ManifestEntry] = [:]

    /// In-flight downloads keyed by cache identity: many rows showing the same avatar await one
    /// download instead of each firing their own (mirrors `LinkPreviewService.inFlight`). The
    /// tasks are unstructured so a row scrolling away (its `.task` gets cancelled) can't kill a
    /// download other rows are waiting on - the bytes always land in the cache.
    private var inFlightDownloads: [String: Task<UIImage?, Never>] = [:]

    /// Failed downloads retry after a cooldown instead of on every row remount - a dead avatar
    /// URL would otherwise be re-requested on every scroll (negative-cache-with-cooldown, same
    /// pattern as LinkPreviewService's Nextcloud probe failures). Bounded by periodic pruning.
    private var downloadFailureAt: [String: Date] = [:]
    private let downloadFailureCooldown: TimeInterval = 60
    private let maxFailureEntries = 512

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

    /// `maxPixelSize` selects a decode variant, not a different file: the bytes on disk are
    /// always the original, and each variant is memory-cached under its own key.
    func image(for descriptor: KNSProfileImageDescriptor, maxPixelSize: Int? = nil) async -> UIImage? {
        let key = memoryKey(for: descriptor.cacheIdentity, maxPixelSize: maxPixelSize)
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        await loadManifestIfNeeded()

        if let entry = manifest[descriptor.cacheIdentity],
           let diskImage = imageFromDisk(fileName: entry.fileName, maxPixelSize: maxPixelSize) {
            memoryCache.setObject(diskImage, forKey: key, cost: Self.cacheCost(for: diskImage))
            touchAccess(identity: descriptor.cacheIdentity)

            if shouldRevalidate(entry: entry, descriptor: descriptor) {
                if let refreshed = await revalidate(
                    entry: entry,
                    descriptor: descriptor,
                    cachedImage: diskImage,
                    maxPixelSize: maxPixelSize
                ) {
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

        return await coalescedDownload(descriptor: descriptor, maxPixelSize: maxPixelSize)
    }

    private func memoryKey(for identity: String, maxPixelSize: Int?) -> NSString {
        let suffix = maxPixelSize.map { "|thumb\($0)" } ?? ""
        knownVariantSuffixes.insert(suffix)
        return (identity + suffix) as NSString
    }

    private func removeMemoryVariants(for identity: String) {
        for suffix in knownVariantSuffixes {
            memoryCache.removeObject(forKey: (identity + suffix) as NSString)
        }
    }

    /// Decoded bitmap bytes - what the image actually occupies - so `totalCostLimit` means
    /// something. The old zero-cost inserts made the 48MB limit a no-op and left only the
    /// count limit doing any work.
    private static func cacheCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.width * cgImage.height * 4
        }
        let scale = max(1, image.scale)
        return Int(image.size.width * scale * image.size.height * scale * 4)
    }

    /// Records a disk read for LRU pruning; the write to disk is batched (see
    /// `manifestAccessPersistedAt`).
    private func touchAccess(identity: String) {
        guard var entry = manifest[identity] else { return }
        entry.lastAccessedAt = Date()
        manifest[identity] = entry
        if Date().timeIntervalSince(manifestAccessPersistedAt) >= manifestAccessPersistInterval {
            persistManifest()
        }
    }

    /// Cold download path: joins an in-flight download for the same identity when one exists,
    /// respects the failure cooldown, and runs the download detached from the caller's task so
    /// view cancellation (row scrolled offscreen) can't abort it mid-flight.
    private func coalescedDownload(descriptor: KNSProfileImageDescriptor, maxPixelSize: Int?) async -> UIImage? {
        let identity = descriptor.cacheIdentity

        if let existing = inFlightDownloads[identity] {
            // The in-flight task decoded at ITS caller's size; if ours differs, the file is on
            // disk by now, so decode our variant from there rather than hand back the wrong one.
            guard let image = await existing.value else { return nil }
            let key = memoryKey(for: identity, maxPixelSize: maxPixelSize)
            if let cached = memoryCache.object(forKey: key) { return cached }
            if let entry = manifest[identity],
               let variant = imageFromDisk(fileName: entry.fileName, maxPixelSize: maxPixelSize) {
                memoryCache.setObject(variant, forKey: key, cost: Self.cacheCost(for: variant))
                return variant
            }
            return image
        }
        if let failedAt = downloadFailureAt[identity],
           Date().timeIntervalSince(failedAt) < downloadFailureCooldown {
            return nil
        }

        let existingEntry = manifest[identity]
        let task = Task<UIImage?, Never> {
            await self.downloadAndStore(descriptor: descriptor, existingEntry: existingEntry, maxPixelSize: maxPixelSize)
        }
        inFlightDownloads[identity] = task
        let image = await task.value
        inFlightDownloads.removeValue(forKey: identity)

        if image == nil {
            downloadFailureAt[identity] = Date()
            pruneFailureEntriesIfNeeded()
        } else {
            downloadFailureAt.removeValue(forKey: identity)
        }
        return image
    }

    private func pruneFailureEntriesIfNeeded() {
        guard downloadFailureAt.count > maxFailureEntries else { return }
        // Expired cooldowns are dead weight; drop them first, then oldest overflow if needed.
        let now = Date()
        downloadFailureAt = downloadFailureAt.filter {
            now.timeIntervalSince($0.value) < downloadFailureCooldown
        }
        if downloadFailureAt.count > maxFailureEntries {
            let overflow = downloadFailureAt.count - maxFailureEntries
            let oldestKeys = downloadFailureAt.sorted { $0.value < $1.value }.prefix(overflow).map(\.key)
            for key in oldestKeys {
                downloadFailureAt.removeValue(forKey: key)
            }
        }
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
        cachedImage: UIImage,
        maxPixelSize: Int?
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

        return await downloadAndStore(descriptor: descriptor, existingEntry: entry, maxPixelSize: maxPixelSize) ?? cachedImage
    }

    private func downloadAndStore(
        descriptor: KNSProfileImageDescriptor,
        existingEntry: ManifestEntry?,
        maxPixelSize: Int?
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
               let cached = imageFromDisk(fileName: existingEntry.fileName, maxPixelSize: maxPixelSize) {
                var updated = existingEntry
                updated.requestURL = descriptor.requestURL.absoluteString
                updated.lastValidatedAt = Date()
                updated.lastAccessedAt = Date()
                manifest[descriptor.cacheIdentity] = updated
                persistManifest()
                memoryCache.setObject(
                    cached,
                    forKey: memoryKey(for: descriptor.cacheIdentity, maxPixelSize: maxPixelSize),
                    cost: Self.cacheCost(for: cached)
                )
                return cached
            }

            guard (200...299).contains(http.statusCode),
                  let image = Self.decodeImage(data, maxPixelSize: maxPixelSize) else {
                return nil
            }

            try ensureDirectory()
            let fileURL = imageDirectoryURL.appendingPathComponent(descriptor.fileName, isDirectory: false)
            try data.write(to: fileURL, options: .atomic)

            if let existingEntry, existingEntry.fileName != descriptor.fileName {
                let oldFile = imageDirectoryURL.appendingPathComponent(existingEntry.fileName, isDirectory: false)
                try? fileManager.removeItem(at: oldFile)
            }

            // A fresh download is the previous variants' expiry: they were decoded from the
            // bytes just overwritten.
            removeMemoryVariants(for: descriptor.cacheIdentity)

            let entry = ManifestEntry(
                fileName: descriptor.fileName,
                requestURL: descriptor.requestURL.absoluteString,
                eTag: header(named: "ETag", in: http),
                lastModified: header(named: "Last-Modified", in: http),
                contentLength: Int64(data.count),
                contentDigest: sha256Hex(data),
                updatedAt: Date(),
                lastValidatedAt: Date(),
                lastAccessedAt: Date()
            )
            manifest[descriptor.cacheIdentity] = entry
            pruneDiskIfNeeded()
            persistManifest()

            memoryCache.setObject(
                image,
                forKey: memoryKey(for: descriptor.cacheIdentity, maxPixelSize: maxPixelSize),
                cost: Self.cacheCost(for: image)
            )
            return image
        } catch {
            return nil
        }
    }

    /// LRU prune of the on-disk store, run after every write (on this actor, never the main
    /// thread). Nothing pruned this directory before: every avatar ever shown stayed in Caches
    /// until the user cleared it by hand in Settings > Storage.
    private func pruneDiskIfNeeded() {
        var total = manifest.values.reduce(Int64(0)) { $0 + diskSize(of: $1) }
        guard total > diskHighWaterBytes else { return }

        let leastRecentFirst = manifest.sorted { lhs, rhs in
            (lhs.value.lastAccessedAt ?? lhs.value.updatedAt) < (rhs.value.lastAccessedAt ?? rhs.value.updatedAt)
        }
        for (identity, entry) in leastRecentFirst {
            guard total > diskLowWaterBytes else { break }
            // An identity mid-download is about to be rewritten; skipping it avoids deleting a
            // file another caller is decoding from.
            guard inFlightDownloads[identity] == nil else { continue }
            let fileURL = imageDirectoryURL.appendingPathComponent(entry.fileName, isDirectory: false)
            try? fileManager.removeItem(at: fileURL)
            manifest.removeValue(forKey: identity)
            removeMemoryVariants(for: identity)
            total -= diskSize(of: entry)
        }
    }

    private func diskSize(of entry: ManifestEntry) -> Int64 {
        if let length = entry.contentLength { return length }
        let fileURL = imageDirectoryURL.appendingPathComponent(entry.fileName, isDirectory: false)
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Full decode when `maxPixelSize` is nil; otherwise an ImageIO thumbnail, which decodes
    /// straight to the target size instead of materialising the full bitmap and scaling it
    /// (same approach as `MessageBubbleView`'s photo thumbnails). Falls back to a plain decode
    /// for formats ImageIO won't thumbnail.
    private static func decodeImage(_ data: Data, maxPixelSize: Int?) -> UIImage? {
        guard let maxPixelSize else { return UIImage(data: data) }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
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
            manifestAccessPersistedAt = Date()
        } catch {
            // Best-effort cache persistence.
        }
    }

    private func imageFromDisk(fileName: String, maxPixelSize: Int?) -> UIImage? {
        let fileURL = imageDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let image = Self.decodeImage(data, maxPixelSize: maxPixelSize) else {
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

        // A sliding window of `maxConcurrent` in-flight loads: one finishes, the next starts.
        // The previous version sliced into batches and then awaited each item in turn, so it
        // was fully sequential and `maxConcurrent` did nothing. Prefetch feeds the chat list,
        // so it warms the row-sized variant.
        let concurrency = max(1, maxConcurrent)
        let thumbnailSize = KNSProfileImageCache.rowThumbnailMaxPixelSize
        await withTaskGroup(of: Void.self) { group in
            var iterator = uniqueDescriptors.makeIterator()
            var running = 0
            while running < concurrency, let descriptor = iterator.next() {
                group.addTask {
                    _ = await KNSProfileImageCache.shared.image(for: descriptor, maxPixelSize: thumbnailSize)
                }
                running += 1
            }
            while await group.next() != nil {
                guard let descriptor = iterator.next() else { continue }
                group.addTask {
                    _ = await KNSProfileImageCache.shared.image(for: descriptor, maxPixelSize: thumbnailSize)
                }
            }
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
