import Foundation

/// Pure, UI-free chess rules engine backing the "Play Chess" 1:1 chat feature. No external
/// dependencies (see ChessGameService's doc comment for why - adding a real chess library isn't
/// safely scriptable for the iOS target here). Board state is never persisted directly; it's
/// always re-derived by replaying a game's move messages through this engine (see
/// ChessGameService.summarize).
enum ChessColor: String, Codable, Equatable {
    case white
    case black

    var opposite: ChessColor { self == .white ? .black : .white }
}

enum ChessPieceType: String, Codable, Equatable {
    case pawn, knight, bishop, rook, queen, king

    /// Single-letter wire notation for promotion (`"q"`, `"r"`, `"b"`, `"n"`) - pawn/king never
    /// appear here since only those four types are ever promoted to.
    var promotionLetter: String? {
        switch self {
        case .queen: return "q"
        case .rook: return "r"
        case .bishop: return "b"
        case .knight: return "n"
        case .pawn, .king: return nil
        }
    }

    static func fromPromotionLetter(_ letter: String?) -> ChessPieceType? {
        switch letter?.lowercased() {
        case "q": return .queen
        case "r": return .rook
        case "b": return .bishop
        case "n": return .knight
        default: return nil
        }
    }
}

struct ChessPiece: Equatable {
    let type: ChessPieceType
    let color: ChessColor

    /// Unicode chess glyph - used by both the in-chat board thumbnail and the full-screen board,
    /// so neither needs bundled piece image assets. Deliberately always uses the solid/filled
    /// "black" code points (U+265A-265F) regardless of `color` - the "white" code points
    /// (U+2654-2659) are outline-only glyphs with almost no solid area, so filling them white
    /// (see ChessPieceGlyphView.fillColor) against a light board square looked nearly invisible.
    /// Color is conveyed entirely by the fill/outline trick below, not by which glyph is used.
    ///
    /// The trailing U+FE0E (text presentation selector) on the pawn matters: Apple's system font
    /// has a special colored glyph for the bare pawn character (unlike the other five chess
    /// symbols, which stay plain outline/solid text glyphs), so without it every pawn - both
    /// colors, and every captured pawn in the captured-pieces tray - rendered with that same
    /// fixed color regardless of `fillColor`/`outlineColor` below, ignoring `piece.color` entirely.
    /// VS15 forces the plain text glyph, which does respect the applied text color.
    var glyph: String {
        switch type {
        case .king: return "♚"
        case .queen: return "♛"
        case .rook: return "♜"
        case .bishop: return "♝"
        case .knight: return "♞"
        case .pawn: return "♟\u{FE0E}"
        }
    }
}

/// 0-indexed file (a=0...h=7) and rank (1=0...8=7).
struct ChessSquare: Equatable, Hashable {
    let file: Int
    let rank: Int

    var isValid: Bool { file >= 0 && file <= 7 && rank >= 0 && rank <= 7 }

    /// Algebraic notation, e.g. "e4".
    var algebraic: String {
        let fileChar = Character(UnicodeScalar(97 + file)!)
        return "\(fileChar)\(rank + 1)"
    }

    init(file: Int, rank: Int) {
        self.file = file
        self.rank = rank
    }

    init?(algebraic: String) {
        let chars = Array(algebraic.lowercased())
        guard chars.count == 2,
              let fileAscii = chars[0].asciiValue, fileAscii >= 97, fileAscii <= 104,
              let rankDigit = chars[1].wholeNumberValue, rankDigit >= 1, rankDigit <= 8 else {
            return nil
        }
        self.file = Int(fileAscii) - 97
        self.rank = rankDigit - 1
    }
}

struct ChessMove: Equatable, Identifiable {
    let from: ChessSquare
    let to: ChessSquare
    /// Non-nil only for a pawn move landing on the back rank. `legalMoves` always generates all
    /// four options for such a move; a wire move with promotion omitted is treated as queen (see
    /// `ChessMove.normalizingPromotion`).
    let promotion: ChessPieceType?

    /// Lets a pending promotion choice drive `.sheet(item:)` directly.
    var id: String { "\(from.algebraic)-\(to.algebraic)-\(promotion?.rawValue ?? "")" }
}

struct ChessBoard {
    /// squares[rank][file], rank 0 = rank "1".
    var squares: [[ChessPiece?]]
    var sideToMove: ChessColor
    var whiteCanCastleKingside: Bool
    var whiteCanCastleQueenside: Bool
    var blackCanCastleKingside: Bool
    var blackCanCastleQueenside: Bool
    /// The square a pawn skipped over on its most recent double-push, capturable en passant this
    /// ply only - cleared on every move that isn't itself a qualifying double push.
    var enPassantTarget: ChessSquare?

    func piece(at square: ChessSquare) -> ChessPiece? {
        guard square.isValid else { return nil }
        return squares[square.rank][square.file]
    }

    mutating func setPiece(_ piece: ChessPiece?, at square: ChessSquare) {
        squares[square.rank][square.file] = piece
    }

    func canCastleKingside(_ color: ChessColor) -> Bool {
        color == .white ? whiteCanCastleKingside : blackCanCastleKingside
    }

    func canCastleQueenside(_ color: ChessColor) -> Bool {
        color == .white ? whiteCanCastleQueenside : blackCanCastleQueenside
    }

    mutating func setCanCastleKingside(_ value: Bool, for color: ChessColor) {
        if color == .white { whiteCanCastleKingside = value } else { blackCanCastleKingside = value }
    }

    mutating func setCanCastleQueenside(_ value: Bool, for color: ChessColor) {
        if color == .white { whiteCanCastleQueenside = value } else { blackCanCastleQueenside = value }
    }
}

enum ChessEngine {
    static func initialBoard() -> ChessBoard {
        var squares: [[ChessPiece?]] = Array(repeating: Array(repeating: nil, count: 8), count: 8)
        let backRank: [ChessPieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for file in 0..<8 {
            squares[0][file] = ChessPiece(type: backRank[file], color: .white)
            squares[1][file] = ChessPiece(type: .pawn, color: .white)
            squares[6][file] = ChessPiece(type: .pawn, color: .black)
            squares[7][file] = ChessPiece(type: backRank[file], color: .black)
        }
        return ChessBoard(
            squares: squares,
            sideToMove: .white,
            whiteCanCastleKingside: true,
            whiteCanCastleQueenside: true,
            blackCanCastleKingside: true,
            blackCanCastleQueenside: true,
            enPassantTarget: nil
        )
    }

    // MARK: - Move generation

    /// Every legal move for the side to move - pseudo-legal moves filtered to exclude any that
    /// leave the mover's own king in check.
    static func legalMoves(for board: ChessBoard) -> [ChessMove] {
        var moves: [ChessMove] = []
        for rank in 0..<8 {
            for file in 0..<8 {
                let square = ChessSquare(file: file, rank: rank)
                guard let piece = board.piece(at: square), piece.color == board.sideToMove else { continue }
                moves.append(contentsOf: pseudoLegalMoves(for: piece, at: square, board: board))
            }
        }
        return moves.filter { move in
            let resulting = apply(move, to: board)
            return !isKingInCheck(color: board.sideToMove, board: resulting)
        }
    }

    static func legalMoves(from square: ChessSquare, board: ChessBoard) -> [ChessMove] {
        legalMoves(for: board).filter { $0.from == square }
    }

    static func isLegal(_ move: ChessMove, in board: ChessBoard) -> Bool {
        legalMoves(for: board).contains(normalizingPromotion(move, in: board))
    }

    /// A wire move with `promotion == nil` reaching the back rank defaults to queen - matches the
    /// engine's own generated move list, which always includes an explicit queen-promotion
    /// variant for such a move.
    static func normalizingPromotion(_ move: ChessMove, in board: ChessBoard) -> ChessMove {
        guard move.promotion == nil, let piece = board.piece(at: move.from), piece.type == .pawn else {
            return move
        }
        let backRank = piece.color == .white ? 7 : 0
        guard move.to.rank == backRank else { return move }
        return ChessMove(from: move.from, to: move.to, promotion: .queen)
    }

    static func isKingInCheck(color: ChessColor, board: ChessBoard) -> Bool {
        guard let kingSquare = findKing(color: color, board: board) else { return false }
        return isSquareAttacked(kingSquare, by: color.opposite, board: board)
    }

    static func isCheckmate(_ board: ChessBoard) -> Bool {
        isKingInCheck(color: board.sideToMove, board: board) && legalMoves(for: board).isEmpty
    }

    static func isStalemate(_ board: ChessBoard) -> Bool {
        !isKingInCheck(color: board.sideToMove, board: board) && legalMoves(for: board).isEmpty
    }

    private static func findKing(color: ChessColor, board: ChessBoard) -> ChessSquare? {
        for rank in 0..<8 {
            for file in 0..<8 {
                let square = ChessSquare(file: file, rank: rank)
                if let piece = board.piece(at: square), piece.type == .king, piece.color == color {
                    return square
                }
            }
        }
        return nil
    }

    /// True if any `color` piece currently attacks `square` - used for check detection and for
    /// castling's "king may not pass through or land on an attacked square" rule. Deliberately
    /// separate from move generation for pawns (a pawn attacks diagonally regardless of whether
    /// that square is occupied, but only ever *moves* straight into an empty square).
    static func isSquareAttacked(_ square: ChessSquare, by color: ChessColor, board: ChessBoard) -> Bool {
        // Pawns
        let pawnRankOffset = color == .white ? -1 : 1
        for fileOffset in [-1, 1] {
            let from = ChessSquare(file: square.file + fileOffset, rank: square.rank + pawnRankOffset)
            if let piece = board.piece(at: from), piece.type == .pawn, piece.color == color {
                return true
            }
        }
        // Knights
        for (df, dr) in knightOffsets {
            let from = ChessSquare(file: square.file + df, rank: square.rank + dr)
            if let piece = board.piece(at: from), piece.type == .knight, piece.color == color {
                return true
            }
        }
        // King
        for (df, dr) in kingOffsets {
            let from = ChessSquare(file: square.file + df, rank: square.rank + dr)
            if let piece = board.piece(at: from), piece.type == .king, piece.color == color {
                return true
            }
        }
        // Sliding pieces (bishop/rook/queen)
        for (df, dr) in diagonalDirections {
            if slidingAttacker(from: square, direction: (df, dr), board: board, color: color, types: [.bishop, .queen]) {
                return true
            }
        }
        for (df, dr) in straightDirections {
            if slidingAttacker(from: square, direction: (df, dr), board: board, color: color, types: [.rook, .queen]) {
                return true
            }
        }
        return false
    }

    private static func slidingAttacker(
        from square: ChessSquare,
        direction: (Int, Int),
        board: ChessBoard,
        color: ChessColor,
        types: Set<ChessPieceType>
    ) -> Bool {
        var current = ChessSquare(file: square.file + direction.0, rank: square.rank + direction.1)
        while current.isValid {
            if let piece = board.piece(at: current) {
                return piece.color == color && types.contains(piece.type)
            }
            current = ChessSquare(file: current.file + direction.0, rank: current.rank + direction.1)
        }
        return false
    }

    private static let knightOffsets: [(Int, Int)] = [
        (1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)
    ]
    private static let kingOffsets: [(Int, Int)] = [
        (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)
    ]
    private static let diagonalDirections: [(Int, Int)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    private static let straightDirections: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    // MARK: - Pseudo-legal move generation (per piece, ignoring own-king-safety)

    private static func pseudoLegalMoves(for piece: ChessPiece, at square: ChessSquare, board: ChessBoard) -> [ChessMove] {
        switch piece.type {
        case .pawn: return pawnMoves(color: piece.color, at: square, board: board)
        case .knight: return steppingMoves(offsets: knightOffsets, color: piece.color, at: square, board: board)
        case .bishop: return slidingMoves(directions: diagonalDirections, color: piece.color, at: square, board: board)
        case .rook: return slidingMoves(directions: straightDirections, color: piece.color, at: square, board: board)
        case .queen: return slidingMoves(directions: diagonalDirections + straightDirections, color: piece.color, at: square, board: board)
        case .king: return kingMoves(color: piece.color, at: square, board: board)
        }
    }

    private static func pawnMoves(color: ChessColor, at square: ChessSquare, board: ChessBoard) -> [ChessMove] {
        var moves: [ChessMove] = []
        let direction = color == .white ? 1 : -1
        let startRank = color == .white ? 1 : 6
        let backRank = color == .white ? 7 : 0

        func addMove(to: ChessSquare) {
            guard to.isValid else { return }
            if to.rank == backRank {
                for promo: ChessPieceType in [.queen, .rook, .bishop, .knight] {
                    moves.append(ChessMove(from: square, to: to, promotion: promo))
                }
            } else {
                moves.append(ChessMove(from: square, to: to, promotion: nil))
            }
        }

        let singlePush = ChessSquare(file: square.file, rank: square.rank + direction)
        if singlePush.isValid, board.piece(at: singlePush) == nil {
            addMove(to: singlePush)
            let doublePush = ChessSquare(file: square.file, rank: square.rank + direction * 2)
            if square.rank == startRank, board.piece(at: doublePush) == nil {
                moves.append(ChessMove(from: square, to: doublePush, promotion: nil))
            }
        }

        for fileOffset in [-1, 1] {
            let target = ChessSquare(file: square.file + fileOffset, rank: square.rank + direction)
            guard target.isValid else { continue }
            if let occupant = board.piece(at: target), occupant.color != color {
                addMove(to: target)
            } else if target == board.enPassantTarget {
                moves.append(ChessMove(from: square, to: target, promotion: nil))
            }
        }
        return moves
    }

    private static func steppingMoves(offsets: [(Int, Int)], color: ChessColor, at square: ChessSquare, board: ChessBoard) -> [ChessMove] {
        var moves: [ChessMove] = []
        for (df, dr) in offsets {
            let target = ChessSquare(file: square.file + df, rank: square.rank + dr)
            guard target.isValid else { continue }
            if let occupant = board.piece(at: target), occupant.color == color { continue }
            moves.append(ChessMove(from: square, to: target, promotion: nil))
        }
        return moves
    }

    private static func slidingMoves(directions: [(Int, Int)], color: ChessColor, at square: ChessSquare, board: ChessBoard) -> [ChessMove] {
        var moves: [ChessMove] = []
        for (df, dr) in directions {
            var target = ChessSquare(file: square.file + df, rank: square.rank + dr)
            while target.isValid {
                if let occupant = board.piece(at: target) {
                    if occupant.color != color {
                        moves.append(ChessMove(from: square, to: target, promotion: nil))
                    }
                    break
                }
                moves.append(ChessMove(from: square, to: target, promotion: nil))
                target = ChessSquare(file: target.file + df, rank: target.rank + dr)
            }
        }
        return moves
    }

    private static func kingMoves(color: ChessColor, at square: ChessSquare, board: ChessBoard) -> [ChessMove] {
        var moves = steppingMoves(offsets: kingOffsets, color: color, at: square, board: board)

        // Castling: king/rook still have rights, in-between squares empty, king not currently in
        // check and doesn't pass through or land on an attacked square.
        guard !isSquareAttacked(square, by: color.opposite, board: board) else { return moves }
        let rank = color == .white ? 0 : 7

        if board.canCastleKingside(color),
           board.piece(at: ChessSquare(file: 5, rank: rank)) == nil,
           board.piece(at: ChessSquare(file: 6, rank: rank)) == nil,
           !isSquareAttacked(ChessSquare(file: 5, rank: rank), by: color.opposite, board: board),
           !isSquareAttacked(ChessSquare(file: 6, rank: rank), by: color.opposite, board: board) {
            moves.append(ChessMove(from: square, to: ChessSquare(file: 6, rank: rank), promotion: nil))
        }
        if board.canCastleQueenside(color),
           board.piece(at: ChessSquare(file: 3, rank: rank)) == nil,
           board.piece(at: ChessSquare(file: 2, rank: rank)) == nil,
           board.piece(at: ChessSquare(file: 1, rank: rank)) == nil,
           !isSquareAttacked(ChessSquare(file: 3, rank: rank), by: color.opposite, board: board),
           !isSquareAttacked(ChessSquare(file: 2, rank: rank), by: color.opposite, board: board) {
            moves.append(ChessMove(from: square, to: ChessSquare(file: 2, rank: rank), promotion: nil))
        }
        return moves
    }

    // MARK: - Applying a move

    /// Mechanically performs `move` (assumed to be at least pseudo-legal - `legalMoves` is the
    /// gate that should be checked before calling this for a real game action). Handles capture,
    /// en passant capture, castling (moves the rook too), promotion, and updates castling
    /// rights/en passant target/side to move.
    static func apply(_ move: ChessMove, to board: ChessBoard) -> ChessBoard {
        var result = board
        guard let piece = result.piece(at: move.from) else { return result }

        let isEnPassantCapture = piece.type == .pawn && move.to == board.enPassantTarget && result.piece(at: move.to) == nil
        let isCastle = piece.type == .king && abs(move.to.file - move.from.file) == 2

        result.setPiece(nil, at: move.from)
        let movedPiece = ChessPiece(type: move.promotion ?? piece.type, color: piece.color)
        result.setPiece(movedPiece, at: move.to)

        if isEnPassantCapture {
            let capturedPawnSquare = ChessSquare(file: move.to.file, rank: move.from.rank)
            result.setPiece(nil, at: capturedPawnSquare)
        }

        if isCastle {
            let rank = move.from.rank
            if move.to.file == 6 {
                result.setPiece(nil, at: ChessSquare(file: 7, rank: rank))
                result.setPiece(ChessPiece(type: .rook, color: piece.color), at: ChessSquare(file: 5, rank: rank))
            } else {
                result.setPiece(nil, at: ChessSquare(file: 0, rank: rank))
                result.setPiece(ChessPiece(type: .rook, color: piece.color), at: ChessSquare(file: 3, rank: rank))
            }
        }

        // Castling rights: moving the king revokes both; moving a rook (or having it captured)
        // from its original corner revokes that side.
        if piece.type == .king {
            result.setCanCastleKingside(false, for: piece.color)
            result.setCanCastleQueenside(false, for: piece.color)
        }
        revokeCastlingRightIfCornerTouched(move.from, board: &result)
        revokeCastlingRightIfCornerTouched(move.to, board: &result)

        // En passant target: only set immediately after a qualifying pawn double push.
        if piece.type == .pawn, abs(move.to.rank - move.from.rank) == 2 {
            result.enPassantTarget = ChessSquare(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
        } else {
            result.enPassantTarget = nil
        }

        result.sideToMove = board.sideToMove.opposite
        return result
    }

    private static func revokeCastlingRightIfCornerTouched(_ square: ChessSquare, board: inout ChessBoard) {
        switch (square.file, square.rank) {
        case (0, 0): board.whiteCanCastleQueenside = false
        case (7, 0): board.whiteCanCastleKingside = false
        case (0, 7): board.blackCanCastleQueenside = false
        case (7, 7): board.blackCanCastleKingside = false
        default: break
        }
    }
}
