import SwiftUI

/// One tournament: the bracket and the players. A player is taken straight to their game the
/// moment it exists (round 1 at the eighth join; later rounds when the pair's other game ends),
/// and can tap any game to watch it meanwhile. Waiting for a room to fill happens in
/// ChessWaitingRoomView, which covers everything until it does.
struct ChessTournamentView: View {
    let tournamentId: String
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var openGameId: String?
    @State private var autoOpenedGameId: String?
    @State private var isJoining = false
    @State private var showCancelConfirm = false

    private var tournament: ChessTournament? { service.tournaments[tournamentId] }
    private var me: String? { walletManager.currentWallet?.publicAddress }

    var body: some View {
        Group {
            if let tournament {
                content(tournament)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading the tournament from the arena…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(tournament?.name ?? "Tournament")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
        }
        .navigationDestination(isPresented: Binding(
            get: { openGameId != nil },
            set: { if !$0 { openGameId = nil } }
        )) {
            if let gameId = openGameId {
                ChessTournamentGameView(tournamentId: tournamentId, gameId: gameId)
            }
        }
        .onAppear { service.acquire() }
        .onDisappear { service.release() }
        // The player's game came into being: open it (once per game).
        .onChange(of: tournament?.games.count) { _ in autoOpenMyGameIfNeeded() }
        .onChange(of: service.now) { _ in autoOpenMyGameIfNeeded() }
        .onAppear { autoOpenMyGameIfNeeded() }
    }

    /// The player's next game, waiting on its cool-down: it opens at its start block time plus
    /// `matchFoundDelayMs` - ten seconds on the bracket, the same instant for both players -
    /// and immediately when a player arrives after that.
    private var nextGameCountdownMs: Int64? {
        guard let tournament, let me, let game = tournament.currentGame(for: me), !game.isOver else { return nil }
        let left = game.startedAt + ChessTournamentCodec.matchFoundDelayMs - service.now
        return left > 0 ? left : nil
    }

    private func autoOpenMyGameIfNeeded() {
        guard let tournament, let me, let game = tournament.currentGame(for: me), !game.isOver,
              autoOpenedGameId != game.id, nextGameCountdownMs == nil else { return }
        autoOpenedGameId = game.id
        Haptics.success()
        openGameId = game.id
    }

    /// Contact name, then KNS domain, then the shortened address - for the player too.
    private func name(for address: String) -> String {
        ContactsManager.shared.displayName(for: address)
    }

    @ViewBuilder
    private func content(_ tournament: ChessTournament) -> some View {
        List {
            Section {
                statusRow(tournament)
            }
            if tournament.status == .open {
                let seated = tournament.seatedPlayers(at: service.now)
                Section("Players (\(seated.count) of \(tournament.capacity))") {
                    ForEach(Array(seated.enumerated()), id: \.offset) { index, address in
                        playerRow(seed: index + 1, address: address)
                    }
                    ForEach(0..<max(0, tournament.capacity - seated.count), id: \.self) { _ in
                        HStack(spacing: 12) {
                            Circle().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: 36, height: 36)
                            Text("Open seat").foregroundColor(.secondary)
                        }
                    }
                }
            } else if tournament.isDuel {
                Section("Game") {
                    ForEach(tournament.games(inRound: 1)) { game in
                        gameRow(game, tournament: tournament)
                    }
                }
            } else {
                Section {
                    ChessBracketView(tournament: tournament, me: me, now: service.now) { gameId in
                        openGameId = gameId
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Bracket · tap a game to watch")
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Cancel this tournament?", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Cancel tournament", role: .destructive) { Task { await service.cancel(tournament) } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Everyone who joined is released. This is one transaction.")
        }
        .toast(message: service.lastError, style: .error)
    }

    @ViewBuilder
    private func statusRow(_ tournament: ChessTournament) -> some View {
        switch tournament.status {
        case .open:
            VStack(alignment: .leading, spacing: 8) {
                Text(tournament.isDuel
                     ? "Waiting for your opponent. The game starts by itself when they join."
                     : "Waiting for \(tournament.seatsLeft) more player\(tournament.seatsLeft == 1 ? "" : "s"). It starts by itself when the eighth joins.")
                    .font(.subheadline)
                if let me, !tournament.isSeated(me, at: service.now) {
                    Button {
                        guard !isJoining else { return }
                        isJoining = true
                        Task { await service.join(tournament); isJoining = false }
                    } label: {
                        Text(isJoining ? "Joining…" : service.joinLabel(roomId: tournament.id))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
                if tournament.creator == me, !tournament.isPublic {
                    Button("Cancel tournament", role: .destructive) { showCancelConfirm = true }
                        .font(.subheadline)
                }
                if !tournament.isPublic {
                    HStack(spacing: 8) {
                        Text("Code: \(tournament.id)")
                            .font(.subheadline.monospaced().weight(.semibold))
                        Spacer()
                        Button {
                            UIPasteboard.general.string = tournament.id
                            Haptics.success()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.caption.weight(.semibold))
                        }
                        ShareLink(item: "Join my KaChat chess tournament: open Kaspa Hub > Chess Online > \(tournament.isDuel ? "1v1" : "Tournaments") > Join with a code, and enter \(tournament.id)") {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .padding(.top, 4)
                }
            }
        case .live:
            if let me, let game = tournament.currentGame(for: me) {
                if game.isOver {
                    if game.winner == me {
                        Text("You won \(roundName(game.round)). Waiting for your next opponent - watch the other game meanwhile.")
                            .font(.subheadline)
                    } else {
                        Text("You are out of this tournament. Watch the rest of the bracket.")
                            .font(.subheadline)
                    }
                } else if let left = nextGameCountdownMs {
                    // Cool-down on the bracket before the next round: who it is, and when.
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Next: \(roundName(game.round)) vs \(name(for: game.address(of: game.color(of: me) == .white ? .black : .white)))")
                                .font(.subheadline.weight(.semibold))
                            Text("Your game starts in")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(Int((left + 999) / 1000))")
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.accentColor)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.2), value: Int((left + 999) / 1000))
                    }
                } else {
                    Button {
                        openGameId = game.id
                    } label: {
                        Label("Go to your game", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            } else {
                Text("In play. Tap any game to watch it live.")
                    .font(.subheadline)
            }
        case .finished:
            if let champion = tournament.champion {
                Label(tournament.isDuel ? "\(name(for: champion)) won" : "\(name(for: champion)) won the tournament", systemImage: "trophy.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.yellow)
            }
        case .cancelled:
            Text("Cancelled by the creator.").font(.subheadline).foregroundColor(.secondary)
        }
    }

    private func roundName(_ round: Int) -> String {
        guard let tournament, !tournament.isDuel else { return "the game" }
        return round == 3 ? "the final" : (round == 2 ? "the semifinal" : "round 1")
    }

    private func playerRow(seed: Int, address: String) -> some View {
        HStack(spacing: 12) {
            KNSAvatarView(
                avatarURLString: KNSService.shared.profileCache[address]?.avatarURL,
                fallbackText: ContactsManager.shared.displayName(for: address),
                size: 36,
                contactAddress: address
            )
            Text(name(for: address)).font(.subheadline.weight(.semibold))
            Spacer()
            Text("Seed \(seed)").font(.caption).foregroundColor(.secondary)
        }
    }

    private func gameRow(_ game: ChessTournamentGame, tournament: ChessTournament) -> some View {
        Button {
            openGameId = game.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name(for: game.white)).fontWeight(game.winner == game.white ? .bold : .regular)
                        Text("vs").foregroundColor(.secondary)
                        Text(name(for: game.black)).fontWeight(game.winner == game.black ? .bold : .regular)
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                    Text(gameStatus(game)).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !game.isOver {
                    Text(clockText(game.remainingMs(game.sideToMove, at: service.now)))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func gameStatus(_ game: ChessTournamentGame) -> String {
        guard let winner = game.winner, let outcome = game.outcome else {
            return "Move \(game.moves.count / 2 + 1) · \(game.sideToMove == .white ? "white" : "black") to move"
        }
        let who = name(for: winner)
        switch outcome {
        case .checkmate: return "\(who) won by checkmate"
        case .resignation: return "\(who) won by resignation"
        case .timeout: return "\(who) won on time"
        case .drawTiebreak(let reason): return "\(who) won on clock after a draw (\(reason))"
        }
    }

    private func clockText(_ ms: Int64) -> String {
        let seconds = Int(ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
