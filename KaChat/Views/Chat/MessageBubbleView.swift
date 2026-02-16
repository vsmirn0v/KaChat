import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers
#if canImport(YbridOpus)
import YbridOpus
#endif

private let kaspaBubbleColor = Color(red: 112.0 / 255.0, green: 199.0 / 255.0, blue: 186.0 / 255.0)

struct MessageBubbleView: View {
    let message: ChatMessage
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: ((ChatMessage) -> Void)?
    let onAcceptHandshake: (() -> Void)?
    let onDeclineHandshake: (() -> Void)?
    @State private var showImagePreview = false
    @State private var shimmerPhase: CGFloat = -1

    init(message: ChatMessage, onCopy: ((String, ToastStyle) -> Void)? = nil, onRetry: ((ChatMessage) -> Void)? = nil, onAcceptHandshake: (() -> Void)? = nil, onDeclineHandshake: (() -> Void)? = nil) {
        self.message = message
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onAcceptHandshake = onAcceptHandshake
        self.onDeclineHandshake = onDeclineHandshake
    }

    var body: some View {
        let media = mediaFile
        let image = media?.image(cacheKey: message.txId)
        let isSingleEmojiOnly = isSingleEmojiOnlyMessage(message.content)

        HStack {
            if message.isOutgoing {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Message type indicator for special messages
                if message.messageType != .contextual {
                    messageTypeIndicator
                }

                // Incoming handshake request with Accept/Decline actions
                if message.messageType == .handshake && !message.isOutgoing && onAcceptHandshake != nil {
                    handshakeRequestBubble
                } else if let media, media.isImage, let image {
                    Button {
                        showImagePreview = true
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            handleCopy(media.name, toast: "File name copied.")
                        } label: {
                            Label("Copy File Name", systemImage: "doc.on.doc")
                        }

                        Button {
                            handleCopy(message.txId, toast: "Transaction ID copied.")
                        } label: {
                            Label("Copy Transaction ID", systemImage: "number")
                        }

                        if shouldShowRetry {
                            Button {
                                onRetry?(message)
                            } label: {
                                Label("Retry Send", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                    .fullScreenCover(isPresented: $showImagePreview) {
                        ImagePreviewView(
                            image: image,
                            title: media.name
                        )
                    }
                } else if let media, media.isAudio, let data = media.fileData(cacheKey: message.txId) {
                    LazyAudioBubble(
                        data: data,
                        mimeType: media.mimeType,
                        isOutgoing: message.isOutgoing,
                        fileName: media.name,
                        txId: message.txId,
                        onCopy: onCopy,
                        onRetry: shouldShowRetry ? { onRetry?(message) } : nil
                    )
                } else {
                    LinkifiedMessageTextView(
                        text: message.content,
                        isOutgoing: message.isOutgoing,
                        isSingleEmojiOnly: isSingleEmojiOnly,
                        onLinkLongPress: { url in
                            handleCopy(url.absoluteString, toast: "Link copied to clipboard.")
                        }
                    )
                        .padding(.horizontal, isSingleEmojiOnly ? 0 : 12)
                        .padding(.vertical, isSingleEmojiOnly ? 0 : 8)
                        .background(isSingleEmojiOnly ? Color.clear : (message.isOutgoing ? kaspaBubbleColor : Color(.systemGray5)))
                        .clipShape(RoundedRectangle(cornerRadius: isSingleEmojiOnly ? 0 : 16))
                        .overlay {
                            if !isSingleEmojiOnly && shouldShowResolvingOverlay {
                                ShimmerOverlay(phase: shimmerPhase)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .allowsHitTesting(false)
                            }
                        }
                        .contextMenu {
                            Button {
                                handleCopy(message.content, toast: "Message copied to clipboard.")
                            } label: {
                                Label("Copy Message", systemImage: "doc.on.doc")
                            }

                            Button {
                                handleCopy(message.txId, toast: "Transaction ID copied.")
                            } label: {
                                Label("Copy Transaction ID", systemImage: "number")
                            }

                            if shouldShowRetry {
                                Button {
                                    onRetry?(message)
                                } label: {
                                    Label("Retry Send", systemImage: "arrow.clockwise")
                                }
                            }
                        }
                }

                // Timestamp and status
                HStack(spacing: 4) {
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if shouldShowStatusIcon {
                        statusIcon
                    }
                }
            }
            .onAppear {
                startShimmerIfNeeded()
            }
            .onChange(of: shouldShowResolvingOverlay, initial: false) { _, _ in
                startShimmerIfNeeded()
            }

            if !message.isOutgoing {
                Spacer(minLength: 60)
            }
        }
    }

    private var shouldShowResolvingOverlay: Bool {
        message.messageType == .payment && message.deliveryStatus == .pending
    }

    private func startShimmerIfNeeded() {
        guard shouldShowResolvingOverlay else {
            shimmerPhase = -1
            return
        }
        shimmerPhase = -1
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            shimmerPhase = 1
        }
    }

    private var shouldShowRetry: Bool {
        guard message.isOutgoing, message.deliveryStatus == .failed else { return false }
        switch message.messageType {
        case .contextual, .audio, .handshake:
            return true
        case .payment:
            return false
        }
    }

    private var shouldShowStatusIcon: Bool {
        message.isOutgoing || message.deliveryStatus == .warning
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.deliveryStatus {
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        case .warning:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.orange)
        }
    }

    private var handshakeRequestBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.wave.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Contact has requested permission to communicate")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            HStack(spacing: 12) {
                Button {
                    onAcceptHandshake?()
                } label: {
                    Text("Accept")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(kaspaBubbleColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button {
                    onDeclineHandshake?()
                } label: {
                    Text("Decline")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5))
                        .foregroundColor(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 300)
    }

    @ViewBuilder
    private var messageTypeIndicator: some View {
        switch message.messageType {
        case .handshake:
            HStack(spacing: 4) {
                Image(systemName: "hand.wave.fill")
                    .font(.caption2)
                Text("Handshake")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(.systemGray6))
            .clipShape(Capsule())

        case .payment:
            HStack(spacing: 4) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.caption2)
                Text("Payment")
                    .font(.caption2)
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.1))
            .clipShape(Capsule())

        case .contextual:
            EmptyView()

        case .audio:
            HStack(spacing: 4) {
                Image(systemName: "waveform.circle.fill")
                    .font(.caption2)
                Text("Audio")
                    .font(.caption2)
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.1))
            .clipShape(Capsule())
        }
    }

    private func formatTime(_ date: Date) -> String {
        SharedFormatting.chatTime.string(from: date)
    }

    private func handleCopy(_ value: String, toast: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        onCopy?(toast, .success)
    }

    private var mediaFile: MediaFile? {
        MediaFile.from(message.content, cacheKey: message.txId)
    }

    private func isSingleEmojiOnlyMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1 else {
            return false
        }
        return trimmed.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        }
    }
}

private struct LinkifiedMessageTextView: UIViewRepresentable {
    let text: String
    let isOutgoing: Bool
    let isSingleEmojiOnly: Bool
    let onLinkLongPress: (URL) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.required, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        context.coordinator.textView = textView
        context.coordinator.configureGestureRecognizersIfNeeded()
        textView.attributedText = context.coordinator.makeAttributedText(
            text: text,
            isOutgoing: isOutgoing,
            isSingleEmojiOnly: isSingleEmojiOnly
        )
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        uiView.attributedText = context.coordinator.makeAttributedText(
            text: text,
            isOutgoing: isOutgoing,
            isSingleEmojiOnly: isSingleEmojiOnly
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let screenWidth = UIScreen.main.bounds.width
        let maxBubbleWidth = screenWidth * 0.72
        let proposedWidth = proposal.width ?? maxBubbleWidth
        let targetMaxWidth = max(1, min(maxBubbleWidth, proposedWidth))

        let unconstrained = uiView.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        let targetWidth = max(1, min(targetMaxWidth, ceil(unconstrained.width)))
        let fitting = uiView.sizeThatFits(
            CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: targetWidth, height: ceil(fitting.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: LinkifiedMessageTextView
        weak var textView: UITextView?
        private var tapRecognizer: UITapGestureRecognizer?
        private var longPressRecognizer: UILongPressGestureRecognizer?
        private var cachedText: String?
        private var cachedIsOutgoing = false
        private var cachedIsSingleEmojiOnly = false
        private var cachedAttributedText: NSAttributedString?

        init(parent: LinkifiedMessageTextView) {
            self.parent = parent
        }

        func configureGestureRecognizersIfNeeded() {
            guard let textView else { return }
            if tapRecognizer == nil {
                let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                recognizer.delegate = self
                recognizer.cancelsTouchesInView = true
                textView.addGestureRecognizer(recognizer)
                tapRecognizer = recognizer
            }
            guard longPressRecognizer == nil else { return }
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            recognizer.delegate = self
            recognizer.minimumPressDuration = 0.45
            recognizer.cancelsTouchesInView = true
            textView.addGestureRecognizer(recognizer)
            longPressRecognizer = recognizer
        }

        func makeAttributedText(text: String, isOutgoing: Bool, isSingleEmojiOnly: Bool) -> NSAttributedString {
            if let cachedText,
               cachedText == text,
               cachedIsOutgoing == isOutgoing,
               cachedIsSingleEmojiOnly == isSingleEmojiOnly,
               let cachedAttributedText {
                return cachedAttributedText
            }

            let baseColor = isSingleEmojiOnly ? UIColor.label : (isOutgoing ? UIColor.white : UIColor.label)
            let bodyFont = UIFont.preferredFont(forTextStyle: .body)
            let baseFont = isSingleEmojiOnly ? bodyFont.withSize(bodyFont.pointSize * 5.0) : bodyFont
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: baseFont,
                    .foregroundColor: baseColor
                ]
            )
            let fullRange = NSRange(location: 0, length: attributed.length)

            if let detector = SharedDetectors.link {
                detector.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                    guard let match, let url = match.url else { return }
                    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
                    attributed.addAttributes(
                        [
                            .link: url,
                            .foregroundColor: UIColor.systemBlue,
                            .underlineStyle: NSUnderlineStyle.single.rawValue
                        ],
                        range: match.range
                    )
                }
            }

            let result = NSAttributedString(attributedString: attributed)
            cachedText = text
            cachedIsOutgoing = isOutgoing
            cachedIsSingleEmojiOnly = isSingleEmojiOnly
            cachedAttributedText = result
            return result
        }

        @objc
        private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let textView else { return }
            let point = gesture.location(in: textView)
            guard let url = url(at: point, in: textView) else { return }
            UIApplication.shared.open(url)
        }

        @objc
        private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let textView else { return }
            let point = gesture.location(in: textView)
            guard let url = url(at: point, in: textView) else { return }
            parent.onLinkLongPress(url)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let textView else { return false }
            guard gestureRecognizer === tapRecognizer || gestureRecognizer === longPressRecognizer else {
                return true
            }
            let location = gestureRecognizer.location(in: textView)
            return url(at: location, in: textView) != nil
        }

        private func url(at point: CGPoint, in textView: UITextView) -> URL? {
            let textContainerPoint = CGPoint(
                x: point.x - textView.textContainerInset.left,
                y: point.y - textView.textContainerInset.top
            )
            guard textContainerPoint.x >= 0, textContainerPoint.y >= 0 else { return nil }

            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            let glyphIndex = layoutManager.glyphIndex(for: textContainerPoint, in: textContainer)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            guard glyphRect.contains(textContainerPoint) else { return nil }

            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard charIndex < textView.textStorage.length else { return nil }

            let attributes = textView.textStorage.attributes(at: charIndex, effectiveRange: nil)
            if let url = attributes[.link] as? URL {
                return url
            }
            if let urlString = attributes[.link] as? String {
                return URL(string: urlString)
            }
            return nil
        }

    }
}

private struct ShimmerOverlay: View {
    let phase: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.25),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .rotationEffect(.degrees(20))
                .offset(x: phase * width * 1.5)
        }
    }
}

private struct MediaFile: Codable {
    let type: String
    let name: String
    let size: Int?
    let mimeType: String
    let content: String

    private final class OptionalMediaFileBox: NSObject {
        let value: MediaFile?
        init(_ value: MediaFile?) {
            self.value = value
        }
    }
    private static let parsedCache: NSCache<NSString, OptionalMediaFileBox> = {
        let cache = NSCache<NSString, OptionalMediaFileBox>()
        cache.countLimit = 512
        return cache
    }()
    private static let dataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    var isAudio: Bool {
        mimeType.lowercased().hasPrefix("audio/")
    }

    var fileData: Data? {
        fileData(cacheKey: nil)
    }

    func fileData(cacheKey: String?) -> Data? {
        if let key = Self.cacheKey(from: cacheKey),
           let cached = Self.dataCache.object(forKey: key) {
            return cached as Data
        }
        let decoded = Self.dataFromDataURL(content) ?? Data(base64Encoded: content)
        if let key = Self.cacheKey(from: cacheKey), let decoded {
            Self.dataCache.setObject(decoded as NSData, forKey: key, cost: decoded.count)
        }
        return decoded
    }

    func image(cacheKey: String?) -> UIImage? {
        guard isImage else { return nil }
        if let key = Self.cacheKey(from: cacheKey),
           let cachedImage = Self.imageCache.object(forKey: key) {
            return cachedImage
        }
        guard let data = fileData(cacheKey: cacheKey),
              let image = UIImage(data: data) else {
            return nil
        }
        if let key = Self.cacheKey(from: cacheKey) {
            Self.imageCache.setObject(image, forKey: key, cost: data.count)
        }
        return image
    }

    static func from(_ text: String, cacheKey cacheToken: String? = nil) -> MediaFile? {
        if let key = cacheKey(from: cacheToken),
           let cached = parsedCache.object(forKey: key) {
            return cached.value
        }

        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            if let key = cacheKey(from: cacheToken) {
                parsedCache.setObject(OptionalMediaFileBox(nil), forKey: key)
            }
            return nil
        }
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let file = try? decoder.decode(MediaFile.self, from: data),
              file.type == "file" else {
            if let key = cacheKey(from: cacheToken) {
                parsedCache.setObject(OptionalMediaFileBox(nil), forKey: key)
            }
            return nil
        }
        if let key = cacheKey(from: cacheToken) {
            parsedCache.setObject(OptionalMediaFileBox(file), forKey: key)
        }
        return file
    }

    private static func cacheKey(from value: String?) -> NSString? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed as NSString
    }

    private static func dataFromDataURL(_ text: String) -> Data? {
        guard let prefixRange = text.range(of: "base64,") else { return nil }
        let base64 = text[prefixRange.upperBound...]
        return Data(base64Encoded: String(base64))
    }
}

private final class AudioPlaybackHelper: NSObject, ObservableObject, AVAudioPlayerDelegate, @unchecked Sendable {
    @Published var isPlaying = false
    @Published var durationText: String = "--:--"
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var waveformSamples: [Float] = []

    private var player: AVAudioPlayer?
    private var tempPlaybackURL: URL?
    private var cachedDuration: TimeInterval?
    private var dataHash: Int?
    private var progressTimer: Timer?

    func preloadDuration(data: Data, mimeType: String) {
        let newHash = data.hashValue
        if dataHash == newHash, cachedDuration != nil {
            return // Already loaded for this data
        }
        dataHash = newHash

        isLoading = true
        Task { @MainActor [weak self] in
            do {
                let (duration, samples) = try await Self.loadAudioInfo(data: data, mimeType: mimeType)
                self?.cachedDuration = duration
                self?.durationText = self?.formattedDuration(duration) ?? "--:--"
                self?.waveformSamples = samples
                self?.isLoading = false
            } catch {
                self?.durationText = "--:--"
                self?.waveformSamples = Array(repeating: 0.3, count: 40)
                self?.isLoading = false
            }
        }
    }

    private static func loadAudioInfo(data: Data, mimeType: String) async throws -> (TimeInterval, [Float]) {
        if mimeType.lowercased().contains("webm") {
            let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
            let samples = extractWaveformSamples(from: decoded.url, sampleCount: 40)
            try? FileManager.default.removeItem(at: decoded.url)
            return (decoded.duration, samples)
        }
        if mimeType.lowercased().contains("ogg") || mimeType.lowercased().contains("opus") {
            let decoded = try OggOpusDecoder.decodeToPCMFile(data: data)
            let samples = extractWaveformSamples(from: decoded.url, sampleCount: 40)
            try? FileManager.default.removeItem(at: decoded.url)
            return (decoded.duration, samples)
        }
        // For other formats
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".audio")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let player = try AVAudioPlayer(contentsOf: tempURL)
        let samples = extractWaveformSamples(from: tempURL, sampleCount: 40)
        return (player.duration, samples)
    }

    private static func extractWaveformSamples(from url: URL, sampleCount: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        do {
            try file.read(into: buffer)
        } catch {
            return Array(repeating: 0.3, count: sampleCount)
        }

        guard let floatData = buffer.floatChannelData?[0] else {
            return Array(repeating: 0.3, count: sampleCount)
        }

        let totalFrames = Int(buffer.frameLength)
        let framesPerSample = max(1, totalFrames / sampleCount)
        var samples: [Float] = []

        for i in 0..<sampleCount {
            let start = i * framesPerSample
            let end = min(start + framesPerSample, totalFrames)
            var maxAmp: Float = 0
            for j in start..<end {
                maxAmp = max(maxAmp, abs(floatData[j]))
            }
            // Normalize and clamp
            samples.append(min(1.0, max(0.1, maxAmp * 2)))
        }

        return samples
    }

    func togglePlayback(data: Data, mimeType: String) {
        if isPlaying {
            stop()
            return
        }

        do {
            try setPlaybackSession()
            player = try makePlayer(data: data, mimeType: mimeType)
            player?.delegate = self
            player?.prepareToPlay()
            if player?.play() != true {
                stop()
                return
            }
            isPlaying = true
            progress = 0
            startProgressTimer()
            if let duration = cachedDuration {
                durationText = formattedDuration(duration)
            } else {
                durationText = formattedDuration(player?.duration ?? 0)
            }
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        if let url = tempPlaybackURL {
            try? FileManager.default.removeItem(at: url)
            tempPlaybackURL = nil
        }
        isPlaying = false
        progress = 0
        if let duration = cachedDuration {
            durationText = formattedDuration(duration)
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            let duration = player.duration
            if duration > 0 {
                self.progress = player.currentTime / duration
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = nil
            self.isPlaying = false
            self.progress = 0
            if let url = self.tempPlaybackURL {
                try? FileManager.default.removeItem(at: url)
                self.tempPlaybackURL = nil
            }
            if let duration = self.cachedDuration {
                self.durationText = self.formattedDuration(duration)
            }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "--:--" }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func setPlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func makePlayer(data: Data, mimeType: String) throws -> AVAudioPlayer {
        if mimeType.lowercased().contains("webm") {
            let decoded = try WebMOpusDecoder.decodeToPCMFile(data: data)
            tempPlaybackURL = decoded.url
            cachedDuration = decoded.duration
            durationText = formattedDuration(decoded.duration)
            return try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
        }
        if mimeType.lowercased().contains("ogg") || mimeType.lowercased().contains("opus") {
            let decoded = try OggOpusDecoder.decodeToPCMFile(data: data)
            tempPlaybackURL = decoded.url
            cachedDuration = decoded.duration
            durationText = formattedDuration(decoded.duration)
            return try AVAudioPlayer(contentsOf: decoded.url, fileTypeHint: AVFileType.caf.rawValue)
        }
        return try AVAudioPlayer(data: data)
    }
}

/// Wrapper that lazily creates AudioPlaybackHelper only when needed
private struct LazyAudioBubble: View {
    let data: Data
    let mimeType: String
    let isOutgoing: Bool
    let fileName: String
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    @StateObject private var helper = AudioPlaybackHelper()

    var body: some View {
        AudioBubble(
            helper: helper,
            data: data,
            mimeType: mimeType,
            isOutgoing: isOutgoing,
            fileName: fileName,
            txId: txId,
            onCopy: onCopy,
            onRetry: onRetry
        )
    }
}

private struct AudioBubble: View {
    @ObservedObject var helper: AudioPlaybackHelper
    let data: Data
    let mimeType: String
    let isOutgoing: Bool
    let fileName: String
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    @State private var showShareSheet = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                helper.togglePlayback(data: data, mimeType: mimeType)
            } label: {
                if helper.isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: helper.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                }
            }
            .disabled(helper.isLoading)

            VStack(alignment: .leading, spacing: 4) {
                WaveformView(
                    samples: helper.waveformSamples,
                    progress: helper.progress,
                    isOutgoing: isOutgoing
                )
                .frame(height: 24)

                Text(helper.durationText)
                    .font(.caption)
                    .foregroundColor(isOutgoing ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isOutgoing ? kaspaBubbleColor : Color(.systemGray5))
        .foregroundColor(isOutgoing ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contextMenu {
            Button {
                showShareSheet = true
            } label: {
                Label("Save Audio", systemImage: "square.and.arrow.down")
            }

            Button {
                UIPasteboard.general.string = txId
                Haptics.success()
                onCopy?("Transaction ID copied.", .success)
            } label: {
                Label("Copy Transaction ID", systemImage: "number")
            }

            if let onRetry {
                Button {
                    onRetry()
                } label: {
                    Label("Retry Send", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            AudioShareSheet(data: data, fileName: fileName, mimeType: mimeType)
        }
        .onAppear {
            helper.preloadDuration(data: data, mimeType: mimeType)
        }
        .onDisappear {
            helper.stop()
        }
    }
}

private struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let isOutgoing: Bool

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: barSpacing) {
                let displaySamples = samples.isEmpty ? Array(repeating: Float(0.3), count: 40) : samples
                ForEach(0..<displaySamples.count, id: \.self) { index in
                    let amplitude = CGFloat(displaySamples[index])
                    let barProgress = Double(index) / Double(displaySamples.count)
                    let isPlayed = barProgress < progress

                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(barColor(isPlayed: isPlayed))
                        .frame(width: barWidth, height: max(4, amplitude * geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func barColor(isPlayed: Bool) -> Color {
        if isOutgoing {
            return isPlayed ? .white : .white.opacity(0.5)
        } else {
            return isPlayed ? kaspaBubbleColor : .gray.opacity(0.4)
        }
    }
}

private struct AudioShareSheet: UIViewControllerRepresentable {
    let data: Data
    let fileName: String
    let mimeType: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Create temp file for sharing
        let lowercasedMime = mimeType.lowercased()
        let fileExtension: String
        if lowercasedMime.contains("webm") {
            fileExtension = "webm"
        } else if lowercasedMime.contains("ogg") || lowercasedMime.contains("opus") {
            fileExtension = "ogg"
        } else {
            fileExtension = "m4a"
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName.hasSuffix(".\(fileExtension)") ? fileName : "\(fileName).\(fileExtension)")

        try? data.write(to: tempURL)

        let controller = UIActivityViewController(
            activityItems: [tempURL],
            applicationActivities: nil
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#if canImport(YbridOpus) || OPUS_CATALYST
private enum WebMOpusDecodeError: LocalizedError {
    case invalidWebM(String)
    case missingOpusHead
    case invalidOpusHead
    case unsupportedLacing
    case decoderInit(Int32)
    case decodeFailed(Int32)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidWebM(let details):
            return "Invalid WebM data. \(details)"
        case .missingOpusHead:
            return "Missing Opus header."
        case .invalidOpusHead:
            return "Invalid Opus header."
        case .unsupportedLacing:
            return "Unsupported block lacing."
        case .decoderInit(let code):
            return "Opus decoder init failed (\(code))."
        case .decodeFailed(let code):
            return "Opus decode failed (\(code))."
        case .noAudio:
            return "No audio data."
        }
    }
}

struct WebMOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        let parsed = try parseWebM(data)
        let head = try parseOpusHead(parsed.opusHead)
        let packets = parsed.packets
        if packets.isEmpty {
            throw WebMOpusDecodeError.noAudio
        }

        let sampleRate = normalizedSampleRate(head.sampleRate)
        var opusError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(sampleRate), Int32(head.channels), &opusError) else {
            throw WebMOpusDecodeError.decoderInit(opusError)
        }
        defer { opus_decoder_destroy(decoder) }

        let maxFrameSize = Int(sampleRate / 1000.0 * 120.0)
        var samples = [Float]()
        samples.reserveCapacity(packets.count * maxFrameSize * head.channels)

        var tempBuffer = [Float](repeating: 0, count: maxFrameSize * head.channels)
        for packet in packets {
            let decodedFrames = packet.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OPUS_BAD_ARG
                }
                return opus_decode_float(
                    decoder,
                    base,
                    Int32(buffer.count),
                    &tempBuffer,
                    Int32(maxFrameSize),
                    0
                )
            }
            if decodedFrames < 0 {
                throw WebMOpusDecodeError.decodeFailed(decodedFrames)
            }
            let frameCount = Int(decodedFrames)
            let total = frameCount * head.channels
            samples.append(contentsOf: tempBuffer.prefix(total))
        }

        let skipFrames = Int(Double(head.preSkip) * sampleRate / 48_000.0)
        if skipFrames > 0 && samples.count >= skipFrames * head.channels {
            samples.removeFirst(skipFrames * head.channels)
        }

        let duration = TimeInterval(Double(samples.count / head.channels) / sampleRate)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-play-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(head.channels),
                                         interleaved: false) else {
            throw WebMOpusDecodeError.invalidWebM("Failed to build output format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count / head.channels)) else {
            throw WebMOpusDecodeError.invalidWebM("Failed to allocate output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count / head.channels)
        if let channels = buffer.floatChannelData {
            for channel in 0..<head.channels {
                var writeIndex = 0
                let channelPointer = channels[channel]
                for frameIndex in stride(from: channel, to: samples.count, by: head.channels) {
                    channelPointer[writeIndex] = samples[frameIndex]
                    writeIndex += 1
                }
            }
        }

        let audioFile = try AVAudioFile(forWriting: outputURL,
                                        settings: format.settings,
                                        commonFormat: format.commonFormat,
                                        interleaved: format.isInterleaved)
        try audioFile.write(from: buffer)

        return DecodedAudio(url: outputURL, duration: duration)
    }

    private struct OpusHead {
        let channels: Int
        let preSkip: Int
        let sampleRate: Double
    }

    private struct ParsedWebM {
        let opusHead: Data
        let packets: [Data]
    }

    private static func parseWebM(_ data: Data) throws -> ParsedWebM {
        var opusHead: Data?
        var packets: [Data] = []

        let containerIDs: Set<UInt64> = [
            0x18538067, // Segment
            0x1549A966, // Info
            0x1654AE6B, // Tracks
            0xAE,       // TrackEntry
            0x1F43B675  // Cluster
        ]

        func parseElements(in range: Range<Int>) throws {
            var offset = range.lowerBound
            while offset < range.upperBound {
                let (id, idLen, _) = try readVInt(data, offset: offset, forSize: false)
                let sizeOffset = offset + idLen
                if sizeOffset >= range.upperBound { break }
                let (size, _, isUnknown, payloadStart) = try readElementSize(
                    data: data,
                    id: id,
                    sizeOffset: sizeOffset,
                    range: range
                )
                if payloadStart > range.upperBound { break }
                let payloadEnd: Int
                if isUnknown {
                    payloadEnd = range.upperBound
                } else {
                    let end = payloadStart + Int(size)
                    if end < payloadStart { break }
                    payloadEnd = min(end, range.upperBound)
                }

                if id == 0x63A2 {
                    opusHead = data.subdata(in: payloadStart..<payloadEnd)
                } else if id == 0xA3 {
                    let block = data.subdata(in: payloadStart..<payloadEnd)
                    if let packet = try parseSimpleBlock(block) {
                        packets.append(packet)
                    }
                } else if containerIDs.contains(id) {
                    try parseElements(in: payloadStart..<payloadEnd)
                }

                if payloadEnd <= offset {
                    break
                }
                offset = payloadEnd
            }
        }

        try parseElements(in: 0..<data.count)

        guard let opusHead else {
            throw WebMOpusDecodeError.missingOpusHead
        }
        return ParsedWebM(opusHead: opusHead, packets: packets)
    }

    private static func parseSimpleBlock(_ data: Data) throws -> Data? {
        var offset = 0
        let (trackNumber, trackLen) = try readVIntValue(data, offset: offset)
        offset += trackLen
        guard offset + 3 <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Short SimpleBlock.")
        }
        let _ = Int16(bitPattern: UInt16(data[offset]) << 8 | UInt16(data[offset + 1]))
        offset += 2
        let flags = data[offset]
        offset += 1

        let lacing = (flags >> 1) & 0x03
        if lacing != 0 {
            throw WebMOpusDecodeError.unsupportedLacing
        }
        guard trackNumber == 1 else {
            return nil
        }
        guard offset <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Short SimpleBlock payload.")
        }
        return data.subdata(in: offset..<data.count)
    }

    private static func readElementSize(
        data: Data,
        id: UInt64,
        sizeOffset: Int,
        range: Range<Int>
    ) throws -> (size: UInt64, sizeLen: Int, isUnknown: Bool, payloadStart: Int) {
        if id == 0x18538067, sizeOffset + 8 <= range.upperBound {
            let candidate = data[sizeOffset..<(sizeOffset + 8)]
            if candidate.allSatisfy({ $0 == 0xFF }) {
                return (0, 8, true, sizeOffset + 8)
            }
        }
        let (size, sizeLen, isUnknown) = try readVInt(data, offset: sizeOffset, forSize: true)
        return (size, sizeLen, isUnknown, sizeOffset + sizeLen)
    }

    private static func parseOpusHead(_ data: Data) throws -> OpusHead {
        guard data.count >= 19, data.starts(with: Array("OpusHead".utf8)) else {
            throw WebMOpusDecodeError.invalidOpusHead
        }
        let channels = Int(data[9])
        let preSkip = Int(readUInt16LE(data, offset: 10))
        let sampleRate = Double(readUInt32LE(data, offset: 12))
        return OpusHead(channels: max(1, channels), preSkip: preSkip, sampleRate: sampleRate)
    }

    private static func readVInt(_ data: Data, offset: Int, forSize: Bool) throws -> (value: UInt64, length: Int, isUnknown: Bool) {
        guard offset < data.count else {
            throw WebMOpusDecodeError.invalidWebM("Unexpected end of data.")
        }
        let first = data[offset]
        var mask: UInt8 = 0x80
        var length = 1
        while length <= 8 && (first & mask) == 0 {
            mask >>= 1
            length += 1
        }
        guard length <= 8 else {
            throw WebMOpusDecodeError.invalidWebM("Invalid VINT length.")
        }
        guard offset + length <= data.count else {
            throw WebMOpusDecodeError.invalidWebM("Truncated VINT.")
        }

        var value: UInt64
        if forSize {
            let leadingBit = mask
            value = UInt64(first & (leadingBit - 1))
        } else {
            value = UInt64(first)
        }
        if length > 1 {
            for index in 1..<length {
                value = (value << 8) | UInt64(data[offset + index])
            }
        }

        if forSize {
            let maxValue = (UInt64(1) << (7 * length)) - 1
            let isUnknown = value == maxValue
            return (value, length, isUnknown)
        }
        return (value, length, false)
    }

    private static func readVIntValue(_ data: Data, offset: Int) throws -> (value: UInt64, length: Int) {
        let (value, length, _) = try readVInt(data, offset: offset, forSize: true)
        return (value, length)
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func normalizedSampleRate(_ value: Double) -> Double {
        switch value {
        case 8_000, 12_000, 16_000, 24_000, 48_000:
            return value
        default:
            return 48_000
        }
    }
}

private enum OggOpusDecodeError: LocalizedError {
    case invalidOgg(String)
    case invalidOpusHead
    case decoderInit(Int32)
    case decodeFailed(Int32)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .invalidOgg(let details):
            return "Invalid Ogg data. \(details)"
        case .invalidOpusHead:
            return "Invalid Opus header."
        case .decoderInit(let code):
            return "Opus decoder init failed (\(code))."
        case .decodeFailed(let code):
            return "Opus decode failed (\(code))."
        case .noAudio:
            return "No audio data."
        }
    }
}

private struct OggOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    /// Get duration from Ogg file by parsing granule position without full decode
    static func getDuration(data: Data) throws -> TimeInterval {
        // Find the last Ogg page and read its granule position
        var lastGranulePosition: UInt64 = 0
        var sampleRate: Double = 48_000
        var preSkip: Int = 0
        var offset = 0

        while offset + 27 <= data.count {
            guard data[offset..<(offset + 4)] == Data([0x4f, 0x67, 0x67, 0x53]) else {
                break
            }

            // Read granule position (bytes 6-13, little endian)
            let granule = readUInt64LE(data, offset: offset + 6)
            lastGranulePosition = granule

            let pageSegments = Int(data[offset + 26])
            let headerSize = 27 + pageSegments
            guard offset + headerSize <= data.count else { break }

            let segmentTable = data[(offset + 27)..<(offset + 27 + pageSegments)]
            let bodySize = segmentTable.reduce(0) { $0 + Int($1) }
            let bodyStart = offset + headerSize

            // Parse OpusHead from first page to get sample rate and pre-skip
            if offset == 0 && bodySize >= 19 {
                let headData = data[bodyStart..<(bodyStart + min(bodySize, 19))]
                if headData.starts(with: Array("OpusHead".utf8)) {
                    preSkip = Int(readUInt16LE(data, offset: bodyStart + 10))
                    sampleRate = Double(readUInt32LE(data, offset: bodyStart + 12))
                    if sampleRate == 0 { sampleRate = 48_000 }
                }
            }

            offset = bodyStart + bodySize
        }

        // Opus always uses 48kHz internally for granule position
        let totalSamples = Int64(lastGranulePosition) - Int64(preSkip)
        let duration = max(0, Double(totalSamples) / 48_000.0)
        return duration
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        let packets = try extractPackets(from: data)
        guard packets.count >= 2 else {
            throw OggOpusDecodeError.invalidOgg("Missing Opus header.")
        }
        guard packets[0].starts(with: Array("OpusHead".utf8)) else {
            throw OggOpusDecodeError.invalidOpusHead
        }
        let head = try parseOpusHead(packets[0])
        let audioPackets = packets.dropFirst(2)
        if audioPackets.isEmpty {
            throw OggOpusDecodeError.noAudio
        }

        let sampleRate = normalizedSampleRate(head.sampleRate)
        var opusError: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(sampleRate), Int32(head.channels), &opusError) else {
            throw OggOpusDecodeError.decoderInit(opusError)
        }
        defer { opus_decoder_destroy(decoder) }

        let maxFrameSize = Int(sampleRate / 1000.0 * 120.0)
        var samples = [Float]()
        samples.reserveCapacity(audioPackets.count * maxFrameSize * head.channels)

        var tempBuffer = [Float](repeating: 0, count: maxFrameSize * head.channels)
        for packet in audioPackets {
            let decodedFrames = packet.withUnsafeBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OPUS_BAD_ARG
                }
                return opus_decode_float(
                    decoder,
                    base,
                    Int32(buffer.count),
                    &tempBuffer,
                    Int32(maxFrameSize),
                    0
                )
            }
            if decodedFrames < 0 {
                throw OggOpusDecodeError.decodeFailed(decodedFrames)
            }
            let frameCount = Int(decodedFrames)
            let total = frameCount * head.channels
            samples.append(contentsOf: tempBuffer.prefix(total))
        }

        let skipFrames = Int(Double(head.preSkip) * sampleRate / 48_000.0)
        if skipFrames > 0 && samples.count >= skipFrames * head.channels {
            samples.removeFirst(skipFrames * head.channels)
        }

        let duration = TimeInterval(Double(samples.count / head.channels) / sampleRate)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kasia-audio-play-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(head.channels),
                                         interleaved: false) else {
            throw OggOpusDecodeError.invalidOgg("Failed to build output format.")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count / head.channels)) else {
            throw OggOpusDecodeError.invalidOgg("Failed to allocate output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count / head.channels)
        if let channels = buffer.floatChannelData {
            for channel in 0..<head.channels {
                var writeIndex = 0
                let channelPointer = channels[channel]
                for frameIndex in stride(from: channel, to: samples.count, by: head.channels) {
                    channelPointer[writeIndex] = samples[frameIndex]
                    writeIndex += 1
                }
            }
        }

        let audioFile = try AVAudioFile(forWriting: outputURL,
                                        settings: format.settings,
                                        commonFormat: format.commonFormat,
                                        interleaved: format.isInterleaved)
        try audioFile.write(from: buffer)

        return DecodedAudio(url: outputURL, duration: duration)
    }

    private struct OpusHead {
        let channels: Int
        let preSkip: Int
        let sampleRate: Double
    }

    private static func parseOpusHead(_ data: Data) throws -> OpusHead {
        guard data.count >= 19 else {
            throw OggOpusDecodeError.invalidOpusHead
        }
        let channels = Int(data[9])
        let preSkip = Int(readUInt16LE(data, offset: 10))
        let sampleRate = Double(readUInt32LE(data, offset: 12))
        return OpusHead(channels: max(1, channels), preSkip: preSkip, sampleRate: sampleRate)
    }

    private static func extractPackets(from data: Data) throws -> [Data] {
        var packets: [Data] = []
        var current = Data()
        var offset = 0

        while offset + 27 <= data.count {
            guard data[offset..<(offset + 4)] == Data([0x4f, 0x67, 0x67, 0x53]) else {
                throw OggOpusDecodeError.invalidOgg("Missing OggS at \(offset).")
            }
            let pageSegments = Int(data[offset + 26])
            let headerSize = 27 + pageSegments
            guard offset + headerSize <= data.count else {
                throw OggOpusDecodeError.invalidOgg("Short header.")
            }
            let segmentTable = data[(offset + 27)..<(offset + 27 + pageSegments)]
            let bodySize = segmentTable.reduce(0) { $0 + Int($1) }
            let bodyStart = offset + headerSize
            guard bodyStart + bodySize <= data.count else {
                throw OggOpusDecodeError.invalidOgg("Short body.")
            }
            var cursor = bodyStart
            for seg in segmentTable {
                let length = Int(seg)
                if length > 0 {
                    current.append(data[cursor..<(cursor + length)])
                }
                cursor += length
                if seg < 255 {
                    packets.append(current)
                    current = Data()
                }
            }
            offset = bodyStart + bodySize
        }
        return packets
    }

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, offset: Int) -> UInt64 {
        UInt64(data[offset])
            | (UInt64(data[offset + 1]) << 8)
            | (UInt64(data[offset + 2]) << 16)
            | (UInt64(data[offset + 3]) << 24)
            | (UInt64(data[offset + 4]) << 32)
            | (UInt64(data[offset + 5]) << 40)
            | (UInt64(data[offset + 6]) << 48)
            | (UInt64(data[offset + 7]) << 56)
    }

    private static func normalizedSampleRate(_ value: Double) -> Double {
        switch value {
        case 8_000, 12_000, 16_000, 24_000, 48_000:
            return value
        default:
            return 48_000
        }
    }
}
#else
private enum WebMOpusDecodeError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio decoding is not supported on this platform."
    }
}

private enum OggOpusDecodeError: LocalizedError {
    case unsupportedPlatform

    var errorDescription: String? {
        "Audio decoding is not supported on this platform."
    }
}

struct WebMOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        throw WebMOpusDecodeError.unsupportedPlatform
    }
}

private struct OggOpusDecoder {
    struct DecodedAudio {
        let url: URL
        let duration: TimeInterval
    }

    static func decodeToPCMFile(data: Data) throws -> DecodedAudio {
        throw OggOpusDecodeError.unsupportedPlatform
    }

    static func getDuration(data: Data) throws -> TimeInterval {
        throw OggOpusDecodeError.unsupportedPlatform
    }
}
#endif

private struct ImagePreviewView: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZoomableImageView(image: image)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(
                        item: ShareableImage(image: image),
                        preview: SharePreview(title, image: Image(uiImage: image))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4.0
        scrollView.minimumZoomScale = 1.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }
    }
}

private struct ShareableImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            guard let data = item.image.pngData() else { throw TransferError.couldNotEncode }
            return data
        }
    }

    enum TransferError: Error {
        case couldNotEncode
    }
}

#Preview {
    VStack(spacing: 20) {
        MessageBubbleView(message: ChatMessage(
            txId: "1",
            senderAddress: "kaspa:qr123",
            receiverAddress: "kaspa:qr456",
            content: "Hello! How are you?",
            timestamp: Date(),
            blockTime: UInt64(Date().timeIntervalSince1970),
            acceptingBlock: "abc123",
            isOutgoing: false
        ))

        MessageBubbleView(message: ChatMessage(
            txId: "2",
            senderAddress: "kaspa:qr456",
            receiverAddress: "kaspa:qr123",
            content: "I'm doing great, thanks for asking! How about you?",
            timestamp: Date(),
            blockTime: UInt64(Date().timeIntervalSince1970),
            acceptingBlock: nil,
            isOutgoing: true
        ))

        MessageBubbleView(message: ChatMessage(
            txId: "3",
            senderAddress: "kaspa:qr123",
            receiverAddress: "kaspa:qr456",
            content: "Payment received",
            timestamp: Date(),
            blockTime: UInt64(Date().timeIntervalSince1970),
            isOutgoing: false,
            messageType: .payment
        ))
    }
    .padding()
}
