import SwiftUI
import UIKit
import AVKit
import PDFKit

/// Rich link-preview card shown below a chat bubble's text when the message contains a link -
/// mirrors iMessage. Renders nothing while the fetch is in flight and nothing if no preview data
/// was found and no [fallbackText] was given, rather than a placeholder that could flash or look
/// broken. Used by 1:1 (`MessageBubbleView`), group (`GroupChatDetailView`), and broadcast
/// (`BroadcastChannelView`) bubbles.
struct LinkPreviewCardView: View {
    let url: URL
    /// The owning message's transaction id, for the "View in Explorer" long-press action -
    /// matches every other bubble type's identical action (`MessageBubbleView`'s
    /// `settingsViewModel.settings.kaspaExplorer.txURL(for:)` call sites).
    let txId: String
    /// Non-nil only when this card is standing in for the *entire* message (nothing but a bare
    /// link, no separate text bubble shown alongside it) - shown as a plain tappable-link bubble
    /// if the fetch finds no preview data, so the message doesn't render as nothing at all. Nil
    /// when used alongside a real text bubble, where showing nothing on failure is correct since
    /// the message's own text is already visible.
    var fallbackText: String?
    /// Enters the chat's message multi-select mode with this message pre-selected - nil disables
    /// the "Select" context-menu action entirely, matching every other bubble type's convention.
    var onSelect: (() -> Void)?
    /// Double-tapping the preview card opens the owning message's quick-reaction menu (reactions +
    /// reply), exactly like double-tapping a normal message bubble. Nil disables it. Single tap
    /// still opens the link.
    var onDoubleTap: (() -> Void)?
    /// Whether the preview fetch may start on render. True (the default) for accepted 1:1
    /// contacts and for group chats (members chose each other); false for non-accepted senders
    /// and for broadcast rooms (anyone can post there), where the card renders as a
    /// "Tap to load preview" placeholder and only fetches - and therefore only touches the
    /// link's server - when the user explicitly taps it. A URL that already resolved this
    /// session shows its cached result either way, since no new fetch is involved.
    var autoFetch: Bool = true

    @State private var preview: LinkPreviewData?
    @State private var hasFinishedLoading: Bool
    /// Set when the user taps the tap-to-load placeholder of a non-`autoFetch` card - flips the
    /// `.task(id:)` below so the gated fetch runs exactly once, on demand.
    @State private var loadRequested = false
    /// Non-nil while the full-screen Nextcloud media viewer is up (tap on a Nextcloud card).
    @State private var nextcloudViewerTarget: NextcloudViewerTarget?
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    init(url: URL, txId: String, fallbackText: String? = nil, onSelect: (() -> Void)? = nil, onDoubleTap: (() -> Void)? = nil, autoFetch: Bool = true) {
        self.url = url
        self.txId = txId
        self.fallbackText = fallbackText
        self.onSelect = onSelect
        self.onDoubleTap = onDoubleTap
        self.autoFetch = autoFetch
        // If this exact URL was already resolved earlier (e.g. scrolled past once already, or
        // another row with the same link), seed state with the final result immediately instead
        // of starting in the "loading" state and waiting for `.task` to come back - avoids a
        // late height change on rows that are already off in older, scrolled-past history, which
        // is what was breaking pagination scroll-restoration.
        if let cached = LinkPreviewService.shared.cachedResultIfKnown(for: url) {
            _preview = State(initialValue: cached)
            _hasFinishedLoading = State(initialValue: true)
        } else {
            _preview = State(initialValue: nil)
            _hasFinishedLoading = State(initialValue: false)
        }
    }

    private static let videoHosts: Set<String> = ["youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com"]

    private var isVideoLink: Bool {
        guard let host = url.host?.lowercased() else { return false }
        return Self.videoHosts.contains(host)
    }

    var body: some View {
        Group {
            // Always some real, concrete content here (never a bare `EmptyView` from an `if`
            // with no `else`) - a `Group`/container whose content is *entirely* conditional and
            // starts out empty doesn't reliably run an attached `.task` in SwiftUI (confirmed:
            // this exact view stopped fetching once its only content was the conditional
            // `cardBody`, and started again the moment *any* unconditional view - even a plain
            // debug label - was added). `Color.clear` sized to zero keeps a stable, real view
            // identity for `.task` to attach to without taking up any visible space.
            if hasFinishedLoading, let preview {
                cardBody(preview)
            } else if hasFinishedLoading, let fallbackText {
                fallbackBubble(fallbackText)
            } else if !autoFetch && !loadRequested {
                tapToLoadCard
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
        // `loadRequested` is part of the id so tapping the gated placeholder re-runs this task
        // and performs the on-demand fetch (a `.task(id:)` body only re-executes when its id
        // changes).
        .task(id: "\(url.absoluteString)|\(loadRequested)") {
            // Already seeded synchronously from the cache in `init` - skip re-running the fetch
            // (which would flip `hasFinishedLoading` false then true again, causing exactly the
            // late height-change flicker this seeding exists to avoid). Non-`autoFetch` cards
            // additionally wait for an explicit tap before fetching anything.
            guard !hasFinishedLoading, autoFetch || loadRequested else { return }
            preview = await LinkPreviewService.shared.preview(for: url)
            hasFinishedLoading = true
        }
        .fullScreenCover(item: $nextcloudViewerTarget) { target in
            NextcloudMediaViewerView(target: target)
        }
    }

    /// Tapping a Nextcloud media card opens the in-app full-quality viewer (photo zoom /
    /// streaming video) instead of bouncing out to Safari; every other link opens as before.
    private func handleTap(_ data: LinkPreviewData) {
        if let kind = data.nextcloudMedia,
           kind != .file, // Office docs & co. have no native renderer — Nextcloud's web viewer does
           let downloadString = data.mediaDownloadURLString,
           let downloadURL = URL(string: downloadString) {
            nextcloudViewerTarget = NextcloudViewerTarget(kind: kind, downloadURL: downloadURL, shareURL: url, title: data.title ?? "Nextcloud")
        } else {
            openURL(url)
        }
    }

    @ViewBuilder
    private func cardBody(_ data: LinkPreviewData) -> some View {
        // A plain tappable view rather than a Button, so a double-tap can open the quick-reaction
        // menu while a single tap opens the link. `onTapGesture(count: 2)` is listed first so a
        // double-tap is claimed by that handler instead of also firing the single-tap open. Matches
        // a normal message bubble's double-tap.
        if let kind = data.nextcloudMedia, kind == .image || kind == .video {
            // Nextcloud media renders as a bare photo/video bubble (like a sent photo), not a
            // titled link card — the media IS the message. Tap opens the viewer; its top-right
            // Safari button is the way to the underlying share link.
            nextcloudMediaBubble(data, kind: kind)
                .onTapGesture(count: 2) { onDoubleTap?() }
                .onTapGesture { handleTap(data) }
                .contextMenu { contextMenuItems }
        } else if let kind = data.nextcloudMedia {
            // Audio/PDF/other files: an attachment card (icon, filename, type · size). Audio
            // and PDF open the in-app viewer; everything else opens Nextcloud's own web viewer,
            // the only thing that can actually render an Office doc.
            nextcloudAttachmentCard(data, kind: kind)
                .onTapGesture(count: 2) { onDoubleTap?() }
                .onTapGesture { handleTap(data) }
                .contextMenu { contextMenuItems }
        } else {
            cardContent(data)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture(count: 2) { onDoubleTap?() }
                .onTapGesture { handleTap(data) }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 260)
                .contextMenu { contextMenuItems }
        }
    }

    @ViewBuilder
    private func nextcloudMediaBubble(_ data: LinkPreviewData, kind: NextcloudMediaKind) -> some View {
        ZStack {
            NextcloudPosterImage(
                previewURL: data.imageURLString.flatMap(URL.init(string:)),
                downloadURL: data.mediaDownloadURLString.flatMap(URL.init(string:)),
                kind: kind,
                referer: url
            )
            if kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .shadow(color: .black.opacity(0.3), radius: 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func nextcloudAttachmentCard(_ data: LinkPreviewData, kind: NextcloudMediaKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: {
                switch kind {
                case .audio: return "waveform.circle.fill"
                case .pdf: return "doc.richtext.fill"
                default: return "doc.fill"
                }
            }())
            .font(.system(size: 34))
            .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(data.title ?? "File")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(attachmentCaption(data, kind: kind))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func attachmentCaption(_ data: LinkPreviewData, kind: NextcloudMediaKind) -> String {
        let label: String
        switch kind {
        case .audio: label = "AUDIO"
        case .pdf: label = "PDF"
        default:
            // Show the real extension when we have a filename ("DOCX", "ZIP", …).
            let ext = (data.title as NSString?)?.pathExtension.uppercased() ?? ""
            label = ext.isEmpty ? "FILE" : ext
        }
        if let bytes = data.mediaByteSize, bytes > 0 {
            return "\(label) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        return label
    }

    @ViewBuilder
    private func cardContent(_ data: LinkPreviewData) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                if let imageURLString = data.imageURLString, let imageURL = URL(string: imageURLString) {
                    ZStack {
                        LinkPreviewImage(imageURL: imageURL, referer: url)
                            .frame(height: 140)
                            .frame(maxWidth: .infinity)
                            .clipped()

                        if isVideoLink || data.nextcloudMedia == .video {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.white, .black.opacity(0.45))
                                .shadow(color: .black.opacity(0.3), radius: 4)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let title = data.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let description = data.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let siteName = data.siteName, !siteName.isEmpty {
                        Text(siteName.uppercased())
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
            )
    }

    @ViewBuilder
    private func fallbackBubble(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture(count: 2) { onDoubleTap?() }
            .onTapGesture { openURL(url) }
            .contextMenu { contextMenuItems }
    }

    /// Shown instead of an automatic fetch when `autoFetch` is false (non-accepted 1:1 senders
    /// and broadcast rooms): a neutral card naming the link's host, fetched only on tap. The
    /// long-press menu still offers Copy Link / View in Explorer / Select, so the message stays
    /// fully usable without ever loading the preview.
    @ViewBuilder
    private var tapToLoadCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tap to load preview")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                if let host = url.host {
                    Text(host)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(count: 2) { onDoubleTap?() }
        .onTapGesture { loadRequested = true }
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            UIPasteboard.general.string = url.absoluteString
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }
        if let explorerURL = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
            Link(destination: explorerURL) {
                Label("View in Explorer", systemImage: "safari")
            }
        }
        if let onSelect {
            Button {
                onSelect()
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
        }
    }
}

/// The media-bubble poster: shows the share's actual image at its real aspect ratio (no crop,
/// no text chrome). Load order: the server's small `/preview` thumbnail; if the server can't
/// render one (HEIC without ImageMagick, MOV without ffmpeg), fall back to the PUBLIC
/// `/download` endpoint — decoding the original locally for images (iOS reads HEIC natively)
/// or grabbing a stream frame for videos. Both fallbacks are recipient-safe: public share
/// endpoints need no credentials.
private struct NextcloudPosterImage: View {
    let previewURL: URL?
    let downloadURL: URL?
    let kind: NextcloudMediaKind
    let referer: URL

    @State private var uiImage: UIImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 240, height: 180)
                    if finished {
                        Image(systemName: kind == .video ? "film" : "photo")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task(id: previewURL?.absoluteString ?? downloadURL?.absoluteString ?? "") {
            guard !finished, uiImage == nil else { return }
            defer { finished = true }

            if let previewURL,
               let data = await LinkPreviewService.shared.imageData(previewURL, referer: referer),
               let image = UIImage(data: data) {
                uiImage = image
                return
            }
            guard let downloadURL else { return }
            switch kind {
            case .image:
                if let data = await LinkPreviewService.shared.imageData(downloadURL, referer: referer, maxBytes: 25_000_000),
                   let original = UIImage(data: data) {
                    uiImage = await original.byPreparingThumbnail(ofSize: CGSize(width: 640, height: 640)) ?? original
                }
            case .video:
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: downloadURL))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 640)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
                let time = CMTime(seconds: 0.1, preferredTimescale: 600)
                let frame: UIImage? = await withCheckedContinuation { continuation in
                    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                        continuation.resume(returning: cgImage.map { UIImage(cgImage: $0) })
                    }
                }
                if let frame { uiImage = frame }
            case .audio, .pdf, .file:
                // Attachment-card kinds never mount this poster view (they render an icon
                // card, not a media bubble) — nothing to fall back to.
                break
            }
        }
    }
}

/// What the full-screen Nextcloud viewer should show — set when a Nextcloud media card is tapped.
private struct NextcloudViewerTarget: Identifiable {
    let kind: NextcloudMediaKind
    let downloadURL: URL
    let shareURL: URL
    let title: String
    var id: String { downloadURL.absoluteString }
}

/// Full-quality viewer for a tapped Nextcloud share (docs:
/// KaChat-Desktop/docs/NEXTCLOUD_MEDIA_PREVIEW.md). Photos fetch the original file through
/// `LinkPreviewService.imageData` with a raised byte cap; videos stream the `/download` URL
/// through AVPlayer (native range-request streaming, handles HEVC/.mov). This full fetch is
/// deliberately tap-gated — only the small `/preview` poster loads with the card.
private struct NextcloudMediaViewerView: View {
    let target: NextcloudViewerTarget
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var pdfData: Data?
    @State private var loadFailed = false
    @State private var player: AVPlayer?
    @State private var isZoomed = false

    /// Original-quality photos are the point of this viewer — far above the card cap.
    private static let fullImageMaxBytes = 50_000_000

    var body: some View {
        NavigationStack {
            Group {
                switch target.kind {
                case .video, .audio:
                    // VideoPlayer handles audio-only streams too (transport controls over a
                    // black stage) — one player path for both.
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                        .onAppear {
                            if player == nil { player = AVPlayer(url: target.downloadURL) }
                            player?.play()
                        }
                        .onDisappear { player?.pause() }
                case .pdf:
                    if let pdfData {
                        PDFKitView(data: pdfData)
                    } else if loadFailed {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("Could not load this file.")
                                .foregroundColor(.secondary)
                            Link("Open in Nextcloud", destination: target.shareURL)
                        }
                    } else {
                        ProgressView().tint(.white)
                    }
                case .file:
                    // Never presented (handleTap routes .file to the browser) — safe fallback.
                    Link("Open in Nextcloud", destination: target.shareURL)
                case .image:
                    if let image {
                        // Same pinch-zoom/pan component as the local chat-photo preview.
                        ZoomableImageView(image: image, isZoomed: $isZoomed)
                    } else if loadFailed {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("Could not load this file.")
                                .foregroundColor(.secondary)
                            Link("Open in Nextcloud", destination: target.shareURL)
                        }
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Link(destination: target.shareURL) {
                        Image(systemName: "safari")
                    }
                }
            }
            .task {
                guard !loadFailed else { return }
                switch target.kind {
                case .image where image == nil:
                    if let data = await LinkPreviewService.shared.imageData(
                        target.downloadURL,
                        referer: target.shareURL,
                        maxBytes: Self.fullImageMaxBytes
                    ), let loaded = UIImage(data: data) {
                        image = loaded
                    } else {
                        loadFailed = true
                    }
                case .pdf where pdfData == nil:
                    // Same authenticated-less public fetch as images — it's just bytes.
                    if let data = await LinkPreviewService.shared.imageData(
                        target.downloadURL,
                        referer: target.shareURL,
                        maxBytes: Self.fullImageMaxBytes
                    ), PDFDocument(data: data) != nil {
                        pdfData = data
                    } else {
                        loadFailed = true
                    }
                default:
                    break
                }
            }
        }
    }
}

/// PDFKit host for the Nextcloud viewer's inline PDF rendering.
private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .black
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document == nil { uiView.document = PDFDocument(data: data) }
    }
}

/// Loads a link-preview image through `LinkPreviewService.imageData` (browser User-Agent + Referer)
/// instead of a bare `AsyncImage`, so CDNs like cdninstagram/fbcdn that 403 header-less requests
/// serve the image. Shows a neutral placeholder until loaded or on failure.
private struct LinkPreviewImage: View {
    let imageURL: URL
    /// The page the image belongs to, sent as the `Referer` header.
    let referer: URL
    @State private var uiImage: UIImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .task(id: imageURL) {
            guard !finished else { return }
            if let data = await LinkPreviewService.shared.imageData(imageURL, referer: referer),
               let image = UIImage(data: data) {
                uiImage = image
            }
            finished = true
        }
    }
}
