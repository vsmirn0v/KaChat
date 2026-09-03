import Foundation

/// Play-chess-in-1:1-chats feature: game state is never persisted on its own - it's always
/// re-derived by scanning a conversation's already-loaded messages for the chess envelopes
/// (`ChessInviteContent`/`ChessResponseContent`/`ChessMoveContent`/`ChessResignContent`, see
/// Models.swift) sharing a given `gameId` and replaying them through `ChessEngine`. This mirrors
/// how the reply feature resolves `replyToId` against the in-memory message list rather than a
/// database relationship - no new persistence, no wire-protocol change.
///
/// No third-party chess library is used on either platform: adding an SPM package reference
/// isn't something that can be done safely by editing `project.pbxproj` by hand here (unlike a
/// Gradle dependency on Android), and this project has already suffered real corruption from
/// manual pbxproj file registration - so the whole engine is hand-written instead (see
/// `ChessEngine.swift`).
/// A timed game's control: initial minutes per side plus a per-move increment in seconds
/// (chess-site style, e.g. "3 | 2"). Carried on the invite envelope (`tcMinutes`/`tcIncSeconds`);
/// nil throughout the feature means a casual untimed game, which behaves exactly like before
/// time controls existed.
struct ChessTimeControl: Equatable {
    let minutes: Int
    let incSeconds: Int

    var initialMs: Int64 { Int64(minutes) * 60_000 }
    var incrementMs: Int64 { Int64(incSeconds) * 1_000 }
    /// "3 | 2"-style display label, matching how chess sites name minute/increment pairs.
    var label: String { "\(minutes) | \(incSeconds)" }
}

enum ChessGameStatus: Equatable {
    case pendingResponse
    case declined
    case inProgress
    case checkmate(winner: ChessColor)
    case stalemate
    /// A dead position - K vs K and friends. A draw, but not a stalemate: see
    /// `ChessEngine.isInsufficientMaterial`.
    case insufficientMaterial
    /// `timeout` true when the loser flagged (their clock ran out and the app auto-sent a
    /// `chess_resign` with reason "timeout") rather than resigning by hand.
    case resigned(loser: ChessColor, timeout: Bool)

    var isGameOver: Bool {
        switch self {
        case .pendingResponse, .inProgress: return false
        case .declined, .checkmate, .stalemate, .insufficientMaterial, .resigned: return true
        }
    }
}

/// One applied move, recorded during `ChessGameService.summarize`'s replay - lets callers show
/// the actual piece that moved/was captured (e.g. the in-thread move log, captured-pieces tray)
/// without re-replaying the game themselves.
struct ChessMoveRecord {
    let from: ChessSquare
    let to: ChessSquare
    let pieceType: ChessPieceType
    let color: ChessColor
    let capturedType: ChessPieceType?
    let capturedColor: ChessColor?
    let promotion: ChessPieceType?
    /// txId of the chat message this move came from - lets a specific log entry look up its own
    /// record via `moveHistory.first(where: { $0.messageTxId == message.txId })`.
    let messageTxId: String
}

struct ChessGameSummary {
    let gameId: String
    let status: ChessGameStatus
    let board: ChessBoard
    /// The wallet address playing white/black - resolved once from the invite's `inviterColor`
    /// plus who sent it.
    let whiteAddress: String
    let blackAddress: String
    /// txId of the most recent chess-related message for this game - used to key SwiftUI
    /// reactivity (`.task(id:)`/`.id(...)`) without needing full board equatability.
    let lastMessageTxId: String
    /// Which color the local device is playing, if it's a participant - lets `statusText` say
    /// "Your turn"/"Their turn" instead of absolute White/Black, which a casual player has to
    /// stop and translate back to "wait, am I white or black in this one?" every time.
    let viewerColor: ChessColor?
    /// Every move actually applied during replay, in play order.
    let moveHistory: [ChessMoveRecord]
    /// Time control from the invite, or nil for a casual untimed game (including every game
    /// started by a legacy client).
    let timeControl: ChessTimeControl?
    /// Last-known remaining clock per side in milliseconds - the `clockMs` of that side's most
    /// recent move, or the initial allotment if they haven't moved yet. nil when untimed. The
    /// side to move's real remaining time is this value minus their accumulated open-board
    /// thinking time this turn, which only their own device tracks (see `ChessClockStore`).
    let whiteClockMs: Int64?
    let blackClockMs: Int64?

    /// Pieces captured so far, grouped by the color that captured them (i.e. `capturedByWhite`
    /// are black pieces White has taken) - drives a captured-pieces tray.
    var capturedByWhite: [ChessPieceType] {
        moveHistory.filter { $0.color == .white }.compactMap { $0.capturedType }
    }
    var capturedByBlack: [ChessPieceType] {
        moveHistory.filter { $0.color == .black }.compactMap { $0.capturedType }
    }

    func color(for address: String) -> ChessColor? {
        if address == whiteAddress { return .white }
        if address == blackAddress { return .black }
        return nil
    }

    var statusText: String {
        switch status {
        case .pendingResponse: return "Waiting for response"
        case .declined: return "Game declined"
        case .inProgress:
            guard let viewerColor else { return board.sideToMove == .white ? "White to move" : "Black to move" }
            return board.sideToMove == viewerColor ? "Your turn" : "Their turn"
        case .checkmate(let winner):
            guard let viewerColor else { return "Checkmate - \(winner == .white ? "White" : "Black") wins" }
            return winner == viewerColor ? "Checkmate - You win!" : "Checkmate - You lost"
        case .stalemate:
            return "Stalemate - draw"
        case .insufficientMaterial:
            return "Draw - not enough pieces to checkmate"
        case .resigned(let loser, let timeout):
            if timeout {
                guard let viewerColor else { return "\(loser == .white ? "White" : "Black") lost on time" }
                return loser == viewerColor ? "You lost on time" : "They lost on time"
            }
            guard let viewerColor else { return "\(loser == .white ? "White" : "Black") resigned" }
            return loser == viewerColor ? "You resigned" : "They resigned"
        }
    }
}

@MainActor
enum ChessGameService {
    /// Scans `messages` for every chess envelope sharing `gameId`, in the order they already
    /// appear (conversations are already chronological), and replays them. Returns nil if no
    /// invite for this `gameId` is present.
    static func summarize(gameId: String, in messages: [ChatMessage], myAddress: String, contactAddress: String) -> ChessGameSummary? {
        var invite: ChessInviteContent?
        var inviterAddress: String?
        var response: ChessResponseContent?
        var board = ChessEngine.initialBoard()
        var resignerAddress: String?
        var resignReason: String?
        var lastMessageTxId: String?
        var moveHistory: [ChessMoveRecord] = []
        // Last clockMs each color reported on its own moves - resolved to a concrete remaining
        // time (falling back to the initial allotment) after the invite's time control is known.
        var lastClockByColor: [ChessColor: Int64] = [:]

        for message in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let envelope = ChessCodec.parseAny(MessageReplyCodec.unwrappedText(message.content)),
                  envelope.gameId == gameId else { continue }
            lastMessageTxId = message.txId
            let senderAddress = message.isOutgoing ? myAddress : contactAddress

            switch envelope {
            case .invite(let content):
                invite = content
                inviterAddress = senderAddress
            case .response(let content):
                response = content
            case .move(let content):
                guard let from = ChessSquare(algebraic: content.from), let to = ChessSquare(algebraic: content.to) else { continue }
                let promotion = ChessPieceType.fromPromotionLetter(content.promotion)
                let move = ChessEngine.normalizingPromotion(ChessMove(from: from, to: to, promotion: promotion), in: board)
                guard ChessEngine.isLegal(move, in: board), let movingPiece = board.piece(at: from) else { continue }
                let isEnPassantCapture = movingPiece.type == .pawn && to == board.enPassantTarget && board.piece(at: to) == nil
                let capturedPiece: ChessPiece? = isEnPassantCapture
                    ? board.piece(at: ChessSquare(file: to.file, rank: from.rank))
                    : board.piece(at: to)
                board = ChessEngine.apply(move, to: board)
                if let clockMs = content.clockMs {
                    lastClockByColor[movingPiece.color] = clockMs
                }
                moveHistory.append(ChessMoveRecord(
                    from: from,
                    to: to,
                    pieceType: movingPiece.type,
                    color: movingPiece.color,
                    capturedType: capturedPiece?.type,
                    capturedColor: capturedPiece?.color,
                    promotion: promotion,
                    messageTxId: message.txId
                ))
            case .resign(let content):
                resignerAddress = senderAddress
                resignReason = content.reason
            }
        }

        guard let invite, let inviterAddress else { return nil }
        let otherAddress = inviterAddress == myAddress ? contactAddress : myAddress
        let whiteAddress = invite.inviterColor == .white ? inviterAddress : otherAddress
        let blackAddress = invite.inviterColor == .white ? otherAddress : inviterAddress

        let status: ChessGameStatus
        if let resignerAddress {
            let loser: ChessColor = resignerAddress == whiteAddress ? .white : .black
            status = .resigned(loser: loser, timeout: resignReason == "timeout")
        } else if let response, !response.accepted {
            status = .declined
        } else if response == nil {
            status = .pendingResponse
        } else if ChessEngine.isCheckmate(board) {
            status = .checkmate(winner: board.sideToMove.opposite)
        } else if ChessEngine.isStalemate(board) {
            status = .stalemate
        } else if ChessEngine.isInsufficientMaterial(board) {
            // Checked after checkmate/stalemate: a position can be both mate and materially
            // dead only in the sense that mate already ended it, and mate wins over a draw.
            status = .insufficientMaterial
        } else {
            status = .inProgress
        }

        let viewerColor: ChessColor? = myAddress == whiteAddress ? .white : (myAddress == blackAddress ? .black : nil)

        var timeControl: ChessTimeControl?
        if let minutes = invite.tcMinutes, minutes > 0 {
            timeControl = ChessTimeControl(minutes: minutes, incSeconds: max(invite.tcIncSeconds ?? 0, 0))
        }

        return ChessGameSummary(
            gameId: gameId,
            status: status,
            board: board,
            whiteAddress: whiteAddress,
            blackAddress: blackAddress,
            lastMessageTxId: lastMessageTxId ?? "",
            viewerColor: viewerColor,
            moveHistory: moveHistory,
            timeControl: timeControl,
            whiteClockMs: timeControl.map { lastClockByColor[.white] ?? $0.initialMs },
            blackClockMs: timeControl.map { lastClockByColor[.black] ?? $0.initialMs }
        )
    }

    /// The contact's current active (not yet game-over) chess game, if any - scans for every
    /// distinct `gameId` invited in `messages` and returns the summary for whichever is still
    /// active. `startGame` enforces at most one active game per contact, so this should never find
    /// more than one candidate in practice; if older history somehow left more than one, the most
    /// recently invited game wins.
    static func activeGame(in messages: [ChatMessage], myAddress: String, contactAddress: String) -> ChessGameSummary? {
        let inviteMessages = messages
            .filter {
                if case .invite = ChessCodec.parseAny(MessageReplyCodec.unwrappedText($0.content)) { return true }
                return false
            }
            .sorted { $0.timestamp > $1.timestamp }

        var seenGameIds = Set<String>()
        for message in inviteMessages {
            guard let envelope = ChessCodec.parseAny(MessageReplyCodec.unwrappedText(message.content)) else { continue }
            guard seenGameIds.insert(envelope.gameId).inserted else { continue }
            if let summary = summarize(gameId: envelope.gameId, in: messages, myAddress: myAddress, contactAddress: contactAddress),
               !summary.status.isGameOver {
                return summary
            }
        }
        return nil
    }

    /// Cumulative decisive-outcome tally across every distinct chess game ever invited with this
    /// contact (not just the current one) - checkmate/resignation count as a win or loss for the
    /// local player; stalemate/declined/pending/in-progress games don't count either way. Used by
    /// `ChessGameView`'s W/L counter and `ChatInfoView`'s "Chess Stats" row.
    static func record(in messages: [ChatMessage], myAddress: String, contactAddress: String) -> (wins: Int, losses: Int) {
        let inviteMessages = messages.filter {
            if case .invite = ChessCodec.parseAny(MessageReplyCodec.unwrappedText($0.content)) { return true }
            return false
        }

        var seenGameIds = Set<String>()
        var wins = 0
        var losses = 0
        for message in inviteMessages {
            guard let envelope = ChessCodec.parseAny(MessageReplyCodec.unwrappedText(message.content)) else { continue }
            guard seenGameIds.insert(envelope.gameId).inserted else { continue }
            guard let summary = summarize(gameId: envelope.gameId, in: messages, myAddress: myAddress, contactAddress: contactAddress),
                  let myColor = summary.color(for: myAddress) else { continue }
            switch summary.status {
            case .checkmate(let winner):
                if winner == myColor { wins += 1 } else { losses += 1 }
            case .resigned(let loser, _):
                if loser == myColor { losses += 1 } else { wins += 1 }
            case .pendingResponse, .declined, .inProgress, .stalemate, .insufficientMaterial:
                break
            }
        }
        return (wins, losses)
    }

    /// True if `message` is any chess envelope and no *later* message in `messages` shares its
    /// `gameId` - i.e. this is the current/latest state for that game, which is the only one that
    /// should render as the live status card (earlier moves render as a compact log line instead,
    /// so a long game doesn't repeat a full board on every message).
    static func isLatestChessMessage(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard let envelope = ChessCodec.parseAny(MessageReplyCodec.unwrappedText(message.content)) else { return false }
        return !messages.contains { other in
            other.timestamp > message.timestamp
                && ChessCodec.parseAny(MessageReplyCodec.unwrappedText(other.content))?.gameId == envelope.gameId
        }
    }

    // MARK: - Sending actions

    static func startGame(with contact: Contact, timeControl: ChessTimeControl? = nil) async throws {
        let gameId = UUID().uuidString
        let content = ChessInviteContent(
            gameId: gameId,
            inviterColor: Bool.random() ? .white : .black,
            tcMinutes: timeControl?.minutes,
            tcIncSeconds: timeControl?.incSeconds
        )
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }

    static func respond(gameId: String, accepted: Bool, to contact: Contact) async throws {
        let content = ChessResponseContent(gameId: gameId, accepted: accepted)
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }

    static func sendMove(_ move: ChessMove, gameId: String, clockMs: Int64? = nil, to contact: Contact) async throws {
        let content = ChessMoveContent(
            gameId: gameId,
            from: move.from.algebraic,
            to: move.to.algebraic,
            promotion: move.promotion?.promotionLetter,
            clockMs: clockMs
        )
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }

    static func resign(gameId: String, reason: String? = nil, to contact: Contact) async throws {
        let content = ChessResignContent(gameId: gameId, reason: reason)
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }
}

// MARK: - Clock persistence

/// Persists the local player's accumulated at-the-board thinking time for their CURRENT turn of
/// a timed game, so a force-quit mid-think doesn't hand the time back. Timed-chess clocks here
/// are deliberately casual: a side's clock only runs while the board is open on their device AND
/// it is their turn (the opponent may be offline for hours - the clock measures thinking time at
/// the board, not wall time). The record is keyed to the move count it applies to; the moment
/// either side's move lands, the stored move count no longer matches and the elapsed time
/// implicitly resets to zero for the new turn.
enum ChessClockStore {
    private static func key(_ gameId: String) -> String { "chess_clock_\(gameId)" }

    /// Accumulated open-board thinking milliseconds for the turn identified by `moveCount`
    /// (number of moves applied when this turn started). 0 if the stored record belongs to an
    /// earlier turn or doesn't exist.
    static func elapsedMs(gameId: String, moveCount: Int) -> Int64 {
        guard let record = UserDefaults.standard.dictionary(forKey: key(gameId)),
              record["moveCount"] as? Int == moveCount,
              let ms = (record["elapsedMs"] as? NSNumber)?.int64Value else {
            return 0
        }
        return max(ms, 0)
    }

    static func setElapsedMs(_ ms: Int64, gameId: String, moveCount: Int) {
        UserDefaults.standard.set(
            ["moveCount": moveCount, "elapsedMs": NSNumber(value: max(ms, 0))],
            forKey: key(gameId)
        )
    }

    /// Drops the record entirely - called once a game is over so finished games leave nothing
    /// behind in UserDefaults.
    static func clear(gameId: String) {
        UserDefaults.standard.removeObject(forKey: key(gameId))
    }
}
