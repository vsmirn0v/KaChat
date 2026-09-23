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
    /// Chat of ours not yet returned by the chain (`ChessPendingChatLine`), oldest first.
    @Published private(set) var pendingChat: [ChessPendingChatLine] = []

    private var cancellables = Set<AnyCancellable>()
    private var clockTask: Task<Void, Never>?
    private var refCount = 0
    private var arenaJoined = false
    /// Claims already posted for a game - one is enough; the chain confirms it.
    private var claimedGames: Set<String> = []

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
        if let me = myAddress { resolveNames(for: [me]) }
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
        // Every change, not only a change in row COUNT: our own sends replace a pending row in
        // place when the transaction lands, so the count stays the same - and a count guard
        // here left a player's own leave (and moves) unapplied until the next unrelated row or
        // a relaunch. The publisher already drops identical arrays.
        let events: [ChessArenaEvent] = rows.compactMap { row in
            guard row.deliveryStatus == .sent, !row.id.hasPrefix("pending_"),
                  let message = ChessTournamentCodec.decode(row.content) else { return nil }
            return ChessArenaEvent(txId: row.id, sender: row.senderAddress, blockTime: row.blockTime, message: message)
        }
        let reduced = ChessTournamentEngine.reduce(events)
        tournaments = reduced
        pendingChat = rows.compactMap { row in
            guard row.deliveryStatus != .sent, row.senderAddress == myAddress,
                  let message = ChessTournamentCodec.decode(row.content), message.a == "chat",
                  let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let line = ChessTournamentChatLine(id: row.id, sender: row.senderAddress, text: text, blockTime: row.blockTime, game: message.g ?? "")
            return ChessPendingChatLine(id: row.id, tournament: message.t, line: line, failed: row.deliveryStatus == .failed)
        }
        leaderboard = ChessTournamentEngine.leaderboard(from: Array(reduced.values))
        resolveNames(for: Set(reduced.values.flatMap(\.players)))
        // Asked to join a public room that filled first: queue into the next one, once.
        if let queued = queuedPublicRoomId, let me = myAddress, let room = reduced[queued],
           room.isFull, !room.players.contains(me) {
            queuedPublicRoomId = nil
            let wasDuel = ChessTournamentCodec.duelNumber(of: queued) != nil
            Task { if wasDuel { await self.joinPublicDuelQueue() } else { await self.joinPublicQueue() } }
        } else if let queued = queuedPublicRoomId, let me = myAddress, reduced[queued]?.players.contains(me) == true {
            queuedPublicRoomId = nil
        }
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

    /// The public room taking players right now: the first numbered room that is not full.
    /// Its id exists before anyone has joined it (the first join creates it), so the lobby can
    /// always show "Public tournament #N" with its seats.
    var currentPublicRoomId: String {
        var number = 1
        while let room = tournaments[ChessTournamentCodec.publicId(number)], room.isFull { number += 1 }
        return ChessTournamentCodec.publicId(number)
    }
    var currentPublicRoom: ChessTournament? { tournaments[currentPublicRoomId] }

    /// The public 1v1 room taking players right now.
    var currentDuelRoomId: String {
        var number = 1
        while let room = tournaments[ChessTournamentCodec.duelId(number)], room.isFull { number += 1 }
        return ChessTournamentCodec.duelId(number)
    }
    var currentDuelRoom: ChessTournament? { tournaments[currentDuelRoomId] }

    /// Private 1v1s this player is in, still open or in play.
    var myPrivateDuels: [ChessTournament] {
        guard let me = myAddress else { return [] }
        return tournaments.values
            .filter { !$0.isPublic && $0.isDuel && ($0.status == .open || $0.status == .live) && $0.players.contains(me) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Private tournaments this player is in, still open or in play.
    var myPrivateTournaments: [ChessTournament] {
        guard let me = myAddress else { return [] }
        return tournaments.values
            .filter { !$0.isPublic && !$0.isDuel && ($0.status == .open || $0.status == .live) && $0.players.contains(me) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var openTournaments: [ChessTournament] {
        tournaments.values.filter { $0.status == .open }.sorted { $0.createdAt > $1.createdAt }
    }
    var liveTournaments: [ChessTournament] {
        tournaments.values.filter { $0.status == .live }.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }
    var finishedTournaments: [ChessTournament] {
        tournaments.values.filter { $0.status == .finished }.sorted { ($0.startedAt ?? 0) > ($1.startedAt ?? 0) }
    }

    /// The tournament this player is in that is not over, if any. A waiting seat that has
    /// expired does not count: the player is free to join elsewhere.
    var myActiveTournament: ChessTournament? {
        guard let me = myAddress else { return nil }
        return tournaments.values
            .filter { ($0.status == .live && $0.players.contains(me)) || ($0.status == .open && $0.isSeated(me, at: now)) }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    // MARK: - Names

    /// Addresses whose KNS profile was asked for this session.
    private var resolvedNames: Set<String> = []

    /// Names in the arena follow the app's rule - contact name, then KNS domain, then the
    /// shortened address (`ContactsManager.displayName`) - and the domain part needs the
    /// profile in `KNSService.profileCache`. Fetched once per address per session; the cache
    /// answers after that, and `KNSService` publishes so rows re-render when it lands.
    private func resolveNames(for addresses: Set<String>) {
        let fresh = addresses.subtracting(resolvedNames)
        guard !fresh.isEmpty else { return }
        resolvedNames.formUnion(fresh)
        let network = AppSettings.load().networkType
        for address in fresh {
            Task { _ = await KNSService.shared.fetchProfile(for: address, network: network) }
        }
    }

    // MARK: - Fees

    /// What sending `message` costs right now, as "0.0017 KAS", for a button label. An arena
    /// message is a fixed-size payload, so this is the same estimate the composer shows while
    /// typing, without a network round trip (one input, like every arena send).
    func feeText(for message: ChessTournamentMessage) -> String? {
        guard let wallet = WalletManager.shared.currentWallet,
              let senderScriptPubKey = KaspaAddress.scriptPublicKey(from: wallet.publicAddress) else { return nil }
        let payload = KasiaTransactionBuilder.buildBroadcastPayload(
            channel: ChessTournamentCodec.arenaChannel,
            content: ChessTournamentCodec.encode(message)
        )
        let sompi = KasiaTransactionBuilder.estimateBroadcastFee(payload: payload, inputCount: 1, senderScriptPubKey: senderScriptPubKey)
        // Four decimals: "0.0017 KAS" reads at a glance; the exact sompi is in the transaction.
        return String(format: "%.4f KAS", Double(sompi) / 100_000_000)
    }

    /// The join button's label: "Join (Fee: 0.0017 KAS)".
    func joinLabel(roomId: String) -> String {
        guard let fee = feeText(for: ChessTournamentCodec.join(id: roomId)) else { return "Join" }
        return "Join (Fee: \(fee))"
    }

    // MARK: - Actions (each one a broadcast transaction)

    /// Joins the public room taking players now. If that room fills before this join lands
    /// (someone else got the last seat), `reduce` notices and joins the next room.
    func joinPublicQueue() async {
        await joinPublicRoom(id: currentPublicRoomId)
    }

    /// The seat that ran out is still in `players` until the next join drops it (the engine
    /// judges that at the join's block time) - so "already in" means seated NOW, never the
    /// stale list, or a returning player's tap would do nothing at all.
    private func joinPublicRoom(id: String) async {
        guard let me = myAddress else { return }
        if let busy = myActiveTournament {
            lastError = busy.status == .open ? "You're already waiting in \(busy.name)." : "You're still playing in \(busy.name)."
            return
        }
        if let room = tournaments[id], room.isSeated(me, at: now) {
            lastError = "You're already in this room."
            return
        }
        queuedPublicRoomId = id
        _ = await send(ChessTournamentCodec.join(id: id))
    }

    /// The room this player asked to join and is waiting to appear in.
    private var queuedPublicRoomId: String?

    /// Joins the public 1v1 room taking players now; same race handling as the tournaments.
    func joinPublicDuelQueue() async {
        await joinPublicRoom(id: currentDuelRoomId)
    }

    /// A private 1v1 for a friend: no creator code, an eight-character code to share.
    func createPrivateDuel(named name: String) async -> String? {
        let id = ChessTournamentCodec.newPrivateId()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await send(ChessTournamentCodec.createDuel(id: id, name: clean.isEmpty ? "1v1" : clean)) else { return nil }
        return id
    }

    /// A private tournament for friends. Needs the creator code; returns nil (with a message)
    /// when it is wrong, without sending anything.
    func createPrivateTournament(named name: String, code: String) async -> String? {
        guard ChessTournamentCodec.isValidCreateKey(ChessTournamentCodec.createKey(code: code, id: "check"), id: "check") else {
            lastError = "That creator code is not right."
            return nil
        }
        let id = ChessTournamentCodec.newPrivateId()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard await send(ChessTournamentCodec.create(id: id, name: clean.isEmpty ? "Private tournament" : clean, code: code)) else { return nil }
        return id
    }

    /// Joins a friend's private tournament by its code (the tournament id).
    func joinPrivate(code raw: String) async -> Bool {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let tournament = tournaments[id], !tournament.isPublic else {
            lastError = "No open tournament with that code. Codes are eight characters; the tournament must exist and still have seats."
            return false
        }
        guard tournament.status == .open else { lastError = "That tournament has already started."; return false }
        await join(tournament)
        return true
    }

    func join(_ tournament: ChessTournament) async {
        guard let me = myAddress, tournament.status == .open else { return }
        if tournament.isSeated(me, at: now) { lastError = "You're already in this room."; return }
        if let busy = myActiveTournament, busy.id != tournament.id {
            lastError = busy.status == .open ? "You're already waiting in \(busy.name)." : "You're still playing in \(busy.name)."
            return
        }
        _ = await send(ChessTournamentCodec.join(id: tournament.id))
    }

    /// Gives the seat back while the room is still waiting (one transaction).
    func leave(_ tournament: ChessTournament) async {
        guard let me = myAddress, tournament.status == .open, tournament.isSeated(me, at: now) else { return }
        queuedPublicRoomId = nil
        _ = await send(ChessTournamentCodec.leave(id: tournament.id))
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
