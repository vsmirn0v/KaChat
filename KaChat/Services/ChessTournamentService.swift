import Foundation
import Combine
import UIKit

/// Chess tournaments (CHESS_TOURNAMENTS.md): the `#chess-arena` room read through
/// `BroadcastService`, reduced by `ChessTournamentEngine` into the bracket every phone agrees
/// on, and the actions a player can take - each one a broadcast transaction.
@MainActor
final class ChessTournamentService: ObservableObject {
    static let shared = ChessTournamentService()

    @Published private(set) var tournaments: [String: ChessTournament] = [:]
    @Published private(set) var leaderboard: [ChessLeaderboardRow] = []
    /// Chain time as this phone estimates it: wall clock, for running clocks between blocks.
    @Published private(set) var now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    @Published var lastError: String?
    /// Moves sent and not yet seen back from the chain, so the board shows them at once and
    /// the player cannot double-send.
    @Published private(set) var pendingMoveGames: Set<String> = []

    private var cancellables = Set<AnyCancellable>()
    private var clockTask: Task<Void, Never>?
    private var refCount = 0
    private var arenaJoined = false
    /// Claims already posted for a game - one is enough; the chain confirms it.
    private var claimedGames: Set<String> = []
    private var lastReducedRowCount = -1

    private init() {
        BroadcastService.shared.$messagesByChannel
            .map { $0[ChessTournamentCodec.arenaChannel] ?? [] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] rows in self?.reduce(rows) }
            .store(in: &cancellables)
    }

    var myAddress: String? { WalletManager.shared.currentWallet?.publicAddress }

    // MARK: - Watching the arena

    /// A chess screen came on: keep the arena scanned and polled while any is up.
    func acquire() {
        refCount += 1
        guard refCount == 1 else { return }
        let broadcast = BroadcastService.shared
        if !arenaJoined, !broadcast.channels.contains(where: { $0.channelName == ChessTournamentCodec.arenaChannel }) {
            broadcast.joinChannel(ChessTournamentCodec.arenaChannel)
        }
        arenaJoined = true
        broadcast.acquire(ChessTournamentCodec.arenaChannel)
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.now = Int64(Date().timeIntervalSince1970 * 1000)
                self.claimTimeoutsIfDue()
            }
        }
    }

    func release() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        BroadcastService.shared.release(ChessTournamentCodec.arenaChannel)
        clockTask?.cancel()
        clockTask = nil
    }

    private func reduce(_ rows: [BroadcastMessage]) {
        guard rows.count != lastReducedRowCount || tournaments.isEmpty else { return }
        lastReducedRowCount = rows.count
        let events: [ChessArenaEvent] = rows.compactMap { row in
            guard row.deliveryStatus == .sent, !row.id.hasPrefix("pending_"),
                  let message = ChessTournamentCodec.decode(row.content) else { return nil }
            return ChessArenaEvent(txId: row.id, sender: row.senderAddress, blockTime: row.blockTime, message: message)
        }
        let reduced = ChessTournamentEngine.reduce(events)
        tournaments = reduced
        leaderboard = ChessTournamentEngine.leaderboard(from: Array(reduced.values))
        // A move of ours that the chain now shows is no longer pending.
        let mine = myAddress
        pendingMoveGames = pendingMoveGames.filter { key in
            guard let (tid, gid) = Self.split(key), let game = reduced[tid]?.games[gid] else { return true }
            return game.playerToMove == mine && !game.isOver
        }
    }

    private static func split(_ key: String) -> (String, String)? {
        guard let range = key.range(of: "|") else { return nil }
        return (String(key[..<range.lowerBound]), String(key[range.upperBound...]))
    }

    // MARK: - Lists

    var openTournaments: [ChessTournament] {
        tournaments.values.filter { $0.status == .open }.sorted { $0.createdAt > $1.createdAt }
    }
    var liveTournaments: [ChessTournament] {
        tournaments.values.filter { $0.status == .live }.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }
    var finishedTournaments: [ChessTournament] {
        tournaments.values.filter { $0.status == .finished }.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }

    /// The tournament this player is in that is not over, if any.
    var myActiveTournament: ChessTournament? {
        guard let me = myAddress else { return nil }
        return tournaments.values
            .filter { ($0.status == .open || $0.status == .live) && $0.players.contains(me) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    // MARK: - Actions (each one a broadcast transaction)

    func createTournament(named name: String) async -> String? {
        let id = UUID().uuidString.lowercased()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await send(ChessTournamentCodec.create(id: id, name: clean.isEmpty ? "Tournament" : clean)) else { return nil }
        return id
    }

    func join(_ tournament: ChessTournament) async {
        guard let me = myAddress, !tournament.players.contains(me), tournament.status == .open else { return }
        _ = await send(ChessTournamentCodec.join(id: tournament.id))
    }

    func cancel(_ tournament: ChessTournament) async {
        guard tournament.creator == myAddress, tournament.status == .open else { return }
        _ = await send(ChessTournamentCodec.cancel(id: tournament.id))
    }

    /// Plays a move if it is ours to make and legal; the board shows it as pending until the
    /// chain returns it.
    func play(_ move: ChessMove, in tournament: ChessTournament, game: ChessTournamentGame) async {
        guard let me = myAddress, game.playerToMove == me, !game.isOver,
              !pendingMoveGames.contains("\(tournament.id)|\(game.id)"),
              ChessEngine.isLegal(move, in: game.board) else { return }
        let normalized = ChessEngine.normalizingPromotion(move, in: game.board)
        pendingMoveGames.insert("\(tournament.id)|\(game.id)")
        let sent = await send(ChessTournamentCodec.move(
            id: tournament.id, game: game.id, ply: game.moves.count + 1,
            from: normalized.from.algebraic, to: normalized.to.algebraic,
            promotion: normalized.promotion?.promotionLetter
        ))
        if !sent { pendingMoveGames.remove("\(tournament.id)|\(game.id)") }
    }

    func resign(_ tournament: ChessTournament, game: ChessTournamentGame) async {
        guard let me = myAddress, game.color(of: me) != nil, !game.isOver else { return }
        _ = await send(ChessTournamentCodec.resign(id: tournament.id, game: game.id))
    }

    func sendChat(_ text: String, tournament: ChessTournament, game: ChessTournamentGame?) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        _ = await send(ChessTournamentCodec.chat(id: tournament.id, game: game?.id, text: clean))
    }

    /// The opponent flagged in one of our games: post the claim (once). Runs on every tick.
    private func claimTimeoutsIfDue() {
        guard let me = myAddress else { return }
        for tournament in tournaments.values where tournament.status == .live {
            for game in tournament.games.values where !game.isOver {
                guard let mine = game.color(of: me), game.sideToMove != mine else { continue }
                let key = "\(tournament.id)|\(game.id)"
                guard !claimedGames.contains(key) else { continue }
                // A second's margin past zero, so the claim's block time is safely after.
                guard game.remainingMs(game.sideToMove, at: now - 1_500) == 0 else { continue }
                claimedGames.insert(key)
                Task { _ = await self.send(ChessTournamentCodec.claim(id: tournament.id, game: game.id)) }
            }
        }
    }

    /// One broadcast transaction, with the retries a fast sequence of sends needs: the change
    /// of the previous transaction is not spendable until it is mined, so a move sent within a
    /// second of the last one can hit "no spendable UTXO" - the same retry KaPosts threads use.
    private func send(_ message: ChessTournamentMessage) async -> Bool {
        let content = ChessTournamentCodec.encode(message)
        var attempt = 0
        while true {
            do {
                try await BroadcastService.shared.sendBroadcast(channel: ChessTournamentCodec.arenaChannel, content: content)
                lastError = nil
                return true
            } catch {
                attempt += 1
                if attempt > 5 {
                    lastError = error.localizedDescription
                    AppLog.log("[Chess] Send failed after retries: %@", error.localizedDescription)
                    return false
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}
