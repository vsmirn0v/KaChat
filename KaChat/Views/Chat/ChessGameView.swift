import SwiftUI

/// Full-screen interactive chess board, opened by tapping a chess card in a 1:1 chat
/// (`MessageBubbleView.chessBubble`). Board state is entirely derived from the conversation's
/// messages (see `ChessGameService.summarize`) - re-derived fresh from `chatService.conversations`
/// on every render, so a new move arriving while this view is open updates it automatically, the
/// same way any other message-driven view in this app stays live.
struct ChessGameView: View {
    let gameId: String
    let contact: Contact

    @EnvironmentObject var chatService: ChatService
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSquare: ChessSquare?
    @State private var pendingPromotionMove: ChessMove?
    @State private var showResignConfirm = false
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var isComposerFocused: Bool

    // `summary`/`chatMessages` used to be computed properties re-derived from `messages` on every
    // access - fine for the board alone (state changes were infrequent, one per square tap), but
    // once a text composer was added, typing put `chatDraft` on this same view's `@State`, and
    // *every keystroke* re-evaluated `body`, which re-ran `ChessGameService.summarize` (a full
    // game replay) and a JSON-sniffing filter+sort over the whole conversation - on every
    // character. Caching them here, refreshed only via `.task(id: messagesDigest)` (which only
    // re-fires when the underlying messages actually change), fixes that regardless of what else
    // on this view re-renders.
    @State private var summary: ChessGameSummary?
    @State private var chatMessages: [ChatMessage] = []

    private var myAddress: String? {
        walletManager.currentWallet?.publicAddress
    }

    /// Deduped the same way `ChatDetailView.rebuildMessageSnapshotIfNeeded` dedupes the main chat -
    /// the underlying store can legitimately hold more than one `ChatMessage` for what's really a
    /// single logical message (a local pending/placeholder entry plus the confirmed on-chain
    /// version, or "Sent via another device" placeholders resolving to real content later).
    /// `ChatDetailView` already handles this for the main thread; this view was reading the raw,
    /// undeduped list directly, which showed as duplicate rows in the mini chat history -
    /// especially noticeable for voice messages, which always go through that pending->confirmed
    /// transition.
    private var messages: [ChatMessage] {
        let source = chatService.conversations.first(where: { $0.contact.address == contact.address })?.messages ?? []
        let sorted = source.sorted(by: isMessageOrderedBefore)
        var byId: [UUID: ChatMessage] = [:]
        for message in sorted {
            if let existing = byId[message.id] {
                if shouldPrefer(message, over: existing) {
                    byId[message.id] = message
                }
            } else {
                byId[message.id] = message
            }
        }
        var byTxId: [String: ChatMessage] = [:]
        for message in byId.values {
            let key = message.txId.isEmpty ? message.id.uuidString : message.txId
            if let existing = byTxId[key] {
                if shouldPrefer(message, over: existing) {
                    byTxId[key] = message
                }
            } else {
                byTxId[key] = message
            }
        }
        return byTxId.values.sorted(by: isMessageOrderedBefore)
    }

    private func isMessageOrderedBefore(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.blockTime != rhs.blockTime { return lhs.blockTime < rhs.blockTime }
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.id != rhs.id { return lhs.id.uuidString < rhs.id.uuidString }
        return lhs.txId < rhs.txId
    }

    private func shouldPrefer(_ candidate: ChatMessage, over existing: ChatMessage) -> Bool {
        let existingPlaceholder = isPlaceholderContent(existing.content)
        let candidatePlaceholder = isPlaceholderContent(candidate.content)
        if existingPlaceholder != candidatePlaceholder {
            return !candidatePlaceholder
        }
        if existing.deliveryStatus != candidate.deliveryStatus,
           candidate.deliveryStatus.priority != existing.deliveryStatus.priority {
            return candidate.deliveryStatus.priority > existing.deliveryStatus.priority
        }
        return isMessageOrderedBefore(existing, candidate)
    }

    private func isPlaceholderContent(_ content: String) -> Bool {
        content == "📤 Sent via another device" || content == "[Encrypted message]"
    }

    /// Cheap-relative-to-a-full-replay digest driving `.task(id:)` below - still O(N), but just a
    /// hash combine per message rather than a full chess-engine replay or a JSON parse attempt
    /// per message, and (post composer-extraction) it's no longer evaluated on every keystroke.
    private var messagesDigest: Int {
        var hasher = Hasher()
        hasher.combine(messages.count)
        for message in messages {
            hasher.combine(message.id)
            hasher.combine(message.txId)
            hasher.combine(message.deliveryStatus)
        }
        return hasher.finalize()
    }

    private func refreshCache() {
        guard let myAddress else {
            summary = nil
            chatMessages = []
            return
        }
        summary = ChessGameService.summarize(gameId: gameId, in: messages, myAddress: myAddress, contactAddress: contact.address)
        let nonChessMessages: [ChatMessage] = messages.filter { message in
            ChessCodec.parseAny(MessageReplyCodec.unwrappedText(message.content)) == nil
        }
        chatMessages = nonChessMessages.sorted { $0.timestamp < $1.timestamp }
    }

    private var myColor: ChessColor? {
        guard let myAddress, let summary else { return nil }
        return summary.color(for: myAddress)
    }

    private var isMyTurn: Bool {
        guard let summary, let myColor, summary.status == .inProgress else { return false }
        return summary.board.sideToMove == myColor
    }

    /// Cumulative wins/losses against this contact, across every chess game ever played with
    /// them (not just the current one) - see `ChessGameService.record`.
    private var winLossRecord: (wins: Int, losses: Int) {
        guard let myAddress else { return (0, 0) }
        return ChessGameService.record(in: messages, myAddress: myAddress, contactAddress: contact.address)
    }

    /// The `ChatMessage` behind the most recent action in this game, whichever it was (invite/
    /// move/response/resign) - `ChessGameSummary.lastMessageTxId` already identifies it by txId.
    private var lastActionMessage: ChatMessage? {
        guard let summary else { return nil }
        return messages.first { $0.txId == summary.lastMessageTxId }
    }

    /// Drives the "Sent"/"Retry" indicator under the turn status - only shown right after *I*
    /// made the most recent move (not after an invite/response/resign, and not when the most
    /// recent action was the opponent's move, which has no local delivery status to report).
    private var lastMoveSendStatus: ChatMessage.DeliveryStatus? {
        guard let lastActionMessage, lastActionMessage.isOutgoing,
              case .move = ChessCodec.parseAny(MessageReplyCodec.unwrappedText(lastActionMessage.content)) else {
            return nil
        }
        return lastActionMessage.deliveryStatus
    }

    private var legalDestinations: [ChessSquare] {
        guard let selectedSquare, let summary else { return [] }
        return ChessEngine.legalMoves(from: selectedSquare, board: summary.board).map { $0.to }
    }

    private static let coordinateLabelSize: CGFloat = 18
    private static let chatHistoryMinHeight: CGFloat = 96

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                header
                if let summary {
                    capturedPiecesBar(summary)
                        .padding(.horizontal)
                    boardView(summary)
                        .padding(.horizontal)
                        // Wins the fight for vertical space against the chat history below it -
                        // the board should stay as large as the screen allows, with the history
                        // section (pinned to its `minHeight`) taking only what's left over.
                        .layoutPriority(1)
                    Divider()
                    chatHistorySection
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .padding(.top, 8)
            // Re-asserts (never clears) the active-conversation flag `ChatDetailView` already set
            // when it opened - both on appear and on disappear, since dismissing this full-screen
            // cover returns to that still-open chat, not away from the conversation. Without this,
            // a move arriving while this board is on screen could still trigger a notification for
            // a game the user is already watching live, the same redundant-notification bug fixed
            // for Android's separate chess nav destination.
            .onAppear {
                chatService.enterConversation(for: contact.address)
            }
            .onDisappear {
                chatService.enterConversation(for: contact.address)
            }
            .task(id: messagesDigest) {
                refreshCache()
            }
            // Tapping anywhere outside the text field (board, header, captured-pieces bar) drops
            // focus - doesn't interfere with square-selection taps, which fire independently; it
            // just also clears the keyboard when one happens to be up.
            .onTapGesture {
                isComposerFocused = false
            }
            .navigationTitle("Chess")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let summary, summary.status == .inProgress {
                        Button("Resign", role: .destructive) {
                            showResignConfirm = true
                        }
                    }
                }
            }
            // Plain text under the toolbar's Resign button, not sharing its glass-pill background -
            // a shared VStack inside the ToolbarItem made the system draw one combined pill behind
            // both the button and the counter, which looked broken. An overlay on the content below
            // the nav bar keeps the counter visually "under Resign" without borrowing its chrome.
            .overlay(alignment: .topTrailing) {
                winLossCounter
                    .padding(.top, 4)
                    .padding(.trailing, 16)
            }
            // Real `safeAreaInset` (matching ChatDetailView's identical composer pattern) rather
            // than a floating overlay - guarantees the composer sits flush above the keyboard
            // without any manually-tracked keyboard-height math.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if summary != nil {
                    ChessChatComposer(contact: contact, error: $error, isFocused: $isComposerFocused)
                }
            }
            .confirmationDialog("Resign this game?", isPresented: $showResignConfirm, titleVisibility: .visible) {
                Button("Resign", role: .destructive) { resign() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $pendingPromotionMove) { move in
                promotionPicker(move)
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var chatHistorySection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(chatMessages, id: \.id) { message in
                        compactMessageRow(message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(minHeight: Self.chatHistoryMinHeight)
            .onAppear {
                if let last = chatMessages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: chatMessages.count) { _ in
                guard let last = chatMessages.last else { return }
                withAnimation {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func canRetry(_ message: ChatMessage) -> Bool {
        guard message.isOutgoing, message.deliveryStatus == .failed else { return false }
        return message.messageType != .payment
    }

    private func compactMessageRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 4) {
            if message.isOutgoing { Spacer(minLength: 40) }
            if message.isOutgoing {
                if canRetry(message) {
                    // Tappable "Retry" next to the red error icon (the bubble's long-press retry
                    // stays too), matching the full-screen move-status row's Retry affordance.
                    HStack(spacing: 4) {
                        statusIcon(for: message)
                        Text("Retry")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.impact(.medium)
                        retryMessage(message)
                    }
                } else {
                    statusIcon(for: message)
                }
            }
            Text(compactPreviewText(for: message))
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(message.isOutgoing ? Color.accentColor : Color(.systemGray5))
                .foregroundColor(message.isOutgoing ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .onLongPressGesture {
                    guard canRetry(message) else { return }
                    Haptics.impact(.medium)
                    retryMessage(message)
                }
            if !message.isOutgoing { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func statusIcon(for message: ChatMessage) -> some View {
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

    private func retryMessage(_ message: ChatMessage) {
        Task {
            do {
                try await chatService.retryOutgoingMessage(message, contact: contact)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Condensed, text-only rendering for the mini history - unlike `MessageBubbleView`, non-text
    /// content (photos/voice/payments) collapses to a short label rather than fully rendering, to
    /// keep this secondary surface lightweight.
    private func compactPreviewText(for message: ChatMessage) -> String {
        switch message.messageType {
        case .payment: return "💰 Payment"
        case .handshake: return "👋 Handshake"
        case .audio: return "🎤 Voice message"
        case .contextual: break
        }
        let unwrapped = MessageReplyCodec.unwrappedText(message.content)
        let trimmed = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = unwrapped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let mimeType = json["mimeType"] as? String else {
            return unwrapped
        }
        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") { return "📷 Photo" }
        if mime.hasPrefix("video/") { return "🎬 Video" }
        return "📎 File"
    }


    /// "W" / "L" small labels over a "0 - 0"-style tally - toolbar-trailing, under the Resign
    /// button, always visible (not just mid-game) so the running record stays in view.
    private var winLossCounter: some View {
        let record = winLossRecord
        return HStack(alignment: .bottom, spacing: 4) {
            VStack(spacing: 1) {
                Text("W")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(record.wins)")
                    .font(.caption)
                    .fontWeight(.bold)
            }
            Text("-")
                .font(.caption)
                .foregroundColor(.secondary)
            VStack(spacing: 1) {
                Text("L")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(record.losses)")
                    .font(.caption)
                    .fontWeight(.bold)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(contact.alias.isEmpty ? contact.address : contact.alias)
                .font(.headline)
            if let summary {
                Text(summary.statusText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(summary.status.isGameOver ? .secondary : .accentColor)
            }
            if let lastMoveSendStatus {
                moveSendStatusRow(lastMoveSendStatus)
            }
        }
    }

    /// "Sent"/"Retry" indicator directly under the turn status, so the player has confirmation
    /// their move actually went through while in full-screen game mode (they can't see the normal
    /// chat transcript's own delivery-status ticks from here). Mirrors `statusIcon(for:)`'s
    /// existing sent/pending/failed icon language rather than inventing new iconography.
    @ViewBuilder
    private func moveSendStatusRow(_ status: ChatMessage.DeliveryStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .sent:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Sent")
            case .failed, .warning:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                Text("Retry")
                    .foregroundColor(.red)
                    .fontWeight(.semibold)
            case .pending:
                ProgressView()
                    .scaleEffect(0.7)
                Text("Sending…")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            guard status == .failed || status == .warning, let lastActionMessage else { return }
            retryMessage(lastActionMessage)
        }
    }

    private func boardView(_ summary: ChessGameSummary) -> some View {
        // Boards render from the local player's own perspective (their pieces at the bottom) -
        // defaults to white's orientation if this device somehow isn't a participant.
        let orientation = myColor ?? .white
        let ranks = orientation == .white ? Array((0..<8).reversed()) : Array(0..<8)
        let files = orientation == .white ? Array(0..<8) : Array((0..<8).reversed())

        return ZStack {
            GeometryReader { geo in
                let available = min(geo.size.width, geo.size.height) - Self.coordinateLabelSize * 2
                let boardSize = max(available, 0)
                let squareSize = boardSize / 8
                VStack(spacing: 0) {
                    fileLabelsRow(files, squareSize: squareSize)
                    HStack(spacing: 0) {
                        rankLabelsColumn(ranks, squareSize: squareSize)
                        VStack(spacing: 0) {
                            ForEach(ranks, id: \.self) { rank in
                                HStack(spacing: 0) {
                                    ForEach(files, id: \.self) { file in
                                        squareView(file: file, rank: rank, summary: summary, squareSize: squareSize)
                                    }
                                }
                            }
                        }
                        .frame(width: boardSize, height: boardSize)
                        rankLabelsColumn(ranks, squareSize: squareSize)
                    }
                    fileLabelsRow(files, squareSize: squareSize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isMyTurn && summary.status == .inProgress {
                WaitingOnOpponentOverlay()
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// File letters (a-h) shown above and below the board, in the current orientation's order.
    private func fileLabelsRow(_ files: [Int], squareSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.coordinateLabelSize)
            ForEach(files, id: \.self) { file in
                Text(String(UnicodeScalar(97 + file)!))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: squareSize)
            }
            Color.clear.frame(width: Self.coordinateLabelSize)
        }
        .frame(height: Self.coordinateLabelSize)
    }

    /// Rank numbers (1-8) shown to the left and right of the board, in the current orientation's order.
    private func rankLabelsColumn(_ ranks: [Int], squareSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(ranks, id: \.self) { rank in
                Text("\(rank + 1)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(height: squareSize)
            }
        }
        .frame(width: Self.coordinateLabelSize)
    }

    /// Captured-pieces tray: pieces the opponent has taken from me on the leading edge, pieces
    /// I've taken from them on the trailing edge - mirrors how online chess UIs show each side's
    /// haul next to their own info.
    private func capturedPiecesBar(_ summary: ChessGameSummary) -> some View {
        let color = myColor ?? .white
        let takenFromMe = color == .white ? summary.capturedByBlack : summary.capturedByWhite
        let takenByMe = color == .white ? summary.capturedByWhite : summary.capturedByBlack
        return HStack(alignment: .top) {
            capturedGroup(pieces: takenFromMe, pieceColor: color, label: "They captured")
            Spacer()
            capturedGroup(pieces: takenByMe, pieceColor: color.opposite, label: "You captured")
        }
    }

    private func capturedGroup(pieces: [ChessPieceType], pieceColor: ChessColor, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(spacing: 2) {
                if pieces.isEmpty {
                    Text("\u{2013}")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, type in
                        ChessPieceGlyphView(piece: ChessPiece(type: type, color: pieceColor), fontSize: 16)
                    }
                }
            }
        }
    }

    private func squareView(file: Int, rank: Int, summary: ChessGameSummary, squareSize: CGFloat) -> some View {
        let square = ChessSquare(file: file, rank: rank)
        let isLight = !(file + rank).isMultiple(of: 2)
        let isSelected = selectedSquare == square
        let isLegalDestination = legalDestinations.contains(square)
        let lastMove = summary.moveHistory.last
        let isLastMoveSquare = lastMove.map { $0.from == square || $0.to == square } ?? false

        return ZStack {
            Rectangle().fill(isLight ? ChessBoardThumbnail.lightSquareColor : ChessBoardThumbnail.darkSquareColor)
            if isLastMoveSquare {
                Rectangle().fill(Color.yellow.opacity(0.35))
            }
            if isSelected {
                Rectangle().fill(Color.accentColor.opacity(0.35))
            }
            if let piece = summary.board.piece(at: square) {
                ChessPieceGlyphView(piece: piece, fontSize: squareSize * 0.7)
            }
            if isLegalDestination {
                Circle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: squareSize * 0.3, height: squareSize * 0.3)
            }
        }
        .frame(width: squareSize, height: squareSize)
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap(square: square, summary: summary)
        }
    }

    private func handleTap(square: ChessSquare, summary: ChessGameSummary) {
        guard isMyTurn, !isSending else { return }

        if let selectedSquare {
            if legalDestinations.contains(square) {
                let candidate = ChessMove(from: selectedSquare, to: square, promotion: nil)
                let movingPiece = summary.board.piece(at: selectedSquare)
                let backRank = movingPiece?.color == .white ? 7 : 0
                self.selectedSquare = nil
                if movingPiece?.type == .pawn, square.rank == backRank {
                    pendingPromotionMove = candidate
                } else {
                    send(candidate)
                }
                return
            }
            if let piece = summary.board.piece(at: square), piece.color == myColor {
                self.selectedSquare = square
            } else {
                self.selectedSquare = nil
            }
        } else if let piece = summary.board.piece(at: square), piece.color == myColor {
            self.selectedSquare = square
        }
    }

    private func promotionPicker(_ move: ChessMove) -> some View {
        VStack(spacing: 20) {
            Text("Promote pawn to:")
                .font(.headline)
            HStack(spacing: 24) {
                ForEach([ChessPieceType.queen, .rook, .bishop, .knight], id: \.self) { type in
                    Button {
                        pendingPromotionMove = nil
                        send(ChessMove(from: move.from, to: move.to, promotion: type))
                    } label: {
                        ChessPieceGlyphView(piece: ChessPiece(type: type, color: myColor ?? .white), fontSize: 40)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(30)
        .presentationDetents([.height(180)])
    }

    private func send(_ move: ChessMove) {
        isSending = true
        Task {
            do {
                try await ChessGameService.sendMove(move, gameId: gameId, to: contact)
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }

    private func resign() {
        Task {
            try? await ChessGameService.resign(gameId: gameId, to: contact)
            dismiss()
        }
    }
}

/// Extracted into its own `View` (rather than a computed property on `ChessGameView`, as it
/// started as) so its own `@State` - the text draft in particular - is its own independent
/// SwiftUI diffing/dependency unit. A computed property/function isn't: it's inlined directly
/// into whatever view calls it, so a `@State` change anywhere in that owning view (here, every
/// keystroke) forces the *whole* owning view's `body` to re-evaluate, not just the part that
/// actually depends on it - which was silently re-running a full chess-game replay and a
/// conversation-wide filter/sort on every character typed. Deliberately text + voice-note only -
/// no "+" menu, no photos/payments/another chess invite. This is a quick-chat surface for while a
/// game's in progress, not a full composer.
/// Text-only, deliberately - no mic, no "+" menu, no photos/payments/another chess invite. This
/// is a quick-chat surface for while a game's in progress, not a full composer.
private struct ChessChatComposer: View {
    let contact: Contact
    @Binding var error: String?
    var isFocused: FocusState<Bool>.Binding

    @EnvironmentObject private var chatService: ChatService
    @State private var draft = ""
    @State private var isSending = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .focused(isFocused)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            Button {
                sendChatMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func sendChatMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        isSending = true
        Task {
            do {
                try await chatService.sendMessage(to: contact, content: text)
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }
}

/// Overlay shown on the board while waiting for the opponent's move - the "..." cycles 1/2/3 dots
/// like a typing indicator rather than sitting static, so it reads as "still waiting" rather than
/// looking frozen/stuck. Self-contained `.task` loop starts/stops automatically as SwiftUI mounts/
/// unmounts this view (see `boardView`'s conditional inclusion), so nothing leaks a timer while
/// it isn't actually the opponent's turn.
private struct WaitingOnOpponentOverlay: View {
    @State private var dotCount = 1

    var body: some View {
        Text("Waiting on opponent" + String(repeating: ".", count: dotCount))
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    dotCount = dotCount % 3 + 1
                }
            }
    }
}
