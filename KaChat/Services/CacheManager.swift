import Foundation
import UIKit

/// What the app keeps on disk that it can always fetch or rebuild, and how much of it there is.
///
/// Deliberately excludes anything the user would lose by clearing: messages, contacts, keys and
/// settings are not cache, however much space they take. Every category here is re-fetched or
/// re-derived on demand, so clearing costs a little bandwidth and nothing else - which is exactly
/// what makes it safe to offer as a button.
@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()

    enum Category: String, CaseIterable, Identifiable {
        case profileImages
        case contactPhotos
        case webResponses
        case temporaryFiles

        var id: String { rawValue }

        var title: String {
            switch self {
            case .profileImages: return "Profile Images"
            case .contactPhotos: return "Contact Photos"
            case .webResponses: return "Web Responses"
            case .temporaryFiles: return "Temporary Files"
            }
        }

        var detail: String {
            switch self {
            case .profileImages:
                return "KNS avatars and banners. Downloaded again when you next see them."
            case .contactPhotos:
                return "Photos copied from your device address book. Re-read from Contacts."
            case .webResponses:
                return "Link previews and API responses held by the system's network cache."
            case .temporaryFiles:
                return "Scratch files from sending photos and voice notes. Safe to remove at any time."
            }
        }

        var systemImage: String {
            switch self {
            case .profileImages: return "person.crop.square"
            case .contactPhotos: return "person.2"
            case .webResponses: return "globe"
            case .temporaryFiles: return "doc"
            }
        }
    }

    @Published private(set) var sizes: [Category: Int64] = [:]
    @Published private(set) var isMeasuring = false

    var totalBytes: Int64 { sizes.values.reduce(0, +) }

    private init() {}

    // MARK: - Locations

    private var cachesRoot: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    private var applicationSupportRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// The directories a category owns. `webResponses` has none - URLCache does not expose its
    /// files, so it is measured and cleared through its own API instead.
    private func directories(for category: Category) -> [URL] {
        switch category {
        case .profileImages:
            return [cachesRoot?.appendingPathComponent("KNSProfileImages", isDirectory: true)].compactMap { $0 }
        case .contactPhotos:
            return [applicationSupportRoot?.appendingPathComponent("ContactAvatars", isDirectory: true)].compactMap { $0 }
        case .webResponses:
            return []
        case .temporaryFiles:
            return [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]
        }
    }

    // MARK: - Measuring

    /// Walks every category. Off the main actor: a large image cache is thousands of files, and
    /// sizing them on the main thread is exactly the kind of thing that stutters a settings
    /// screen as it opens.
    func refreshSizes() async {
        isMeasuring = true
        defer { isMeasuring = false }

        var measured: [Category: Int64] = [:]
        for category in Category.allCases {
            if category == .webResponses {
                measured[category] = Int64(URLCache.shared.currentDiskUsage)
                continue
            }
            let urls = directories(for: category)
            measured[category] = await Task.detached(priority: .utility) {
                urls.reduce(Int64(0)) { $0 + Self.directorySize(at: $1) }
            }.value
        }
        sizes = measured
    }

    /// Recursive byte total. Skips anything it cannot read rather than failing the whole walk -
    /// a size readout is not worth an error state.
    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey
            ])
            guard values?.isRegularFile == true else { continue }
            let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    // MARK: - Clearing

    func clear(_ category: Category) async {
        switch category {
        case .webResponses:
            URLCache.shared.removeAllCachedResponses()
        case .profileImages:
            await emptyDirectories(directories(for: category))
            // The in-memory half has to go too, or the screen keeps showing what was just
            // deleted from disk until the app is relaunched.
            await KNSProfileImageCacheControl.resetAfterExternalPurge()
        case .contactPhotos:
            await emptyDirectories(directories(for: category))
        case .temporaryFiles:
            await emptyDirectories(directories(for: category))
        }
        await refreshSizes()
    }

    func clearAll() async {
        for category in Category.allCases where category != .webResponses {
            await emptyDirectories(directories(for: category))
        }
        URLCache.shared.removeAllCachedResponses()
        await KNSProfileImageCacheControl.resetAfterExternalPurge()
        await refreshSizes()
    }

    /// Removes the CONTENTS, not the directory: services hold their directory URL from init, so
    /// deleting the folder itself would leave them writing into a path that no longer exists.
    private func emptyDirectories(_ urls: [URL]) async {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for url in urls {
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }
                for item in contents {
                    try? fileManager.removeItem(at: item)
                }
            }
        }.value
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(bytes, 0))
    }
}
