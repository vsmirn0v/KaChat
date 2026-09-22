import SwiftUI

/// Kaspa Hub > Chess: the lobby. Your tournament first (if you are in one), then open rooms
/// waiting for players, tournaments in play (anyone can watch), recent results, and the
/// leaderboard. Every row reads from `ChessTournamentService`, which reduces the arena the
/// moment a screen here is up.
struct ChessTournamentsView: View {
    @ObservedObject private var service = ChessTournamentService.shared
    @ObservedObject private var knsService = KNSService.shared
    @EnvironmentObject private var walletManager: WalletManager
    @State private var showCreate = false
    @State private var newName = ""
    @State private var isCreating = false
    @State private var openTournamentId: String?
    @State private var showLeaderboard = false

    var body: some View {
        NavigationStack {
            List {
                if let mine = service.myActiveTournament {
                    Section("Your tournament") {
                        tournamentRow(mine, action: mine.status == .open ? "Waiting for players" : "In play")
                    }
                }
                Section {
                    let open = service.openTournaments.filter { $0.id != service.myActiveTournament?.id }
                    if open.isEmpty {
                        Text("No one is waiting for players right now. Start a tournament and seven others can join.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    ForEach(open) { tournament in
                        tournamentRow(tournament, action: "\(tournament.seatsLeft) seat\(tournament.seatsLeft == 1 ? "" : "s") left")
                    }
                } header: {
                    Text("Open")
                } footer: {
                    Text("Eight players, single elimination, five minutes a side. Every move is a Kaspa transaction (about 0.0017 KAS each).")
                }
                let live = service.liveTournaments.filter { $0.id != service.myActiveTournament?.id }
                if !live.isEmpty {
                    Section("In play") {
                        ForEach(live) { tournament in
                            tournamentRow(tournament, action: "Watch")
                        }
                    }
                }
                let done = Array(service.finishedTournaments.prefix(20))
                if !done.isEmpty {
                    Section("Finished") {
                        ForEach(done) { tournament in
                            tournamentRow(tournament, action: tournament.champion.map { "Won by \(name(for: $0))" } ?? "Finished")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chess")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { ConnectionStatusIndicator() }
                ToolbarItem(placement: .principal) { BalanceToolbarLabel() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showLeaderboard = true
                    } label: {
                        Image(systemName: "trophy")
                    }
                    .accessibilityLabel("Leaderboard")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if service.myActiveTournament == nil {
                    Button {
                        Haptics.impact(.light)
                        newName = ""
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .frame(width: 56, height: 56)
                            .background(
                                Circle()
                                    .fill(.regularMaterial)
                                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                                    .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                            )
                    }
                    .accessibilityLabel("Start a tournament")
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { openTournamentId != nil },
                set: { if !$0 { openTournamentId = nil } }
            )) {
                if let id = openTournamentId {
                    ChessTournamentView(tournamentId: id)
                }
            }
            .navigationDestination(isPresented: $showLeaderboard) {
                ChessLeaderboardView()
            }
            .alert("Start a tournament", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button(isCreating ? "Starting…" : "Start") {
                    guard !isCreating else { return }
                    isCreating = true
                    Task {
                        if let id = await service.createTournament(named: newName) {
                            openTournamentId = id
                        }
                        isCreating = false
                    }
                }
            } message: {
                Text("You take the first seat. The tournament starts the moment eight players have joined. Creating it is one transaction.")
            }
            .toast(message: service.lastError, style: .error)
            .onAppear { service.acquire() }
            .onDisappear { service.release() }
        }
    }

    private func name(for address: String) -> String {
        if address == walletManager.currentWallet?.publicAddress { return "You" }
        return ContactsManager.shared.displayName(for: address)
    }

    private func tournamentRow(_ tournament: ChessTournament, action: String) -> some View {
        Button {
            openTournamentId = tournament.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tournament.status == .finished ? "trophy.fill" : "checkerboard.rectangle")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tournament.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(tournament.players.count) of \(ChessTournamentCodec.playerCount) players · by \(name(for: tournament.creator))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(action)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Wins, losses and titles for every address seen in the arena. The indexer's version
/// (CHESS_TOURNAMENTS.md §6) will cover all history; this is what the phone has read.
struct ChessLeaderboardView: View {
    @ObservedObject private var service = ChessTournamentService.shared
    @EnvironmentObject private var walletManager: WalletManager

    var body: some View {
        List {
            if service.leaderboard.isEmpty {
                Text("No finished games yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ForEach(Array(service.leaderboard.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    KNSAvatarView(
                        avatarURLString: KNSService.shared.profileCache[row.address]?.avatarURL,
                        fallbackText: ContactsManager.shared.displayName(for: row.address),
                        size: 36,
                        contactAddress: row.address
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.address == walletManager.currentWallet?.publicAddress ? "You" : ContactsManager.shared.displayName(for: row.address))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(row.wins)W · \(row.losses)L · \(row.tournamentsPlayed) played")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if row.tournamentsWon > 0 {
                        Label("\(row.tournamentsWon)", systemImage: "trophy.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { service.acquire() }
        .onDisappear { service.release() }
    }
}
