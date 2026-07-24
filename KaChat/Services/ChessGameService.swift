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
enum ChessGameStatus: Equatable {
    case pendingResponse
    case declined
    case inProgress
    case checkmate(winner: ChessColor)
    case stalemate
    case resigned(loser: ChessColor)

    var isGameOver: Bool {
        switch self {
        case .pendingResponse, .inProgress: return false
        case .declined, .checkmate, .stalemate, .resigned: return true
        }
    }
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
        case .resigned(let loser):
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
        var lastMessageTxId: String?

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
                guard ChessEngine.isLegal(move, in: board) else { continue }
                board = ChessEngine.apply(move, to: board)
            case .resign:
                resignerAddress = senderAddress
            }
        }

        guard let invite, let inviterAddress else { return nil }
        let otherAddress = inviterAddress == myAddress ? contactAddress : myAddress
        let whiteAddress = invite.inviterColor == .white ? inviterAddress : otherAddress
        let blackAddress = invite.inviterColor == .white ? otherAddress : inviterAddress

        let status: ChessGameStatus
        if let resignerAddress {
            let loser: ChessColor = resignerAddress == whiteAddress ? .white : .black
            status = .resigned(loser: loser)
        } else if let response, !response.accepted {
            status = .declined
        } else if response == nil {
            status = .pendingResponse
        } else if ChessEngine.isCheckmate(board) {
            status = .checkmate(winner: board.sideToMove.opposite)
        } else if ChessEngine.isStalemate(board) {
            status = .stalemate
        } else {
            status = .inProgress
        }

        let viewerColor: ChessColor? = myAddress == whiteAddress ? .white : (myAddress == blackAddress ? .black : nil)

        return ChessGameSummary(
            gameId: gameId,
            status: status,
            board: board,
            whiteAddress: whiteAddress,
            blackAddress: blackAddress,
            lastMessageTxId: lastMessageTxId ?? "",
            viewerColor: viewerColor
        )
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

    static func startGame(with contact: Contact) async throws {
        let gameId = UUID().uuidString
        let content = ChessInviteContent(gameId: gameId, inviterColor: Bool.random() ? .white : .black)
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }

    static func respond(gameId: String, accepted: Bool, to contact: Contact) async throws {
        let content = ChessResponseContent(gameId: gameId, accepted: accepted)
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }

    static func sendMove(_ move: ChessMove, gameId: String, to contact: Contact) async throws {
        let content = ChessMoveContent(
            gameId: gameId,
            from: move.from.algebraic,
            to: move.to.algebraic,
            promotion: move.promotion?.promotionLetter
        )
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }

    static func resign(gameId: String, to contact: Contact) async throws {
        let content = ChessResignContent(gameId: gameId)
        try await ChatService.shared.sendMessage(to: contact, content: ChessCodec.encode(content))
    }
}
