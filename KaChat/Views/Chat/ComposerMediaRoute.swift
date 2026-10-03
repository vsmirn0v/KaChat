import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// What a "+"-sheet media row captures. With a Nextcloud server linked, each of these asks where
/// the media goes - on chain or via Nextcloud - every time, which is what replaced the old
/// "Send Media via Nextcloud" setting. Without one, the row goes straight to the on-chain path.
enum ComposerMediaKind: Equatable {
    case camera
    case photo
    case voice
}

enum ComposerMediaLimits {
    /// Ceiling for a voice note uploaded to Nextcloud, everywhere in the app (1:1, groups and
    /// public chats). On-chain voice notes keep their payload-bound ~10 seconds.
    static let nextcloudVoiceSeconds: TimeInterval = 300
}

/// The "+" sheet's second step for Camera / Photo / Voice Message: on chain, or via Nextcloud.
/// Shown only while a Nextcloud server is connected.
struct ComposerMediaRouteStep: View {
    let kind: ComposerMediaKind
    let onChoose: (_ viaNextcloud: Bool) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(LocalizedStringKey(title))
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 4)

            ActionSheetRow(title: onChainTitle, subtitle: onChainSubtitle, systemImage: "link") {
                onChoose(false)
            }
            ActionSheetRow(
                title: nextcloudTitle,
                subtitle: nextcloudSubtitle,
                systemImage: "externaldrive.connected.to.line.below"
            ) {
                onChoose(true)
            }

            Button("Back", action: onBack)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        switch kind {
        case .camera: return "Camera"
        case .photo: return "Photo"
        case .voice: return "Voice Message"
        }
    }

    private var onChainTitle: String {
        switch kind {
        case .camera: return "Take On-Chain Photo"
        case .photo: return "Send Photo On-Chain"
        case .voice: return "Record On-Chain"
        }
    }

    private var onChainSubtitle: String {
        switch kind {
        case .camera: return "Take a photo and send it on chain, compressed to fit."
        case .photo: return "Pick an image and send it on chain, compressed to fit."
        case .voice: return "Up to 10 seconds, sent on chain."
        }
    }

    private var nextcloudTitle: String {
        switch kind {
        case .camera: return "Take Photo via Nextcloud"
        case .photo: return "Send Photo or Video via Nextcloud"
        case .voice: return "Record via Nextcloud"
        }
    }

    private var nextcloudSubtitle: String {
        switch kind {
        case .camera: return "Full quality, or a video. Uploads to your Nextcloud; the chat carries the link."
        case .photo: return "Full quality, or a video. Uploads to your Nextcloud; the chat carries the link."
        case .voice: return "Up to 5 minutes. Uploads to your Nextcloud; the chat carries the link."
        }
    }
}

/// A video picked from the photo library ("Send Photo or Video via Nextcloud"), copied to a temp
/// file the caller owns - the Nextcloud video send deletes it once uploaded.
struct PickedMovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("kachat-picked-video-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovieFile(url: copy)
        }
    }
}

extension PhotosPickerItem {
    /// The library item is a video rather than a still.
    var isMovie: Bool {
        supportedContentTypes.contains { $0.conforms(to: .movie) }
    }
}
