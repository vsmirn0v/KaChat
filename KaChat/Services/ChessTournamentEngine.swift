import Foundation

/// The rules of CHESS_TOURNAMENTS.md §3-4 as one pure function: the arena's tournament
/// messages, in chain order, in; every tournament's bracket, boards, clocks and results out.
/// Every phone runs this over the same rows and lands on the same state - there is no referee.
/// The indexer's leaderboard is a port of this file, so keep it self-contained.
enum ChessTournamentEngine {
    /// Chain order: block time, then txid - the same on every device.
    static func ordered(_ events: [ChessArenaEvent]) -> [ChessArenaEvent] {
        events.sorted {
            if $0.blockTime != $1.blockTime { return $0.blockTime < $1.blockTime }
            return $0.txId < $1.txId
        }
    }

    static func reduce(_ events: [ChessArenaEvent]) -> [String: ChessTournament] {
        var tournaments: [String: ChessTournament] = [:]
        for event in ordered(events) {
            apply(event, to: &tournaments)
        }
        return tournaments
    }

    static func apply(_ event: ChessArenaEvent, to tournaments: inout [String: ChessTournament]) {
        let message = event.message
        switch message.a {
        case "create":
            // Public rooms are never created by message. A private tournament (8) needs the
            // creator key; a private 1v1 (2) is open to anyone.
            let capacity = message.p == 2 ? 2 : ChessTournamentCodec.playerCount
            guard tournaments[message.t] == nil, !ChessTournamentCodec.isPublic(message.t),
                  capacity == 2 || ChessTournamentCodec.isValidCreateKey(message.k, id: message.t) else { return }
            let cleanName = (message.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var tournament = ChessTournament(
                id: message.t,
                name: cleanName.isEmpty ? (capacity == 2 ? "1v1" : "Tournament") : String(cleanName.prefix(ChessTournamentCodec.nameMaxLength)),
                creator: event.sender,
                createdAt: event.blockTime,
                createTxId: event.txId,
                capacity: capacity
            )
            tournament.players = [event.sender]
            tournament.joinedAt[event.sender] = event.blockTime
            tournaments[message.t] = tournament
        case "join":
            if tournaments[message.t] == nil {
                // The first join opens a public room - whichever number it names. There used to
                // be a rule that room N counts only once room N-1 is full; it made every phone's
                // view depend on holding the complete history back to room 1, and a phone
                // missing the early rooms (indexer window, retention, a late backfill) then
                // rejected every later room outright and queued into a room the others had
                // long finished. Which room is "current" is a client choice now
                // (`ChessTournamentService.currentPublicRoomId`: the lowest open room).
                if let number = ChessTournamentCodec.publicNumber(of: message.t) {
                    tournaments[message.t] = ChessTournament(
                        id: message.t, name: "Public tournament #\(number)", creator: event.sender,
                        createdAt: event.blockTime, createTxId: event.txId, capacity: ChessTournamentCodec.playerCount
                    )
                } else if let number = ChessTournamentCodec.duelNumber(of: message.t) {
                    tournaments[message.t] = ChessTournament(
                        id: message.t, name: "Public 1v1 #\(number)", creator: event.sender,
                        createdAt: event.blockTime, createTxId: event.txId, capacity: 2
                    )
                }
            }
            guard var tournament = tournaments[message.t], tournament.status == .open else { return }
            // Seats that ran out while the room waited are given back first - so a room can
            // never fill with players who left long ago, and a returning player takes a fresh
            // seat. Deterministic: judged at this join's block time, the same on every phone.
            expireSeats(&tournament, at: event.blockTime)
            guard !tournament.players.contains(event.sender) else { return }
            tournament.players.append(event.sender)
            tournament.joinedAt[event.sender] = event.blockTime
            if tournament.players.count == tournament.capacity {
                start(&tournament, at: event.blockTime)
            }
            tournaments[message.t] = tournament
        case "leave":
            // A seat given back while the room is still waiting. Once it has started there is
            // no leaving - only resigning the game.
            guard var tournament = tournaments[message.t], tournament.status == .open,
                  let index = tournament.players.firstIndex(of: event.sender) else { return }
            tournament.players.remove(at: index)
            tournament.joinedAt[event.sender] = nil
            tournaments[message.t] = tournament
        case "cancel":
            guard var tournament = tournaments[message.t], tournament.status == .open,
                  !tournament.isPublic, tournament.creator == event.sender else { return }
            tournament.cancelled = true
            tournaments[message.t] = tournament
        case "move":
            guard var tournament = tournaments[message.t], tournament.status == .live,
                  let gameId = message.g, var game = tournament.games[gameId], !game.isOver,
                  game.playerToMove == event.sender,
                  let ply = message.n, ply == game.moves.count + 1,
                  let fromText = message.from, let toText = message.to,
                  let from = ChessSquare(algebraic: fromText), let to = ChessSquare(algebraic: toText) else { return }
            // A move after the mover's clock ran out is void: the opponent's claim decides.
            // Charged past the move's allowance (a minute for a side's first move, ten seconds
            // after) - see ChessTournamentCodec.allowanceMs.
            let elapsed = game.chargedMs(elapsed: event.blockTime - game.lastEventAt)
            let remaining = ChessTournamentCodec.clockMs - game.usedMs(game.sideToMove)
            guard elapsed < remaining else { return }
            var move = ChessMove(from: from, to: to, promotion: ChessPieceType.fromPromotionLetter(message.promo))
            move = ChessEngine.normalizingPromotion(move, in: game.board)
            guard ChessEngine.isLegal(move, in: game.board), let piece = game.board.piece(at: from) else { return }
            let isEnPassant = piece.type == .pawn && to == game.board.enPassantTarget && game.board.piece(at: to) == nil
            let captured = game.board.piece(at: to)?.type ?? (isEnPassant ? .pawn : nil)
            let mover = game.sideToMove
            game.board = ChessEngine.apply(move, to: game.board)
            if mover == .white { game.whiteUsedMs += elapsed } else { game.blackUsedMs += elapsed }
            game.lastEventAt = event.blockTime
            game.moves.append(ChessTournamentMove(
                txId: event.txId, ply: ply, color: mover, from: from, to: to, promotion: move.promotion,
                pieceType: piece.type, captured: captured, blockTime: event.blockTime,
                clockAfterMs: ChessTournamentCodec.clockMs - game.usedMs(mover)
            ))
            game.halfmoveClock = (piece.type == .pawn || captured != nil) ? 0 : game.halfmoveClock + 1
            let key = positionKey(game.board)
            game.positionCounts[key, default: 0] += 1

            if ChessEngine.isCheckmate(game.board) {
                finish(&game, winner: game.address(of: mover), outcome: .checkmate, at: event.blockTime)
            } else if ChessEngine.isStalemate(game.board) {
                finishDraw(&game, reason: "stalemate", at: event.blockTime)
            } else if ChessEngine.isInsufficientMaterial(game.board) {
                finishDraw(&game, reason: "insufficient material", at: event.blockTime)
            } else if game.halfmoveClock >= 100 {
                finishDraw(&game, reason: "fifty-move rule", at: event.blockTime)
            } else if game.positionCounts[key, default: 0] >= 3 {
                finishDraw(&game, reason: "threefold repetition", at: event.blockTime)
            }
            tournament.games[gameId] = game
            if game.isOver { advance(&tournament, after: game) }
            tournaments[message.t] = tournament
        case "resign":
            guard var tournament = tournaments[message.t], tournament.status == .live,
                  let gameId = message.g, var game = tournament.games[gameId], !game.isOver,
                  let color = game.color(of: event.sender) else { return }
            finish(&game, winner: game.address(of: color.opposite), outcome: .resignation, at: event.blockTime)
            tournament.games[gameId] = game
            advance(&tournament, after: game)
            tournaments[message.t] = tournament
        case "claim":
            guard var tournament = tournaments[message.t], tournament.status == .live,
                  let gameId = message.g, var game = tournament.games[gameId], !game.isOver,
                  let claimant = game.color(of: event.sender), claimant != game.sideToMove else { return }
            // Valid only if, by chain time, the side to move had indeed run out - past the
            // same allowance a move gets.
            let elapsed = game.chargedMs(elapsed: event.blockTime - game.lastEventAt)
            let remaining = ChessTournamentCodec.clockMs - game.usedMs(game.sideToMove)
            guard elapsed >= remaining else { return }
            if game.sideToMove == .white { game.whiteUsedMs = ChessTournamentCodec.clockMs } else { game.blackUsedMs = ChessTournamentCodec.clockMs }
            finish(&game, winner: event.sender, outcome: .timeout, at: event.blockTime)
            tournament.games[gameId] = game
            advance(&tournament, after: game)
            tournaments[message.t] = tournament
        case "chat":
            guard var tournament = tournaments[message.t],
                  let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            tournament.chat.append(ChessTournamentChatLine(
                id: event.txId, sender: event.sender, text: String(text.prefix(ChessTournamentCodec.chatMaxLength)),
                blockTime: event.blockTime, game: message.g ?? ""
            ))
            tournaments[message.t] = tournament
        default:
            return
        }
    }

    private static func expireSeats(_ tournament: inout ChessTournament, at time: Int64) {
        let kept = tournament.players.filter { (tournament.joinedAt[$0] ?? tournament.createdAt) + ChessTournamentCodec.seatTTLMs > time }
        guard kept.count != tournament.players.count else { return }
        for gone in tournament.players where !kept.contains(gone) { tournament.joinedAt[gone] = nil }
        tournament.players = kept
    }

    // MARK: - Bracket

    private static func start(_ tournament: inout ChessTournament, at time: Int64) {
        tournament.startedAt = time
        let seeds = tournament.players
        let pairs = tournament.isDuel ? [(0, 1)] : [(0, 7), (1, 6), (2, 5), (3, 4)]
        for (index, pair) in pairs.enumerated() {
            let white = seeds[pair.0], black = seeds[pair.1]
            tournament.games["1-\(index)"] = makeGame(round: 1, index: index, white: white, black: black, at: time)
            tournament.whiteCount[white, default: 0] += 1
        }
    }

    private static func advance(_ tournament: inout ChessTournament, after game: ChessTournamentGame) {
        guard game.round < tournament.rounds, let time = game.endedAt else { return }
        let nextRound = game.round + 1
        let nextIndex = game.index / 2
        let feederA = tournament.game(game.round, nextIndex * 2)
        let feederB = tournament.game(game.round, nextIndex * 2 + 1)
        guard let a = feederA?.winner, let b = feederB?.winner,
              tournament.game(nextRound, nextIndex) == nil else { return }
        // Colours: fewer whites so far gets white; tie -> lower seed.
        let whitesA = tournament.whiteCount[a, default: 0], whitesB = tournament.whiteCount[b, default: 0]
        let aIsWhite: Bool
        if whitesA != whitesB {
            aIsWhite = whitesA < whitesB
        } else {
            aIsWhite = (tournament.seed(of: a) ?? 99) < (tournament.seed(of: b) ?? 99)
        }
        let white = aIsWhite ? a : b, black = aIsWhite ? b : a
        tournament.games["\(nextRound)-\(nextIndex)"] = makeGame(round: nextRound, index: nextIndex, white: white, black: black, at: time)
        tournament.whiteCount[white, default: 0] += 1
    }

    private static func makeGame(round: Int, index: Int, white: String, black: String, at time: Int64) -> ChessTournamentGame {
        let board = ChessEngine.initialBoard()
        var game = ChessTournamentGame(
            id: "\(round)-\(index)", round: round, index: index, white: white, black: black,
            startedAt: time, board: board, moves: [], lastEventAt: time
        )
        game.positionCounts[positionKey(board)] = 1
        return game
    }

    private static func finish(_ game: inout ChessTournamentGame, winner: String, outcome: ChessTournamentGame.Outcome, at time: Int64) {
        game.winner = winner
        game.outcome = outcome
        game.endedAt = time
    }

    /// A draw on the board: the player with more clock left advances; equal -> black.
    private static func finishDraw(_ game: inout ChessTournamentGame, reason: String, at time: Int64) {
        let whiteLeft = ChessTournamentCodec.clockMs - game.whiteUsedMs
        let blackLeft = ChessTournamentCodec.clockMs - game.blackUsedMs
        let winner = whiteLeft > blackLeft ? game.white : game.black
        finish(&game, winner: winner, outcome: .drawTiebreak(reason), at: time)
    }

    /// Board, side to move, castling rights and en-passant square - what repetition compares.
    static func positionKey(_ board: ChessBoard) -> String {
        var key = ""
        for rank in 0..<8 {
            for file in 0..<8 {
                if let piece = board.squares[rank][file] {
                    let letter: String
                    switch piece.type {
                    case .pawn: letter = "p"
                    case .knight: letter = "n"
                    case .bishop: letter = "b"
                    case .rook: letter = "r"
                    case .queen: letter = "q"
                    case .king: letter = "k"
                    }
                    key += piece.color == .white ? letter.uppercased() : letter
                } else {
                    key += "."
                }
            }
        }
        key += board.sideToMove == .white ? "w" : "b"
        key += board.whiteCanCastleKingside ? "K" : "-"
        key += board.whiteCanCastleQueenside ? "Q" : "-"
        key += board.blackCanCastleKingside ? "k" : "-"
        key += board.blackCanCastleQueenside ? "q" : "-"
        key += board.enPassantTarget?.algebraic ?? "-"
        return key
    }

    // MARK: - Leaderboard

    static func leaderboard(from tournaments: [ChessTournament]) -> [ChessLeaderboardRow] {
        var rows: [String: ChessLeaderboardRow] = [:]
        func row(_ address: String) -> ChessLeaderboardRow { rows[address] ?? ChessLeaderboardRow(address: address) }
        for tournament in tournaments where tournament.startedAt != nil {
            // A 1v1 is not a tournament: it counts on the 1v1 board only.
            if !tournament.isDuel {
                for player in tournament.players {
                    var r = row(player)
                    r.tournamentsPlayed += 1
                    r.lastPlayedAt = max(r.lastPlayedAt, tournament.startedAt ?? 0)
                    rows[player] = r
                }
            }
            for game in tournament.games.values where game.isOver {
                guard let winner = game.winner else { continue }
                let loser = winner == game.white ? game.black : game.white
                var w = row(winner)
                w.wins += 1
                if tournament.isDuel { w.duelWins += 1 } else { w.tournamentGameWins += 1 }
                w.lastPlayedAt = max(w.lastPlayedAt, game.endedAt ?? 0)
                rows[winner] = w
                var l = row(loser)
                l.losses += 1
                if tournament.isDuel { l.duelLosses += 1 } else { l.tournamentGameLosses += 1 }
                l.lastPlayedAt = max(l.lastPlayedAt, game.endedAt ?? 0)
                rows[loser] = l
            }
            if !tournament.isDuel, let champion = tournament.champion {
                var c = row(champion); c.tournamentsWon += 1; rows[champion] = c
            }
        }
        // Wins and losses are the leaderboard: most wins first, fewest losses breaking ties.
        return rows.values.sorted {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            if $0.losses != $1.losses { return $0.losses < $1.losses }
            return $0.lastPlayedAt > $1.lastPlayedAt
        }
    }

    /// The 1v1 board: players with a 1v1 game behind them, most wins first, fewest losses
    /// breaking ties.
    static func duelLeaderboard(_ rows: [ChessLeaderboardRow]) -> [ChessLeaderboardRow] {
        rows.filter { $0.duelWins + $0.duelLosses > 0 }.sorted {
            if $0.duelWins != $1.duelWins { return $0.duelWins > $1.duelWins }
            if $0.duelLosses != $1.duelLosses { return $0.duelLosses < $1.duelLosses }
            return $0.lastPlayedAt > $1.lastPlayedAt
        }
    }

    /// The tournament board: tournaments won first, then the record inside them.
    static func tournamentLeaderboard(_ rows: [ChessLeaderboardRow]) -> [ChessLeaderboardRow] {
        rows.filter { $0.tournamentsPlayed > 0 }.sorted {
            if $0.tournamentsWon != $1.tournamentsWon { return $0.tournamentsWon > $1.tournamentsWon }
            if $0.tournamentGameWins != $1.tournamentGameWins { return $0.tournamentGameWins > $1.tournamentGameWins }
            if $0.tournamentGameLosses != $1.tournamentGameLosses { return $0.tournamentGameLosses < $1.tournamentGameLosses }
            return $0.lastPlayedAt > $1.lastPlayedAt
        }
    }
}
