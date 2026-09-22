import Foundation
import CryptoKit

// MARK: - Wire protocol (CHESS_TOURNAMENTS.md §2)

/// One tournament message as it travels in the `#chess-arena` broadcast channel. Every field
/// is optional on the wire except `type`/`v`/`t`/`a`; `decode` returns nil for anything that is
/// not a well-formed tournament message, so the arena can carry other content harmlessly.
struct ChessTournamentMessage: Codable, Equatable {
    var type: String = "chess_t"
    var v: Int = 1
    /// Tournament id: a lowercase UUID chosen by the creator.
    let t: String
    /// Action: create, join, cancel, move, resign, claim, chat.
    let a: String
    var name: String? = nil
    /// Game id "<round>-<index>", e.g. "1-0"; "" (or absent) for tournament-level chat.
    var g: String? = nil
    /// Ply number of a move (1 = white's first move).
    var n: Int? = nil
    var from: String? = nil
    var to: String? = nil
    /// Promotion piece letter: q r b n.
    var promo: String? = nil
    var text: String? = nil
    /// Private tournaments only: proof the creator holds the creator code (§2.1).
    var k: String? = nil
    /// `create` only: how many players - 2 (a 1v1) or 8 (a tournament). Absent = 8.
    var p: Int? = nil
}

enum ChessTournamentCodec {
    static let arenaChannel = "chess-arena"
    static let playerCount = 8
    static let clockMs: Int64 = 5 * 60 * 1000
    /// A seat in a waiting room lasts this long: if the room has not filled by then, the seat
    /// expires and the player is out of the queue - with the app closed, on a walk, whatever.
    static let seatTTLMs: Int64 = 5 * 60 * 1000
    static let nameMaxLength = 40
    static let chatMaxLength = 280

    // MARK: Public rooms and private tournaments (CHESS_TOURNAMENTS.md §2.1)

    /// Public rooms are numbered: `public-1`, `public-2`, ... One is open at a time; a join to
    /// room N is accepted only when room N-1 is full, so the queue never forks. Nobody creates
    /// them - the first join is the creation.
    static let publicIdPrefix = "public-"
    /// Public 1v1 rooms: the same queue, two seats: `duel-1`, `duel-2`, ...
    static let duelIdPrefix = "duel-"
    static func publicId(_ number: Int) -> String { "\(publicIdPrefix)\(number)" }
    static func duelId(_ number: Int) -> String { "\(duelIdPrefix)\(number)" }
    static func publicNumber(of id: String) -> Int? { number(of: id, prefix: publicIdPrefix) }
    static func duelNumber(of id: String) -> Int? { number(of: id, prefix: duelIdPrefix) }
    private static func number(of id: String, prefix: String) -> Int? {
        guard id.hasPrefix(prefix), let n = Int(id.dropFirst(prefix.count)), n >= 1 else { return nil }
        return n
    }
    /// Public = a numbered room of either kind.
    static func isPublic(_ id: String) -> Bool { publicNumber(of: id) != nil || duelNumber(of: id) != nil }

    /// The creator code for private tournaments. Whoever has it can open a room for friends;
    /// the room's id is what they share to let people in. Change here (and in the other apps)
    /// to rotate it. The chain carries only `k` = SHA-256(code + id), so the code itself never
    /// appears on chain and a key from one tournament is no use for another.
    static let privateCreateCode = "KACHAT-CHESS"

    static func createKey(code: String, id: String) -> String {
        let digest = SHA256.hash(data: Data((code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() + ":" + id).utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
    static func isValidCreateKey(_ key: String?, id: String) -> Bool {
        guard let key else { return false }
        return key == createKey(code: privateCreateCode, id: id)
    }

    /// Private ids are short and shareable: eight lowercase letters and digits.
    static func newPrivateId() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    static func encode(_ message: ChessTournamentMessage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(message), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Cheap gate first (this runs over every arena row), then the decode.
    static func decode(_ content: String) -> ChessTournamentMessage? {
        guard content.count <= 2_048, content.hasPrefix("{"), content.contains("\"chess_t\"") else { return nil }
        guard let data = content.data(using: .utf8),
              let message = try? JSONDecoder().decode(ChessTournamentMessage.self, from: data),
              message.type == "chess_t", message.v == 1,
              !message.t.isEmpty, message.t.count <= 64 else { return nil }
        return message
    }

    static func create(id: String, name: String, code: String) -> ChessTournamentMessage {
        ChessTournamentMessage(t: id, a: "create", name: String(name.prefix(nameMaxLength)), k: createKey(code: code, id: id), p: playerCount)
    }
    /// A private 1v1 needs no creator code: anyone can open one for a friend.
    static func createDuel(id: String, name: String) -> ChessTournamentMessage {
        ChessTournamentMessage(t: id, a: "create", name: String(name.prefix(nameMaxLength)), p: 2)
    }
    static func join(id: String) -> ChessTournamentMessage { ChessTournamentMessage(t: id, a: "join") }
    static func leave(id: String) -> ChessTournamentMessage { ChessTournamentMessage(t: id, a: "leave") }
    static func cancel(id: String) -> ChessTournamentMessage { ChessTournamentMessage(t: id, a: "cancel") }
    static func move(id: String, game: String, ply: Int, from: String, to: String, promotion: String?) -> ChessTournamentMessage {
        ChessTournamentMessage(t: id, a: "move", g: game, n: ply, from: from, to: to, promo: promotion)
    }
    static func resign(id: String, game: String) -> ChessTournamentMessage { ChessTournamentMessage(t: id, a: "resign", g: game) }
    static func claim(id: String, game: String) -> ChessTournamentMessage { ChessTournamentMessage(t: id, a: "claim", g: game) }
    static func chat(id: String, game: String?, text: String) -> ChessTournamentMessage {
        ChessTournamentMessage(t: id, a: "chat", g: game ?? "", text: String(text.prefix(chatMaxLength)))
    }
}

// MARK: - Derived state (what every phone computes from the arena, CHESS_TOURNAMENTS.md §3-4)

/// The rules' input: one arena row, already known to be a tournament message.
struct ChessArenaEvent: Equatable {
    let txId: String
    let sender: String
    let blockTime: Int64
    let message: ChessTournamentMessage
}

struct ChessTournamentChatLine: Identifiable, Equatable {
    let id: String
    let sender: String
    let text: String
    let blockTime: Int64
    /// "" for the tournament lobby.
    let game: String
}

struct ChessTournamentGame: Identifiable, Equatable {
    enum Outcome: Equatable {
        case checkmate
        case resignation
        case timeout
        /// A draw on the board (stalemate, material, fifty moves, repetition), broken by clock.
        case drawTiebreak(String)
    }

    let id: String
    let round: Int
    let index: Int
    let white: String
    let black: String
    /// Block time the game started (the message that decided both players).
    let startedAt: Int64
    var board: ChessBoard
    var moves: [ChessTournamentMove]
    /// Clock consumed so far by each side, in chain time.
    var whiteUsedMs: Int64 = 0
    var blackUsedMs: Int64 = 0
    /// Block time of the last event (start or last move) - the side to move's clock runs from here.
    var lastEventAt: Int64
    var winner: String?
    var outcome: Outcome?
    /// Block time the game ended.
    var endedAt: Int64?
    /// Positions seen, for threefold repetition (a compact board key -> count).
    var positionCounts: [String: Int] = [:]
    var halfmoveClock = 0

    var isOver: Bool { winner != nil }
    var sideToMove: ChessColor { board.sideToMove }
    var playerToMove: String { sideToMove == .white ? white : black }

    func address(of color: ChessColor) -> String { color == .white ? white : black }
    func color(of address: String) -> ChessColor? {
        address == white ? .white : (address == black ? .black : nil)
    }

    func usedMs(_ color: ChessColor) -> Int64 { color == .white ? whiteUsedMs : blackUsedMs }

    /// Remaining clock for `color` at chain time `now` (or wall time, for display).
    func remainingMs(_ color: ChessColor, at now: Int64) -> Int64 {
        var used = usedMs(color)
        if !isOver, color == sideToMove {
            used += max(0, now - lastEventAt)
        }
        return max(0, ChessTournamentCodec.clockMs - used)
    }
}

struct ChessTournamentMove: Equatable, Identifiable {
    var id: String { txId }
    let txId: String
    let ply: Int
    let color: ChessColor
    let from: ChessSquare
    let to: ChessSquare
    let promotion: ChessPieceType?
    let pieceType: ChessPieceType
    let captured: ChessPieceType?
    let blockTime: Int64
    /// The mover's remaining clock after this move.
    let clockAfterMs: Int64
}

struct ChessTournament: Identifiable, Equatable {
    enum Status: Equatable { case open, live, finished, cancelled }

    let id: String
    let name: String
    let creator: String
    let createdAt: Int64
    let createTxId: String
    /// 2 for a 1v1, 8 for a tournament.
    let capacity: Int
    /// Seat order: index 0 is seed 1 (the creator).
    var players: [String] = []
    /// Block time each seated player took their seat (for seat expiry while waiting).
    var joinedAt: [String: Int64] = [:]
    var startedAt: Int64?
    var cancelled = false
    var games: [String: ChessTournamentGame] = [:]
    var chat: [ChessTournamentChatLine] = []
    /// White games per player so far, for colour assignment after round 1.
    var whiteCount: [String: Int] = [:]

    var isDuel: Bool { capacity == 2 }
    var rounds: Int { isDuel ? 1 : 3 }
    var finalGameId: String { "\(rounds)-0" }
    var status: Status {
        if cancelled { return .cancelled }
        if startedAt == nil { return .open }
        if let final = games[finalGameId], final.isOver { return .finished }
        return .live
    }
    var champion: String? { games[finalGameId]?.winner }
    var seatsLeft: Int { max(0, capacity - players.count) }

    /// The players whose seats are still good at `now` (chain or wall time): while a room
    /// waits, a seat older than `seatTTLMs` has expired. Once the room has started every
    /// player stays.
    func seatedPlayers(at now: Int64) -> [String] {
        guard status == .open else { return players }
        return players.filter { (joinedAt[$0] ?? createdAt) + ChessTournamentCodec.seatTTLMs > now }
    }
    func isSeated(_ address: String, at now: Int64) -> Bool { seatedPlayers(at: now).contains(address) }
    /// When `address`'s seat runs out, while waiting.
    func seatExpiry(of address: String) -> Int64? {
        guard status == .open, players.contains(address) else { return nil }
        return (joinedAt[address] ?? createdAt) + ChessTournamentCodec.seatTTLMs
    }
    var isPublic: Bool { ChessTournamentCodec.isPublic(id) }
    var isFull: Bool { players.count >= capacity }

    func seed(of address: String) -> Int? { players.firstIndex(of: address).map { $0 + 1 } }

    func game(_ round: Int, _ index: Int) -> ChessTournamentGame? { games["\(round)-\(index)"] }

    /// The games of a round, in bracket order.
    func games(inRound round: Int) -> [ChessTournamentGame] {
        let count = isDuel ? 1 : (round == 1 ? 4 : (round == 2 ? 2 : 1))
        return (0..<count).compactMap { games["\(round)-\($0)"] }
    }

    /// The game `address` is playing (or waiting to play) right now, if any.
    func currentGame(for address: String) -> ChessTournamentGame? {
        for round in [3, 2, 1] {
            if let game = games(inRound: round).first(where: { $0.white == address || $0.black == address }) {
                return game
            }
        }
        return nil
    }
}

/// A row of the leaderboard the phone computes from what it has read.
/// One player's record. Two boards read it: 1v1 (duel games, public and private) and
/// Tournaments (tournaments won, then the games inside them). `wins`/`losses` are the totals
/// over both, the figures the indexer's `/chess/leaderboard` serves.
struct ChessLeaderboardRow: Identifiable, Equatable {
    var id: String { address }
    let address: String
    var wins = 0
    var losses = 0
    /// 1v1 games (`duel-N` rooms and private 1v1s).
    var duelWins = 0
    var duelLosses = 0
    /// Games inside eight-player tournaments.
    var tournamentGameWins = 0
    var tournamentGameLosses = 0
    var tournamentsPlayed = 0
    var tournamentsWon = 0
    var lastPlayedAt: Int64 = 0
}
