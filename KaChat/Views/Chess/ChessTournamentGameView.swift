import SwiftUI

/// One tournament game: the board with both clocks, the controls, and the game's chat beneath
/// it - laid out like a 1:1 chat with the board where the messages would be. Players tap to
/// move; everyone else watches the same board live.
struct ChessTournamentGameView: View {
    let tournamentId: String
    let gameId: String
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var selectedSquare: ChessSquare?
    @State private var pendingPromotion: ChessMove?
    @State private var showResignConfirm = false
    @State private var chatText = ""
    @State private var reportedEnd = false

    private var tournament: ChessTournament? { service.tournaments[tournamentId] }
    private var game: ChessTournamentGame? { tournament?.games[gameId] }
    private var me: String? { walletManager.currentWallet?.publicAddress }
    private var myColor: ChessColor? { me.flatMap { game?.color(of: $0) } }
    private var isMyTurn: Bool {
        guard let game, let myColor, !game.isOver else { return false }
        return game.sideToMove == myColor && !service.pendingMoveGames.contains("\(tournamentId)|\(gameId)")
    }
    /// The board is drawn from the viewer's side: black players see black at the bottom.
    private var flipped: Bool { myColor == .black }

    var body: some View {
        Group {
            if let tournament, let game {
                content(tournament, game)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(game.map { roundLabel($0) } ?? "Game")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { BalanceToolbarLabel() } }
        .onAppear { service.acquire() }
        .onDisappear { service.release() }
    }

    private func roundLabel(_ game: ChessTournamentGame) -> String {
        game.round == 3 ? "Final" : (game.round == 2 ? "Semifinal" : "Round 1")
    }

    private func name(for address: String) -> String {
        if address == me { return "You" }
        return ContactsManager.shared.displayName(for: address)
    }

    @ViewBuilder
    private func content(_ tournament: ChessTournament, _ game: ChessTournamentGame) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    clockRow(game, color: flipped ? .white : .black)
                    board(game)
                        .padding(.horizontal, 12)
                    clockRow(game, color: flipped ? .black : .white)
                    statusLine(game)
                    if myColor != nil, !game.isOver {
                        Button(role: .destructive) { showResignConfirm = true } label: {
                            Label("Resign", systemImage: "flag.fill").font(.subheadline.weight(.semibold))
                        }
                        .padding(.top, 2)
                    }
                    Divider().padding(.vertical, 6)
                    chatSection(tournament, game)
                }
                .padding(.vertical, 12)
            }
            composer(tournament, game)
        }
        .confirmationDialog("Resign this game?", isPresented: $showResignConfirm, titleVisibility: .visible) {
            Button("Resign", role: .destructive) { Task { await service.resign(tournament, game: game) } }
            Button("Keep playing", role: .cancel) {}
        }
        .sheet(item: $pendingPromotion) { move in
            promotionSheet(move, tournament: tournament, game: game)
        }
        .toast(message: service.lastError, style: .error)
    }

    // MARK: - Clocks and status

    private func clockRow(_ game: ChessTournamentGame, color: ChessColor) -> some View {
        let address = game.address(of: color)
        let remaining = game.remainingMs(color, at: service.now)
        let running = !game.isOver && game.sideToMove == color
        return HStack(spacing: 12) {
            KNSAvatarView(
                avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                fallbackText: ContactsManager.shared.displayName(for: address),
                size: 36,
                contactAddress: address
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(name(for: address)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(color == .white ? "White" : "Black").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(clockText(remaining))
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(remaining < 20_000 && running ? .red : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(running ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
        }
        .padding(.horizontal, 16)
    }

    private func clockText(_ ms: Int64) -> String {
        let tenths = Int(ms / 100)
        let seconds = tenths / 10
        if seconds < 10 { return String(format: "0:%02d.%d", seconds, tenths % 10) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private func statusLine(_ game: ChessTournamentGame) -> some View {
        let text: String = {
            if let winner = game.winner, let outcome = game.outcome {
                let who = name(for: winner)
                switch outcome {
                case .checkmate: return "Checkmate. \(who) won."
                case .resignation: return "\(who) won by resignation."
                case .timeout: return "\(who) won on time."
                case .drawTiebreak(let reason): return "Draw by \(reason). \(who) won on clock."
                }
            }
            if service.pendingMoveGames.contains("\(tournamentId)|\(gameId)") { return "Sending your move…" }
            if let myColor {
                if ChessEngine.isKingInCheck(color: game.sideToMove, board: game.board), game.sideToMove == myColor { return "Check. Your move." }
                return game.sideToMove == myColor ? "Your move" : "Their move"
            }
            return game.sideToMove == .white ? "White to move" : "Black to move"
        }()
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(game.isOver ? .secondary : .primary)
    }

    // MARK: - Board

    private var legalDestinations: [ChessSquare] {
        guard let game, let selectedSquare, isMyTurn else { return [] }
        return ChessEngine.legalMoves(from: selectedSquare, board: game.board).map { $0.to }
    }

    private func board(_ game: ChessTournamentGame) -> some View {
        GeometryReader { proxy in
            let size = proxy.size.width / 8
            let ranks = flipped ? Array(0..<8) : Array((0..<8).reversed())
            let files = flipped ? Array((0..<8).reversed()) : Array(0..<8)
            VStack(spacing: 0) {
                ForEach(ranks, id: \.self) { rank in
                    HStack(spacing: 0) {
                        ForEach(files, id: \.self) { file in
                            square(file: file, rank: rank, game: game, size: size)
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func square(file: Int, rank: Int, game: ChessTournamentGame, size: CGFloat) -> some View {
        let sq = ChessSquare(file: file, rank: rank)
        let isLight = !(file + rank).isMultiple(of: 2)
        let last = game.moves.last
        let isLast = last.map { $0.from == sq || $0.to == sq } ?? false
        let isSelected = selectedSquare == sq
        let isTarget = legalDestinations.contains(sq)
        return ZStack {
            Rectangle().fill(isLight ? ChessBoardThumbnail.lightSquareColor : ChessBoardThumbnail.darkSquareColor)
            if isLast { Rectangle().fill(Color.yellow.opacity(0.35)) }
            if isSelected { Rectangle().fill(Color.accentColor.opacity(0.35)) }
            if let piece = game.board.piece(at: sq) {
                ChessPieceGlyphView(piece: piece, fontSize: size * 0.7)
            }
            if isTarget {
                Circle().fill(Color.accentColor.opacity(0.55)).frame(width: size * 0.3, height: size * 0.3)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { tap(sq, game: game) }
    }

    private func tap(_ sq: ChessSquare, game: ChessTournamentGame) {
        guard isMyTurn, let tournament, let myColor else { return }
        if let from = selectedSquare {
            if legalDestinations.contains(sq) {
                let move = ChessMove(from: from, to: sq, promotion: nil)
                let piece = game.board.piece(at: from)
                selectedSquare = nil
                if piece?.type == .pawn, sq.rank == (myColor == .white ? 7 : 0) {
                    pendingPromotion = move
                } else {
                    Haptics.impact(.light)
                    Task { await service.play(move, in: tournament, game: game) }
                }
                return
            }
            if game.board.piece(at: sq)?.color == myColor { selectedSquare = sq } else { selectedSquare = nil }
            return
        }
        if game.board.piece(at: sq)?.color == myColor { selectedSquare = sq }
    }

    private func promotionSheet(_ move: ChessMove, tournament: ChessTournament, game: ChessTournamentGame) -> some View {
        VStack(spacing: 12) {
            Text("Promote to").font(.headline).padding(.top, 20)
            HStack(spacing: 18) {
                ForEach([ChessPieceType.queen, .rook, .bishop, .knight], id: \.self) { type in
                    Button {
                        pendingPromotion = nil
                        Task { await service.play(ChessMove(from: move.from, to: move.to, promotion: type), in: tournament, game: game) }
                    } label: {
                        ChessPieceGlyphView(piece: ChessPiece(type: type, color: myColor ?? .white), fontSize: 44)
                            .frame(width: 60, height: 60)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(180)])
    }

    // MARK: - Chat under the board

    private func chatSection(_ tournament: ChessTournament, _ game: ChessTournamentGame) -> some View {
        let lines = tournament.chat.filter { $0.game == game.id }.suffix(80)
        return VStack(alignment: .leading, spacing: 8) {
            if lines.isEmpty {
                Text("No messages yet.").font(.caption).foregroundColor(.secondary).padding(.horizontal, 16)
            }
            ForEach(Array(lines)) { line in
                let mine = line.sender == me
                HStack {
                    if mine { Spacer(minLength: 40) }
                    VStack(alignment: .leading, spacing: 2) {
                        if !mine {
                            Text(name(for: line.sender)).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                        }
                        Text(line.text).font(.subheadline).foregroundColor(mine ? .white : .primary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(mine ? OutgoingBubble.color : Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    if !mine { Spacer(minLength: 40) }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func composer(_ tournament: ChessTournament, _ game: ChessTournamentGame) -> some View {
        HStack(spacing: 8) {
            TextField("Message (one transaction)", text: $chatText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { sendChat(tournament, game) }
            Button {
                sendChat(tournament, game)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(chatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func sendChat(_ tournament: ChessTournament, _ game: ChessTournamentGame) {
        let text = chatText
        chatText = ""
        Task { await service.sendChat(text, tournament: tournament, game: game) }
    }
}
