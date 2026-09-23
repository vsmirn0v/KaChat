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
    /// End-of-game flow: the overlay over the board, then the result screen (players only).
    @State private var showEndOverlay = false
    @State private var showResult = false
    @State private var endHandledForGame: String?
    /// The player's record as it stood while the game was on - the result screen counts up from it.
    @State private var recordBeforeEnd: ChessLeaderboardRow?

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
        .onAppear { service.acquire(); rememberRecord() }
        .onDisappear { service.release() }
        .onChange(of: game?.isOver) { _ in gameEndedIfNeeded() }
        // Keep the "before" record fresh while the game is on (the arena may still be loading
        // when the screen opens); once the game is over it is left alone.
        .onChange(of: service.leaderboard) { _ in rememberRecord() }
        .onAppear { gameEndedIfNeeded() }
        .fullScreenCover(isPresented: $showResult) {
            ChessGameResultView(tournamentId: tournamentId, gameId: gameId, before: recordBeforeEnd) {
                showResult = false
            }
            .environmentObject(walletManager)
        }
    }

    /// The record before the end lands, so the result screen can count up from it.
    private func rememberRecord() {
        guard let me, let game, !game.isOver else { return }
        recordBeforeEnd = service.leaderboard.first { $0.address == me } ?? ChessLeaderboardRow(address: me)
    }

    /// The game just ended: the burst over the board for a couple of seconds, then - for the
    /// two players, not for someone watching - the result screen with the record.
    private func gameEndedIfNeeded() {
        guard let game, game.isOver, game.winner != nil, endHandledForGame != game.id else { return }
        // Opened on a game that was already over (watching a finished bracket): nothing to show.
        let justEnded = (game.endedAt ?? 0) > service.now - 60_000
        endHandledForGame = game.id
        guard justEnded else { return }
        withAnimation(.easeOut(duration: 0.25)) { showEndOverlay = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation { showEndOverlay = false }
            if myColor != nil { showResult = true }
        }
    }

    private func roundLabel(_ game: ChessTournamentGame) -> String {
        if tournament?.isDuel == true { return "1v1" }
        return game.round == 3 ? "Final" : (game.round == 2 ? "Semifinal" : "Round 1")
    }

    /// Contact name, then KNS domain, then the shortened address - the app's rule, and the
    /// same for the player themselves (their own domain or address, never "You").
    private func name(for address: String) -> String {
        ContactsManager.shared.displayName(for: address)
    }

    @ViewBuilder
    private func content(_ tournament: ChessTournament, _ game: ChessTournamentGame) -> some View {
        // The same arrangement as the 1:1 chat's board (ChessGameView): header, the other
        // side's clock chip, the board as large as the screen allows (it wins the fight for
        // height), our clock chip, then the chat taking what is left, the composer a bottom
        // safe-area inset so it sits flush above the keyboard.
        VStack(spacing: 10) {
            header(game)
            clockChip(game, color: flipped ? .white : .black)
                .padding(.horizontal)
            board(game)
                .padding(.horizontal)
                .layoutPriority(1)
            clockChip(game, color: flipped ? .black : .white)
                .padding(.horizontal)
            Divider()
            chatSection(tournament, game)
        }
        .padding(.top, 8)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer(tournament, game)
        }
        .sheet(isPresented: $showResignConfirm) {
            resignSheet(tournament, game)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $pendingPromotion) { move in
            promotionSheet(move, tournament: tournament, game: game)
        }
        .toast(message: service.lastError, style: .error)
    }

    // MARK: - Resign

    /// The half sheet behind the Resign button: what it means, then Resign or Keep playing.
    private func resignSheet(_ tournament: ChessTournament, _ game: ChessTournamentGame) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.fill")
                .font(.system(size: 34))
                .foregroundColor(.red)
                .padding(.top, 28)
            Text("Resign this game?")
                .font(.title3.weight(.bold))
            Text(tournament.isDuel
                 ? "\(name(for: game.address(of: myColor == .white ? .black : .white))) wins, and it counts as a loss on the leaderboard. Resigning is one transaction."
                 : "\(name(for: game.address(of: myColor == .white ? .black : .white))) goes through and you are out of the tournament. It counts as a loss on the leaderboard. Resigning is one transaction.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    showResignConfirm = false
                    Task { await service.resign(tournament, game: game) }
                } label: {
                    Text("Resign")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Button {
                    showResignConfirm = false
                } label: {
                    Text("Keep playing")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Header, clocks and status

    /// Who is playing and where the game stands - the 1:1 board's header. A player sees the
    /// opponent's name (their own is on their clock chip); a spectator sees both.
    private func header(_ game: ChessTournamentGame) -> some View {
        VStack(spacing: 4) {
            if let myColor {
                Text(name(for: game.address(of: myColor.opposite)))
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("\(name(for: game.white)) vs \(name(for: game.black))")
                    .font(.headline)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                statusLine(game)
                if myColor != nil, !game.isOver {
                    Button(role: .destructive) { showResignConfirm = true } label: {
                        Label("Resign", systemImage: "flag.fill").font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    /// The 1:1 board's clock chip - label, timer, time - lit while that side is to move, red
    /// under twenty seconds; the side's avatar and name sit at the leading edge.
    private func clockChip(_ game: ChessTournamentGame, color: ChessColor) -> some View {
        let address = game.address(of: color)
        let remaining = game.remainingMs(color, at: service.now)
        let isActive = !game.isOver && game.sideToMove == color
        let isLow = remaining < 20_000
        let label: String = myColor == nil ? (color == .white ? "White" : "Black") : (color == myColor ? "You" : "Them")
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let tint: Color = isLow ? Color.red.opacity(0.14) : (isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        let stroke: Color = isLow ? Color.red.opacity(0.55) : (isActive ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.18))
        return HStack(spacing: 8) {
            KNSAvatarView(
                avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                fallbackText: ContactsManager.shared.displayName(for: address),
                size: 26,
                contactAddress: address
            )
            Text(name(for: address))
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                Image(systemName: "timer")
                    .font(.caption)
                Text(clockText(remaining))
                    .font(.system(.callout, design: .monospaced).weight(isActive ? .bold : .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(isLow ? .red : (isActive ? .primary : .secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                shape.fill(.regularMaterial)
                    .overlay(shape.fill(tint))
                    .overlay(shape.stroke(stroke, lineWidth: isActive ? 1.2 : 0.8))
                    .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
            )
        }
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
            // A side's first move has a minute before its clock runs (the gate on a
            // simultaneous join - see ChessTournamentCodec.firstMoveGraceMs); say so.
            var grace = ""
            if game.moves.count < 2 {
                let left = game.allowanceLeftMs(at: service.now)
                if left > 0 { grace = " · clock starts in \(clockText(left))" }
            }
            if let myColor {
                if ChessEngine.isKingInCheck(color: game.sideToMove, board: game.board), game.sideToMove == myColor { return "Check. Your move." + grace }
                return (game.sideToMove == myColor ? "Your move" : "Their move") + grace
            }
            return (game.sideToMove == .white ? "White to move" : "Black to move") + grace
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
            ZStack {
                VStack(spacing: 0) {
                    ForEach(ranks, id: \.self) { rank in
                        HStack(spacing: 0) {
                            ForEach(files, id: \.self) { file in
                                square(file: file, rank: rank, game: game, size: size)
                            }
                        }
                    }
                }
                // Same "Waiting on opponent..." as the 1:1 board, while it is their move.
                if let myColor, !game.isOver, game.sideToMove != myColor {
                    WaitingOnOpponentOverlay()
                }
                if showEndOverlay, let winner = game.winner, let outcome = game.outcome {
                    ChessGameEndOverlay(winnerName: name(for: winner), outcome: outcome, iWon: myColor == nil ? nil : winner == me)
                        .transition(.opacity)
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

    /// One bubble's delivery state - the three a 1:1 chat bubble has.
    private enum LineStatus { case sent, pending, failed }

    /// The game's chat: lines the chain returned (green check on ours), then ours still on the
    /// way (clock) or failed (red). Scrolls on its own and follows the newest line.
    private func chatSection(_ tournament: ChessTournament, _ game: ChessTournamentGame) -> some View {
        let sent = tournament.chat.filter { $0.game == game.id }.suffix(120).map { ($0, LineStatus.sent) }
        let pending = service.pendingChat
            .filter { $0.tournament == tournament.id && $0.line.game == game.id }
            .map { ($0.line, $0.failed ? LineStatus.failed : .pending) }
        let lines = sent + pending
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if lines.isEmpty {
                        Text("No messages yet. Each message is one transaction.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    }
                    ForEach(lines, id: \.0.id) { item in
                        chatBubble(item.0, status: item.1)
                            .id(item.0.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollDismissesKeyboard(.immediately)
            .frame(minHeight: 96)
            .onAppear { if let last = lines.last { proxy.scrollTo(last.0.id, anchor: .bottom) } }
            .onChange(of: lines.map(\.0.id)) { ids in
                if let last = ids.last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
    }

    private func chatBubble(_ line: ChessTournamentChatLine, status: LineStatus) -> some View {
        let mine = line.sender == me
        return HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 2) {
                    if !mine {
                        Text(name(for: line.sender)).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
                    }
                    Text(line.text).font(.body).foregroundColor(mine ? .white : .primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? OutgoingBubble.color : Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                if mine {
                    // Under the bubble, as in a 1:1 chat: green check once the chain has it.
                    switch status {
                    case .sent: Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundColor(.green)
                    case .pending: Image(systemName: "clock").font(.caption2).foregroundColor(.secondary)
                    case .failed: Image(systemName: "exclamationmark.circle.fill").font(.caption2).foregroundColor(.red)
                    }
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 12)
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
