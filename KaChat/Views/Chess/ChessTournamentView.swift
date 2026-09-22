import SwiftUI

/// One tournament: the bracket, the players, and the lobby chat. A player is taken straight to
/// their game the moment it exists (round 1 at the eighth join; later rounds when the pair's
/// other game ends), and can tap any game to watch it meanwhile.
struct ChessTournamentView: View {
    let tournamentId: String
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var openGameId: String?
    @State private var autoOpenedGameId: String?
    @State private var chatText = ""
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
        .onAppear { autoOpenMyGameIfNeeded() }
    }

    private func autoOpenMyGameIfNeeded() {
        guard let tournament, let me, let game = tournament.currentGame(for: me), !game.isOver,
              autoOpenedGameId != game.id else { return }
        autoOpenedGameId = game.id
        openGameId = game.id
    }

    private func name(for address: String) -> String {
        if address == me { return "You" }
        return ContactsManager.shared.displayName(for: address)
    }

    @ViewBuilder
    private func content(_ tournament: ChessTournament) -> some View {
        List {
            Section {
                statusRow(tournament)
            }
            if tournament.status == .open {
                Section("Players (\(tournament.players.count) of \(tournament.capacity))") {
                    ForEach(Array(tournament.players.enumerated()), id: \.offset) { index, address in
                        playerRow(seed: index + 1, address: address)
                    }
                    ForEach(0..<tournament.seatsLeft, id: \.self) { _ in
                        HStack(spacing: 12) {
                            Circle().strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .frame(width: 36, height: 36)
                            Text("Open seat").foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                ForEach(Array(1...tournament.rounds), id: \.self) { round in
                    let games = tournament.games(inRound: round)
                    if !games.isEmpty {
                        Section(tournament.isDuel ? "Game" : (round == 3 ? "Final" : (round == 2 ? "Semifinals" : "Round 1"))) {
                            ForEach(games) { game in
                                gameRow(game, tournament: tournament)
                            }
                        }
                    }
                }
            }
            Section("Lobby chat") {
                let lines = tournament.chat.filter { $0.game.isEmpty }.suffix(50)
                if lines.isEmpty {
                    Text("Say hello.").font(.subheadline).foregroundColor(.secondary)
                }
                ForEach(Array(lines)) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(for: line.sender)).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        Text(line.text).font(.subheadline)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Message (one transaction)", text: $chatText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendChat(tournament) }
                    Button {
                        sendChat(tournament)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(chatText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func sendChat(_ tournament: ChessTournament) {
        let text = chatText
        chatText = ""
        Task { await service.sendChat(text, tournament: tournament, game: nil) }
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
                if let me, !tournament.players.contains(me) {
                    Button {
                        guard !isJoining else { return }
                        isJoining = true
                        Task { await service.join(tournament); isJoining = false }
                    } label: {
                        Text(isJoining ? "Joining…" : "Join (one transaction)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                } else if tournament.creator == me, !tournament.isPublic {
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
                        ShareLink(item: "Join my KaChat chess tournament: open Kaspa Hub > Chess > Join with a code, and enter \(tournament.id)") {
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
