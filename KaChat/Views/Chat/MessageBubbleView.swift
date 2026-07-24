import SwiftUI
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(YbridOpus)
import YbridOpus
#endif

private let kaspaBubbleColor = Color(red: 112.0 / 255.0, green: 199.0 / 255.0, blue: 186.0 / 255.0)

struct MessageBubbleView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    let message: ChatMessage
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: ((ChatMessage) -> Void)?
    let onAcceptHandshake: (() -> Void)?
    let onDeclineHandshake: (() -> Void)?
    /// Parsed reply envelope, if `message.content` is a reply - matches broadcast rooms'
    /// `BroadcastMessageRow.replyQuote`.
    let replyQuote: MessageReplyContent?
    let replySenderDisplayName: String?
    let onReply: (() -> Void)?
    /// Tapping the reply quote (if any) jumps to and highlights the original message - nil
    /// when `replyQuote` is nil, since there's nothing to jump to.
    let onJumpToReply: (() -> Void)?
    /// Sender's KNS avatar (or nil for plain initials), matching broadcast rooms'
    /// `BroadcastMessageRow.avatarButton`.
    let avatarURLString: String?
    let avatarDisplayName: String
    /// Parsed chess envelope, if `message.content` is one - mirrors `replyQuote`. `chessSummary`
    /// is the current game state (nil only if `chessEnvelope` is nil), always reflecting the
    /// *latest* message for that game, not necessarily this one - see `isLatestChessMessage`.
    let chessEnvelope: ChessEnvelope?
    let chessSummary: ChessGameSummary?
    /// True only for the most recent chess message belonging to its game - that one renders as
    /// the live status card; earlier moves in the same game render as a compact log line instead.
    var isLatestChessMessage: Bool = false
    /// Non-nil only for an incoming, not-yet-responded-to invite.
    let onRespondToChessInvite: ((Bool) -> Void)?
    let onOpenChessGame: (() -> Void)?
    /// Shared horizontal offset driven by the message list's swipe-left-to-reveal-timestamp
    /// gesture (see `ChatDetailView`'s drag gesture) - 0 at rest, negative while revealed.
    var revealOffset: CGFloat = 0
    var maxRevealOffset: CGFloat = 64
    /// When true, an incoming photo from this contact stays hidden behind a "Show Photo" tap
    /// instead of auto-decoding - driven by `ContactsManager.shouldAutoDisplayPhotos(for:settings:)`.
    var photosBlocked: Bool = false
    @State private var shimmerPhase: CGFloat = -1
    @State private var showFullText = false

    init(
        message: ChatMessage,
        onCopy: ((String, ToastStyle) -> Void)? = nil,
        onRetry: ((ChatMessage) -> Void)? = nil,
        onAcceptHandshake: (() -> Void)? = nil,
        onDeclineHandshake: (() -> Void)? = nil,
        replyQuote: MessageReplyContent? = nil,
        replySenderDisplayName: String? = nil,
        onReply: (() -> Void)? = nil,
        onJumpToReply: (() -> Void)? = nil,
        avatarURLString: String? = nil,
        avatarDisplayName: String = "",
        revealOffset: CGFloat = 0,
        maxRevealOffset: CGFloat = 64,
        photosBlocked: Bool = false,
        chessEnvelope: ChessEnvelope? = nil,
        chessSummary: ChessGameSummary? = nil,
        isLatestChessMessage: Bool = false,
        onRespondToChessInvite: ((Bool) -> Void)? = nil,
        onOpenChessGame: (() -> Void)? = nil
    ) {
        self.message = message
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onAcceptHandshake = onAcceptHandshake
        self.onDeclineHandshake = onDeclineHandshake
        self.replyQuote = replyQuote
        self.replySenderDisplayName = replySenderDisplayName
        self.onReply = onReply
        self.onJumpToReply = onJumpToReply
        self.avatarURLString = avatarURLString
        self.avatarDisplayName = avatarDisplayName
        self.revealOffset = revealOffset
        self.maxRevealOffset = maxRevealOffset
        self.photosBlocked = photosBlocked
        self.chessEnvelope = chessEnvelope
        self.chessSummary = chessSummary
        self.isLatestChessMessage = isLatestChessMessage
        self.onRespondToChessInvite = onRespondToChessInvite
        self.onOpenChessGame = onOpenChessGame
    }

    /// The reply's own text, or the raw content when this isn't a reply - matches broadcast
    /// rooms' `BroadcastMessageRow.displayText`.
    private var displayText: String {
        replyQuote?.text ?? message.content
    }

    private var timeText: String {
        SharedFormatting.chatTime.string(from: message.timestamp)
    }

    /// 0 at rest, 1 once fully dragged open.
    private var revealProgress: CGFloat {
        min(max(-revealOffset / maxRevealOffset, 0), 1)
    }


    var body: some View {
        let media = mediaFile
        let isSingleEmojiOnly = isSingleEmojiOnlyMessage(displayText)

        ZStack(alignment: .trailing) {
            Text(timeText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.trailing, 12)
                .opacity(revealProgress)

            messageContent(media: media, isSingleEmojiOnly: isSingleEmojiOnly)
                .offset(x: revealOffset)
        }
    }

    private var avatarView: some View {
        KNSAvatarView(avatarURLString: avatarURLString, fallbackText: avatarDisplayName, size: 32)
    }

    @ViewBuilder
    private func messageContent(media: MediaFile?, isSingleEmojiOnly: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !message.isOutgoing {
                avatarView
            } else {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Message type indicator for special messages
                if shouldShowMessageTypeIndicator {
                    messageTypeIndicator
                }

                // Incoming handshake request with Accept/Decline actions
                if message.messageType == .handshake && !message.isOutgoing && onAcceptHandshake != nil {
                    handshakeRequestBubble
                } else if let chessEnvelope {
                    chessBubble(chessEnvelope)
                } else {
                    if let replyQuote {
                        replyQuoteView(replyQuote)
                    }

                    if let media, media.isImage {
                        // Double-tap-to-reply is handled inside LazyImageBubble itself (co-located
                        // with its single-tap-to-preview gesture so SwiftUI can disambiguate the
                        // two correctly) rather than here, unlike the audio/text cases below.
                        LazyImageBubble(
                            media: media,
                            txId: message.txId,
                            shouldShowRetry: shouldShowRetry,
                            photosBlocked: photosBlocked && !message.isOutgoing,
                            senderDisplayName: avatarDisplayName,
                            onCopy: onCopy,
                            onRetry: { onRetry?(message) },
                            onReply: onReply
                        )
                    } else if let media, media.isAudio, let data = media.fileData(cacheKey: message.txId) {
                        LazyAudioBubble(
                            data: data,
                            mimeType: media.mimeType,
                            isOutgoing: message.isOutgoing,
                            fileName: media.name,
                            txId: message.txId,
                            onCopy: onCopy,
                            onRetry: shouldShowRetry ? { onRetry?(message) } : nil,
                            onReply: onReply
                        )
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onReply?() })
                    } else {
                        messageTextBubble(isSingleEmojiOnly: isSingleEmojiOnly)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { onReply?() })
                    }
                }

                // Delivery status only - the time now shows via swipe-to-reveal, matching
                // broadcast rooms, instead of always being visible under every bubble.
                if shouldShowStatusIcon {
                    statusIcon
                }
            }
            .onAppear {
                startShimmerIfNeeded()
            }
            .onChange(of: shouldShowResolvingOverlay) { _ in
                startShimmerIfNeeded()
            }

            if message.isOutgoing {
                avatarView
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    private var shouldShowResolvingOverlay: Bool {
        message.messageType == .payment && message.deliveryStatus == .pending
    }

    private var shouldShowMessageTypeIndicator: Bool {
        message.messageType != .contextual || isKNSTransferMessage
    }

    private var isKNSTransferMessage: Bool {
        guard message.messageType == .contextual else { return false }
        // A KNS transfer status message is always a short fixed phrase ("Sent alice.kas
        // domain") - bail out on UTF-8 byte length before the `trimmingCharacters`/`lowercased`
        // normalization below, which otherwise runs unguarded on every bubble's `body`
        // evaluation, including photo messages whose `content` is their multi-KB-to-multi-MB
        // base64 JSON payload (photos are also sent as `.contextual`, so they hit this path too).
        guard message.content.utf8.count <= 256 else { return false }
        let normalized = message.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if matchesSinglePlaceholderFormat(
            normalizedContent: normalized,
            localizedTemplate: NSLocalizedString("Sent %@ domain", comment: "Outgoing KNS domain transfer message")
        ) {
            return true
        }
        if matchesSinglePlaceholderFormat(
            normalizedContent: normalized,
            localizedTemplate: NSLocalizedString("Received %@ domain", comment: "Incoming KNS domain transfer message")
        ) {
            return true
        }

        let localizedOutgoingFallback = NSLocalizedString("Sent domain transfer", comment: "Outgoing KNS domain transfer fallback")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let localizedIncomingFallback = NSLocalizedString("Received domain transfer", comment: "Incoming KNS domain transfer fallback")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized == localizedOutgoingFallback || normalized == localizedIncomingFallback {
            return true
        }

        // Backward compatibility for already-stored English messages.
        if normalized.hasPrefix("sent ") && normalized.contains(".kas domain") {
            return true
        }
        if normalized.hasPrefix("received ") && normalized.contains(".kas domain") {
            return true
        }
        if normalized == "sent domain transfer" || normalized == "received domain transfer" {
            return true
        }
        return false
    }

    private func matchesSinglePlaceholderFormat(
        normalizedContent: String,
        localizedTemplate: String
    ) -> Bool {
        let normalizedTemplate = localizedTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let placeholderRange = normalizedTemplate.range(of: "%@") else {
            return false
        }

        let prefix = String(normalizedTemplate[..<placeholderRange.lowerBound])
        let suffix = String(normalizedTemplate[placeholderRange.upperBound...])
        guard normalizedContent.hasPrefix(prefix),
              normalizedContent.hasSuffix(suffix) else {
            return false
        }

        let domainStart = normalizedContent.index(normalizedContent.startIndex, offsetBy: prefix.count)
        let domainEnd = normalizedContent.index(normalizedContent.endIndex, offsetBy: -suffix.count)
        guard domainStart <= domainEnd else { return false }
        let domainPart = normalizedContent[domainStart..<domainEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return !domainPart.isEmpty
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

    private func messageTextBubble(isSingleEmojiOnly: Bool) -> some View {
        messageTextContent(isSingleEmojiOnly: isSingleEmojiOnly)
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
                    handleCopy(displayText, toast: "Message copied to clipboard.")
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }

                if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: message.txId) {
                    Link(destination: url) {
                        Label("View in Explorer", systemImage: "safari")
                    }
                }

                if let onReply {
                    Button {
                        onReply()
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                }

                if shouldShowRetry {
                    Button {
                        onRetry?(message)
                    } label: {
                        Label("Retry Send", systemImage: "arrow.clockwise")
                    }
                }
            }
            .tint(.accentColor)
    }

    private func replyQuoteView(_ reply: MessageReplyContent) -> some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            Text(replySenderDisplayName ?? String(reply.replyToSender.suffix(10)))
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
            Text(reply.replyToPreview)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(message.isOutgoing ? .trailing : .leading)
        }
        .padding(8)
        .background(Color(UIColor.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 240, alignment: message.isOutgoing ? .trailing : .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onJumpToReply?()
        }
    }

    /// Above this, a message renders as a truncated, tap-to-expand preview instead of laying out
    /// the full text inline - matches iMessage's behavior for very long messages, and specifically
    /// guards against a huge wall of text (e.g. raw base64 that ended up as plain message content
    /// instead of being recognized as a file/image envelope) making the whole chat scroll janky,
    /// since SwiftUI's `Text`/`fixedSize` layout cost for a single giant string is what actually
    /// causes the lag, not the message itself being "long" in a normal-prose sense.
    private static let inlineTextTruncationThreshold = 2_000
    private static let truncatedPreviewLength = 500

    @ViewBuilder
    private func messageTextContent(isSingleEmojiOnly: Bool) -> some View {
        // Cheap proxy for "is this too long" - String.utf8.count is O(1) for native Swift
        // strings, unlike .count (grapheme-cluster counting), which is a full O(n) scan and
        // would itself cost real time on a huge string.
        if displayText.utf8.count > Self.inlineTextTruncationThreshold {
            truncatedMessageContent
        } else if MessageTextRenderPlan.requiresLinkTextView(displayText) {
            LinkifiedMessageTextView(
                text: displayText,
                isOutgoing: message.isOutgoing,
                isSingleEmojiOnly: isSingleEmojiOnly,
                onLinkLongPress: { url in
                    handleCopy(url.absoluteString, toast: "Link copied to clipboard.")
                }
            )
        } else {
            Text(displayText)
                .font(isSingleEmojiOnly ? .system(size: UIFont.preferredFont(forTextStyle: .body).pointSize * 5.0) : .body)
                .foregroundStyle(isSingleEmojiOnly ? Color.primary : (message.isOutgoing ? Color.white : Color.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var truncatedMessageContent: some View {
        Button {
            showFullText = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(displayText.prefix(Self.truncatedPreviewLength)) + "…")
                    .font(.body)
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Show More")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.85) : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showFullText) {
            FullMessageTextView(text: displayText) {
                handleCopy(displayText, toast: "Message copied to clipboard.")
            }
        }
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
    private func chessBubble(_ envelope: ChessEnvelope) -> some View {
        switch envelope {
        case .invite(let content):
            chessInviteBubble(content)
        case .response, .move, .resign:
            if isLatestChessMessage, let chessSummary {
                chessLiveCard(chessSummary)
            } else {
                chessLogEntry(envelope)
            }
        }
    }

    private func chessInviteBubble(_ content: ChessInviteContent) -> some View {
        let showsResponseButtons = !message.isOutgoing
            && onRespondToChessInvite != nil
            && chessSummary?.status == .pendingResponse
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("♟️")
                    .font(.title3)
                Text(message.isOutgoing ? "Chess game invite sent" : "Invited you to a game of chess")
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }

            if showsResponseButtons {
                HStack(spacing: 12) {
                    Button {
                        onRespondToChessInvite?(true)
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
                        onRespondToChessInvite?(false)
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
            } else if let chessSummary {
                Text(chessSummary.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 300)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !showsResponseButtons else { return }
            onOpenChessGame?()
        }
        .chessExplorerMenu(txId: message.txId, settingsViewModel: settingsViewModel)
    }

    private func chessLiveCard(_ summary: ChessGameSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ChessBoardThumbnail(board: summary.board)
            Text(summary.statusText)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(summary.status.isGameOver ? .secondary : .primary)
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenChessGame?()
        }
        .chessExplorerMenu(txId: message.txId, settingsViewModel: settingsViewModel)
    }

    private func chessLogEntry(_ envelope: ChessEnvelope) -> some View {
        Text(chessLogText(envelope))
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .onTapGesture {
                onOpenChessGame?()
            }
            .chessExplorerMenu(txId: message.txId, settingsViewModel: settingsViewModel)
    }

    private func chessLogText(_ envelope: ChessEnvelope) -> String {
        switch envelope {
        case .move(let content):
            let promotionSuffix = content.promotion.map { " (\($0.uppercased()))" } ?? ""
            return "♟️ \(content.from) → \(content.to)\(promotionSuffix)"
        case .resign:
            return "♟️ Resigned"
        case .response(let content):
            return content.accepted ? "♟️ Accepted the game" : "♟️ Declined the game"
        case .invite:
            return "♟️ Chess invite"
        }
    }

    @ViewBuilder
    private var messageTypeIndicator: some View {
        switch message.messageType {
        case .handshake:
            HStack(spacing: 4) {
                Image(systemName: "hand.wave.fill")
                    .font(.caption2)
                Text("Request to communicate")
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
            if isKNSTransferMessage {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption2)
                    Text("Domain")
                        .font(.caption2)
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
            } else {
                EmptyView()
            }

        case .audio:
            // `sendImage` deliberately reuses `.audio` as the message type (the JSON envelope's
            // own `mimeType` is what actually distinguishes a photo from a voice message), so this
            // badge needs to check `mediaFile` itself rather than assuming every `.audio` message
            // is a voice message.
            if mediaFile?.isImage == true {
                HStack(spacing: 4) {
                    Image(systemName: "photo.circle.fill")
                        .font(.caption2)
                    Text("Photo")
                        .font(.caption2)
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
            } else {
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
    }

    private func handleCopy(_ value: String, toast: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        onCopy?(toast, .success)
    }

    private var mediaFile: MediaFile? {
        MediaFile.from(displayText, cacheKey: message.txId)
    }

    private func isSingleEmojiOnlyMessage(_ text: String) -> Bool {
        // `.count` is a full Unicode grapheme-cluster scan (O(n)) - fine for a real single-emoji
        // message, but this runs unguarded on every bubble's `body` evaluation for every message,
        // including photo/audio ones whose `displayText` (see call site) is their multi-KB-to
        // -multi-MB base64 JSON payload. Bailing out on UTF-8 byte length first (O(1) on native
        // Swift storage, unlike `.count`) avoids paying that scan for anything that obviously
        // isn't a single character already - matches the same fix already applied to
        // `ConversationRow.formatPreview` and `MessageReplyCodec.parse` for this exact pattern.
        guard text.utf8.count <= 32 else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1 else {
            return false
        }
        return trimmed.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        }
    }
}

struct LinkifiedMessageTextView: UIViewRepresentable {
    let text: String
    let isOutgoing: Bool
    let isSingleEmojiOnly: Bool
    let onLinkLongPress: (URL) -> Void
    /// When false, tapping a link does nothing - only the long-press menu can open it. Used in
    /// broadcast rooms, where links can come from anonymous public senders, so opening one
    /// should always require a deliberate long-press rather than a single accidental tap.
    var tapOpensLink: Bool = true

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
            guard parent.tapOpensLink else { return }
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

/// Full text of a message too long to render inline (see `MessageBubbleView.inlineTextTruncationThreshold`)
/// - a plain scrollable, selectable text view, matching iMessage's "tap to see more" detail sheet.
/// Shared with `BroadcastChannelView`'s room bubble, not just private-chat messages.
struct FullMessageTextView: View {
    let text: String
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        onCopy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
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

/// Persists which photo messages the user has explicitly chosen to reveal, keyed by txId, so a
/// once-revealed photo (from a contact whose photos are otherwise hidden by default) doesn't
/// re-hide itself on the next launch. TxIds are unique chain-wide, so no per-wallet namespacing
/// is needed.
private enum PhotoRevealStore {
    private static let key = "kachat.revealedPhotoTxIds"

    static func isRevealed(_ txId: String) -> Bool {
        revealedSet.contains(txId)
    }

    static func markRevealed(_ txId: String) {
        var set = revealedSet
        guard !set.contains(txId) else { return }
        set.insert(txId)
        UserDefaults.standard.set(Array(set), forKey: key)
    }

    private static var revealedSet: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}

/// Not `private` - reused by `GroupChatDetailView` so group photo messages render identically
/// to 1:1 ones instead of duplicating this (thumbnail caching, reveal-gating, share sheet) logic.
struct LazyImageBubble: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    private static let thumbnailDisplaySize = CGSize(width: 220, height: 160)

    let media: MediaFile
    let txId: String
    let shouldShowRetry: Bool
    let photosBlocked: Bool
    let senderDisplayName: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?

    @State private var thumbnailState: (txId: String, image: UIImage)?
    @State private var previewImage: UIImage?
    @State private var sharePayload: MessageImageSharePayload?
    @State private var isLoadingPreview = false
    @State private var showImagePreview = false
    @State private var isRevealed: Bool

    init(
        media: MediaFile,
        txId: String,
        shouldShowRetry: Bool,
        photosBlocked: Bool,
        senderDisplayName: String,
        onCopy: ((String, ToastStyle) -> Void)?,
        onRetry: (() -> Void)?,
        onReply: (() -> Void)?
    ) {
        self.media = media
        self.txId = txId
        self.shouldShowRetry = shouldShowRetry
        self.photosBlocked = photosBlocked
        self.senderDisplayName = senderDisplayName
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onReply = onReply
        _isRevealed = State(initialValue: PhotoRevealStore.isRevealed(txId))
    }

    /// Still hidden behind a manual reveal - photos blocked for this contact that the user
    /// hasn't tapped "Show Photo" on yet.
    private var isHidden: Bool {
        photosBlocked && !isRevealed
    }

    private func reveal() {
        PhotoRevealStore.markRevealed(txId)
        isRevealed = true
    }

    var body: some View {
        if isHidden {
            hiddenBubble
        } else {
            unlockedBubble
        }
    }

    private var hiddenBubble: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(.secondary)
            Text("\(senderDisplayName) sent a photo")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button {
                reveal()
            } label: {
                Text("Show Photo")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: Self.thumbnailDisplaySize.width, height: Self.thumbnailDisplaySize.height)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var unlockedBubble: some View {
        // Plain tappable view rather than `Button`: a Button's tap action fires immediately on
        // the first touch-up, which always won the race against a double-tap-to-reply gesture
        // attached to an ancestor view (opening the preview before "is this a double tap?" could
        // even be decided) and aggressively claimed touches that were meant to start a
        // swipe-to-reply drag. Attaching both tap counts directly to this same view lets SwiftUI
        // properly wait to see whether a second tap follows before firing the single-tap action.
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))

            if let thumbnailState, thumbnailState.txId == txId {
                Image(uiImage: thumbnailState.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.thumbnailDisplaySize.width, height: Self.thumbnailDisplaySize.height)
            } else {
                placeholder
            }

            if isLoadingPreview {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(Circle())
            }
        }
        .frame(width: Self.thumbnailDisplaySize.width, height: Self.thumbnailDisplaySize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onReply?()
        }
        .onTapGesture(count: 1) {
            openPreview()
        }
        .contextMenu {
            Button {
                handleCopy(media.name, toast: "File name copied.")
            } label: {
                Label("Copy File Name", systemImage: "doc.on.doc")
            }

            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                Link(destination: url) {
                    Label("View in Explorer", systemImage: "safari")
                }
            }

            if let onReply {
                Button {
                    onReply()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }

            if shouldShowRetry {
                Button {
                    onRetry?()
                } label: {
                    Label("Retry Send", systemImage: "arrow.clockwise")
                }
            }
        }
        .tint(.accentColor)
        .task(id: txId) {
            guard thumbnailState?.txId != txId else { return }
            guard let loadedThumbnail = await media.thumbnailImage(cacheKey: txId),
                  !Task.isCancelled else {
                return
            }
            thumbnailState = (txId, loadedThumbnail)
        }
        .fullScreenCover(isPresented: $showImagePreview) {
            if let previewImage, let sharePayload {
                ImagePreviewView(
                    image: previewImage,
                    title: media.name,
                    sharePayload: sharePayload
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 28, weight: .regular))
            .foregroundColor(.secondary)
            .frame(width: Self.thumbnailDisplaySize.width, height: Self.thumbnailDisplaySize.height)
    }

    private func openPreview() {
        if previewImage != nil, sharePayload != nil {
            showImagePreview = true
            return
        }

        isLoadingPreview = true
        Task {
            let loaded = await media.previewImagePayload(cacheKey: txId)
            isLoadingPreview = false
            guard let loaded else { return }
            previewImage = loaded.image
            sharePayload = loaded.sharePayload
            showImagePreview = true
        }
    }

    private func handleCopy(_ value: String, toast: String) {
        UIPasteboard.general.string = value
        Haptics.success()
        onCopy?(toast, .success)
    }
}

/// Bounds how many thumbnail decodes run at once. Without this, opening a chat with many
/// photos - especially jumping straight to the bottom of a long history, as happens when a
/// lock-screen notification tap cold-launches straight into a photo-heavy chat - fired one
/// `Task.detached(priority: .userInitiated)` base64-decode-and-downsample per bubble that
/// appeared, all at once. That can saturate every core while the main thread is also trying to
/// lay out/scroll the message list and, on a cold launch, while wallet unlock/node pool init are
/// already competing for the same CPU time - reading as a multi-second freeze rather than a
/// smooth scroll-in. Capping concurrency keeps CPU headroom free for that other work; each
/// decode is still cheap individually (ImageIO's downsampled thumbnail path), so a small cap
/// doesn't meaningfully slow down how soon photos appear.
private actor ImageDecodeLimiter {
    static let shared = ImageDecodeLimiter()

    private var availablePermits = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Not `private` - reused by `GroupChatDetailView` for group photo/audio message rendering.
struct MediaFile: Codable {
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
    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
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
            Self.imageCache.setObject(image, forKey: key, cost: Self.cacheCost(for: image))
        }
        return image
    }

    func imageSharePayload(cacheKey: String?) -> MessageImageSharePayload? {
        guard isImage, let data = fileData(cacheKey: cacheKey) else { return nil }
        return MessageImageSharePayload(data: data, fileName: name, mimeType: mimeType)
    }

    func thumbnailImage(cacheKey: String?, maxPixelSize: CGFloat = 440) async -> UIImage? {
        guard isImage else { return nil }
        if let key = Self.thumbnailCacheKey(from: cacheKey, maxPixelSize: maxPixelSize),
           let cached = Self.thumbnailCache.object(forKey: key) {
            return cached
        }

        await ImageDecodeLimiter.shared.wait()
        defer { Task { await ImageDecodeLimiter.shared.signal() } }

        return await Task.detached(priority: .userInitiated) {
            guard let data = fileData(cacheKey: cacheKey),
                  let image = Self.downsampledImage(data: data, maxPixelSize: maxPixelSize) ?? UIImage(data: data) else {
                return nil
            }

            if let key = Self.thumbnailCacheKey(from: cacheKey, maxPixelSize: maxPixelSize) {
                Self.thumbnailCache.setObject(image, forKey: key, cost: Self.cacheCost(for: image))
            }
            return image
        }.value
    }

    func previewImagePayload(cacheKey: String?) async -> (image: UIImage, sharePayload: MessageImageSharePayload)? {
        guard isImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = fileData(cacheKey: cacheKey),
                  let image = image(cacheKey: cacheKey) else {
                return nil
            }
            return (
                image,
                MessageImageSharePayload(data: data, fileName: name, mimeType: mimeType)
            )
        }.value
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

    private static func thumbnailCacheKey(from value: String?, maxPixelSize: CGFloat) -> NSString? {
        guard let base = cacheKey(from: value) else { return nil }
        return "\(base)|thumb|\(Int(maxPixelSize.rounded()))" as NSString
    }

    private static func dataFromDataURL(_ text: String) -> Data? {
        guard let prefixRange = text.range(of: "base64,") else { return nil }
        let base64 = text[prefixRange.upperBound...]
        return Data(base64Encoded: String(base64))
    }

    private static func downsampledImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func cacheCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let width = max(1, Int((image.size.width * image.scale).rounded(.up)))
        let height = max(1, Int((image.size.height * image.scale).rounded(.up)))
        return width * height * 4
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
/// Not `private` - reused by `GroupChatDetailView` for group audio message rendering.
struct LazyAudioBubble: View {
    let data: Data
    let mimeType: String
    let isOutgoing: Bool
    let fileName: String
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
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
            onRetry: onRetry,
            onReply: onReply
        )
    }
}

private struct AudioBubble: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @ObservedObject var helper: AudioPlaybackHelper
    let data: Data
    let mimeType: String
    let isOutgoing: Bool
    let fileName: String
    let txId: String
    let onCopy: ((String, ToastStyle) -> Void)?
    let onRetry: (() -> Void)?
    let onReply: (() -> Void)?
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

            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                Link(destination: url) {
                    Label("View in Explorer", systemImage: "safari")
                }
            }

            if let onReply {
                Button {
                    onReply()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }

            if let onRetry {
                Button {
                    onRetry()
                } label: {
                    Label("Retry Send", systemImage: "arrow.clockwise")
                }
            }
        }
        .tint(.accentColor)
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

#if canImport(YbridOpus) || OPUS_BRIDGE || OPUS_CATALYST
private enum WebMOpusDecodeError: LocalizedError {
    case invalidWebM(String)
    case missingOpusHead
    case invalidOpusHead
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
            0x1F43B675, // Cluster
            0xA0        // BlockGroup - real WebM muxers (e.g. Android's AOSP MediaRecorder/
                        // MediaMuxer) commonly wrap an Opus frame in BlockGroup > Block rather
                        // than a bare SimpleBlock, unlike this app's own hand-rolled encoder.
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
                } else if id == 0xA3 || id == 0xA1 {
                    // SimpleBlock (0xA3) or Block (0xA1, inside a BlockGroup) - both share the
                    // same track-number/timecode/flags header layout for our purposes.
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
        // Track number isn't validated against a fixed value (e.g. this app's own encoder
        // always uses track 1) - these files only ever contain a single audio track, and other
        // real-world muxers (Android's AOSP MediaRecorder among them) aren't guaranteed to number
        // it the same way, so any track number here is accepted.
        let (_, trackLen) = try readVIntValue(data, offset: offset)
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
            // Skip rather than abort the whole file - one oddly-laced block shouldn't lose every
            // other valid packet already parsed.
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
    let sharePayload: MessageImageSharePayload
    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false
    @State private var dragOffset: CGFloat = 0

    /// Past this translation (or a fast-enough flick, see `onEnded`), the swipe commits to
    /// dismissing instead of springing back.
    private let dismissThreshold: CGFloat = 120

    var body: some View {
        NavigationStack {
            ZoomableImageView(image: image, isZoomed: $isZoomed)
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
                        item: ShareableImage(payload: sharePayload),
                        preview: SharePreview(title, image: Image(uiImage: image))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .offset(y: dragOffset)
        .opacity(1 - min(abs(dragOffset) / 500, 0.4))
        // `simultaneousGesture` rather than `gesture` so this never steals the scroll view's own
        // pinch-zoom/pan recognizers; the `!isZoomed` guards below additionally make sure a swipe
        // only dismisses when the image is at its default scale, matching how Photos/Messages
        // handle swipe-to-dismiss on a zoomable image.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard !isZoomed, abs(value.translation.height) > abs(value.translation.width) else { return }
                    dragOffset = value.translation.height
                }
                .onEnded { value in
                    guard !isZoomed else { return }
                    if abs(dragOffset) > dismissThreshold || abs(value.predictedEndTranslation.height) > dismissThreshold * 2 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool

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
        Coordinator(isZoomed: $isZoomed)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        @Binding var isZoomed: Bool

        init(isZoomed: Binding<Bool>) {
            _isZoomed = isZoomed
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if isZoomed != zoomed {
                isZoomed = zoomed
            }
        }
    }
}

private struct ShareableImage: Transferable {
    let payload: MessageImageSharePayload

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(try item.payload.writeTemporaryFile())
        }
    }
}

/// Small, non-interactive board render for the in-chat live game card. The full-screen
/// `ChessGameView` has its own interactive board renderer (tap-to-select, highlights) rather than
/// reusing this - different enough concerns (static thumbnail vs. tappable squares) that sharing
/// the layout code wasn't worth the added complexity.
private extension View {
    /// Long-press "View in Explorer" for any chess bubble (invite/live card/log entry) - mirrors
    /// `messageTextBubble`'s own `.contextMenu`, scoped down to just the one action since a
    /// chess envelope's own JSON isn't meaningful to offer as "Copy Message".
    func chessExplorerMenu(txId: String, settingsViewModel: SettingsViewModel) -> some View {
        contextMenu {
            if let url = settingsViewModel.settings.kaspaExplorer.txURL(for: txId) {
                Link(destination: url) {
                    Label("View in Explorer", systemImage: "safari")
                }
            }
        }
    }
}

struct ChessBoardThumbnail: View {
    let board: ChessBoard
    var size: CGFloat = 160

    /// Classic wood-tone board colors (matches chess.com/lichess's default theme) - shared with
    /// the full-screen board in ChessGameView.
    static let lightSquareColor = Color(red: 0.937, green: 0.851, blue: 0.706) // #EFD9B4
    static let darkSquareColor = Color(red: 0.710, green: 0.533, blue: 0.388)  // #B58863

    var body: some View {
        let squareSize = size / 8
        VStack(spacing: 0) {
            ForEach((0..<8).reversed(), id: \.self) { rank in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { file in
                        let isLight = !(file + rank).isMultiple(of: 2)
                        ZStack {
                            Rectangle().fill(isLight ? Self.lightSquareColor : Self.darkSquareColor)
                            if let piece = board.piece(at: ChessSquare(file: file, rank: rank)) {
                                ChessPieceGlyphView(piece: piece, fontSize: squareSize * 0.72)
                            }
                        }
                        .frame(width: squareSize, height: squareSize)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Renders a single chess piece glyph with an explicit white/black fill plus a crisp
/// contrasting outline (four offset copies of the glyph drawn behind the fill, a standard
/// lightweight text-stroke trick), rather than relying on the bare Unicode glyph's
/// outline-vs-filled shape alone to distinguish sides - at typical board sizes that distinction
/// was too subtle to read at a glance, especially on a same-toned square.
struct ChessPieceGlyphView: View {
    let piece: ChessPiece
    var fontSize: CGFloat

    private var fillColor: Color { piece.color == .white ? Color(white: 0.99) : Color(white: 0.07) }
    private var outlineColor: Color { piece.color == .white ? Color(white: 0.07) : Color(white: 0.99) }

    private static let outlineOffsets: [CGSize] = {
        let d: CGFloat = 0.9
        return [CGSize(width: d, height: 0), CGSize(width: -d, height: 0), CGSize(width: 0, height: d), CGSize(width: 0, height: -d)]
    }()

    private var glyphText: some View {
        Text(piece.glyph)
            .font(.system(size: fontSize))
            .minimumScaleFactor(0.5)
    }

    var body: some View {
        ZStack {
            ForEach(0..<Self.outlineOffsets.count, id: \.self) { index in
                glyphText
                    .foregroundColor(outlineColor)
                    .offset(Self.outlineOffsets[index])
            }
            glyphText
                .foregroundColor(fillColor)
        }
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
