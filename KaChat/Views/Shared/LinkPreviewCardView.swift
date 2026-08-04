import SwiftUI
import UIKit

/// Rich link-preview card shown below a chat bubble's text when the message contains a link -
/// mirrors iMessage. Renders nothing while the fetch is in flight and nothing if no preview data
/// was found and no [fallbackText] was given, rather than a placeholder that could flash or look
/// broken. Used by 1:1 (`MessageBubbleView`) and group (`GroupChatDetailView`) chats only -
/// broadcast rooms never construct this view.
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

    @State private var preview: LinkPreviewData?
    @State private var hasFinishedLoading: Bool
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    init(url: URL, txId: String, fallbackText: String? = nil, onSelect: (() -> Void)? = nil, onDoubleTap: (() -> Void)? = nil) {
        self.url = url
        self.txId = txId
        self.fallbackText = fallbackText
        self.onSelect = onSelect
        self.onDoubleTap = onDoubleTap
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
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
        .task(id: url) {
            // Already seeded synchronously from the cache in `init` - skip re-running the fetch
            // (which would flip `hasFinishedLoading` false then true again, causing exactly the
            // late height-change flicker this seeding exists to avoid).
            guard !hasFinishedLoading else { return }
            preview = await LinkPreviewService.shared.preview(for: url)
            hasFinishedLoading = true
        }
    }

    @ViewBuilder
    private func cardBody(_ data: LinkPreviewData) -> some View {
        // A plain tappable view rather than a Button, so a double-tap can open the quick-reaction
        // menu while a single tap opens the link. `onTapGesture(count: 2)` is listed first so a
        // double-tap is claimed by that handler instead of also firing the single-tap open. Matches
        // a normal message bubble's double-tap.
        cardContent(data)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture(count: 2) { onDoubleTap?() }
            .onTapGesture { openURL(url) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 260)
            .contextMenu { contextMenuItems }
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

                        if isVideoLink {
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
