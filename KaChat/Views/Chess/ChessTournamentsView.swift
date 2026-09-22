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
    @State private var creatorCode = ""
    @State private var isCreating = false
    @State private var showJoinPrivate = false
    @State private var privateCode = ""
    @State private var isJoining = false
    @State private var openTournamentId: String?
    @State private var showLeaderboard = false

    private var me: String? { walletManager.currentWallet?.publicAddress }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    publicRoomCard
                } header: {
                    Text("Public")
                } footer: {
                    Text("There is always a public room waiting for players. When it fills, it starts and the next one opens. Eight players, single elimination, five minutes a side. Every move is a Kaspa transaction (about 0.0017 KAS each).")
                }
                Section {
                    ForEach(service.myPrivateTournaments) { tournament in
                        tournamentRow(tournament, action: tournament.status == .open ? "\(tournament.seatsLeft) seat\(tournament.seatsLeft == 1 ? "" : "s") left" : "In play")
                    }
                    Button {
                        privateCode = ""
                        showJoinPrivate = true
                    } label: {
                        Label("Join with a code", systemImage: "key")
                    }
                    Button {
                        newName = ""
                        creatorCode = ""
                        showCreate = true
                    } label: {
                        Label("Create a private tournament", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Private")
                } footer: {
                    Text("A private tournament is for friends: the creator shares its eight-character code. Creating one needs the creator code.")
                }
                let live = service.liveTournaments.filter { $0.isPublic && $0.id != service.myActiveTournament?.id }
                if !live.isEmpty {
                    Section("In play") {
                        ForEach(live) { tournament in
                            tournamentRow(tournament, action: "Watch")
                        }
                    }
                }
                let done = Array(service.finishedTournaments.filter { $0.isPublic }.prefix(20))
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
            .alert("Create a private tournament", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                TextField("Creator code", text: $creatorCode)
                Button("Cancel", role: .cancel) {}
                Button(isCreating ? "Creating…" : "Create") {
                    guard !isCreating else { return }
                    isCreating = true
                    Task {
                        if let id = await service.createPrivateTournament(named: newName, code: creatorCode) {
                            openTournamentId = id
                        }
                        isCreating = false
                    }
                }
            } message: {
                Text("You take the first seat and get a code to share. It starts when eight players have joined. Creating it is one transaction.")
            }
            .alert("Join a private tournament", isPresented: $showJoinPrivate) {
                TextField("Code", text: $privateCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button(isJoining ? "Joining…" : "Join") {
                    guard !isJoining else { return }
                    isJoining = true
                    Task {
                        if await service.joinPrivate(code: privateCode) {
                            openTournamentId = privateCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        }
                        isJoining = false
                    }
                }
            } message: {
                Text("The eight-character code the creator shared. Joining is one transaction.")
            }
            .toast(message: service.lastError, style: .error)
            .onAppear { service.acquire() }
            .onDisappear { service.release() }
        }
    }

    /// The one public room taking players: its seats, and Join - or "you're in" once joined.
    private var publicRoomCard: some View {
        let room = service.currentPublicRoom
        let number = ChessTournamentCodec.publicNumber(of: service.currentPublicRoomId) ?? 1
        let count = room?.players.count ?? 0
        let inThisRoom = me.map { room?.players.contains($0) ?? false } ?? false
        let busyElsewhere = service.myActiveTournament != nil && !inThisRoom
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "person.3.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Public tournament #\(number)").font(.headline)
                    Text("\(count) of \(ChessTournamentCodec.playerCount) players waiting").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(0..<ChessTournamentCodec.playerCount, id: \.self) { seat in
                    Circle()
                        .fill(seat < count ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 12, height: 12)
                }
            }
            if inThisRoom, let room {
                Button {
                    openTournamentId = room.id
                } label: {
                    Text("You're in. Waiting for \(room.seatsLeft) more…")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else if let mine = service.myActiveTournament, busyElsewhere {
                Button {
                    openTournamentId = mine.id
                } label: {
                    Text(mine.status == .open ? "You're waiting in \(mine.name)" : "You're playing in \(mine.name)")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    guard !isJoining else { return }
                    Haptics.impact(.light)
                    isJoining = true
                    Task { await service.joinPublicQueue(); isJoining = false }
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
            }
        }
        .padding(.vertical, 4)
    }

    private func name(for address: String) -> String {
        if address == me { return "You" }
        return ContactsManager.shared.displayName(for: address)
    }

    private func tournamentRow(_ tournament: ChessTournament, action: String) -> some View {
        Button {
            openTournamentId = tournament.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tournament.status == .finished ? "trophy.fill" : (tournament.isPublic ? "person.3.fill" : "lock.fill"))
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tournament.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(tournament.players.count) of \(ChessTournamentCodec.playerCount) players" + (tournament.isPublic ? "" : " · code \(tournament.id)"))
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
