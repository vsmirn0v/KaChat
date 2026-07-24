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

    private var myAddress: String? {
        walletManager.currentWallet?.publicAddress
    }

    private var messages: [ChatMessage] {
        chatService.conversations.first(where: { $0.contact.address == contact.address })?.messages ?? []
    }

    private var summary: ChessGameSummary? {
        guard let myAddress else { return nil }
        return ChessGameService.summarize(gameId: gameId, in: messages, myAddress: myAddress, contactAddress: contact.address)
    }

    private var myColor: ChessColor? {
        guard let myAddress, let summary else { return nil }
        return summary.color(for: myAddress)
    }

    private var isMyTurn: Bool {
        guard let summary, let myColor, summary.status == .inProgress else { return false }
        return summary.board.sideToMove == myColor
    }

    private var legalDestinations: [ChessSquare] {
        guard let selectedSquare, let summary else { return [] }
        return ChessEngine.legalMoves(from: selectedSquare, board: summary.board).map { $0.to }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                header
                if let summary {
                    boardView(summary)
                        .padding(.horizontal)
                } else {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
            .padding(.top, 12)
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
        }
    }

    private func boardView(_ summary: ChessGameSummary) -> some View {
        // Boards render from the local player's own perspective (their pieces at the bottom) -
        // defaults to white's orientation if this device somehow isn't a participant.
        let orientation = myColor ?? .white
        let ranks = orientation == .white ? Array((0..<8).reversed()) : Array(0..<8)
        let files = orientation == .white ? Array(0..<8) : Array((0..<8).reversed())

        return GeometryReader { geo in
            let boardSize = min(geo.size.width, geo.size.height)
            let squareSize = boardSize / 8
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func squareView(file: Int, rank: Int, summary: ChessGameSummary, squareSize: CGFloat) -> some View {
        let square = ChessSquare(file: file, rank: rank)
        let isLight = !(file + rank).isMultiple(of: 2)
        let isSelected = selectedSquare == square
        let isLegalDestination = legalDestinations.contains(square)

        return ZStack {
            Rectangle().fill(isLight ? ChessBoardThumbnail.lightSquareColor : ChessBoardThumbnail.darkSquareColor)
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
