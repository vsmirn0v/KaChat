import SwiftUI
import UIKit
import AVFoundation

/// "Send from Nextcloud" picker (docs: KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md): browses
/// the connected account's files over WebDAV, and picking a photo/video asks the server for a
/// public `/s/TOKEN` share link via OCS — the caller sends that link as a normal chat message,
/// which the recipient's link-preview feature renders as tappable media.
///
/// Browsing starts at the account's configured start folder (Settings > Storage > Nextcloud >
/// Start Folder), with an "All Files" escape hatch back to the root. Folders list as rows;
/// photos/videos render as a Photos-style square thumbnail grid fed by the server's
/// `core/preview` endpoint.
struct NextcloudPickerView: View {
    /// Called with the created share link and the picked file after the sheet dismisses itself.
    let onPick: (URL, NextcloudFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rootPath: String

    init(onPick: @escaping (URL, NextcloudFile) -> Void) {
        self.onPick = onPick
        _rootPath = State(initialValue: NextcloudService.shared.account?.defaultFolder ?? "")
    }

    var body: some View {
        NavigationStack {
            NextcloudFolderListView(path: rootPath, title: rootTitle) { url, file in
                dismiss()
                onPick(url, file)
            }
            .id(rootPath) // switching to "All Files" swaps the navigation root
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if !rootPath.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("All Files") { rootPath = "" }
                    }
                }
            }
        }
    }

    private var rootTitle: String {
        if rootPath.isEmpty { return "Nextcloud" }
        return rootPath.split(separator: "/").last.map(String.init) ?? "Nextcloud"
    }
}

private struct NextcloudFolderListView: View {
    let path: String
    let title: String
    let onPick: (URL, NextcloudFile) -> Void

    @State private var files: [NextcloudFile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Path of the file whose share link is currently being created — shows that cell's spinner
    /// and blocks double-picks.
    @State private var sharingPath: String?

    private var folders: [NextcloudFile] {
        files.filter(\.isDirectory)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var media: [NextcloudFile] {
        files.filter { $0.isImage || $0.isVideo }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Everything else (audio, PDFs, docs, …) — sendable too, listed as rows under the grid.
    private var otherFiles: [NextcloudFile] {
        files.filter { !$0.isDirectory && !$0.isImage && !$0.isVideo }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                }

                ForEach(folders) { folder in
                    NavigationLink {
                        NextcloudFolderListView(path: folder.path, title: folder.name, onPick: onPick)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder")
                                .foregroundColor(.accentColor)
                            Text(folder.name)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    Divider().padding(.leading, 16)
                }

                if !media.isEmpty {
                    LazyVGrid(columns: gridColumns, spacing: 3) {
                        ForEach(media) { file in
                            NextcloudThumbnailCell(file: file, isSharing: sharingPath == file.path)
                                .onTapGesture { share(file) }
                        }
                    }
                    .padding(3)
                }

                ForEach(otherFiles) { file in
                    Button {
                        share(file)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: iconName(for: file))
                                .font(.system(size: 22))
                                .foregroundColor(.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if let size = file.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if sharingPath == file.path { ProgressView() }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .disabled(sharingPath != nil)
                    Divider().padding(.leading, 16)
                }

                if !isLoading && folders.isEmpty && media.isEmpty && otherFiles.isEmpty && errorMessage == nil {
                    Text("This folder is empty.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
        }
        .overlay {
            if isLoading && files.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) { await load() }
        .refreshable { await load() }
    }

    private func iconName(for file: NextcloudFile) -> String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.contentType?.hasPrefix("audio/") == true || ["mp3", "m4a", "aac", "wav", "ogg", "opus", "flac"].contains(ext) {
            return "waveform.circle.fill"
        }
        if ext == "pdf" { return "doc.richtext.fill" }
        return "doc.fill"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            files = try await NextcloudService.shared.listFolder(path)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func share(_ file: NextcloudFile) {
        guard sharingPath == nil else { return }
        sharingPath = file.path
        Task {
            do {
                let url = try await NextcloudService.shared.createPublicShareLink(for: file.path)
                sharingPath = nil
                onPick(url, file)
            } catch {
                sharingPath = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One square grid cell: server-side thumbnail when available, media-type icon otherwise,
/// play badge for videos, spinner overlay while its share link is being created.
private struct NextcloudThumbnailCell: View {
    let file: NextcloudFile
    let isSharing: Bool

    @State private var thumbnail: UIImage?
    @State private var finished = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                        Image(systemName: file.isVideo ? "film" : "photo")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .overlay {
                if file.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(color: .black.opacity(0.3), radius: 3)
                }
            }
            .overlay {
                if isSharing {
                    ZStack {
                        Color.black.opacity(0.45)
                        ProgressView().tint(.white)
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: file.path) {
                guard !finished, thumbnail == nil else { return }
                defer { finished = true }

                // 1. Server-generated preview (fast, covers most formats).
                if let data = await NextcloudService.shared.thumbnailData(for: file.path),
                   let image = UIImage(data: data) {
                    thumbnail = image
                    return
                }

                // 2. HEIC/odd images the server can't preview: fetch the original and decode
                // locally (iOS reads HEIC natively), downscaled to grid size. (The service is
                // main-actor like this view, so its synchronous helpers need no `await`.)
                if file.isImage {
                    if let data = await NextcloudService.shared.fileData(for: file.path),
                       let original = UIImage(data: data) {
                        let thumb = await original.byPreparingThumbnail(ofSize: CGSize(width: 512, height: 512)) ?? original
                        thumbnail = thumb
                        if let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                            NextcloudService.shared.storeThumbnail(jpeg, for: file.path)
                        }
                    }
                    return
                }

                // 3. Videos (e.g. .mov) without a server preview provider: grab a frame from
                // the authenticated stream — no full download needed.
                if file.isVideo,
                   let request = NextcloudService.shared.authenticatedFileRequest(for: file.path),
                   let frame = await Self.videoFrame(from: request) {
                    thumbnail = frame
                    if let jpeg = frame.jpegData(compressionQuality: 0.8) {
                        NextcloudService.shared.storeThumbnail(jpeg, for: file.path)
                    }
                }
            }
    }

    /// First-frame grab over the authenticated WebDAV stream. `AVURLAsset` fetches only the
    /// bytes it needs (moov + one frame), so this is far cheaper than downloading the file.
    private static func videoFrame(from request: URLRequest) async -> UIImage? {
        guard let url = request.url else { return nil }
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                continuation.resume(returning: cgImage.map { UIImage(cgImage: $0) })
            }
        }
    }
}

// MARK: - Start-folder selection (Settings > Storage > Nextcloud)

/// Folder-only browser for choosing where "Send from Nextcloud" starts. Selecting the root
/// reports nil (= All Files).
struct NextcloudFolderSelectView: View {
    let onSelect: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NextcloudFolderSelectList(path: "", title: "All Files") { selected in
                dismiss()
                onSelect(selected.isEmpty ? nil : selected)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct NextcloudFolderSelectList: View {
    let path: String
    let title: String
    let onChoose: (String) -> Void

    @State private var folders: [NextcloudFile] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    onChoose(path)
                } label: {
                    Label(path.isEmpty ? "Use All Files" : "Use This Folder", systemImage: "checkmark.circle")
                }
            }
            Section {
                ForEach(folders) { folder in
                    NavigationLink {
                        NextcloudFolderSelectList(path: folder.path, title: folder.name, onChoose: onChoose)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                if !isLoading && folders.isEmpty && errorMessage == nil {
                    Text("No subfolders.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            isLoading = true
            errorMessage = nil
            do {
                folders = try await NextcloudService.shared.listFolder(path)
                    .filter(\.isDirectory)
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
